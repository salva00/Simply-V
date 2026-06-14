// Xilinx JTAG-to-AXI Master simulation stub.
// Quiescent AXI master: no transactions initiated; all *valid outputs = 0,
// all *ready outputs = 1 to drain any incoming responses.
// Port contract verified against sys_master.sv:510 (LOCAL_ID_WIDTH=2).
// Port fix vs old repo: m_axi_arid widened from [0:0] to [1:0] to match
// DECLARE_AXI_BUS(jtag_to_axi_dwidth_converter, 32, LOCAL_ADDR_WIDTH, 2).
// NOT suitable for functional JTAG-AXI simulation.

module xlnx_jtag_axi (
    input  logic        aclk,
    input  logic        aresetn,

    // AXI4 Master write address channel
    output logic [1:0]  m_axi_awid,
    output logic [31:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awlock,
    output logic [3:0]  m_axi_awcache,
    output logic [2:0]  m_axi_awprot,
    output logic [3:0]  m_axi_awqos,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,

    // AXI4 Master write data channel
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,

    // AXI4 Master write response channel
    input  logic [1:0]  m_axi_bid,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,

    // AXI4 Master read address channel
    output logic [1:0]  m_axi_arid,
    output logic [31:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arlock,
    output logic [3:0]  m_axi_arcache,
    output logic [2:0]  m_axi_arprot,
    output logic [3:0]  m_axi_arqos,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,

    // AXI4 Master read data channel
    input  logic [1:0]  m_axi_rid,
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready
);
    // Write address channel: never initiate
    assign m_axi_awid    = '0;
    assign m_axi_awaddr  = '0;
    assign m_axi_awlen   = '0;
    assign m_axi_awsize  = '0;
    assign m_axi_awburst = '0;
    assign m_axi_awlock  = '0;
    assign m_axi_awcache = '0;
    assign m_axi_awprot  = '0;
    assign m_axi_awqos   = '0;
    assign m_axi_awvalid = 1'b0;

    // Write data channel: never initiate
    assign m_axi_wdata   = '0;
    assign m_axi_wstrb   = '0;
    assign m_axi_wlast   = 1'b0;
    assign m_axi_wvalid  = 1'b0;

    // Write response channel: always ready to accept (drain)
    assign m_axi_bready  = 1'b1;

    // Read address channel: never initiate
    assign m_axi_arid    = '0;
    assign m_axi_araddr  = '0;
    assign m_axi_arlen   = '0;
    assign m_axi_arsize  = '0;
    assign m_axi_arburst = '0;
    assign m_axi_arlock  = '0;
    assign m_axi_arcache = '0;
    assign m_axi_arprot  = '0;
    assign m_axi_arqos   = '0;
    assign m_axi_arvalid = 1'b0;

    // Read data channel: always ready to accept (drain)
    assign m_axi_rready  = 1'b1;
endmodule
