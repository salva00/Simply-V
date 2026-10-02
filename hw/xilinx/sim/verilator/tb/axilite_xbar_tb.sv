// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: Self-checking bench for simplyv_axilite_xbar. Two masters
//              drive concurrent random write/readback traffic against two
//              AXI-Lite memory slaves with random ready backpressure; one
//              slave additionally withholds AWREADY until it has seen
//              WVALID (tb_axilite_mem.aw_waits_for_w), to prove the
//              crossbar's AW and W handshakes are independent. An unmapped
//              address checks DECERR.
//              +define+AXI4PC binds the ARM AXI4 protocol checker shipped
//              with Vivado on every port. AXI-Lite is a subset of AXI4, so
//              the missing burst/ID fields are tied to legal single-beat
//              constants (ID=0, AWLEN/ARLEN=0, AWBURST/ARBURST=FIXED,
//              WLAST/RLAST=1).

`timescale 1ns/1ps

// AXI4-Lite slave memory with random ready delays, one outstanding
// transaction per channel. aw_waits_for_w models a legal slave (e.g. Xilinx
// axi_lite_ipif) that asserts AWREADY only after observing WVALID.
module tb_axilite_mem #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned MEM_BYTES  = 4096,
    localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8
) (
    input  logic                  aclk,
    input  logic                  aresetn,
    input  logic [ADDR_WIDTH-1:0] awaddr,
    input  logic                  awvalid,
    output logic                  awready,
    input  logic [DATA_WIDTH-1:0] wdata,
    input  logic [STRB_WIDTH-1:0] wstrb,
    input  logic                  wvalid,
    output logic                  wready,
    output logic [1:0]            bresp,
    output logic                  bvalid,
    input  logic                  bready,
    input  logic [ADDR_WIDTH-1:0] araddr,
    input  logic                  arvalid,
    output logic                  arready,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic [1:0]            rresp,
    output logic                  rvalid,
    input  logic                  rready,
    // TB-only: withholds AWREADY until WVALID has been observed.
    input  logic                  aw_waits_for_w
);
    localparam int unsigned AW = $clog2(MEM_BYTES);
    logic [7:0] mem [MEM_BYTES];

    typedef enum logic {W_IDLE, W_RESP} wst_t;
    wst_t wst;
    logic aw_done, w_done, w_seen;
    logic [ADDR_WIDTH-1:0] aw_addr_r;
    logic [DATA_WIDTH-1:0] w_data_r;
    logic [STRB_WIDTH-1:0] w_strb_r;
    logic aw_stall, w_stall;

    assign awready = (wst == W_IDLE) && !aw_done && !aw_stall && (!aw_waits_for_w || w_seen);
    assign wready  = (wst == W_IDLE) && !w_done && !w_stall;
    assign bvalid  = (wst == W_RESP);
    assign bresp   = 2'b00;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            wst <= W_IDLE; aw_done <= 1'b0; w_done <= 1'b0; w_seen <= 1'b0;
            aw_stall <= 1'b0; w_stall <= 1'b0; aw_addr_r <= '0; w_data_r <= '0; w_strb_r <= '0;
        end else begin
            aw_stall <= $urandom_range(0, 3) == 0;
            w_stall  <= $urandom_range(0, 3) == 0;
            case (wst)
                W_IDLE: begin
                    if (awvalid && awready) begin aw_done <= 1'b1; aw_addr_r <= awaddr; w_seen <= 1'b0; end
                    else if (wvalid)        w_seen <= 1'b1;
                    if (wvalid && wready) begin w_done <= 1'b1; w_data_r <= wdata; w_strb_r <= wstrb; end
                    if ((aw_done || (awvalid && awready)) && (w_done || (wvalid && wready))) begin
                        automatic logic [ADDR_WIDTH-1:0] final_addr = aw_done ? aw_addr_r : awaddr;
                        automatic logic [DATA_WIDTH-1:0] final_data = w_done ? w_data_r : wdata;
                        automatic logic [STRB_WIDTH-1:0] final_strb = w_done ? w_strb_r : wstrb;
                        for (int b = 0; b < STRB_WIDTH; b++)
                            if (final_strb[b]) mem[(final_addr[AW-1:0] & ~(STRB_WIDTH-1)) + b] <= final_data[8*b +: 8];
                        wst <= W_RESP; aw_done <= 1'b0; w_done <= 1'b0;
                    end
                end
                W_RESP: if (bready) wst <= W_IDLE;
                default: wst <= W_IDLE;
            endcase
        end
    end

    typedef enum logic {R_IDLE, R_VALID} rst_t;
    rst_t rst;
    logic [ADDR_WIDTH-1:0] r_addr;
    logic r_stall;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin rst <= R_IDLE; r_stall <= 1'b0; end
        else begin
            r_stall <= $urandom_range(0, 3) == 0;
            case (rst)
                R_IDLE:  if (arvalid && arready) begin r_addr <= araddr; rst <= R_VALID; end
                R_VALID: if (rready) rst <= R_IDLE;
                default: rst <= R_IDLE;
            endcase
        end
    end
    assign arready = (rst == R_IDLE) && !r_stall;
    assign rvalid  = (rst == R_VALID);
    assign rresp   = 2'b00;
    always_comb begin
        for (int b = 0; b < STRB_WIDTH; b++) rdata[8*b +: 8] = mem[(r_addr[AW-1:0] & ~(STRB_WIDTH-1)) + b];
    end
endmodule


module axilite_xbar_tb;
    localparam int unsigned N = 2, M = 2, AW = 32, DW = 32, SW = DW / 8;
    localparam logic [AW-1:0] MI_BASE [M] = '{32'h0000_0000, 32'h0001_0000};
    localparam int unsigned   MI_BITS [M] = '{16, 16};
    localparam logic [AW-1:0] UNMAPPED = 32'h0002_0000;

    logic clk = 0, rstn = 0;
    always #5 clk = ~clk;

    logic [N-1:0][AW-1:0] s_awaddr, s_araddr;
    logic [N-1:0][2:0]    s_awprot, s_arprot;
    logic [N-1:0]         s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready, s_arvalid, s_arready, s_rvalid, s_rready;
    logic [N-1:0][DW-1:0] s_wdata, s_rdata;
    logic [N-1:0][SW-1:0] s_wstrb;
    logic [N-1:0][1:0]    s_bresp, s_rresp;

    logic [M-1:0][AW-1:0] m_awaddr, m_araddr;
    logic [M-1:0][2:0]    m_awprot, m_arprot;
    logic [M-1:0]         m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready;
    logic [M-1:0][DW-1:0] m_wdata, m_rdata;
    logic [M-1:0][SW-1:0] m_wstrb;
    logic [M-1:0][1:0]    m_bresp, m_rresp;

    // TB-only: puts a memory port's AW channel in "waits for WVALID" mode.
    logic [M-1:0] aw_waits_for_w;

    simplyv_axilite_xbar #(
        .NUM_SI(N), .NUM_MI(M), .DATA_WIDTH(DW), .ADDR_WIDTH(AW),
        .MI_BASE(MI_BASE), .MI_RANGE_BITS(MI_BITS)
    ) dut (
        .aclk(clk), .aresetn(rstn),
        .s_axi_awaddr(s_awaddr), .s_axi_awprot(s_awprot), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_araddr(s_araddr), .s_axi_arprot(s_arprot), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
        .m_axi_awaddr(m_awaddr), .m_axi_awprot(m_awprot), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_araddr(m_araddr), .m_axi_arprot(m_arprot), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    for (genvar j = 0; j < M; j++) begin : g_mem
        tb_axilite_mem #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW)) mem (
            .aclk(clk), .aresetn(rstn),
            .awaddr(m_awaddr[j]), .awvalid(m_awvalid[j]), .awready(m_awready[j]),
            .wdata(m_wdata[j]), .wstrb(m_wstrb[j]), .wvalid(m_wvalid[j]), .wready(m_wready[j]),
            .bresp(m_bresp[j]), .bvalid(m_bvalid[j]), .bready(m_bready[j]),
            .araddr(m_araddr[j]), .arvalid(m_arvalid[j]), .arready(m_arready[j]),
            .rdata(m_rdata[j]), .rresp(m_rresp[j]), .rvalid(m_rvalid[j]), .rready(m_rready[j]),
            .aw_waits_for_w(aw_waits_for_w[j])
        );
    end

`ifdef AXI4PC
    // AXI-Lite is a subset of AXI4: tie the missing burst/ID fields to legal
    // single-beat constants (ID=0, LEN=0, BURST=FIXED, WLAST/RLAST=1).
    for (genvar i = 0; i < N; i++) begin : g_pc_s
        axi_vip_axi4pc #(
            .WADDR_WIDTH(AW), .RADDR_WIDTH(AW), .WDATA_WIDTH(DW), .RDATA_WIDTH(DW), .WID_WIDTH(1), .RID_WIDTH(1), .MAXWAITS(256)
        ) pc (
            .ACLK(clk), .ACLKEN(1'b1), .ARESETn(rstn),
            .AWID(1'b0), .AWADDR(s_awaddr[i]), .AWLEN(8'd0), .AWSIZE(3'($clog2(SW))), .AWBURST(2'b00), .AWLOCK(1'b0),
            .AWCACHE(4'd0), .AWPROT(s_awprot[i]), .AWQOS(4'd0), .AWREGION(4'd0), .AWUSER(1'b0), .AWVALID(s_awvalid[i]), .AWREADY(s_awready[i]),
            .WLAST(1'b1), .WDATA(s_wdata[i]), .WSTRB(s_wstrb[i]), .WUSER(1'b0), .WVALID(s_wvalid[i]), .WREADY(s_wready[i]),
            .BID(1'b0), .BRESP(s_bresp[i]), .BUSER(1'b0), .BVALID(s_bvalid[i]), .BREADY(s_bready[i]),
            .ARID(1'b0), .ARADDR(s_araddr[i]), .ARLEN(8'd0), .ARSIZE(3'($clog2(SW))), .ARBURST(2'b00), .ARLOCK(1'b0),
            .ARCACHE(4'd0), .ARPROT(s_arprot[i]), .ARQOS(4'd0), .ARREGION(4'd0), .ARUSER(1'b0), .ARVALID(s_arvalid[i]), .ARREADY(s_arready[i]),
            .RID(1'b0), .RLAST(1'b1), .RDATA(s_rdata[i]), .RRESP(s_rresp[i]), .RUSER(1'b0), .RVALID(s_rvalid[i]), .RREADY(s_rready[i]),
            .CACTIVE(1'b1), .CSYSREQ(1'b1), .CSYSACK(1'b1)
        );
    end
    for (genvar j = 0; j < M; j++) begin : g_pc_m
        axi_vip_axi4pc #(
            .WADDR_WIDTH(AW), .RADDR_WIDTH(AW), .WDATA_WIDTH(DW), .RDATA_WIDTH(DW), .WID_WIDTH(1), .RID_WIDTH(1), .MAXWAITS(256)
        ) pc_m (
            .ACLK(clk), .ACLKEN(1'b1), .ARESETn(rstn),
            .AWID(1'b0), .AWADDR(m_awaddr[j]), .AWLEN(8'd0), .AWSIZE(3'($clog2(SW))), .AWBURST(2'b00), .AWLOCK(1'b0),
            .AWCACHE(4'd0), .AWPROT(m_awprot[j]), .AWQOS(4'd0), .AWREGION(4'd0), .AWUSER(1'b0), .AWVALID(m_awvalid[j]), .AWREADY(m_awready[j]),
            .WLAST(1'b1), .WDATA(m_wdata[j]), .WSTRB(m_wstrb[j]), .WUSER(1'b0), .WVALID(m_wvalid[j]), .WREADY(m_wready[j]),
            .BID(1'b0), .BRESP(m_bresp[j]), .BUSER(1'b0), .BVALID(m_bvalid[j]), .BREADY(m_bready[j]),
            .ARID(1'b0), .ARADDR(m_araddr[j]), .ARLEN(8'd0), .ARSIZE(3'($clog2(SW))), .ARBURST(2'b00), .ARLOCK(1'b0),
            .ARCACHE(4'd0), .ARPROT(m_arprot[j]), .ARQOS(4'd0), .ARREGION(4'd0), .ARUSER(1'b0), .ARVALID(m_arvalid[j]), .ARREADY(m_arready[j]),
            .RID(1'b0), .RLAST(1'b1), .RDATA(m_rdata[j]), .RRESP(m_rresp[j]), .RUSER(1'b0), .RVALID(m_rvalid[j]), .RREADY(m_rready[j]),
            .CACTIVE(1'b1), .CSYSREQ(1'b1), .CSYSACK(1'b1)
        );
    end
`endif

    int errors = 0;

    // Presents AWVALID and WVALID together (neither waits on the other's
    // ready), the way a real master is allowed to.
    task automatic axi_write(input int i, input logic [AW-1:0] addr, input logic [DW-1:0] data, output logic [1:0] resp);
        @(posedge clk);
        s_awaddr[i] <= addr; s_awprot[i] <= 3'd0; s_awvalid[i] <= 1;
        s_wdata[i]  <= data; s_wstrb[i]  <= '1;   s_wvalid[i]  <= 1;
        fork
            begin do @(posedge clk); while (!s_awready[i]); s_awvalid[i] <= 0; end
            begin do @(posedge clk); while (!s_wready[i]);  s_wvalid[i]  <= 0; end
        join
        s_bready[i] <= 1;
        do @(posedge clk); while (!s_bvalid[i]);
        resp = s_bresp[i];
        s_bready[i] <= 0;
    endtask

    task automatic axi_read(input int i, input logic [AW-1:0] addr, output logic [DW-1:0] data, output logic [1:0] resp);
        @(posedge clk);
        s_araddr[i] <= addr; s_arprot[i] <= 3'd0; s_arvalid[i] <= 1;
        do @(posedge clk); while (!s_arready[i]);
        s_arvalid[i] <= 0; s_rready[i] <= 1;
        do @(posedge clk); while (!s_rvalid[i]);
        data = s_rdata[i]; resp = s_rresp[i];
        s_rready[i] <= 0;
    endtask

    task automatic traffic(input int i, input int n);
        logic [DW-1:0] wd, rd; logic [1:0] resp; int j; logic [AW-1:0] a;
        repeat (n) begin
            j = $urandom_range(M - 1);
            a = MI_BASE[j] + (i * 32'h100);
            wd = {$urandom};
            axi_write(i, a, wd, resp);
            if (resp != 2'b00) begin errors++; $display("ERROR m%0d s%0d bresp=%0d", i, j, resp); end
            axi_read(i, a, rd, resp);
            if (resp != 2'b00) begin errors++; $display("ERROR m%0d s%0d rresp=%0d", i, j, resp); end
            if (rd !== wd) begin errors++; $display("ERROR m%0d s%0d @%h: %h != %h", i, j, a, rd, wd); end
        end
    endtask

    task automatic decerr(input int i);
        logic [DW-1:0] rd; logic [1:0] resp;
        axi_write(i, UNMAPPED, 32'hDEAD_BEEF, resp);
        if (resp != 2'b11) begin errors++; $display("ERROR m%0d write to unmapped: bresp=%0d", i, resp); end
        axi_read(i, UNMAPPED, rd, resp);
        if (resp != 2'b11) begin errors++; $display("ERROR m%0d read from unmapped: rresp=%0d", i, resp); end
    endtask

    // AW/W independence: MI1 withholds AWREADY until it has seen WVALID. A
    // crossbar that gated WVALID on AWREADY deadlocks (caught by the watchdog).
    task automatic aw_waits_for_w_test();
        logic [DW-1:0] rd; logic [1:0] resp;
        logic [AW-1:0] a = MI_BASE[1] + 32'hF000;
        aw_waits_for_w[1] = 1'b1;
        axi_write(0, a, 32'hA5A5_1234, resp);
        if (resp != 2'b00) begin errors++; $display("ERROR aw_waits_for_w_test: bresp=%0d", resp); end
        axi_read(0, a, rd, resp);
        if (resp != 2'b00 || rd !== 32'hA5A5_1234) begin errors++; $display("ERROR aw_waits_for_w_test: readback %h", rd); end
        aw_waits_for_w[1] = 1'b0;
    endtask

    initial begin
        s_awvalid = '0; s_wvalid = '0; s_bready = '0; s_arvalid = '0; s_rready = '0; aw_waits_for_w = '0;
        s_awaddr = '0; s_araddr = '0; s_wdata = '0; s_wstrb = '0; s_awprot = '0; s_arprot = '0;
        repeat (5) @(posedge clk); rstn = 1; repeat (2) @(posedge clk);

        aw_waits_for_w_test();
        fork traffic(0, 200); traffic(1, 200); join
        decerr(0); decerr(1);

        $display("[AXILITE_XBAR] %s errors=%0d", errors ? "FAIL" : "PASS", errors);
        $finish;
    end

    initial begin #2ms; $display("[AXILITE_XBAR] FAIL timeout"); $finish; end
endmodule
