// Simply-V simulation shim (Verilator)
// Description: Behavioral pass-through model for the Xilinx AXI4 64-bit clock
//              converter IP (64-bit MBUS data path, e.g. cv64a6). Both clock
//              domains are derived from the same source in simulation, so no
//              CDC logic is required: every slave-side input is forwarded to
//              the corresponding master-side output and vice-versa.
//
// Port contract verified against:
//   hw/xilinx/rtl/wrappers/axi_clock_converter_wrapper.sv (64: branch)
// 64-bit analog of xlnx_axi_d32_clock_converter.sv. Flat AXI4 port names reuse
// the canonical macros in simplyv_axi.svh to guarantee an exact name match
// with the instantiation. Defaults mirror the MBUS geometry (DATA=64, ADDR=32,
// ID=5) so the unparametrized instantiation binds at the right widths.

`include "simplyv_axi.svh"

module xlnx_axi_d64_clock_converter #(
    parameter int unsigned LOCAL_DATA_WIDTH = 64,
    parameter int unsigned LOCAL_ADDR_WIDTH = 32,
    parameter int unsigned LOCAL_ID_WIDTH   = 5
) (
    // Slave clock/reset
    input logic s_axi_aclk,
    input logic s_axi_aresetn,
    // Master clock/reset
    input logic m_axi_aclk,
    input logic m_axi_aresetn,

    // AXI4 slave interface (one clock domain)
    `DEFINE_AXI_SLAVE_PORTS(s, LOCAL_DATA_WIDTH, LOCAL_ADDR_WIDTH, LOCAL_ID_WIDTH),

    // AXI4 master interface (another clock domain)
    `DEFINE_AXI_MASTER_PORTS(m, LOCAL_DATA_WIDTH, LOCAL_ADDR_WIDTH, LOCAL_ID_WIDTH)
);

    // Pass-through: slave inputs -> master outputs
    // AW channel
    assign m_axi_awid     = s_axi_awid;
    assign m_axi_awaddr   = s_axi_awaddr;
    assign m_axi_awlen    = s_axi_awlen;
    assign m_axi_awsize   = s_axi_awsize;
    assign m_axi_awburst  = s_axi_awburst;
    assign m_axi_awlock   = s_axi_awlock;
    assign m_axi_awcache  = s_axi_awcache;
    assign m_axi_awprot   = s_axi_awprot;
    assign m_axi_awqos    = s_axi_awqos;
    assign m_axi_awregion = s_axi_awregion;
    assign m_axi_awvalid  = s_axi_awvalid;
    // W channel
    assign m_axi_wdata    = s_axi_wdata;
    assign m_axi_wstrb    = s_axi_wstrb;
    assign m_axi_wlast    = s_axi_wlast;
    assign m_axi_wvalid   = s_axi_wvalid;
    // B channel
    assign m_axi_bready   = s_axi_bready;
    // AR channel
    assign m_axi_arid     = s_axi_arid;
    assign m_axi_araddr   = s_axi_araddr;
    assign m_axi_arlen    = s_axi_arlen;
    assign m_axi_arsize   = s_axi_arsize;
    assign m_axi_arburst  = s_axi_arburst;
    assign m_axi_arlock   = s_axi_arlock;
    assign m_axi_arcache  = s_axi_arcache;
    assign m_axi_arprot   = s_axi_arprot;
    assign m_axi_arqos    = s_axi_arqos;
    assign m_axi_arregion = s_axi_arregion;
    assign m_axi_arvalid  = s_axi_arvalid;
    // R channel
    assign m_axi_rready   = s_axi_rready;

    // Pass-through: master inputs -> slave outputs
    // AW/W handshake
    assign s_axi_awready  = m_axi_awready;
    assign s_axi_wready   = m_axi_wready;
    // B channel
    assign s_axi_bid      = m_axi_bid;
    assign s_axi_bresp    = m_axi_bresp;
    assign s_axi_bvalid   = m_axi_bvalid;
    // AR handshake
    assign s_axi_arready  = m_axi_arready;
    // R channel
    assign s_axi_rid      = m_axi_rid;
    assign s_axi_rdata    = m_axi_rdata;
    assign s_axi_rresp    = m_axi_rresp;
    assign s_axi_rlast    = m_axi_rlast;
    assign s_axi_rvalid   = m_axi_rvalid;

endmodule
