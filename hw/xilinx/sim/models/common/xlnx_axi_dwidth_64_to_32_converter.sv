// Simply-V simulation shim (Verilator)
// Description: Behavioral model for the Xilinx AXI4 data-width DOWNSIZER IP
//              (64-bit slave -> 32-bit master). Used on the 64-bit MBUS to
//              reach the 32-bit peripheral fabric (PBUS, CLINT, PLIC) when the
//              selected core has a 64-bit data bus (e.g. cv64a6).
//
// Scope / assumptions: the only traffic crossing this converter is single-beat,
//   naturally-aligned, <=32-bit MMIO (peripheral loads/stores are word accesses;
//   caches never target peripherals). A full burst-splitting downsizer is
//   unnecessary: forward the transaction 1:1 and steer the active 32-bit lane
//   by addr[2].
//   - Write: pick the low or high 32-bit half of the 64-bit wdata/wstrb by
//     awaddr[2] and present it on the 32-bit master.
//   - Read: replicate the 32-bit master rdata into both halves of the 64-bit
//     slave rdata (the master reads back the correct lane regardless).
// IDs are reflected slave-side; the master port carries no IDs (matches the
// Xilinx IP's single-downstream-master port map).

`include "simplyv_axi.svh"

module xlnx_axi_dwidth_64_to_32_converter #(
    parameter int unsigned S_DATA_WIDTH = 64,
    parameter int unsigned M_DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH   = 32,
    parameter int unsigned ID_WIDTH     = 5
) (
    input logic s_axi_aclk,
    input logic s_axi_aresetn,

    // 64-bit slave (from MBUS)
    `DEFINE_AXI_SLAVE_PORTS(s, S_DATA_WIDTH, ADDR_WIDTH, ID_WIDTH),

    // 32-bit master (to peripheral) - no IDs (Xilinx IP omits them here)
    output logic [ADDR_WIDTH-1:0]   m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic [0:0]              m_axi_awlock,
    output logic [3:0]              m_axi_awcache,
    output logic [2:0]              m_axi_awprot,
    output logic [3:0]              m_axi_awqos,
    output logic [3:0]              m_axi_awregion,
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,
    output logic [M_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [M_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,
    input  logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,
    output logic [ADDR_WIDTH-1:0]   m_axi_araddr,
    output logic [7:0]              m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic [0:0]              m_axi_arlock,
    output logic [3:0]              m_axi_arcache,
    output logic [2:0]              m_axi_arprot,
    output logic [3:0]              m_axi_arqos,
    output logic [3:0]              m_axi_arregion,
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,
    input  logic [M_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]              m_axi_rresp,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready
);

    // Lane select: which 32-bit half of the 64-bit word the access targets.
    // Latched at address handshake so the data phase uses the right lane.
    // IDs are latched too and reflected on B/R: the master (CVA6) matches its
    // outstanding transaction by ID, so zeroing it deadlocks the core.
    // Single-outstanding per direction (these are single-beat uncached MMIO).
    logic                  aw_lane_q, ar_lane_q;
    logic [ID_WIDTH-1:0]   aw_id_q, ar_id_q;

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

    // ---- Write address: forward, force 32-bit beats ----
    assign m_axi_awaddr   = s_axi_awaddr;
    assign m_axi_awlen    = s_axi_awlen;
    assign m_axi_awsize   = 3'd2;            // 4 bytes on the 32-bit master
    assign m_axi_awburst  = s_axi_awburst;
    assign m_axi_awlock   = s_axi_awlock;
    assign m_axi_awcache  = s_axi_awcache;
    assign m_axi_awprot   = s_axi_awprot;
    assign m_axi_awqos    = s_axi_awqos;
    assign m_axi_awregion = s_axi_awregion;
    assign m_axi_awvalid  = s_axi_awvalid;
    assign s_axi_awready  = m_axi_awready;

    // ---- Write data: select the addressed 32-bit lane ----
    assign m_axi_wdata = aw_lane_q ? s_axi_wdata[63:32] : s_axi_wdata[31:0];
    assign m_axi_wstrb = aw_lane_q ? s_axi_wstrb[7:4]   : s_axi_wstrb[3:0];
    assign m_axi_wlast = s_axi_wlast;
    assign m_axi_wvalid = s_axi_wvalid;
    assign s_axi_wready = m_axi_wready;

    // ---- Write response ----
    assign s_axi_bid    = aw_id_q;
    assign s_axi_bresp  = m_axi_bresp;
    assign s_axi_bvalid = m_axi_bvalid;
    assign m_axi_bready = s_axi_bready;

    // ---- Read address: forward, force 32-bit beats ----
    assign m_axi_araddr   = s_axi_araddr;
    assign m_axi_arlen    = s_axi_arlen;
    assign m_axi_arsize   = 3'd2;
    assign m_axi_arburst  = s_axi_arburst;
    assign m_axi_arlock   = s_axi_arlock;
    assign m_axi_arcache  = s_axi_arcache;
    assign m_axi_arprot   = s_axi_arprot;
    assign m_axi_arqos    = s_axi_arqos;
    assign m_axi_arregion = s_axi_arregion;
    assign m_axi_arvalid  = s_axi_arvalid;
    assign s_axi_arready  = m_axi_arready;

    // ---- Read data: replicate 32-bit master data into both 64-bit lanes ----
    assign s_axi_rid    = ar_id_q;
    assign s_axi_rdata  = {m_axi_rdata, m_axi_rdata};
    assign s_axi_rresp  = m_axi_rresp;
    assign s_axi_rlast  = m_axi_rlast;
    assign s_axi_rvalid = m_axi_rvalid;
    assign m_axi_rready = s_axi_rready;

    // ar_lane_q kept for symmetry/debug; reads replicate so lane is implicit.
    wire _unused_ar_lane = ar_lane_q;

endmodule
