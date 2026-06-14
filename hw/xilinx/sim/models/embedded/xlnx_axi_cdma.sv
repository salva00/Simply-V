// Simulation shim for Xilinx AXI Central DMA (xlnx_axi_cdma).
// AXI-Lite slave side: quiescent (accepts writes/reads, returns OKAY, no stalls).
// AXI4 master side: quiescent (never initiates any transaction).
// Functional outputs tied to 0.
// NOT suitable for functional DMA simulation.
//
// PORT NOTE: s_axi_lite_wstrb is NOT present in the real Xilinx CDMA IP
// (confirmed from simplyv.sv:981 comment "// not present") — it is omitted here.

module xlnx_axi_cdma #(
    parameter int unsigned C_M_AXI_ADDR_WIDTH = 32,
    parameter int unsigned C_M_AXI_DATA_WIDTH = 32
) (
    // Clocks & resets
    input  logic        s_axi_lite_aclk,
    input  logic        s_axi_lite_aresetn,
    input  logic        m_axi_aclk,

    // Interrupt
    output logic        cdma_introut,

    // AXI-Lite control slave interface (no wstrb — not present in real IP)
    input  logic        s_axi_lite_awvalid,
    output logic        s_axi_lite_awready,
    input  logic [31:0] s_axi_lite_awaddr,

    input  logic        s_axi_lite_wvalid,
    output logic        s_axi_lite_wready,
    input  logic [31:0] s_axi_lite_wdata,

    output logic        s_axi_lite_bvalid,
    input  logic        s_axi_lite_bready,
    output logic [1:0]  s_axi_lite_bresp,

    input  logic        s_axi_lite_arvalid,
    output logic        s_axi_lite_arready,
    input  logic [31:0] s_axi_lite_araddr,

    output logic        s_axi_lite_rvalid,
    input  logic        s_axi_lite_rready,
    output logic [31:0] s_axi_lite_rdata,
    output logic [1:0]  s_axi_lite_rresp,

    // AXI4 master write address channel
    output logic [C_M_AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic [2:0]  m_axi_awprot,
    output logic [3:0]  m_axi_awcache,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,

    // AXI4 master write data channel
    output logic [C_M_AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output logic [C_M_AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,

    // AXI4 master write response channel
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    input  logic [1:0]  m_axi_bresp,

    // AXI4 master read address channel
    output logic [C_M_AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic [2:0]  m_axi_arprot,
    output logic [3:0]  m_axi_arcache,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,

    // AXI4 master read data channel
    input  logic [C_M_AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    // Scatter-gather (unused, left open at instantiation)
    output logic        cdma_tvect_out
);

    assign cdma_introut   = 1'b0;
    assign cdma_tvect_out = 1'b0;

    // ----- AXI-Lite slave: quiescent write/read FSM -----
    typedef enum logic [1:0] {IDLE, WDATA, WRESP, RRESP} state_t;
    state_t wr_state, rd_state;

    // Write FSM
    always_ff @(posedge s_axi_lite_aclk or negedge s_axi_lite_aresetn) begin
        if (!s_axi_lite_aresetn) wr_state <= IDLE;
        else case (wr_state)
            IDLE:  if (s_axi_lite_awvalid & s_axi_lite_awready) wr_state <= WDATA;
            WDATA: if (s_axi_lite_wvalid  & s_axi_lite_wready)  wr_state <= WRESP;
            WRESP: if (s_axi_lite_bready)                        wr_state <= IDLE;
            default: wr_state <= IDLE;
        endcase
    end

    assign s_axi_lite_awready = (wr_state == IDLE);
    assign s_axi_lite_wready  = (wr_state == WDATA);
    assign s_axi_lite_bvalid  = (wr_state == WRESP);
    assign s_axi_lite_bresp   = 2'b00; // OKAY

    // Read FSM
    always_ff @(posedge s_axi_lite_aclk or negedge s_axi_lite_aresetn) begin
        if (!s_axi_lite_aresetn) rd_state <= IDLE;
        else case (rd_state)
            IDLE:  if (s_axi_lite_arvalid & s_axi_lite_arready) rd_state <= RRESP;
            RRESP: if (s_axi_lite_rready)                        rd_state <= IDLE;
            default: rd_state <= IDLE;
        endcase
    end

    assign s_axi_lite_arready = (rd_state == IDLE);
    assign s_axi_lite_rvalid  = (rd_state == RRESP);
    assign s_axi_lite_rdata   = '0;
    assign s_axi_lite_rresp   = 2'b00; // OKAY

    // ----- AXI4 master: quiescent (never initiate) -----
    assign m_axi_awaddr  = '0;
    assign m_axi_awlen   = '0;
    assign m_axi_awsize  = '0;
    assign m_axi_awburst = '0;
    assign m_axi_awprot  = '0;
    assign m_axi_awcache = '0;
    assign m_axi_awvalid = 1'b0;

    assign m_axi_wdata   = '0;
    assign m_axi_wstrb   = '0;
    assign m_axi_wlast   = 1'b0;
    assign m_axi_wvalid  = 1'b0;

    assign m_axi_bready  = 1'b1;

    assign m_axi_araddr  = '0;
    assign m_axi_arlen   = '0;
    assign m_axi_arsize  = '0;
    assign m_axi_arburst = '0;
    assign m_axi_arprot  = '0;
    assign m_axi_arcache = '0;
    assign m_axi_arvalid = 1'b0;

    assign m_axi_rready  = 1'b1;

endmodule
