// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: AXI4 crossbar, NUM_SI slave ports to NUM_MI master ports, flat
//              element-major array ports (same contract as the xlnx_*_crossbar
//              wrappers). Address decode on MI_BASE/MI_RANGE_BITS, round-robin
//              arbitration per master port, one outstanding transaction per
//              slave port and channel, DECERR on unmapped addresses.
//              The slave-port index travels in the low $clog2(NUM_SI+1) bits
//              of the ID on the master side, thread bits above it, and routes
//              B/R back; the original ID is restored on the way back.
//              Limit: one outstanding per slave port and channel. Out-of-order
//              completion needs per-ID tracking on top of this structure.

module simplyv_axi_xbar #(
    parameter int unsigned NUM_SI     = 2,
    parameter int unsigned NUM_MI     = 2,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned ID_WIDTH   = 4,
    parameter logic [ADDR_WIDTH-1:0] MI_BASE       [NUM_MI] = '{default: '0},
    parameter int unsigned           MI_RANGE_BITS [NUM_MI] = '{default: 16},
    localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8
) (
    input  logic aclk,
    input  logic aresetn,

    // Slave ports [NUM_SI-1:0][WIDTH-1:0]
    input  logic [NUM_SI-1:0][ID_WIDTH-1:0]   s_axi_awid,
    input  logic [NUM_SI-1:0][ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [NUM_SI-1:0][7:0]            s_axi_awlen,
    input  logic [NUM_SI-1:0][2:0]            s_axi_awsize,
    input  logic [NUM_SI-1:0][1:0]            s_axi_awburst,
    input  logic [NUM_SI-1:0]                 s_axi_awlock,
    input  logic [NUM_SI-1:0][3:0]            s_axi_awcache,
    input  logic [NUM_SI-1:0][2:0]            s_axi_awprot,
    input  logic [NUM_SI-1:0][3:0]            s_axi_awqos,
    input  logic [NUM_SI-1:0]                 s_axi_awvalid,
    output logic [NUM_SI-1:0]                 s_axi_awready,
    input  logic [NUM_SI-1:0][DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [NUM_SI-1:0][STRB_WIDTH-1:0] s_axi_wstrb,
    input  logic [NUM_SI-1:0]                 s_axi_wlast,
    input  logic [NUM_SI-1:0]                 s_axi_wvalid,
    output logic [NUM_SI-1:0]                 s_axi_wready,
    output logic [NUM_SI-1:0][ID_WIDTH-1:0]   s_axi_bid,
    output logic [NUM_SI-1:0][1:0]            s_axi_bresp,
    output logic [NUM_SI-1:0]                 s_axi_bvalid,
    input  logic [NUM_SI-1:0]                 s_axi_bready,
    input  logic [NUM_SI-1:0][ID_WIDTH-1:0]   s_axi_arid,
    input  logic [NUM_SI-1:0][ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [NUM_SI-1:0][7:0]            s_axi_arlen,
    input  logic [NUM_SI-1:0][2:0]            s_axi_arsize,
    input  logic [NUM_SI-1:0][1:0]            s_axi_arburst,
    input  logic [NUM_SI-1:0]                 s_axi_arlock,
    input  logic [NUM_SI-1:0][3:0]            s_axi_arcache,
    input  logic [NUM_SI-1:0][2:0]            s_axi_arprot,
    input  logic [NUM_SI-1:0][3:0]            s_axi_arqos,
    input  logic [NUM_SI-1:0]                 s_axi_arvalid,
    output logic [NUM_SI-1:0]                 s_axi_arready,
    output logic [NUM_SI-1:0][ID_WIDTH-1:0]   s_axi_rid,
    output logic [NUM_SI-1:0][DATA_WIDTH-1:0] s_axi_rdata,
    output logic [NUM_SI-1:0][1:0]            s_axi_rresp,
    output logic [NUM_SI-1:0]                 s_axi_rlast,
    output logic [NUM_SI-1:0]                 s_axi_rvalid,
    input  logic [NUM_SI-1:0]                 s_axi_rready,

    // Master ports [NUM_MI-1:0][WIDTH-1:0]
    output logic [NUM_MI-1:0][ID_WIDTH-1:0]   m_axi_awid,
    output logic [NUM_MI-1:0][ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [NUM_MI-1:0][7:0]            m_axi_awlen,
    output logic [NUM_MI-1:0][2:0]            m_axi_awsize,
    output logic [NUM_MI-1:0][1:0]            m_axi_awburst,
    output logic [NUM_MI-1:0]                 m_axi_awlock,
    output logic [NUM_MI-1:0][3:0]            m_axi_awcache,
    output logic [NUM_MI-1:0][2:0]            m_axi_awprot,
    output logic [NUM_MI-1:0][3:0]            m_axi_awregion,
    output logic [NUM_MI-1:0][3:0]            m_axi_awqos,
    output logic [NUM_MI-1:0]                 m_axi_awvalid,
    input  logic [NUM_MI-1:0]                 m_axi_awready,
    output logic [NUM_MI-1:0][DATA_WIDTH-1:0] m_axi_wdata,
    output logic [NUM_MI-1:0][STRB_WIDTH-1:0] m_axi_wstrb,
    output logic [NUM_MI-1:0]                 m_axi_wlast,
    output logic [NUM_MI-1:0]                 m_axi_wvalid,
    input  logic [NUM_MI-1:0]                 m_axi_wready,
    input  logic [NUM_MI-1:0][ID_WIDTH-1:0]   m_axi_bid,
    input  logic [NUM_MI-1:0][1:0]            m_axi_bresp,
    input  logic [NUM_MI-1:0]                 m_axi_bvalid,
    output logic [NUM_MI-1:0]                 m_axi_bready,
    output logic [NUM_MI-1:0][ID_WIDTH-1:0]   m_axi_arid,
    output logic [NUM_MI-1:0][ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [NUM_MI-1:0][7:0]            m_axi_arlen,
    output logic [NUM_MI-1:0][2:0]            m_axi_arsize,
    output logic [NUM_MI-1:0][1:0]            m_axi_arburst,
    output logic [NUM_MI-1:0]                 m_axi_arlock,
    output logic [NUM_MI-1:0][3:0]            m_axi_arcache,
    output logic [NUM_MI-1:0][2:0]            m_axi_arprot,
    output logic [NUM_MI-1:0][3:0]            m_axi_arregion,
    output logic [NUM_MI-1:0][3:0]            m_axi_arqos,
    output logic [NUM_MI-1:0]                 m_axi_arvalid,
    input  logic [NUM_MI-1:0]                 m_axi_arready,
    input  logic [NUM_MI-1:0][ID_WIDTH-1:0]   m_axi_rid,
    input  logic [NUM_MI-1:0][DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [NUM_MI-1:0][1:0]            m_axi_rresp,
    input  logic [NUM_MI-1:0]                 m_axi_rlast,
    input  logic [NUM_MI-1:0]                 m_axi_rvalid,
    output logic [NUM_MI-1:0]                 m_axi_rready
);

    // ID layout: {thread bits, slave-port index}; index in the low bits
    localparam int unsigned SI_W     = $clog2(NUM_SI + 1);
    localparam int unsigned TH_W     = ID_WIDTH - SI_W;
    localparam int unsigned NUM_MI_E = NUM_MI + 1;            // + error slave
    localparam int unsigned MI_W     = $clog2(NUM_MI_E);

    // Internal master-side channels; index NUM_MI is the error slave
    logic [NUM_MI_E-1:0][ID_WIDTH-1:0]   mi_awid, mi_bid, mi_arid, mi_rid;
    logic [NUM_MI_E-1:0][ADDR_WIDTH-1:0] mi_awaddr, mi_araddr;
    logic [NUM_MI_E-1:0][7:0]            mi_awlen, mi_arlen;
    logic [NUM_MI_E-1:0][2:0]            mi_awsize, mi_arsize, mi_awprot, mi_arprot;
    logic [NUM_MI_E-1:0][1:0]            mi_awburst, mi_arburst, mi_bresp, mi_rresp;
    logic [NUM_MI_E-1:0][3:0]            mi_awcache, mi_arcache, mi_awqos, mi_arqos;
    logic [NUM_MI_E-1:0]                 mi_awlock, mi_arlock, mi_awvalid, mi_awready, mi_wvalid, mi_wready, mi_wlast;
    logic [NUM_MI_E-1:0]                 mi_bvalid, mi_bready, mi_arvalid, mi_arready, mi_rvalid, mi_rready, mi_rlast;
    logic [NUM_MI_E-1:0][DATA_WIDTH-1:0] mi_wdata, mi_rdata;
    logic [NUM_MI_E-1:0][STRB_WIDTH-1:0] mi_wstrb;

    /////////////
    // Decode  //
    /////////////

    function automatic logic [MI_W-1:0] decode(input logic [ADDR_WIDTH-1:0] addr);
        decode = MI_W'(NUM_MI);
        for (int j = 0; j < NUM_MI; j++)
            if ((addr >> MI_RANGE_BITS[j]) == (MI_BASE[j] >> MI_RANGE_BITS[j])) decode = MI_W'(j);
    endfunction

    // Round-robin pick: first requester at or after ptr
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

    function automatic logic [SI_W-1:0] next_ptr(input logic [SI_W-1:0] idx);
        next_ptr = (int'(idx) + 1 >= NUM_SI) ? '0 : idx + 1'b1;
    endfunction

    //////////////////////
    // Per-port state   //
    //////////////////////

    logic [NUM_SI-1:0]                  wr_busy, rd_busy;
    logic [NUM_SI-1:0][ID_WIDTH-1:0]    wr_id, rd_id;          // ID to restore on B/R
    logic [NUM_SI-1:0][MI_W-1:0]        aw_dec, ar_dec;
    logic [NUM_MI_E-1:0][NUM_SI-1:0]    aw_req, aw_gnt, ar_req, ar_gnt;
    logic [NUM_MI_E-1:0][SI_W-1:0]      aw_rr, ar_rr, aw_gnt_idx, ar_gnt_idx;

    // Grant held per master port while valid and not yet accepted, so the
    // payload on mi_aw*/mi_ar* cannot switch requester mid-stall (AXI address
    // stability). Independent for AW and AR.
    logic [NUM_MI_E-1:0]                aw_lock, ar_lock;
    logic [NUM_MI_E-1:0][SI_W-1:0]      aw_lock_idx, ar_lock_idx;

    // W-channel order per master port: slave-port indices in AW-accept order.
    // While the queue is empty, W may flow against the pending, not-yet-accepted
    // grant (W must not wait on AWREADY); w_done_pending then blocks further W
    // until that AW is accepted and skips its enqueue.
    logic [NUM_MI_E-1:0][NUM_SI-1:0][SI_W-1:0] wq;
    logic [NUM_MI_E-1:0][SI_W:0]               wq_cnt;
    logic [NUM_MI_E-1:0]                       w_done_pending;

    always_comb begin
        for (int i = 0; i < NUM_SI; i++) begin
            aw_dec[i] = decode(s_axi_awaddr[i]);
            ar_dec[i] = decode(s_axi_araddr[i]);
        end
        aw_req = '0;
        ar_req = '0;
        for (int i = 0; i < NUM_SI; i++) begin
            if (s_axi_awvalid[i] && !wr_busy[i]) aw_req[aw_dec[i]][i] = 1'b1;
            if (s_axi_arvalid[i] && !rd_busy[i]) ar_req[ar_dec[i]][i] = 1'b1;
        end
        for (int j = 0; j < NUM_MI_E; j++) begin
            if (aw_lock[j]) begin
                automatic int li = int'(aw_lock_idx[j]);
                aw_gnt[j]      = '0;
                aw_gnt[j][li]  = 1'b1;
                aw_gnt_idx[j]  = aw_lock_idx[j];
            end else begin
                aw_gnt[j]     = rr_pick(aw_req[j], aw_rr[j]);
                aw_gnt_idx[j] = onehot_idx(aw_gnt[j]);
            end
            if (ar_lock[j]) begin
                automatic int li = int'(ar_lock_idx[j]);
                ar_gnt[j]      = '0;
                ar_gnt[j][li]  = 1'b1;
                ar_gnt_idx[j]  = ar_lock_idx[j];
            end else begin
                ar_gnt[j]     = rr_pick(ar_req[j], ar_rr[j]);
                ar_gnt_idx[j] = onehot_idx(ar_gnt[j]);
            end
        end
    end

    ////////////////
    // AW and AR  //
    ////////////////

    always_comb begin
        for (int j = 0; j < NUM_MI_E; j++) begin
            automatic int i = int'(aw_gnt_idx[j]);
            mi_awvalid[j] = |aw_gnt[j];
            mi_awid[j]    = {s_axi_awid[i][TH_W-1:0], SI_W'(i)};
            mi_awaddr[j]  = s_axi_awaddr[i];
            mi_awlen[j]   = s_axi_awlen[i];
            mi_awsize[j]  = s_axi_awsize[i];
            mi_awburst[j] = s_axi_awburst[i];
            mi_awlock[j]  = s_axi_awlock[i];
            mi_awcache[j] = s_axi_awcache[i];
            mi_awprot[j]  = s_axi_awprot[i];
            mi_awqos[j]   = s_axi_awqos[i];
        end
        for (int j = 0; j < NUM_MI_E; j++) begin
            automatic int i = int'(ar_gnt_idx[j]);
            mi_arvalid[j] = |ar_gnt[j];
            mi_arid[j]    = {s_axi_arid[i][TH_W-1:0], SI_W'(i)};
            mi_araddr[j]  = s_axi_araddr[i];
            mi_arlen[j]   = s_axi_arlen[i];
            mi_arsize[j]  = s_axi_arsize[i];
            mi_arburst[j] = s_axi_arburst[i];
            mi_arlock[j]  = s_axi_arlock[i];
            mi_arcache[j] = s_axi_arcache[i];
            mi_arprot[j]  = s_axi_arprot[i];
            mi_arqos[j]   = s_axi_arqos[i];
        end
        for (int i = 0; i < NUM_SI; i++) begin
            s_axi_awready[i] = aw_gnt[aw_dec[i]][i] & mi_awready[aw_dec[i]];
            s_axi_arready[i] = ar_gnt[ar_dec[i]][i] & mi_arready[ar_dec[i]];
        end
    end

    ///////////
    // W     //
    ///////////

    always_comb begin
        s_axi_wready = '0;
        for (int j = 0; j < NUM_MI_E; j++) begin
            automatic int h = (wq_cnt[j] != '0) ? int'(wq[j][0]) : int'(aw_gnt_idx[j]);
            automatic logic w_active = (wq_cnt[j] != '0) | (mi_awvalid[j] & ~w_done_pending[j]);
            mi_wvalid[j] = w_active & s_axi_wvalid[h];
            mi_wdata[j]  = s_axi_wdata[h];
            mi_wstrb[j]  = s_axi_wstrb[h];
            mi_wlast[j]  = s_axi_wlast[h];
            if (w_active) s_axi_wready[h] = mi_wready[j];
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            wq_cnt         <= '0;
            wq             <= '0;
            w_done_pending <= '0;
        end else begin
            for (int j = 0; j < NUM_MI_E; j++) begin : wq_upd
                logic [SI_W:0] cnt;
                logic          wlast_fire, aw_fire;
                cnt        = wq_cnt[j];
                wlast_fire = mi_wvalid[j] && mi_wready[j] && mi_wlast[j];
                aw_fire    = mi_awvalid[j] && mi_awready[j];
                if (cnt != '0) begin
                    if (wlast_fire) begin
                        for (int k = 0; k < NUM_SI - 1; k++) wq[j][k] <= wq[j][k+1];
                        cnt = cnt - 1'b1;
                    end
                    if (aw_fire) begin
                        wq[j][cnt[SI_W-1:0]] <= aw_gnt_idx[j];
                        cnt = cnt + 1'b1;
                    end
                end else begin
                    // No queued entry: W may already be flowing against the
                    // pending, not-yet-accepted AW grant (aw_gnt_idx[j]).
                    if (aw_fire && wlast_fire) begin
                        w_done_pending[j] <= 1'b0;
                    end else if (wlast_fire) begin
                        w_done_pending[j] <= 1'b1;
                    end else if (aw_fire) begin
                        if (w_done_pending[j]) begin
                            w_done_pending[j] <= 1'b0;
                        end else begin
                            wq[j][0] <= aw_gnt_idx[j];
                            cnt = '0;
                            cnt[0] = 1'b1;
                        end
                    end
                end
                wq_cnt[j] <= cnt;
            end
        end
    end

    ///////////////
    // B and R   //
    ///////////////

    always_comb begin
        s_axi_bvalid = '0; s_axi_bid = '0; s_axi_bresp = '0; mi_bready = '0;
        s_axi_rvalid = '0; s_axi_rid = '0; s_axi_rdata = '0; s_axi_rresp = '0; s_axi_rlast = '0; mi_rready = '0;
        for (int j = 0; j < NUM_MI_E; j++) begin
            automatic int bi = int'(mi_bid[j][SI_W-1:0]);
            automatic int ri = int'(mi_rid[j][SI_W-1:0]);
            if (mi_bvalid[j] && bi < NUM_SI) begin
                s_axi_bvalid[bi] = 1'b1;
                s_axi_bid[bi]    = wr_id[bi];
                s_axi_bresp[bi]  = mi_bresp[j];
                mi_bready[j]     = s_axi_bready[bi];
            end
            if (mi_rvalid[j] && ri < NUM_SI) begin
                s_axi_rvalid[ri] = 1'b1;
                s_axi_rid[ri]    = rd_id[ri];
                s_axi_rdata[ri]  = mi_rdata[j];
                s_axi_rresp[ri]  = mi_rresp[j];
                s_axi_rlast[ri]  = mi_rlast[j];
                mi_rready[j]     = s_axi_rready[ri];
            end
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            wr_busy <= '0; rd_busy <= '0; aw_rr <= '0; ar_rr <= '0; wr_id <= '0; rd_id <= '0;
            aw_lock <= '0; ar_lock <= '0;
        end else begin
            for (int i = 0; i < NUM_SI; i++) begin
                if (s_axi_awvalid[i] && s_axi_awready[i]) begin wr_busy[i] <= 1'b1; wr_id[i] <= s_axi_awid[i]; end
                if (s_axi_bvalid[i] && s_axi_bready[i]) wr_busy[i] <= 1'b0;
                if (s_axi_arvalid[i] && s_axi_arready[i]) begin rd_busy[i] <= 1'b1; rd_id[i] <= s_axi_arid[i]; end
                if (s_axi_rvalid[i] && s_axi_rready[i] && s_axi_rlast[i]) rd_busy[i] <= 1'b0;
            end
            for (int j = 0; j < NUM_MI_E; j++) begin
                if (mi_awvalid[j] && mi_awready[j]) aw_rr[j] <= next_ptr(aw_gnt_idx[j]);
                if (mi_arvalid[j] && mi_arready[j]) ar_rr[j] <= next_ptr(ar_gnt_idx[j]);
                if (mi_awvalid[j] && !mi_awready[j]) begin aw_lock[j] <= 1'b1; aw_lock_idx[j] <= aw_gnt_idx[j]; end
                else aw_lock[j] <= 1'b0;
                if (mi_arvalid[j] && !mi_arready[j]) begin ar_lock[j] <= 1'b1; ar_lock_idx[j] <= ar_gnt_idx[j]; end
                else ar_lock[j] <= 1'b0;
            end
        end
    end

    //////////////////////////////
    // Master ports, error slave //
    //////////////////////////////

    for (genvar j = 0; j < NUM_MI; j++) begin : g_mi
        assign m_axi_awregion[j] = '0;
        assign m_axi_arregion[j] = '0;
        assign m_axi_awid[j] = mi_awid[j];       assign m_axi_awaddr[j] = mi_awaddr[j];   assign m_axi_awlen[j] = mi_awlen[j];
        assign m_axi_awsize[j] = mi_awsize[j];   assign m_axi_awburst[j] = mi_awburst[j]; assign m_axi_awlock[j] = mi_awlock[j];
        assign m_axi_awcache[j] = mi_awcache[j]; assign m_axi_awprot[j] = mi_awprot[j];   assign m_axi_awqos[j] = mi_awqos[j];
        assign m_axi_awvalid[j] = mi_awvalid[j]; assign mi_awready[j] = m_axi_awready[j];
        assign m_axi_wdata[j] = mi_wdata[j];     assign m_axi_wstrb[j] = mi_wstrb[j];     assign m_axi_wlast[j] = mi_wlast[j];
        assign m_axi_wvalid[j] = mi_wvalid[j];   assign mi_wready[j] = m_axi_wready[j];
        assign mi_bid[j] = m_axi_bid[j];         assign mi_bresp[j] = m_axi_bresp[j];     assign mi_bvalid[j] = m_axi_bvalid[j];
        assign m_axi_bready[j] = mi_bready[j];
        assign m_axi_arid[j] = mi_arid[j];       assign m_axi_araddr[j] = mi_araddr[j];   assign m_axi_arlen[j] = mi_arlen[j];
        assign m_axi_arsize[j] = mi_arsize[j];   assign m_axi_arburst[j] = mi_arburst[j]; assign m_axi_arlock[j] = mi_arlock[j];
        assign m_axi_arcache[j] = mi_arcache[j]; assign m_axi_arprot[j] = mi_arprot[j];   assign m_axi_arqos[j] = mi_arqos[j];
        assign m_axi_arvalid[j] = mi_arvalid[j]; assign mi_arready[j] = m_axi_arready[j];
        assign mi_rid[j] = m_axi_rid[j];         assign mi_rdata[j] = m_axi_rdata[j];     assign mi_rresp[j] = m_axi_rresp[j];
        assign mi_rlast[j] = m_axi_rlast[j];     assign mi_rvalid[j] = m_axi_rvalid[j];   assign m_axi_rready[j] = mi_rready[j];
    end

    simplyv_axi_err_slv #(
        .DATA_WIDTH ( DATA_WIDTH ),
        .ID_WIDTH   ( ID_WIDTH   )
    ) err_slv_u (
        .aclk, .aresetn,
        .s_axi_awid(mi_awid[NUM_MI]), .s_axi_awvalid(mi_awvalid[NUM_MI]), .s_axi_awready(mi_awready[NUM_MI]),
        .s_axi_wlast(mi_wlast[NUM_MI]), .s_axi_wvalid(mi_wvalid[NUM_MI]), .s_axi_wready(mi_wready[NUM_MI]),
        .s_axi_bid(mi_bid[NUM_MI]), .s_axi_bresp(mi_bresp[NUM_MI]), .s_axi_bvalid(mi_bvalid[NUM_MI]), .s_axi_bready(mi_bready[NUM_MI]),
        .s_axi_arid(mi_arid[NUM_MI]), .s_axi_arlen(mi_arlen[NUM_MI]), .s_axi_arvalid(mi_arvalid[NUM_MI]), .s_axi_arready(mi_arready[NUM_MI]),
        .s_axi_rid(mi_rid[NUM_MI]), .s_axi_rdata(mi_rdata[NUM_MI]), .s_axi_rresp(mi_rresp[NUM_MI]), .s_axi_rlast(mi_rlast[NUM_MI]),
        .s_axi_rvalid(mi_rvalid[NUM_MI]), .s_axi_rready(mi_rready[NUM_MI])
    );

endmodule
