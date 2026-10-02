// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: xsim bench for simplyv_axi_xbar with the Xilinx AXI VIP: four
//              master agents drive constrained-random write/readback traffic
//              through the crossbar to four slave memory agents; the VIP
//              protocol checker guards every port. Routing is verified by a
//              backdoor read of the targeted slave memory; an unmapped address
//              must return DECERR.

import axi_vip_pkg::*;

module xbar_vip_tb;
    localparam int N = 4, M = 4, AW = 32, DW = 32, IW = 5, SW = DW / 8;
    localparam logic [AW-1:0] MI_BASE [M] = '{32'h0000_0000, 32'h0001_0000, 32'h0002_0000, 32'h0400_0000};
    localparam int unsigned   MI_BITS [M] = '{16, 16, 12, 26};
    localparam logic [AW-1:0] UNMAPPED = 32'h0003_0000;

    bit clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // crossbar-side wires, element-major (same declarations as xbar_tb)
    logic [N-1:0][IW-1:0] s_awid, s_bid, s_arid, s_rid;
    logic [N-1:0][AW-1:0] s_awaddr, s_araddr;
    logic [N-1:0][7:0]    s_awlen, s_arlen;
    logic [N-1:0][2:0]    s_awsize, s_arsize, s_awprot, s_arprot;
    logic [N-1:0][1:0]    s_awburst, s_arburst, s_bresp, s_rresp;
    logic [N-1:0][3:0]    s_awcache, s_arcache, s_awqos, s_arqos;
    logic [N-1:0]         s_awlock, s_arlock, s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready, s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;
    logic [N-1:0][DW-1:0] s_wdata, s_rdata;
    logic [N-1:0][SW-1:0] s_wstrb;
    logic [M-1:0][IW-1:0] m_awid, m_bid, m_arid, m_rid;
    logic [M-1:0][AW-1:0] m_awaddr, m_araddr;
    logic [M-1:0][7:0]    m_awlen, m_arlen;
    logic [M-1:0][2:0]    m_awsize, m_arsize, m_awprot, m_arprot;
    logic [M-1:0][1:0]    m_awburst, m_arburst, m_bresp, m_rresp;
    logic [M-1:0][3:0]    m_awcache, m_arcache, m_awqos, m_arqos, m_awregion, m_arregion;
    logic [M-1:0]         m_awlock, m_arlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
    logic [M-1:0][DW-1:0] m_wdata, m_rdata;
    logic [M-1:0][SW-1:0] m_wstrb;

    // Master VIPs: m_axi_* drives the crossbar slave port i; the VIP's own s_axi_* side is unused
    for (genvar i = 0; i < N; i++) begin : g_mst
        axi_vip_v1_1_19_top #(
            .C_AXI_PROTOCOL(0), .C_AXI_INTERFACE_MODE(0), .C_AXI_ADDR_WIDTH(AW), .C_AXI_WDATA_WIDTH(DW), .C_AXI_RDATA_WIDTH(DW),
            .C_AXI_WID_WIDTH(IW), .C_AXI_RID_WIDTH(IW), .C_AXI_AWUSER_WIDTH(0), .C_AXI_ARUSER_WIDTH(0), .C_AXI_WUSER_WIDTH(0),
            .C_AXI_RUSER_WIDTH(0), .C_AXI_BUSER_WIDTH(0), .C_AXI_SUPPORTS_NARROW(1), .C_AXI_HAS_BURST(1), .C_AXI_HAS_LOCK(1),
            .C_AXI_HAS_CACHE(1), .C_AXI_HAS_REGION(1), .C_AXI_HAS_PROT(1), .C_AXI_HAS_QOS(1), .C_AXI_HAS_WSTRB(1),
            .C_AXI_HAS_BRESP(1), .C_AXI_HAS_RRESP(1), .C_AXI_HAS_ARESETN(1)
        ) vip (
            .aclk(clk), .aclken(1'b1), .aresetn(rstn),
            .m_axi_awid(s_awid[i]), .m_axi_awaddr(s_awaddr[i]), .m_axi_awlen(s_awlen[i]), .m_axi_awsize(s_awsize[i]), .m_axi_awburst(s_awburst[i]),
            .m_axi_awlock(s_awlock[i]), .m_axi_awcache(s_awcache[i]), .m_axi_awprot(s_awprot[i]), .m_axi_awregion(), .m_axi_awqos(s_awqos[i]), .m_axi_awuser(),
            .m_axi_awvalid(s_awvalid[i]), .m_axi_awready(s_awready[i]),
            .m_axi_wid(), .m_axi_wdata(s_wdata[i]), .m_axi_wstrb(s_wstrb[i]), .m_axi_wlast(s_wlast[i]), .m_axi_wuser(), .m_axi_wvalid(s_wvalid[i]), .m_axi_wready(s_wready[i]),
            .m_axi_bid(s_bid[i]), .m_axi_bresp(s_bresp[i]), .m_axi_buser(), .m_axi_bvalid(s_bvalid[i]), .m_axi_bready(s_bready[i]),
            .m_axi_arid(s_arid[i]), .m_axi_araddr(s_araddr[i]), .m_axi_arlen(s_arlen[i]), .m_axi_arsize(s_arsize[i]), .m_axi_arburst(s_arburst[i]),
            .m_axi_arlock(s_arlock[i]), .m_axi_arcache(s_arcache[i]), .m_axi_arprot(s_arprot[i]), .m_axi_arregion(), .m_axi_arqos(s_arqos[i]), .m_axi_aruser(),
            .m_axi_arvalid(s_arvalid[i]), .m_axi_arready(s_arready[i]),
            .m_axi_rid(s_rid[i]), .m_axi_rdata(s_rdata[i]), .m_axi_rresp(s_rresp[i]), .m_axi_rlast(s_rlast[i]), .m_axi_ruser(), .m_axi_rvalid(s_rvalid[i]), .m_axi_rready(s_rready[i]),
            // unused slave-side interface of a master-mode VIP: inputs tied off, outputs open
            .s_axi_awid('0), .s_axi_awaddr('0), .s_axi_awlen('0), .s_axi_awsize('0), .s_axi_awburst('0), .s_axi_awlock('0), .s_axi_awcache('0),
            .s_axi_awprot('0), .s_axi_awregion('0), .s_axi_awqos('0), .s_axi_awuser('0), .s_axi_awvalid(1'b0), .s_axi_awready(),
            .s_axi_wid('0), .s_axi_wdata('0), .s_axi_wstrb('0), .s_axi_wlast(1'b0), .s_axi_wuser('0), .s_axi_wvalid(1'b0), .s_axi_wready(),
            .s_axi_bid(), .s_axi_bresp(), .s_axi_buser(), .s_axi_bvalid(), .s_axi_bready(1'b0),
            .s_axi_arid('0), .s_axi_araddr('0), .s_axi_arlen('0), .s_axi_arsize('0), .s_axi_arburst('0), .s_axi_arlock('0), .s_axi_arcache('0),
            .s_axi_arprot('0), .s_axi_arregion('0), .s_axi_arqos('0), .s_axi_aruser('0), .s_axi_arvalid(1'b0), .s_axi_arready(),
            .s_axi_rid(), .s_axi_rdata(), .s_axi_rresp(), .s_axi_rlast(), .s_axi_ruser(), .s_axi_rvalid(), .s_axi_rready(1'b0)
        );
    end

    // Slave VIPs (memory model): s_axi_* receives the crossbar master port j
    for (genvar j = 0; j < M; j++) begin : g_slv
        axi_vip_v1_1_19_top #(
            .C_AXI_PROTOCOL(0), .C_AXI_INTERFACE_MODE(2), .C_AXI_ADDR_WIDTH(AW), .C_AXI_WDATA_WIDTH(DW), .C_AXI_RDATA_WIDTH(DW),
            .C_AXI_WID_WIDTH(IW), .C_AXI_RID_WIDTH(IW), .C_AXI_AWUSER_WIDTH(0), .C_AXI_ARUSER_WIDTH(0), .C_AXI_WUSER_WIDTH(0),
            .C_AXI_RUSER_WIDTH(0), .C_AXI_BUSER_WIDTH(0), .C_AXI_SUPPORTS_NARROW(1), .C_AXI_HAS_BURST(1), .C_AXI_HAS_LOCK(1),
            .C_AXI_HAS_CACHE(1), .C_AXI_HAS_REGION(1), .C_AXI_HAS_PROT(1), .C_AXI_HAS_QOS(1), .C_AXI_HAS_WSTRB(1),
            .C_AXI_HAS_BRESP(1), .C_AXI_HAS_RRESP(1), .C_AXI_HAS_ARESETN(1)
        ) vip (
            .aclk(clk), .aclken(1'b1), .aresetn(rstn),
            .s_axi_awid(m_awid[j]), .s_axi_awaddr(m_awaddr[j]), .s_axi_awlen(m_awlen[j]), .s_axi_awsize(m_awsize[j]), .s_axi_awburst(m_awburst[j]),
            .s_axi_awlock(m_awlock[j]), .s_axi_awcache(m_awcache[j]), .s_axi_awprot(m_awprot[j]), .s_axi_awregion(m_awregion[j]), .s_axi_awqos(m_awqos[j]), .s_axi_awuser('0),
            .s_axi_awvalid(m_awvalid[j]), .s_axi_awready(m_awready[j]),
            .s_axi_wid('0), .s_axi_wdata(m_wdata[j]), .s_axi_wstrb(m_wstrb[j]), .s_axi_wlast(m_wlast[j]), .s_axi_wuser('0), .s_axi_wvalid(m_wvalid[j]), .s_axi_wready(m_wready[j]),
            .s_axi_bid(m_bid[j]), .s_axi_bresp(m_bresp[j]), .s_axi_buser(), .s_axi_bvalid(m_bvalid[j]), .s_axi_bready(m_bready[j]),
            .s_axi_arid(m_arid[j]), .s_axi_araddr(m_araddr[j]), .s_axi_arlen(m_arlen[j]), .s_axi_arsize(m_arsize[j]), .s_axi_arburst(m_arburst[j]),
            .s_axi_arlock(m_arlock[j]), .s_axi_arcache(m_arcache[j]), .s_axi_arprot(m_arprot[j]), .s_axi_arregion(m_arregion[j]), .s_axi_arqos(m_arqos[j]), .s_axi_aruser('0),
            .s_axi_arvalid(m_arvalid[j]), .s_axi_arready(m_arready[j]),
            .s_axi_rid(m_rid[j]), .s_axi_rdata(m_rdata[j]), .s_axi_rresp(m_rresp[j]), .s_axi_rlast(m_rlast[j]), .s_axi_ruser(), .s_axi_rvalid(m_rvalid[j]), .s_axi_rready(m_rready[j]),
            // unused master-side interface of a slave-mode VIP
            .m_axi_awid(), .m_axi_awaddr(), .m_axi_awlen(), .m_axi_awsize(), .m_axi_awburst(), .m_axi_awlock(), .m_axi_awcache(),
            .m_axi_awprot(), .m_axi_awregion(), .m_axi_awqos(), .m_axi_awuser(), .m_axi_awvalid(), .m_axi_awready(1'b0),
            .m_axi_wid(), .m_axi_wdata(), .m_axi_wstrb(), .m_axi_wlast(), .m_axi_wuser(), .m_axi_wvalid(), .m_axi_wready(1'b0),
            .m_axi_bid('0), .m_axi_bresp('0), .m_axi_buser('0), .m_axi_bvalid(1'b0), .m_axi_bready(),
            .m_axi_arid(), .m_axi_araddr(), .m_axi_arlen(), .m_axi_arsize(), .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(),
            .m_axi_arprot(), .m_axi_arregion(), .m_axi_arqos(), .m_axi_aruser(), .m_axi_arvalid(), .m_axi_arready(1'b0),
            .m_axi_rid('0), .m_axi_rdata('0), .m_axi_rresp('0), .m_axi_rlast(1'b0), .m_axi_ruser('0), .m_axi_rvalid(1'b0), .m_axi_rready()
        );
    end

    simplyv_axi_xbar #(
        .NUM_SI(N), .NUM_MI(M), .DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ID_WIDTH(IW),
        .MI_BASE(MI_BASE), .MI_RANGE_BITS(MI_BITS), .ATOMICS_MASK(4'b0011)
    ) dut (
        .aclk(clk), .aresetn(rstn),
        .s_axi_awid(s_awid), .s_axi_awaddr(s_awaddr), .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize), .s_axi_awburst(s_awburst),
        .s_axi_awlock(s_awlock), .s_axi_awcache(s_awcache), .s_axi_awprot(s_awprot), .s_axi_awqos(s_awqos), .s_axi_awatop('0),
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

    typedef axi_mst_agent     #(0, AW, DW, DW, IW, IW, 0,0,0,0,0, 1,1,1,1,1,1,1,1,1,1,1) mst_t;
    typedef axi_slv_mem_agent #(0, AW, DW, DW, IW, IW, 0,0,0,0,0, 1,1,1,1,1,1,1,1,1,1,1) slv_t;
    mst_t mst [N];
    slv_t slv [M];
    int errors = 0;

    task automatic traffic(int i, int n);
        axi_transaction wr, rd; int j, nbeats; bit [8*4096-1:0] wb, rb;
        repeat (n) begin
            j  = $urandom_range(M - 1);
            wr = mst[i].wr_driver.create_transaction($sformatf("m%0d_wr", i));
            // 1 KiB slice per master: the smallest MI decode window (MI2, 4 KiB)
            // must fit all four masters without spilling into a neighbor's slice.
            if (!wr.randomize() with { addr inside {[MI_BASE[j] + i * 32'h400 : MI_BASE[j] + i * 32'h400 + 32'h3C0]};
                                       burst == XIL_AXI_BURST_TYPE_INCR; len < 8; size == XIL_AXI_SIZE_4BYTE; id == i; })
                $fatal(1, "randomize");
            wr.set_driver_return_item_policy(XIL_AXI_PAYLOAD_RETURN);
            mst[i].wr_driver.send(wr); mst[i].wr_driver.wait_rsp(wr);
            if (wr.get_bresp() != XIL_AXI_RESP_OKAY) begin errors++; $display("ERROR m%0d bresp=%0d", i, wr.get_bresp()); end
            rd = mst[i].rd_driver.create_transaction($sformatf("m%0d_rd", i));
            rd.set_read_cmd(wr.get_addr(), wr.get_burst(), wr.get_id(), wr.get_len(), wr.get_size());
            rd.set_driver_return_item_policy(XIL_AXI_PAYLOAD_RETURN);
            mst[i].rd_driver.send(rd); mst[i].rd_driver.wait_rsp(rd);
            wb = wr.get_data_block(); rb = rd.get_data_block();
            if (rb !== wb) begin errors++; $display("ERROR m%0d s%0d data @%h", i, j, wr.get_addr()); end
            // per-beat: rresp (OKAY expected) and a backdoor routing check at every beat's
            // own address, not just the first -- size==4BYTE so beats are 4-byte-contiguous.
            nbeats = wr.get_len() + 1;
            for (int k = 0; k < nbeats; k++) begin
                if (rd.get_rresp(k) != XIL_AXI_RESP_OKAY) begin errors++; $display("ERROR m%0d s%0d rresp beat%0d=%0d", i, j, k, rd.get_rresp(k)); end
                if (slv[j].mem_model.backdoor_memory_read_4byte((wr.get_addr() & ~32'h3) + k * 4) !== wb[32*k +: 32]) begin
                    errors++; $display("ERROR routing m%0d->s%0d beat%0d", i, j, k);
                end
            end
        end
    endtask

    // DECERR is expected on this one read: silence the VIP's own read-response
    // check only around this transaction, then restore it so the rest of
    // master 0's traffic (before and after this call) stays fully checked.
    // Hardcoded to g_mst[0]: a generate-block instance cannot be hierarchically
    // referenced through a non-constant index, and this task is only ever
    // called as decerr(0).
    task automatic decerr(int i);
        axi_transaction rd = mst[i].rd_driver.create_transaction("decerr");
        rd.set_read_cmd(UNMAPPED, XIL_AXI_BURST_TYPE_INCR, i, 0, XIL_AXI_SIZE_4BYTE);
        rd.set_driver_return_item_policy(XIL_AXI_PAYLOAD_RETURN);
        g_mst[0].vip.IF.clr_read_response_error_check();
        mst[i].rd_driver.send(rd); mst[i].rd_driver.wait_rsp(rd);
        g_mst[0].vip.IF.set_read_response_error_check();
        if (rd.get_rresp(0) != XIL_AXI_RESP_DECERR) begin errors++; $display("ERROR m%0d no DECERR", i); end
    endtask

    initial begin
        repeat (20) @(posedge clk); rstn = 1; repeat (2) @(posedge clk);
        mst[0] = new("m0", g_mst[0].vip.IF); mst[1] = new("m1", g_mst[1].vip.IF); mst[2] = new("m2", g_mst[2].vip.IF); mst[3] = new("m3", g_mst[3].vip.IF);
        slv[0] = new("s0", g_slv[0].vip.IF); slv[1] = new("s1", g_slv[1].vip.IF); slv[2] = new("s2", g_slv[2].vip.IF); slv[3] = new("s3", g_slv[3].vip.IF);
        foreach (mst[i]) begin mst[i].set_agent_tag($sformatf("M%0d", i)); mst[i].start_master(); end
        foreach (slv[j]) begin slv[j].set_agent_tag($sformatf("S%0d", j)); slv[j].start_slave(); end
        fork traffic(0, 200); traffic(1, 200); traffic(2, 200); traffic(3, 200); join
        decerr(0);
        foreach (mst[i]) mst[i].wait_drivers_idle();
        $display("[XBAR-VIP] %s errors=%0d", errors ? "FAIL" : "PASS", errors);
        if (errors) $fatal(1, "scoreboard errors");
        $finish;
    end
endmodule
