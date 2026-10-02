// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: AXI5 atomic-transaction unit in front of a memory port.
//              Non-atomic traffic passes through. An atomic write (awatop != 0,
//              single beat) is executed as read-modify-write on the slave: read
//              the old value, apply the operation, write the result, then answer
//              B and, for AtomicLoad/Swap/Compare, one R beat with the old value.
//              One atomic at a time; pass-through traffic drains before an
//              atomic starts and is held while it runs.
//              Limits: single-beat, little-endian atomics only; a multi-beat
//              (awlen != 0) or big-endian (awatop[3]) atomic is answered SLVERR
//              on B and R without touching the slave. AtomicCompare writes the
//              old value back on mismatch (memory unchanged).
//              Precondition: an atomic's W is presented only after its AW has
//              been accepted (simplyv_axi_xbar guarantees it).

module simplyv_axi_atomics #(
    parameter int unsigned DATA_WIDTH  = 32,
    parameter int unsigned ADDR_WIDTH  = 32,
    parameter int unsigned ID_WIDTH    = 4,
    // pass-through transactions open per channel on the slave, at most
    parameter int unsigned MAX_PENDING = 15,
    localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8,
    localparam int unsigned PEND_W     = $clog2(MAX_PENDING + 1)
) (
    input  logic                  aclk,
    input  logic                  aresetn,

    input  logic [ID_WIDTH-1:0]   s_axi_awid,
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [7:0]            s_axi_awlen,
    input  logic [2:0]            s_axi_awsize,
    input  logic [1:0]            s_axi_awburst,
    input  logic                  s_axi_awlock,
    input  logic [3:0]            s_axi_awcache,
    input  logic [2:0]            s_axi_awprot,
    input  logic [3:0]            s_axi_awqos,
    input  logic [5:0]            s_axi_awatop,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [STRB_WIDTH-1:0] s_axi_wstrb,
    input  logic                  s_axi_wlast,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    output logic [ID_WIDTH-1:0]   s_axi_bid,
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,
    input  logic [ID_WIDTH-1:0]   s_axi_arid,
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [7:0]            s_axi_arlen,
    input  logic [2:0]            s_axi_arsize,
    input  logic [1:0]            s_axi_arburst,
    input  logic                  s_axi_arlock,
    input  logic [3:0]            s_axi_arcache,
    input  logic [2:0]            s_axi_arprot,
    input  logic [3:0]            s_axi_arqos,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    output logic [ID_WIDTH-1:0]   s_axi_rid,
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rlast,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,

    output logic [ID_WIDTH-1:0]   m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awlock,
    output logic [3:0]            m_axi_awcache,
    output logic [2:0]            m_axi_awprot,
    output logic [3:0]            m_axi_awqos,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [DATA_WIDTH-1:0] m_axi_wdata,
    output logic [STRB_WIDTH-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    input  logic [ID_WIDTH-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    output logic [ID_WIDTH-1:0]   m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arlock,
    output logic [3:0]            m_axi_arcache,
    output logic [2:0]            m_axi_arprot,
    output logic [3:0]            m_axi_arqos,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    input  logic [ID_WIDTH-1:0]   m_axi_rid,
    input  logic [DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready
);

    typedef enum logic [3:0] {IDLE, AT_W, AT_AR, AT_R, AT_AW, AT_B, AT_RESP_B, AT_RESP_R} state_t;
    state_t state;

    // pass-through transactions still open on the slave
    logic [PEND_W-1:0] wr_pend, rd_pend;
    logic              pt_idle, is_atomic;
    // W in IDLE always belongs to a plain write (see the precondition above).
    // A new pass-through AR is held off while an atomic waits; one already
    // presented (ar_hold) stays stable until accepted.
    logic       ar_hold;
    logic       ar_present;
    assign pt_idle    = (wr_pend == '0) && (rd_pend == '0) && !ar_hold;
    assign is_atomic  = s_axi_awvalid && (s_axi_awatop != 6'd0);
    assign ar_present = (state == IDLE) && s_axi_arvalid && (!is_atomic || ar_hold);

    // captured atomic
    logic [ID_WIDTH-1:0]   at_id;
    logic [ADDR_WIDTH-1:0] at_addr;
    logic [2:0]            at_size;
    logic [5:0]            at_op;
    logic [DATA_WIDTH-1:0] at_wdata, at_old, at_new;
    logic [STRB_WIDTH-1:0] at_strb;
    logic [1:0]            at_resp;
    logic                  at_err;      // unsupported atomic: SLVERR, slave untouched
    logic [7:0]            at_rcnt;     // R beats left after the current one
    // AT_AW presents the RMW's AW and W together; each handshake is tracked.
    logic                  at_aw_done, at_w_done;

    logic pt_aw_hs, pt_b_hs, pt_ar_hs, pt_r_hs;
    assign pt_aw_hs = (state == IDLE) && !is_atomic && s_axi_awvalid && s_axi_awready;
    assign pt_b_hs  = m_axi_bvalid && m_axi_bready && (state != AT_B);
    assign pt_ar_hs = (state == IDLE) && s_axi_arvalid && s_axi_arready;
    assign pt_r_hs  = m_axi_rvalid && m_axi_rready && m_axi_rlast && (state != AT_R);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state <= IDLE; wr_pend <= '0; rd_pend <= '0; ar_hold <= 1'b0;
            at_id <= '0; at_addr <= '0; at_size <= '0; at_op <= '0; at_wdata <= '0; at_old <= '0; at_resp <= '0;
            at_err <= 1'b0; at_rcnt <= '0; at_aw_done <= 1'b0; at_w_done <= 1'b0;
        end else begin
            wr_pend <= wr_pend + PEND_W'(pt_aw_hs) - PEND_W'(pt_b_hs);
            rd_pend <= rd_pend + PEND_W'(pt_ar_hs) - PEND_W'(pt_r_hs);
            ar_hold <= ar_present && !m_axi_arready;
            case (state)
                IDLE: if (is_atomic && pt_idle) begin
                    at_id <= s_axi_awid; at_addr <= s_axi_awaddr; at_size <= s_axi_awsize; at_op <= s_axi_awatop;
                    at_err  <= (s_axi_awlen != 8'd0) || s_axi_awatop[3];
                    at_resp <= ((s_axi_awlen != 8'd0) || s_axi_awatop[3]) ? 2'b10 : 2'b00;
                    // AtomicCompare returns half as many R beats as W beats
                    at_rcnt <= (s_axi_awatop == 6'b110001 && s_axi_awlen != 8'd0) ?
                               8'((s_axi_awlen + 9'd1) >> 1) - 8'd1 : s_axi_awlen;
                    state <= AT_W;
                end
                AT_W: if (s_axi_wvalid) begin
                    at_wdata <= s_axi_wdata;
                    if (!at_err)          state <= AT_AR;
                    else if (s_axi_wlast) state <= AT_RESP_B;
                end
                AT_AR:     if (m_axi_arready) state <= AT_R;
                AT_R:      if (m_axi_rvalid) begin
                    at_old <= m_axi_rdata; at_resp <= m_axi_rresp; state <= AT_AW;
                    at_aw_done <= 1'b0; at_w_done <= 1'b0;
                end
                AT_AW: begin
                    if (m_axi_awvalid && m_axi_awready) at_aw_done <= 1'b1;
                    if (m_axi_wvalid  && m_axi_wready)  at_w_done  <= 1'b1;
                    if ((at_aw_done || (m_axi_awvalid && m_axi_awready)) &&
                        (at_w_done  || (m_axi_wvalid  && m_axi_wready)))
                        state <= AT_B;
                end
                AT_B:      if (m_axi_bvalid) begin at_resp <= at_resp | m_axi_bresp; state <= AT_RESP_B; end
                AT_RESP_B: if (s_axi_bready) state <= at_op[5] ? AT_RESP_R : IDLE;
                AT_RESP_R: if (s_axi_rready) begin
                    if (at_rcnt == '0) state <= IDLE;
                    else               at_rcnt <= at_rcnt - 8'd1;
                end
                default:   state <= IDLE;
            endcase
        end
    end

    /////////
    // ALU //
    /////////

    localparam int unsigned OFF_W = (STRB_WIDTH > 1) ? $clog2(STRB_WIDTH) : 1;
    logic [OFF_W-1:0]      lane, swap_lane;
    int unsigned           nbits, half, op_bytes;
    logic [DATA_WIDTH-1:0] mask_w, hmask, old_w, wd_w, res_w, mask_full, swap_wd;

    function automatic logic sgt(input logic [DATA_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] b, input int unsigned n);
        logic sa = a[n-1], sb = b[n-1];
        sgt = (sa != sb) ? sb : (a > b);
    endfunction

    always_comb begin
        lane   = (STRB_WIDTH > 1) ? at_addr[OFF_W-1:0] : '0;
        nbits  = 8 << at_size;
        half   = nbits / 2;
        mask_w = (nbits >= DATA_WIDTH) ? '1 : ((DATA_WIDTH'(1) << nbits) - 1'b1);
        hmask  = (DATA_WIDTH'(1) << half) - 1'b1;
        old_w  = (at_old   >> (8 * lane)) & mask_w;
        wd_w   = (at_wdata >> (8 * lane)) & mask_w;
        // Compare: the swap value sits in the other half of the aligned pair.
        op_bytes  = half >> 3;
        swap_lane = (OFF_W'(op_bytes) != '0) ? (lane ^ OFF_W'(op_bytes)) : lane;
        swap_wd   = (at_wdata >> (8 * swap_lane)) & hmask;
        res_w  = old_w;
        if (at_op[5:4] == 2'b11) begin
            if (at_op[0]) begin                      // Compare: compare at the addressed half, swap at the other half
                res_w  = ((old_w & hmask) == (wd_w & hmask)) ? swap_wd : (old_w & hmask);
                mask_w = hmask;
            end else begin                           // Swap
                res_w = wd_w;
            end
        end else begin
            case (at_op[2:0])
                3'b000:  res_w = (old_w + wd_w) & mask_w;
                3'b001:  res_w = old_w & ~wd_w;
                3'b010:  res_w = old_w ^ wd_w;
                3'b011:  res_w = old_w | wd_w;
                3'b100:  res_w = sgt(old_w, wd_w, nbits) ? old_w : wd_w;
                3'b101:  res_w = sgt(old_w, wd_w, nbits) ? wd_w  : old_w;
                3'b110:  res_w = (old_w > wd_w) ? old_w : wd_w;
                default: res_w = (old_w > wd_w) ? wd_w  : old_w;
            endcase
        end
        mask_full = mask_w << (8 * lane);
        at_new    = (at_old & ~mask_full) | ((res_w & mask_w) << (8 * lane));
        for (int b = 0; b < STRB_WIDTH; b++) at_strb[b] = mask_full[8*b];
    end

    ///////////////
    // Channels  //
    ///////////////

    always_comb begin
        // pass-through defaults
        m_axi_awid = s_axi_awid; m_axi_awaddr = s_axi_awaddr; m_axi_awlen = s_axi_awlen; m_axi_awsize = s_axi_awsize;
        m_axi_awburst = s_axi_awburst; m_axi_awlock = s_axi_awlock; m_axi_awcache = s_axi_awcache; m_axi_awprot = s_axi_awprot; m_axi_awqos = s_axi_awqos;
        m_axi_awvalid = (state == IDLE) && s_axi_awvalid && !is_atomic;
        s_axi_awready = (state == IDLE) && (is_atomic ? pt_idle : m_axi_awready);

        m_axi_wdata = s_axi_wdata; m_axi_wstrb = s_axi_wstrb; m_axi_wlast = s_axi_wlast;
        m_axi_wvalid = (state == IDLE) && s_axi_wvalid;
        s_axi_wready = (state == AT_W) ? 1'b1 : ((state == IDLE) ? m_axi_wready : 1'b0);

        s_axi_bid = m_axi_bid; s_axi_bresp = m_axi_bresp;
        s_axi_bvalid = m_axi_bvalid && (state != AT_B);
        m_axi_bready = (state == AT_B) ? 1'b1 : s_axi_bready;

        m_axi_arid = s_axi_arid; m_axi_araddr = s_axi_araddr; m_axi_arlen = s_axi_arlen; m_axi_arsize = s_axi_arsize;
        m_axi_arburst = s_axi_arburst; m_axi_arlock = s_axi_arlock; m_axi_arcache = s_axi_arcache; m_axi_arprot = s_axi_arprot; m_axi_arqos = s_axi_arqos;
        m_axi_arvalid = ar_present;
        s_axi_arready = ar_present && m_axi_arready;

        s_axi_rid = m_axi_rid; s_axi_rdata = m_axi_rdata; s_axi_rresp = m_axi_rresp; s_axi_rlast = m_axi_rlast;
        s_axi_rvalid = m_axi_rvalid && (state != AT_R);
        m_axi_rready = (state == AT_R) ? 1'b1 : s_axi_rready;

        case (state)
            AT_AR: begin
                m_axi_arvalid = 1'b1; m_axi_arid = at_id; m_axi_araddr = at_addr; m_axi_arlen = 8'd0; m_axi_arsize = at_size;
                m_axi_arburst = 2'b01; m_axi_arlock = 1'b0; m_axi_arcache = '0; m_axi_arprot = '0; m_axi_arqos = '0;
            end
            AT_AW: begin
                m_axi_awvalid = !at_aw_done; m_axi_awid = at_id; m_axi_awaddr = at_addr; m_axi_awlen = 8'd0; m_axi_awsize = at_size;
                m_axi_awburst = 2'b01; m_axi_awlock = 1'b0; m_axi_awcache = '0; m_axi_awprot = '0; m_axi_awqos = '0;
                m_axi_wvalid = !at_w_done; m_axi_wdata = at_new; m_axi_wstrb = at_strb; m_axi_wlast = 1'b1;
            end
            AT_RESP_B: begin
                s_axi_bvalid = 1'b1; s_axi_bid = at_id; s_axi_bresp = at_resp;
            end
            AT_RESP_R: begin
                s_axi_rvalid = 1'b1; s_axi_rid = at_id; s_axi_rdata = at_old; s_axi_rresp = at_resp; s_axi_rlast = (at_rcnt == '0);
            end
            default: ;
        endcase
    end

endmodule
