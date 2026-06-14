// Simply-V simulation shim (Verilator)
// Description: Wrapper for the Xilinx AXI4-to-AXI4-Lite (32-bit) protocol
//              converter. Wraps the pulp-platform axi_to_axi_lite module:
//              flat Xilinx-style ports on the outside, pulp struct types
//              inside.
//
// Port contract verified against:
//   hw/xilinx/rtl/pbus.sv:331
// Slave side  : full AXI4, flat ports s_axi_*  (reuses DEFINE_AXI_SLAVE_PORTS)
// Master side : AXI4-Lite, flat ports m_axi_*  (NO id, listed explicitly since
//               the instantiation uses the bare m_axi_* naming).
//
// Parameter fix vs old repo: LOCAL_ID_WIDTH default corrected from 5 to 2
// (pbus.sv instantiates with LOCAL_ID_WIDTH=2; old default "MBUS id=5" was wrong).

`include "simplyv_axi.svh"
`include "axi/typedef.svh"

module xlnx_axi4_to_axilite_d32_converter #(
    parameter int unsigned LOCAL_DATA_WIDTH = 32,
    parameter int unsigned LOCAL_ADDR_WIDTH = 32,
    parameter int unsigned LOCAL_ID_WIDTH   = 2,
    localparam int unsigned LOCAL_STRB_WIDTH = LOCAL_DATA_WIDTH / 8
) (
    input logic aclk,
    input logic aresetn,

    // AXI4 slave port (flat s_axi_*)
    `DEFINE_AXI_SLAVE_PORTS(s, LOCAL_DATA_WIDTH, LOCAL_ADDR_WIDTH, LOCAL_ID_WIDTH),

    // AXI4-Lite master port (flat m_axi_*, no id)
    // AW channel
    output logic [LOCAL_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [2:0]                  m_axi_awprot,
    output logic                        m_axi_awvalid,
    input  logic                        m_axi_awready,
    // W channel
    output logic [LOCAL_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [LOCAL_STRB_WIDTH-1:0] m_axi_wstrb,
    output logic                        m_axi_wvalid,
    input  logic                        m_axi_wready,
    // B channel
    input  logic [1:0]                  m_axi_bresp,
    input  logic                        m_axi_bvalid,
    output logic                        m_axi_bready,
    // AR channel
    output logic [LOCAL_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [2:0]                  m_axi_arprot,
    output logic                        m_axi_arvalid,
    input  logic                        m_axi_arready,
    // R channel
    input  logic [LOCAL_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]                  m_axi_rresp,
    input  logic                        m_axi_rvalid,
    output logic                        m_axi_rready
);

    // Build pulp struct types (use non-"axi" prefix to avoid clashing with the
    // axi_resp_t typedef from simplyv_axi.svh).
    `AXI_TYPEDEF_ALL(
        full,
        logic [LOCAL_ADDR_WIDTH-1:0],
        logic [LOCAL_ID_WIDTH-1:0],
        logic [LOCAL_DATA_WIDTH-1:0],
        logic [LOCAL_STRB_WIDTH-1:0],
        logic [0:0]
    )
    `AXI_LITE_TYPEDEF_ALL(
        lite,
        logic [LOCAL_ADDR_WIDTH-1:0],
        logic [LOCAL_DATA_WIDTH-1:0],
        logic [LOCAL_STRB_WIDTH-1:0]
    )

    full_req_t  slv_req;
    full_resp_t slv_rsp;
    lite_req_t  mst_req;
    lite_resp_t mst_rsp;

    // --------- Slave side (flat AXI4 -> struct req) ---------
    // AW
    assign slv_req.aw.id     = s_axi_awid;
    assign slv_req.aw.addr   = s_axi_awaddr;
    assign slv_req.aw.len    = s_axi_awlen;
    assign slv_req.aw.size   = s_axi_awsize;
    assign slv_req.aw.burst  = s_axi_awburst;
    assign slv_req.aw.lock   = s_axi_awlock;
    assign slv_req.aw.cache  = s_axi_awcache;
    assign slv_req.aw.prot   = s_axi_awprot;
    assign slv_req.aw.qos    = s_axi_awqos;
    assign slv_req.aw.region = s_axi_awregion;
    assign slv_req.aw.atop   = '0;
    assign slv_req.aw.user   = '0;
    assign slv_req.aw_valid  = s_axi_awvalid;
    // W
    assign slv_req.w.data    = s_axi_wdata;
    assign slv_req.w.strb    = s_axi_wstrb;
    assign slv_req.w.last    = s_axi_wlast;
    assign slv_req.w.user    = '0;
    assign slv_req.w_valid   = s_axi_wvalid;
    // B
    assign slv_req.b_ready   = s_axi_bready;
    // AR
    assign slv_req.ar.id     = s_axi_arid;
    assign slv_req.ar.addr   = s_axi_araddr;
    assign slv_req.ar.len    = s_axi_arlen;
    assign slv_req.ar.size   = s_axi_arsize;
    assign slv_req.ar.burst  = s_axi_arburst;
    assign slv_req.ar.lock   = s_axi_arlock;
    assign slv_req.ar.cache  = s_axi_arcache;
    assign slv_req.ar.prot   = s_axi_arprot;
    assign slv_req.ar.qos    = s_axi_arqos;
    assign slv_req.ar.region = s_axi_arregion;
    assign slv_req.ar.user   = '0;
    assign slv_req.ar_valid  = s_axi_arvalid;
    // R
    assign slv_req.r_ready   = s_axi_rready;

    // --------- Slave side (struct rsp -> flat AXI4) ---------
    assign s_axi_awready = slv_rsp.aw_ready;
    assign s_axi_wready  = slv_rsp.w_ready;
    assign s_axi_bid     = slv_rsp.b.id;
    assign s_axi_bresp   = slv_rsp.b.resp;
    assign s_axi_bvalid  = slv_rsp.b_valid;
    assign s_axi_arready = slv_rsp.ar_ready;
    assign s_axi_rid     = slv_rsp.r.id;
    assign s_axi_rdata   = slv_rsp.r.data;
    assign s_axi_rresp   = slv_rsp.r.resp;
    assign s_axi_rlast   = slv_rsp.r.last;
    assign s_axi_rvalid  = slv_rsp.r_valid;

    // --------- Master side (struct req -> flat AXI-Lite) ---------
    assign m_axi_awaddr  = mst_req.aw.addr;
    assign m_axi_awprot  = mst_req.aw.prot;
    assign m_axi_awvalid = mst_req.aw_valid;
    assign m_axi_wdata   = mst_req.w.data;
    assign m_axi_wstrb   = mst_req.w.strb;
    assign m_axi_wvalid  = mst_req.w_valid;
    assign m_axi_bready  = mst_req.b_ready;
    assign m_axi_araddr  = mst_req.ar.addr;
    assign m_axi_arprot  = mst_req.ar.prot;
    assign m_axi_arvalid = mst_req.ar_valid;
    assign m_axi_rready  = mst_req.r_ready;

    // --------- Master side (flat AXI-Lite -> struct rsp) ---------
    assign mst_rsp.aw_ready = m_axi_awready;
    assign mst_rsp.w_ready  = m_axi_wready;
    assign mst_rsp.b.resp   = m_axi_bresp;
    assign mst_rsp.b_valid  = m_axi_bvalid;
    assign mst_rsp.ar_ready = m_axi_arready;
    assign mst_rsp.r.data   = m_axi_rdata;
    assign mst_rsp.r.resp   = m_axi_rresp;
    assign mst_rsp.r_valid  = m_axi_rvalid;

    axi_to_axi_lite #(
        .AxiAddrWidth    ( LOCAL_ADDR_WIDTH ),
        .AxiDataWidth    ( LOCAL_DATA_WIDTH ),
        .AxiIdWidth      ( LOCAL_ID_WIDTH   ),
        .AxiUserWidth    ( 1                ),
        .AxiMaxWriteTxns ( 1                ),
        .AxiMaxReadTxns  ( 1                ),
        .FullBW          ( 1'b0             ),
        .FallThrough     ( 1'b1             ),
        .full_req_t      ( full_req_t       ),
        .full_resp_t     ( full_resp_t      ),
        .lite_req_t      ( lite_req_t       ),
        .lite_resp_t     ( lite_resp_t      )
    ) i_axi_to_axi_lite (
        .clk_i      ( aclk    ),
        .rst_ni     ( aresetn ),
        .test_i     ( 1'b0    ),
        .slv_req_i  ( slv_req ),
        .slv_resp_o ( slv_rsp ),
        .mst_req_o  ( mst_req ),
        .mst_resp_i ( mst_rsp )
    );

endmodule
