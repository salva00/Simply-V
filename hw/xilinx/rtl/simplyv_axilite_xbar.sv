// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: AXI4-Lite crossbar, NUM_SI slave ports to NUM_MI master ports,
//              flat element-major array ports (same contract as the
//              xlnx_pbus_crossbar wrapper). Address decode on MI_BASE/
//              MI_RANGE_BITS, round-robin arbitration per master port, one
//              outstanding transaction per port and channel (AXI-Lite has no
//              IDs: the owner of each master port is recorded until the
//              response returns), DECERR on unmapped addresses. A master
//              port latches its write owner the cycle its AW grant first
//              appears and holds it until the B response; AW and W are then
//              independent handshakes (aw_done/w_done track them
//              separately), so a slave that withholds AWREADY until it has
//              seen WVALID cannot deadlock against this crossbar. AR keeps a
//              grant lock (address stability) since a read has no second
//              channel to decouple from.

module simplyv_axilite_xbar #(
    parameter int unsigned NUM_SI     = 1,
    parameter int unsigned NUM_MI     = 2,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 32,
    parameter logic [ADDR_WIDTH-1:0] MI_BASE       [NUM_MI] = '{default: '0},
    parameter int unsigned           MI_RANGE_BITS [NUM_MI] = '{default: 16},
    localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8
) (
    input  logic aclk,
    input  logic aresetn,

    input  logic [NUM_SI-1:0][ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [NUM_SI-1:0][2:0]            s_axi_awprot,
    input  logic [NUM_SI-1:0]                 s_axi_awvalid,
    output logic [NUM_SI-1:0]                 s_axi_awready,
    input  logic [NUM_SI-1:0][DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [NUM_SI-1:0][STRB_WIDTH-1:0] s_axi_wstrb,
    input  logic [NUM_SI-1:0]                 s_axi_wvalid,
    output logic [NUM_SI-1:0]                 s_axi_wready,
    output logic [NUM_SI-1:0][1:0]            s_axi_bresp,
    output logic [NUM_SI-1:0]                 s_axi_bvalid,
    input  logic [NUM_SI-1:0]                 s_axi_bready,
    input  logic [NUM_SI-1:0][ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [NUM_SI-1:0][2:0]            s_axi_arprot,
    input  logic [NUM_SI-1:0]                 s_axi_arvalid,
    output logic [NUM_SI-1:0]                 s_axi_arready,
    output logic [NUM_SI-1:0][DATA_WIDTH-1:0] s_axi_rdata,
    output logic [NUM_SI-1:0][1:0]            s_axi_rresp,
    output logic [NUM_SI-1:0]                 s_axi_rvalid,
    input  logic [NUM_SI-1:0]                 s_axi_rready,

    output logic [NUM_MI-1:0][ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [NUM_MI-1:0][2:0]            m_axi_awprot,
    output logic [NUM_MI-1:0]                 m_axi_awvalid,
    input  logic [NUM_MI-1:0]                 m_axi_awready,
    output logic [NUM_MI-1:0][DATA_WIDTH-1:0] m_axi_wdata,
    output logic [NUM_MI-1:0][STRB_WIDTH-1:0] m_axi_wstrb,
    output logic [NUM_MI-1:0]                 m_axi_wvalid,
    input  logic [NUM_MI-1:0]                 m_axi_wready,
    input  logic [NUM_MI-1:0][1:0]            m_axi_bresp,
    input  logic [NUM_MI-1:0]                 m_axi_bvalid,
    output logic [NUM_MI-1:0]                 m_axi_bready,
    output logic [NUM_MI-1:0][ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [NUM_MI-1:0][2:0]            m_axi_arprot,
    output logic [NUM_MI-1:0]                 m_axi_arvalid,
    input  logic [NUM_MI-1:0]                 m_axi_arready,
    input  logic [NUM_MI-1:0][DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [NUM_MI-1:0][1:0]            m_axi_rresp,
    input  logic [NUM_MI-1:0]                 m_axi_rvalid,
    output logic [NUM_MI-1:0]                 m_axi_rready
);

    localparam int unsigned SI_W     = (NUM_SI > 1) ? $clog2(NUM_SI) : 1;
    localparam int unsigned NUM_MI_E = NUM_MI + 1;                 // + error slave
    localparam int unsigned MI_W     = $clog2(NUM_MI_E);
    localparam logic [1:0] DECERR    = 2'b11;

    function automatic logic [MI_W-1:0] decode(input logic [ADDR_WIDTH-1:0] addr);
        decode = MI_W'(NUM_MI);
        for (int j = 0; j < NUM_MI; j++)
            if ((addr >> MI_RANGE_BITS[j]) == (MI_BASE[j] >> MI_RANGE_BITS[j])) decode = MI_W'(j);
    endfunction

    function automatic logic [NUM_SI-1:0] rr_pick(input logic [NUM_SI-1:0] req, input logic [SI_W-1:0] ptr);
        rr_pick = '0;
        for (int k = 0; k < NUM_SI; k++) begin
            int i = (int'(ptr) + k >= NUM_SI) ? int'(ptr) + k - NUM_SI : int'(ptr) + k;
            if (req[i] && rr_pick == '0) rr_pick[i] = 1'b1;
        end
    endfunction

    function automatic logic [SI_W-1:0] onehot_idx(input logic [NUM_SI-1:0] oh);
        onehot_idx = '0;
        for (int i = 0; i < NUM_SI; i++) if (oh[i]) onehot_idx = SI_W'(i);
    endfunction

    logic [NUM_SI-1:0]               si_wr_busy, si_rd_busy;
    logic [NUM_SI-1:0][MI_W-1:0]     aw_dec, ar_dec;
    logic [NUM_MI_E-1:0][NUM_SI-1:0] aw_req, aw_gnt, ar_req, ar_gnt;
    logic [NUM_MI_E-1:0][SI_W-1:0]   aw_rr, ar_rr, aw_idx, ar_idx;

    // Write side: a master port latches its owner the cycle its grant first
    // appears and holds it until the B response, independent of when AW and
    // W each complete (aw_done/w_done track them separately, so neither
    // channel's handshake depends on the other's).
    logic [NUM_MI_E-1:0]             wr_busy, aw_done, w_done;
    logic [NUM_MI_E-1:0][SI_W-1:0]   wr_owner;

    // Read side: grant held per master port while valid and not yet
    // accepted (address stability); one outstanding read per port.
    logic [NUM_MI_E-1:0]             ar_lock;
    logic [NUM_MI_E-1:0][SI_W-1:0]   ar_lock_idx;
    logic [NUM_MI_E-1:0]             rd_st;
    logic [NUM_MI_E-1:0][SI_W-1:0]   rd_owner;

    logic [NUM_MI_E-1:0] mi_awvalid, mi_awready, mi_wvalid, mi_wready, mi_bvalid, mi_bready, mi_arvalid, mi_arready, mi_rvalid, mi_rready;
    logic [NUM_MI_E-1:0][1:0] mi_bresp, mi_rresp;
    logic [NUM_MI_E-1:0][DATA_WIDTH-1:0] mi_rdata;
    logic [NUM_MI_E-1:0][SI_W-1:0] cur_owner;
    logic [NUM_MI_E-1:0] aw_v, w_v, resp_ready;

    always_comb begin
        for (int i = 0; i < NUM_SI; i++) begin
            aw_dec[i] = decode(s_axi_awaddr[i]);
            ar_dec[i] = decode(s_axi_araddr[i]);
        end
        aw_req = '0; ar_req = '0;
        for (int i = 0; i < NUM_SI; i++) begin
            if (s_axi_awvalid[i] && !si_wr_busy[i] && !wr_busy[aw_dec[i]]) aw_req[aw_dec[i]][i] = 1'b1;
            if (s_axi_arvalid[i] && !si_rd_busy[i] && !rd_st[ar_dec[i]])   ar_req[ar_dec[i]][i] = 1'b1;
        end
        for (int j = 0; j < NUM_MI_E; j++) begin
            aw_gnt[j] = rr_pick(aw_req[j], aw_rr[j]);
            aw_idx[j] = onehot_idx(aw_gnt[j]);
            if (ar_lock[j]) begin
                automatic int li = int'(ar_lock_idx[j]);
                ar_gnt[j]     = '0;
                ar_gnt[j][li] = 1'b1;
                ar_idx[j]     = ar_lock_idx[j];
            end else begin
                ar_gnt[j] = rr_pick(ar_req[j], ar_rr[j]); ar_idx[j] = onehot_idx(ar_gnt[j]);
            end
            cur_owner[j]  = wr_busy[j] ? wr_owner[j] : aw_idx[j];
            aw_v[j]       = (!wr_busy[j] && |aw_gnt[j]) || (wr_busy[j] && !aw_done[j]);
            w_v[j]        = (!wr_busy[j] && |aw_gnt[j]) || (wr_busy[j] && !w_done[j]);
            resp_ready[j] = wr_busy[j] && aw_done[j] && w_done[j];
        end
    end

    // Single pass per port, in dependency order: read the mi_* inputs, drive
    // the m_axi_* request side, then resolve B/R and only then forward
    // mi_bready/mi_rready out to m_axi_bready/m_axi_rready. mi_bready and
    // mi_rready must not be read (to drive an m_axi_* output) before the B/R
    // block below computes their real value in the same pass: a procedural
    // always_comb block does not re-settle a read-before-write on its own
    // internal variables the way a continuous assign would.
    always_comb begin
        s_axi_awready = '0; s_axi_arready = '0; s_axi_wready = '0;
        s_axi_bvalid = '0; s_axi_bresp = '0; s_axi_rvalid = '0; s_axi_rresp = '0; s_axi_rdata = '0;
        m_axi_bready = '0; m_axi_rready = '0;
        mi_bready = '0; mi_rready = '0;
        mi_awready[NUM_MI] = 1'b1; mi_wready[NUM_MI] = 1'b1; mi_arready[NUM_MI] = 1'b1;
        mi_bvalid[NUM_MI]  = resp_ready[NUM_MI]; mi_bresp[NUM_MI] = DECERR;
        mi_rvalid[NUM_MI]  = rd_st[NUM_MI];      mi_rresp[NUM_MI] = DECERR; mi_rdata[NUM_MI] = '0;
        for (int j = 0; j < NUM_MI_E; j++) begin
            automatic int ai = int'(cur_owner[j]);
            automatic int ri = int'(ar_idx[j]);
            automatic int wo = int'(wr_owner[j]);
            automatic int ro = int'(rd_owner[j]);
            if (j < NUM_MI) begin
                m_axi_awvalid[j] = aw_v[j];
                m_axi_awaddr[j]  = s_axi_awaddr[ai];
                m_axi_awprot[j]  = s_axi_awprot[ai];
                m_axi_arvalid[j] = |ar_gnt[j];
                m_axi_araddr[j]  = s_axi_araddr[ri];
                m_axi_arprot[j]  = s_axi_arprot[ri];
                m_axi_wvalid[j]  = w_v[j] && s_axi_wvalid[ai];
                m_axi_wdata[j]   = s_axi_wdata[ai];
                m_axi_wstrb[j]   = s_axi_wstrb[ai];
                mi_awready[j] = m_axi_awready[j]; mi_wready[j] = m_axi_wready[j];
                mi_bvalid[j]  = m_axi_bvalid[j];  mi_bresp[j]   = m_axi_bresp[j];
                mi_arready[j] = m_axi_arready[j];
                mi_rvalid[j]  = m_axi_rvalid[j];  mi_rresp[j]   = m_axi_rresp[j]; mi_rdata[j] = m_axi_rdata[j];
            end
            mi_awvalid[j] = aw_v[j];
            mi_arvalid[j] = |ar_gnt[j];
            mi_wvalid[j]  = w_v[j] && s_axi_wvalid[ai];
            if (aw_v[j])     s_axi_awready[ai] = mi_awready[j];
            if (|ar_gnt[j])  s_axi_arready[ri] = mi_arready[j];
            if (w_v[j])      s_axi_wready[ai]  = mi_wready[j];
            if (resp_ready[j] && mi_bvalid[j]) begin s_axi_bvalid[wo] = 1'b1; s_axi_bresp[wo] = mi_bresp[j]; mi_bready[j] = s_axi_bready[wo]; end
            if (rd_st[j] && mi_rvalid[j]) begin s_axi_rvalid[ro] = 1'b1; s_axi_rresp[ro] = mi_rresp[j]; s_axi_rdata[ro] = mi_rdata[j]; mi_rready[j] = s_axi_rready[ro]; end
            if (j < NUM_MI) begin
                m_axi_bready[j] = mi_bready[j];
                m_axi_rready[j] = mi_rready[j];
            end
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            si_wr_busy <= '0; si_rd_busy <= '0; rd_st <= '0; aw_rr <= '0; ar_rr <= '0; rd_owner <= '0;
            ar_lock <= '0;
            wr_busy <= '0; wr_owner <= '0; aw_done <= '0; w_done <= '0;
        end else begin
            for (int i = 0; i < NUM_SI; i++) begin
                if (s_axi_awvalid[i] && s_axi_awready[i]) si_wr_busy[i] <= 1'b1;
                if (s_axi_bvalid[i] && s_axi_bready[i])   si_wr_busy[i] <= 1'b0;
                if (s_axi_arvalid[i] && s_axi_arready[i]) si_rd_busy[i] <= 1'b1;
                if (s_axi_rvalid[i] && s_axi_rready[i])   si_rd_busy[i] <= 1'b0;
            end
            for (int j = 0; j < NUM_MI_E; j++) begin
                automatic logic aw_fire = mi_awvalid[j] && mi_awready[j];
                automatic logic w_fire  = mi_wvalid[j]  && mi_wready[j];
                if (!wr_busy[j]) begin
                    if (|aw_gnt[j]) begin
                        wr_busy[j]  <= 1'b1;
                        wr_owner[j] <= aw_idx[j];
                        aw_done[j]  <= aw_fire;
                        w_done[j]   <= w_fire;
                        aw_rr[j]    <= (int'(aw_idx[j]) + 1 >= NUM_SI) ? '0 : aw_idx[j] + 1'b1;
                    end
                end else begin
                    if (aw_fire) aw_done[j] <= 1'b1;
                    if (w_fire)  w_done[j]  <= 1'b1;
                    if (resp_ready[j] && mi_bvalid[j] && mi_bready[j]) begin
                        wr_busy[j] <= 1'b0; aw_done[j] <= 1'b0; w_done[j] <= 1'b0;
                    end
                end
                if (mi_arvalid[j] && mi_arready[j]) begin
                    rd_st[j] <= 1'b1; rd_owner[j] <= ar_idx[j];
                    ar_rr[j] <= (int'(ar_idx[j]) + 1 >= NUM_SI) ? '0 : ar_idx[j] + 1'b1;
                end
                if (rd_st[j] && mi_rvalid[j] && mi_rready[j]) rd_st[j] <= 1'b0;
                if (mi_arvalid[j] && !mi_arready[j]) begin ar_lock[j] <= 1'b1; ar_lock_idx[j] <= ar_idx[j]; end
                else ar_lock[j] <= 1'b0;
            end
        end
    end

endmodule
