// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: Self-checking bench for simplyv_axi_xbar. Four masters drive
//              random write/readback traffic against four memory slaves with
//              random ready backpressure; the memory model queues AWs ahead
//              of their W data, so contention exercises the crossbar's
//              per-master-port W-ordering queue past one entry. DECERR on an
//              unmapped address is checked explicitly.
//              +define+AXI4PC binds the ARM AXI4 protocol checker shipped with
//              Vivado on every slave and master port.

`timescale 1ns/1ps

// AXI4 slave memory with random ready delays, one outstanding per channel
module tb_axi_mem #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned ID_WIDTH   = 5,
    parameter int unsigned MEM_BYTES  = 65536,
    localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8
) (
    input  logic                  aclk,
    input  logic                  aresetn,
    input  logic [ID_WIDTH-1:0]   awid,
    input  logic [ADDR_WIDTH-1:0] awaddr,
    input  logic [7:0]            awlen,
    input  logic [2:0]            awsize,
    input  logic [1:0]            awburst,
    input  logic                  awvalid,
    output logic                  awready,
    input  logic [DATA_WIDTH-1:0] wdata,
    input  logic [STRB_WIDTH-1:0] wstrb,
    input  logic                  wlast,
    input  logic                  wvalid,
    output logic                  wready,
    output logic [ID_WIDTH-1:0]   bid,
    output logic [1:0]            bresp,
    output logic                  bvalid,
    input  logic                  bready,
    input  logic [ID_WIDTH-1:0]   arid,
    input  logic [ADDR_WIDTH-1:0] araddr,
    input  logic [7:0]            arlen,
    input  logic [2:0]            arsize,
    input  logic [1:0]            arburst,
    input  logic                  arvalid,
    output logic                  arready,
    output logic [ID_WIDTH-1:0]   rid,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic [1:0]            rresp,
    output logic                  rlast,
    output logic                  rvalid,
    input  logic                  rready,
    // TB-only: forces AWREADY low regardless of the random aw_stall, so a
    // directed test can hold a pending AW while its W (or a stray extra W)
    // is presented.
    input  logic                  force_aw_stall,
    // TB-only: models a legal slave that asserts AWREADY only after it has
    // seen WVALID (e.g. Xilinx axi_lite_ipif), to prove the crossbar's AW
    // and W channels are independent handshakes.
    input  logic                  aw_waits_for_w,
    // TB-only: accepts W with no AW queued yet, pairing it with the next AW
    // in order (a legal slave, the mirror image of aw_waits_for_w).
    input  logic                  w_ahead_ok
);
    localparam int unsigned AW        = $clog2(MEM_BYTES);
    localparam int unsigned AWQ_DEPTH = 4;
    localparam int unsigned WQ_DEPTH  = 4;
    logic [7:0] mem [MEM_BYTES];

    // write side: AW and W each queue independently (AW up to AWQ_DEPTH
    // ahead of its W, and -- when w_ahead_ok -- W up to WQ_DEPTH ahead of
    // its AW), and a beat commits to memory only once both queue heads are
    // available. Read side stays one outstanding.
    logic [ID_WIDTH-1:0]   awq_id    [AWQ_DEPTH];
    logic [ADDR_WIDTH-1:0] awq_addr  [AWQ_DEPTH];
    logic [2:0]            awq_size  [AWQ_DEPTH];
    logic [1:0]            awq_burst [AWQ_DEPTH];
    logic [$clog2(AWQ_DEPTH+1)-1:0] awq_cnt;
    logic [DATA_WIDTH-1:0] wq_data [WQ_DEPTH];
    logic [STRB_WIDTH-1:0] wq_strb [WQ_DEPTH];
    logic                  wq_last [WQ_DEPTH];
    logic [$clog2(WQ_DEPTH+1)-1:0] wq_cnt;
    logic aw_stall, w_stall, w_seen;

    typedef enum logic {WB_IDLE, WB_RESP} wb_t;
    wb_t wb;
    logic w_new;   // next committed W beat starts a fresh burst from the AW queue head
    logic [ADDR_WIDTH-1:0] wr_addr; logic [2:0] wr_size; logic [1:0] wr_burst; logic [ID_WIDTH-1:0] wr_id;
    logic [ID_WIDTH-1:0] bid_r;

    wire commit = (wb == WB_IDLE) && (awq_cnt != 0) && (wq_cnt != 0);
    wire [ADDR_WIDTH-1:0] cur_addr  = w_new ? awq_addr[0]  : wr_addr;
    wire [2:0]            cur_size  = w_new ? awq_size[0]  : wr_size;
    wire [1:0]            cur_burst = w_new ? awq_burst[0] : wr_burst;
    wire [ID_WIDTH-1:0]   cur_id    = w_new ? awq_id[0]    : wr_id;

    assign awready = (awq_cnt < AWQ_DEPTH) && !aw_stall && (!aw_waits_for_w || w_seen) && !force_aw_stall;
    assign wready  = (wq_cnt < WQ_DEPTH) && !w_stall && (w_ahead_ok || awq_cnt != 0);
    assign bvalid  = (wb == WB_RESP);
    assign bid     = bid_r;
    assign bresp   = 2'b00;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            awq_cnt  <= '0;
            wq_cnt   <= '0;
            aw_stall <= 1'b0;
            w_stall  <= 1'b0;
            w_new    <= 1'b1;
            wb       <= WB_IDLE;
            bid_r    <= '0;
            w_seen   <= 1'b0;
        end else begin
            automatic logic [$clog2(AWQ_DEPTH+1)-1:0] awcnt;
            automatic logic [$clog2(WQ_DEPTH+1)-1:0]  wcnt;
            aw_stall <= $urandom_range(0, 3) == 0;
            w_stall  <= $urandom_range(0, 3) == 0;
            if (awvalid && awready) w_seen <= 1'b0;
            else if (wvalid)        w_seen <= 1'b1;

            awcnt = awq_cnt;
            wcnt  = wq_cnt;

            if (commit) begin
                for (int b = 0; b < STRB_WIDTH; b++)
                    if (wq_strb[0][b]) mem[(cur_addr[AW-1:0] & ~(STRB_WIDTH-1)) + b] <= wq_data[0][8*b +: 8];
                wr_addr  <= (cur_burst == 2'b01) ? cur_addr + (1 << cur_size) : cur_addr;
                wr_size  <= cur_size;
                wr_burst <= cur_burst;
                wr_id    <= cur_id;
                w_new    <= wq_last[0];
                for (int k = 0; k < WQ_DEPTH - 1; k++) begin
                    wq_data[k] <= wq_data[k+1]; wq_strb[k] <= wq_strb[k+1]; wq_last[k] <= wq_last[k+1];
                end
                wcnt = wcnt - 1'b1;
                if (wq_last[0]) begin
                    bid_r <= cur_id;
                    wb    <= WB_RESP;
                    for (int k = 0; k < AWQ_DEPTH - 1; k++) begin
                        awq_id[k]    <= awq_id[k+1];
                        awq_addr[k]  <= awq_addr[k+1];
                        awq_size[k]  <= awq_size[k+1];
                        awq_burst[k] <= awq_burst[k+1];
                    end
                    awcnt = awcnt - 1'b1;
                end
            end
            if (awvalid && awready) begin
                awq_id[awcnt]    <= awid;
                awq_addr[awcnt]  <= awaddr;
                awq_size[awcnt]  <= awsize;
                awq_burst[awcnt] <= awburst;
                awcnt = awcnt + 1'b1;
            end
            if (wvalid && wready) begin
                wq_data[wcnt] <= wdata; wq_strb[wcnt] <= wstrb; wq_last[wcnt] <= wlast;
                wcnt = wcnt + 1'b1;
            end
            awq_cnt <= awcnt;
            wq_cnt  <= wcnt;

            if (wb == WB_RESP && bready) wb <= WB_IDLE;
        end
    end

    // read side
    logic [ID_WIDTH-1:0] rd_id; logic [ADDR_WIDTH-1:0] rd_addr; logic [2:0] rd_size; logic [1:0] rd_burst; logic [7:0] rd_cnt;
    typedef enum logic {RI, RD} rs_t; rs_t rs;
    logic r_stall;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin rs <= RI; r_stall <= 0; end
        else begin
            r_stall <= $urandom_range(0, 3) == 0;
            case (rs)
                RI: if (arvalid && arready) begin rd_id <= arid; rd_addr <= araddr; rd_size <= arsize; rd_burst <= arburst; rd_cnt <= arlen; rs <= RD; end
                RD: if (rvalid && rready) begin
                        if (rd_burst == 2'b01) rd_addr <= rd_addr + (1 << rd_size);
                        rd_cnt <= rd_cnt - 1;
                        if (rd_cnt == 0) rs <= RI;
                    end
                default: rs <= RI;
            endcase
        end
    end

    assign arready = (rs == RI) && !r_stall;
    assign rvalid  = (rs == RD) && !r_stall;
    assign rid     = rd_id;
    assign rresp   = 2'b00;
    assign rlast   = (rd_cnt == 0);
    always_comb
        for (int b = 0; b < STRB_WIDTH; b++) rdata[8*b +: 8] = mem[(rd_addr[AW-1:0] & ~(STRB_WIDTH-1)) + b];
endmodule


module xbar_tb;
`ifdef XBAR_DW
    localparam int unsigned DW = `XBAR_DW;
`else
    localparam int unsigned DW = 32;
