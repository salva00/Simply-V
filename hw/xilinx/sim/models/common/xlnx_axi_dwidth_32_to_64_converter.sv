// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: Simulation model of the Xilinx AXI4 32-to-64 data-width
//              upsizer. Transactions pass 1:1; the 32-bit lane is steered by
//              addr[2] (wdata replicated, wstrb placed, rdata selected).
//              Limit: single-beat, aligned, <=32-bit accesses.

`include "simplyv_axi.svh"

module xlnx_axi_dwidth_32_to_64_converter #(
    parameter int unsigned S_DATA_WIDTH = 32,
    parameter int unsigned M_DATA_WIDTH = 64,
    parameter int unsigned ADDR_WIDTH   = 32,
    parameter int unsigned ID_WIDTH     = 5
) (
    input logic s_axi_aclk,
    input logic s_axi_aresetn,

    // 32-bit slave (from JTAG/debug)
    `DEFINE_AXI_SLAVE_PORTS(s, S_DATA_WIDTH, ADDR_WIDTH, ID_WIDTH),

    // 64-bit master (to MBUS) - no IDs / rlast / region
    output logic [ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic [0:0]                m_axi_awlock,
    output logic [3:0]                m_axi_awcache,
    output logic [2:0]                m_axi_awprot,
    output logic [3:0]                m_axi_awqos,
    output logic [3:0]                m_axi_awregion,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,
    output logic [M_DATA_WIDTH-1:0]   m_axi_wdata,
    output logic [M_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic                      m_axi_wlast,
    output logic                      m_axi_wvalid,
    input  logic                      m_axi_wready,
    input  logic [1:0]                m_axi_bresp,
    input  logic                      m_axi_bvalid,
    output logic                      m_axi_bready,
    output logic [ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    output logic [0:0]                m_axi_arlock,
    output logic [3:0]                m_axi_arcache,
    output logic [2:0]                m_axi_arprot,
    output logic [3:0]                m_axi_arqos,
    output logic [3:0]                m_axi_arregion,
    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,
    input  logic [M_DATA_WIDTH-1:0]   m_axi_rdata,
    input  logic [1:0]                m_axi_rresp,
    input  logic                      m_axi_rlast,
    input  logic                      m_axi_rvalid,
    output logic                      m_axi_rready
);

    // Lane + ID latched at address handshake (single-outstanding per direction).
    // IDs must be reflected on B/R so the master matches its transaction.
    logic                aw_lane_q, ar_lane_q;
    logic [ID_WIDTH-1:0] aw_id_q, ar_id_q;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            aw_lane_q <= 1'b0;
            ar_lane_q <= 1'b0;
            aw_id_q   <= '0;
            ar_id_q   <= '0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_lane_q <= s_axi_awaddr[2];
                aw_id_q   <= s_axi_awid;
            end
            if (s_axi_arvalid && s_axi_arready) begin
                ar_lane_q <= s_axi_araddr[2];
                ar_id_q   <= s_axi_arid;
            end
        end
    end

    // ---- Write address ----
    assign m_axi_awaddr  = s_axi_awaddr;
    assign m_axi_awlen   = s_axi_awlen;
    assign m_axi_awsize  = 3'd2;             // 4 bytes (single 32-bit word)
    assign m_axi_awburst = s_axi_awburst;
    assign m_axi_awlock  = s_axi_awlock;
    assign m_axi_awcache = s_axi_awcache;
    assign m_axi_awprot  = s_axi_awprot;
    assign m_axi_awqos    = s_axi_awqos;
    assign m_axi_awregion = s_axi_awregion;
    assign m_axi_awvalid  = s_axi_awvalid;
    assign s_axi_awready  = m_axi_awready;

    // ---- Write data: replicate 32-bit data, strobe only the addressed lane ----
    assign m_axi_wdata = {s_axi_wdata, s_axi_wdata};
    assign m_axi_wstrb = aw_lane_q ? {s_axi_wstrb, 4'b0000} : {4'b0000, s_axi_wstrb};
    assign m_axi_wlast = s_axi_wlast;
    assign m_axi_wvalid = s_axi_wvalid;
    assign s_axi_wready = m_axi_wready;

    // ---- Write response ----
    assign s_axi_bid    = aw_id_q;
    assign s_axi_bresp  = m_axi_bresp;
    assign s_axi_bvalid = m_axi_bvalid;
    assign m_axi_bready = s_axi_bready;

    // ---- Read address ----
    assign m_axi_araddr  = s_axi_araddr;
    assign m_axi_arlen   = s_axi_arlen;
    assign m_axi_arsize  = 3'd2;
    assign m_axi_arburst = s_axi_arburst;
    assign m_axi_arlock  = s_axi_arlock;
    assign m_axi_arcache = s_axi_arcache;
    assign m_axi_arprot  = s_axi_arprot;
    assign m_axi_arqos    = s_axi_arqos;
    assign m_axi_arregion = s_axi_arregion;
    assign m_axi_arvalid  = s_axi_arvalid;
    assign s_axi_arready  = m_axi_arready;

    // ---- Read data: pick the addressed 32-bit lane from the 64-bit beat ----
    assign s_axi_rid    = ar_id_q;
    assign s_axi_rdata  = ar_lane_q ? m_axi_rdata[63:32] : m_axi_rdata[31:0];
    assign s_axi_rresp  = m_axi_rresp;
    assign s_axi_rlast  = m_axi_rlast;
    assign s_axi_rvalid = m_axi_rvalid;
    assign m_axi_rready = s_axi_rready;

endmodule