`endif
    localparam int unsigned N = 4, M = 4, AW = 32, IW = 5, SW = DW / 8;
    localparam logic [AW-1:0] MI_BASE [M] = '{32'h0000_0000, 32'h0001_0000, 32'h0002_0000, 32'h0400_0000};
    localparam int unsigned   MI_BITS [M] = '{16, 16, 12, 26};
    localparam logic [AW-1:0] UNMAPPED = 32'h0003_0000;

    logic clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // master side (TB drives), element-major
    logic [N-1:0][IW-1:0] s_awid, s_bid, s_arid, s_rid;
    logic [N-1:0][AW-1:0] s_awaddr, s_araddr;
    logic [N-1:0][7:0]    s_awlen, s_arlen;
    logic [N-1:0][2:0]    s_awsize, s_arsize, s_awprot, s_arprot;
    logic [N-1:0][1:0]    s_awburst, s_arburst, s_bresp, s_rresp;
    logic [N-1:0][3:0]    s_awcache, s_arcache, s_awqos, s_arqos;
    logic [N-1:0]         s_awlock, s_arlock, s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready, s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;
    logic [N-1:0][DW-1:0] s_wdata, s_rdata;
    logic [N-1:0][SW-1:0] s_wstrb;
    // slave side (memories)
    logic [M-1:0][IW-1:0] m_awid, m_bid, m_arid, m_rid;
    logic [M-1:0][AW-1:0] m_awaddr, m_araddr;
    logic [M-1:0][7:0]    m_awlen, m_arlen;
    logic [M-1:0][2:0]    m_awsize, m_arsize, m_awprot, m_arprot;
    logic [M-1:0][1:0]    m_awburst, m_arburst, m_bresp, m_rresp;
    logic [M-1:0][3:0]    m_awcache, m_arcache, m_awqos, m_arqos, m_awregion, m_arregion;
    logic [M-1:0]         m_awlock, m_arlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
    logic [M-1:0][DW-1:0] m_wdata, m_rdata;
    logic [M-1:0][SW-1:0] m_wstrb;
    // TB-only: forces AWREADY low on a given memory port.
    logic [M-1:0]         force_aw_stall;
    // TB-only: puts a memory port's AW channel in "waits for WVALID" mode
    // (see tb_axi_mem), used to prove the crossbar's AW and W handshakes
    // are independent.
    logic [M-1:0]         aw_waits_for_w;
    // TB-only: puts a memory port's W channel in "accepts W with no AW
    // queued yet" mode (see tb_axi_mem).
    logic [M-1:0]         w_ahead_ok;

    simplyv_axi_xbar #(
        .NUM_SI(N), .NUM_MI(M), .DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ID_WIDTH(IW),
        .MI_BASE(MI_BASE), .MI_RANGE_BITS(MI_BITS)
    ) dut (
        .aclk(clk), .aresetn(rstn),
        .s_axi_awid(s_awid), .s_axi_awaddr(s_awaddr), .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize), .s_axi_awburst(s_awburst),
        .s_axi_awlock(s_awlock), .s_axi_awcache(s_awcache), .s_axi_awprot(s_awprot), .s_axi_awqos(s_awqos),
        .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wlast(s_wlast), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bid(s_bid), .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_arid(s_arid), .s_axi_araddr(s_araddr), .s_axi_arlen(s_arlen), .s_axi_arsize(s_arsize), .s_axi_arburst(s_arburst),
        .s_axi_arlock(s_arlock), .s_axi_arcache(s_arcache), .s_axi_arprot(s_arprot), .s_axi_arqos(s_arqos),
        .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rid(s_rid), .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rlast(s_rlast), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst),
        .m_axi_awlock(m_awlock), .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot), .m_axi_awregion(m_awregion), .m_axi_awqos(m_awqos),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arlock(m_arlock), .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot), .m_axi_arregion(m_arregion), .m_axi_arqos(m_arqos),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    for (genvar j = 0; j < M; j++) begin : g_mem
        tb_axi_mem #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ID_WIDTH(IW)) mem (
            .aclk(clk), .aresetn(rstn),
            .awid(m_awid[j]), .awaddr(m_awaddr[j]), .awlen(m_awlen[j]), .awsize(m_awsize[j]), .awburst(m_awburst[j]), .awvalid(m_awvalid[j]), .awready(m_awready[j]),
            .wdata(m_wdata[j]), .wstrb(m_wstrb[j]), .wlast(m_wlast[j]), .wvalid(m_wvalid[j]), .wready(m_wready[j]),
            .bid(m_bid[j]), .bresp(m_bresp[j]), .bvalid(m_bvalid[j]), .bready(m_bready[j]),
            .arid(m_arid[j]), .araddr(m_araddr[j]), .arlen(m_arlen[j]), .arsize(m_arsize[j]), .arburst(m_arburst[j]), .arvalid(m_arvalid[j]), .arready(m_arready[j]),
            .rid(m_rid[j]), .rdata(m_rdata[j]), .rresp(m_rresp[j]), .rlast(m_rlast[j]), .rvalid(m_rvalid[j]), .rready(m_rready[j]),
            .force_aw_stall(force_aw_stall[j]), .aw_waits_for_w(aw_waits_for_w[j]), .w_ahead_ok(w_ahead_ok[j])
        );
    end

`ifdef AXI4PC
    // ARM AXI4 protocol checker on every slave port
    for (genvar i = 0; i < N; i++) begin : g_pc
        axi_vip_axi4pc #(
            .WADDR_WIDTH(AW), .RADDR_WIDTH(AW), .WDATA_WIDTH(DW), .RDATA_WIDTH(DW), .WID_WIDTH(IW), .RID_WIDTH(IW), .MAXWAITS(256)
        ) pc (
            .ACLK(clk), .ACLKEN(1'b1), .ARESETn(rstn),
            .AWID(s_awid[i]), .AWADDR(s_awaddr[i]), .AWLEN(s_awlen[i]), .AWSIZE(s_awsize[i]), .AWBURST(s_awburst[i]), .AWLOCK(s_awlock[i]),
            .AWCACHE(s_awcache[i]), .AWPROT(s_awprot[i]), .AWQOS(s_awqos[i]), .AWREGION(4'd0), .AWUSER(1'b0), .AWVALID(s_awvalid[i]), .AWREADY(s_awready[i]),
            .WLAST(s_wlast[i]), .WDATA(s_wdata[i]), .WSTRB(s_wstrb[i]), .WUSER(1'b0), .WVALID(s_wvalid[i]), .WREADY(s_wready[i]),
            .BID(s_bid[i]), .BRESP(s_bresp[i]), .BUSER(1'b0), .BVALID(s_bvalid[i]), .BREADY(s_bready[i]),
            .ARID(s_arid[i]), .ARADDR(s_araddr[i]), .ARLEN(s_arlen[i]), .ARSIZE(s_arsize[i]), .ARBURST(s_arburst[i]), .ARLOCK(s_arlock[i]),
            .ARCACHE(s_arcache[i]), .ARPROT(s_arprot[i]), .ARQOS(s_arqos[i]), .ARREGION(4'd0), .ARUSER(1'b0), .ARVALID(s_arvalid[i]), .ARREADY(s_arready[i]),
            .RID(s_rid[i]), .RLAST(s_rlast[i]), .RDATA(s_rdata[i]), .RRESP(s_rresp[i]), .RUSER(1'b0), .RVALID(s_rvalid[i]), .RREADY(s_rready[i]),
            .CACTIVE(1'b1), .CSYSREQ(1'b1), .CSYSACK(1'b1)
        );
    end

    // Same checker on every master port (crossbar output to the memories): this
    // is where an unlocked arbiter would let the payload change while valid is
    // still high, which the slave-side checker above cannot see.
    for (genvar j = 0; j < M; j++) begin : g_pc_m
        axi_vip_axi4pc #(
            .WADDR_WIDTH(AW), .RADDR_WIDTH(AW), .WDATA_WIDTH(DW), .RDATA_WIDTH(DW), .WID_WIDTH(IW), .RID_WIDTH(IW), .MAXWAITS(256)
        ) pc_m (
            .ACLK(clk), .ACLKEN(1'b1), .ARESETn(rstn),
            .AWID(m_awid[j]), .AWADDR(m_awaddr[j]), .AWLEN(m_awlen[j]), .AWSIZE(m_awsize[j]), .AWBURST(m_awburst[j]), .AWLOCK(m_awlock[j]),
            .AWCACHE(m_awcache[j]), .AWPROT(m_awprot[j]), .AWQOS(m_awqos[j]), .AWREGION(m_awregion[j]), .AWUSER(1'b0), .AWVALID(m_awvalid[j]), .AWREADY(m_awready[j]),
            .WLAST(m_wlast[j]), .WDATA(m_wdata[j]), .WSTRB(m_wstrb[j]), .WUSER(1'b0), .WVALID(m_wvalid[j]), .WREADY(m_wready[j]),
            .BID(m_bid[j]), .BRESP(m_bresp[j]), .BUSER(1'b0), .BVALID(m_bvalid[j]), .BREADY(m_bready[j]),
            .ARID(m_arid[j]), .ARADDR(m_araddr[j]), .ARLEN(m_arlen[j]), .ARSIZE(m_arsize[j]), .ARBURST(m_arburst[j]), .ARLOCK(m_arlock[j]),
            .ARCACHE(m_arcache[j]), .ARPROT(m_arprot[j]), .ARQOS(m_arqos[j]), .ARREGION(m_arregion[j]), .ARUSER(1'b0), .ARVALID(m_arvalid[j]), .ARREADY(m_arready[j]),
            .RID(m_rid[j]), .RLAST(m_rlast[j]), .RDATA(m_rdata[j]), .RRESP(m_rresp[j]), .RUSER(1'b0), .RVALID(m_rvalid[j]), .RREADY(m_rready[j]),
            .CACTIVE(1'b1), .CSYSREQ(1'b1), .CSYSACK(1'b1)
        );
    end
`endif

    int errors = 0;

    // Random IDs per transaction, across all ID bits (thread bits included)
    logic [IW-1:0] wid [N], rid [N];

    // INCR write strobes for the beat at addr: the bytes from addr up to the
    // next size boundary
    function automatic logic [SW-1:0] strb(input logic [AW-1:0] addr, input logic [2:0] size);
        int unsigned lo = int'(addr % SW);
        int unsigned hi = int'((addr & ~((AW'(1) << size) - 1)) % SW) + (1 << size);
        for (int b = 0; b < SW; b++) strb[b] = (b >= lo) && (b < hi);
    endfunction

    // ---- master BFM (one outstanding per master, blocking) ----
    task automatic axi_write(input int i, input logic [AW-1:0] addr, input logic [DW-1:0] data [], input logic [2:0] size,
                             output logic [1:0] resp);
        int len = data.size() - 1;
        logic [AW-1:0] base = addr & ~((AW'(1) << size) - 1);
        wid[i] = IW'($urandom);
        @(posedge clk);
        s_awid[i] <= wid[i]; s_awaddr[i] <= addr; s_awlen[i] <= len[7:0]; s_awsize[i] <= size; s_awburst[i] <= 2'b01;
        s_awvalid[i] <= 1;
        do @(posedge clk); while (!s_awready[i]);
        s_awvalid[i] <= 0;
        for (int k = 0; k <= len; k++) begin
            s_wdata[i] <= data[k]; s_wstrb[i] <= strb((k == 0) ? addr : base + AW'(k << size), size);
            s_wlast[i] <= (k == len); s_wvalid[i] <= 1;
            do @(posedge clk); while (!s_wready[i]);
        end
        s_wvalid[i] <= 0; s_wlast[i] <= 0; s_bready[i] <= 1;
        do @(posedge clk); while (!s_bvalid[i]);
        resp = s_bresp[i];
        if (s_bid[i] != wid[i]) begin errors++; $display("ERROR m%0d bid=%0d want %0d", i, s_bid[i], wid[i]); end
        s_bready[i] <= 0;
    endtask

    task automatic axi_read(input int i, input logic [AW-1:0] addr, input int len, input logic [2:0] size,
                            output logic [DW-1:0] data [], output logic [1:0] resp);
        data = new[len + 1]; resp = 2'b00;
        rid[i] = IW'($urandom);
        @(posedge clk);
        s_arid[i] <= rid[i]; s_araddr[i] <= addr; s_arlen[i] <= len[7:0]; s_arsize[i] <= size; s_arburst[i] <= 2'b01; s_arvalid[i] <= 1;
        do @(posedge clk); while (!s_arready[i]);
        s_arvalid[i] <= 0; s_rready[i] <= 1;
        for (int k = 0; k <= len; k++) begin
            do @(posedge clk); while (!s_rvalid[i]);
            data[k] = s_rdata[i]; resp |= s_rresp[i];
            if (s_rid[i] != rid[i]) begin errors++; $display("ERROR m%0d rid=%0d want %0d", i, s_rid[i], rid[i]); end
            if ((k == len) != s_rlast[i]) begin errors++; $display("ERROR m%0d rlast at beat %0d", i, k); end
        end
        s_rready[i] <= 0;
    endtask

    // random write-then-readback inside master i's private slice of a random slave
    task automatic traffic(input int i, input int n);
        logic [DW-1:0] wd [], rd []; logic [1:0] resp; int j, len; logic [AW-1:0] a;
        repeat (n) begin
            j   = $urandom_range(M - 1);
            len = $urandom_range(7);
            // 1 KiB slice per master: the smallest MI decode window (MI2, 4 KiB) must
            // fit all four masters without spilling into a neighbor's slice or past
            // the window into the unmapped hole; the offset stays clear of the next
            // master's slice for the largest burst (8 beats) at any DW.
            a   = MI_BASE[j] + (i * 32'h400) + ($urandom_range(0, (1024 / (8 * SW)) - 1) * (8 * SW));
            wd  = new[len + 1]; foreach (wd[k]) wd[k] = {$urandom, $urandom};
            axi_write(i, a, wd, $clog2(SW), resp);
            if (resp != 2'b00) begin errors++; $display("ERROR m%0d s%0d bresp=%0d", i, j, resp); end
            axi_read(i, a, len, $clog2(SW), rd, resp);
            if (resp != 2'b00) begin errors++; $display("ERROR m%0d s%0d rresp=%0d", i, j, resp); end
            foreach (wd[k]) if (rd[k] !== wd[k]) begin errors++; $display("ERROR m%0d s%0d @%h beat %0d: %h != %h", i, j, a, k, rd[k], wd[k]); end
        end
    endtask

    // Single-beat write that presents AWVALID and WVALID together (neither
    // waits for the other's ready), unlike axi_write above which is legal
    // but AW-then-W. Needed to prove independence against a slave that
    // withholds AWREADY until it has seen WVALID.
    task automatic axi_write_concurrent(input int i, input logic [AW-1:0] addr, input logic [DW-1:0] data, output logic [1:0] resp);
        wid[i] = IW'($urandom);
        @(posedge clk);
        s_awid[i] <= wid[i]; s_awaddr[i] <= addr; s_awlen[i] <= 8'd0; s_awsize[i] <= $clog2(SW); s_awburst[i] <= 2'b01;
        s_awvalid[i] <= 1;
        s_wdata[i] <= data; s_wstrb[i] <= '1; s_wlast[i] <= 1; s_wvalid[i] <= 1;
        fork
            begin do @(posedge clk); while (!s_awready[i]); s_awvalid[i] <= 0; end
            begin do @(posedge clk); while (!s_wready[i]);  s_wvalid[i]  <= 0; s_wlast[i] <= 0; end
        join
        s_bready[i] <= 1;
        do @(posedge clk); while (!s_bvalid[i]);
        resp = s_bresp[i];
        if (s_bid[i] != wid[i]) begin errors++; $display("ERROR m%0d bid=%0d want %0d", i, s_bid[i], wid[i]); end
        s_bready[i] <= 0;
    endtask

    // AW/W independence: MI0 withholds AWREADY until it has seen WVALID
    // (tb_axi_mem.aw_waits_for_w). A master that presents AW and W together
    // must still complete; a crossbar that gated WVALID on AWREADY deadlocks
    // (caught by the watchdog as [XBAR] FAIL timeout).
    task automatic aw_waits_for_w_test();
        logic [DW-1:0] rd []; logic [1:0] resp;
        logic [AW-1:0] a = MI_BASE[0] + 32'hE000;   // clear of the traffic slices
        aw_waits_for_w[0] = 1'b1;
        axi_write_concurrent(0, a, 32'hA5A5_1234, resp);
        if (resp != 2'b00) begin errors++; $display("ERROR aw_waits_for_w_test: bresp=%0d", resp); end
        axi_read(0, a, 0, $clog2(SW), rd, resp);
        if (resp != 2'b00 || rd[0] !== 32'hA5A5_1234) begin errors++; $display("ERROR aw_waits_for_w_test: readback %h", rd[0]); end
        aw_waits_for_w[0] = 1'b0;
    endtask

    // Early W: hold MI0's AW pending (force_aw_stall) while its W is accepted
    // early (w_ahead_ok); the crossbar must then refuse a second W from the
    // same master (WREADY low) until AW1 is accepted, or that W would land on
    // the wrong transaction. W2 ahead of AW2 is legal AXI, so this also runs
    // under AXI4PC.
    task automatic early_w_held_until_aw_test();
        logic [DW-1:0] rd []; logic [1:0] resp;
        logic [AW-1:0] a0 = MI_BASE[0] + 32'hE100;   // AW1's target: MI0
        logic [AW-1:0] a2 = MI_BASE[2] + 32'h0100;   // AW2's target: MI2, a different slave
        int k;

        w_ahead_ok[0]     <= 1'b1;
        force_aw_stall[0] <= 1'b1;

        @(posedge clk);
        s_awid[0] <= 0; s_awaddr[0] <= a0; s_awlen[0] <= 8'd0; s_awsize[0] <= 3'($clog2(SW)); s_awburst[0] <= 2'b01;
        s_awvalid[0] <= 1;
        s_wdata[0] <= 32'hA1A1_A1A1; s_wstrb[0] <= '1; s_wlast[0] <= 1; s_wvalid[0] <= 1;

        k = 0;
        do begin @(posedge clk); k++; end while (!s_wready[0] && k < 50);
        if (!s_wready[0]) begin errors++; $display("ERROR early_w_held_until_aw_test: W1 never accepted"); end
        s_wvalid[0] <= 0; s_wlast[0] <= 0;

        if (!s_awvalid[0] || s_awready[0]) begin errors++; $display("ERROR early_w_held_until_aw_test: AW1 not still pending"); end

        // Hold W2 (this NBA supersedes the s_wvalid<=0 above): stable, unaccepted
        // while AW1 is outstanding.
        s_wdata[0] <= 32'hB2B2_B2B2; s_wlast[0] <= 1; s_wvalid[0] <= 1;
        for (k = 0; k < 20; k++) begin
            @(posedge clk);
            if (s_wready[0]) begin
                errors++; $display("ERROR early_w_held_until_aw_test: W2 accepted while AW1 pending");
                break;
            end
        end

        force_aw_stall[0] <= 1'b0;
        do @(posedge clk); while (!s_awready[0]);
        s_awvalid[0] <= 0;
        s_bready[0] <= 1;
        do @(posedge clk); while (!s_bvalid[0]);
        resp = s_bresp[0];
        s_bready[0] <= 0;
        if (resp != 2'b00) begin errors++; $display("ERROR early_w_held_until_aw_test: bresp=%0d", resp); end
        w_ahead_ok[0] <= 1'b0;

        axi_read(0, a0, 0, $clog2(SW), rd, resp);
        if (resp != 2'b00 || rd[0] !== 32'hA1A1_A1A1) begin
            errors++; $display("ERROR early_w_held_until_aw_test: MI0 readback %h (want A1A1A1A1)", rd[0]);
        end

        // AW2, to a different slave: the held W2 lands here.
        @(posedge clk);
        s_awaddr[0] <= a2; s_awvalid[0] <= 1;
        fork
            begin do @(posedge clk); while (!s_awready[0]); s_awvalid[0] <= 0; end
            begin do @(posedge clk); while (!s_wready[0]);  s_wvalid[0]  <= 0; s_wlast[0] <= 0; end
        join
        s_bready[0] <= 1;
        do @(posedge clk); while (!s_bvalid[0]);
        resp = s_bresp[0];
        s_bready[0] <= 0;
        if (resp != 2'b00) begin errors++; $display("ERROR early_w_held_until_aw_test: MI2 write bresp=%0d", resp); end

        axi_read(0, a2, 0, $clog2(SW), rd, resp);
        if (resp != 2'b00 || rd[0] !== 32'hB2B2_B2B2) begin errors++; $display("ERROR early_w_held_until_aw_test: MI2 readback %h", rd[0]); end
    endtask

    task automatic decerr(input int i);
        logic [DW-1:0] wd [], rd []; logic [1:0] resp;
        wd = new[4]; foreach (wd[k]) wd[k] = k;
        axi_write(i, UNMAPPED, wd, $clog2(SW), resp);
        if (resp != 2'b11) begin errors++; $display("ERROR m%0d write to unmapped: bresp=%0d", i, resp); end
        axi_read(i, UNMAPPED, 3, $clog2(SW), rd, resp);
        if (resp != 2'b11) begin errors++; $display("ERROR m%0d read from unmapped: rresp=%0d", i, resp); end
    endtask

    initial begin
        s_awvalid = '0; s_wvalid = '0; s_bready = '0; s_arvalid = '0; s_rready = '0; force_aw_stall = '0;
        s_awlock = '0; s_awcache = '0; s_awprot = '0; s_awqos = '0; s_arlock = '0; s_arcache = '0; s_arprot = '0; s_arqos = '0;
        s_wlast = '0; s_wstrb = '0; s_wdata = '0; s_awid = '0; s_arid = '0; s_awaddr = '0; s_araddr = '0;
        s_awlen = '0; s_arlen = '0; s_awsize = '0; s_arsize = '0; s_awburst = '0; s_arburst = '0; aw_waits_for_w = '0; w_ahead_ok = '0;
        repeat (5) @(posedge clk); rstn = 1; repeat (2) @(posedge clk);

        aw_waits_for_w_test();
        early_w_held_until_aw_test();
        fork traffic(0, 200); traffic(1, 200); traffic(2, 200); traffic(3, 200); join
        decerr(0); decerr(3);
        $display("[XBAR] %s errors=%0d", errors ? "FAIL" : "PASS", errors);
        $finish;
    end

    initial begin #5ms; $display("[XBAR] FAIL timeout"); $finish; end

endmodule
