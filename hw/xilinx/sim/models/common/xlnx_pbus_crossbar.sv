// Author: Simply-V simulation shim (Verilator)
// Description: Wrapper for the Xilinx AXI4-Lite peripheral crossbar (PBUS).
//              Wraps the pulp-platform axi_lite_xbar module: flat
//              Xilinx-style array ports on the outside, pulp struct types
//              inside. EMBEDDED PBUS: 1 slave port, 5 master ports, 32-bit.
//
// Port contract transcribed from:
//   hw/xilinx/rtl/pbus.sv:397
// The instantiation drives packed-array AXI-Lite signals on bare
// s_axi_*/m_axi_* names, so the port list is written explicitly to match.
//
// Master-port (xbar slave) order (LSB-first concat):
//   [0]=UART [1]=GPIOOUT [2]=GPIOIN [3]=TIM_0 [4]=TIM_1
// Address map comes from sim_addrmap_pkg (generated from config CSVs).
//
// NOTES:
//  - LatencyMode = CUT_ALL_PORTS inserts spill registers on every channel.
//    This is functionally fine for simulation and breaks the wide
//    combinational valid/ready cycle through the SoC fabric that otherwise
//    triggers a Verilator 5.040 V3DfgBreakCycles internal error
//    ("Wrong result width") at the default optimization level.
//  - AXI-Lite has no id fields; AxiIdWidthSlvPorts/AxiIdUsedSlvPorts are
//    unused and set to 0 in the xbar config.

`include "simplyv_axi.svh"
`include "axi/typedef.svh"

module xlnx_pbus_crossbar #(
    parameter int unsigned LOCAL_DATA_WIDTH = 32,
    parameter int unsigned LOCAL_ADDR_WIDTH = 32,
    parameter int unsigned NUM_SI           = 1,   // PBUS slave ports
    parameter int unsigned NUM_MI           = 5,   // PBUS master ports
    localparam int unsigned LOCAL_STRB_WIDTH = LOCAL_DATA_WIDTH / 8
) (
    input logic aclk,
    input logic aresetn,

    // Slave port array (flat s_axi_*, element-major: [NUM_SI-1:0][WIDTH-1:0])
    // AW
    input  logic [NUM_SI-1:0] [LOCAL_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [NUM_SI-1:0] [2:0] s_axi_awprot,
    input  logic [NUM_SI-1:0] [0:0] s_axi_awvalid,
    output logic [NUM_SI-1:0] [0:0] s_axi_awready,
    // W
    input  logic [NUM_SI-1:0] [LOCAL_DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [NUM_SI-1:0] [LOCAL_STRB_WIDTH-1:0] s_axi_wstrb,
    input  logic [NUM_SI-1:0] [0:0] s_axi_wvalid,
    output logic [NUM_SI-1:0] [0:0] s_axi_wready,
    // B
    output logic [NUM_SI-1:0] [1:0] s_axi_bresp,
    output logic [NUM_SI-1:0] [0:0] s_axi_bvalid,
    input  logic [NUM_SI-1:0] [0:0] s_axi_bready,
    // AR
    input  logic [NUM_SI-1:0] [LOCAL_ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [NUM_SI-1:0] [2:0] s_axi_arprot,
    input  logic [NUM_SI-1:0] [0:0] s_axi_arvalid,
    output logic [NUM_SI-1:0] [0:0] s_axi_arready,
    // R
    output logic [NUM_SI-1:0] [LOCAL_DATA_WIDTH-1:0] s_axi_rdata,
    output logic [NUM_SI-1:0] [1:0] s_axi_rresp,
    output logic [NUM_SI-1:0] [0:0] s_axi_rvalid,
    input  logic [NUM_SI-1:0] [0:0] s_axi_rready,

    // Master port array (flat m_axi_*, element-major: [NUM_MI-1:0][WIDTH-1:0])
    // AW
    output logic [NUM_MI-1:0] [LOCAL_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [NUM_MI-1:0] [2:0] m_axi_awprot,
    output logic [NUM_MI-1:0] [0:0] m_axi_awvalid,
    input  logic [NUM_MI-1:0] [0:0] m_axi_awready,
    // W
    output logic [NUM_MI-1:0] [LOCAL_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [NUM_MI-1:0] [LOCAL_STRB_WIDTH-1:0] m_axi_wstrb,
    output logic [NUM_MI-1:0] [0:0] m_axi_wvalid,
    input  logic [NUM_MI-1:0] [0:0] m_axi_wready,
    // B
    input  logic [NUM_MI-1:0] [1:0] m_axi_bresp,
    input  logic [NUM_MI-1:0] [0:0] m_axi_bvalid,
    output logic [NUM_MI-1:0] [0:0] m_axi_bready,
    // AR
    output logic [NUM_MI-1:0] [LOCAL_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [NUM_MI-1:0] [2:0] m_axi_arprot,
    output logic [NUM_MI-1:0] [0:0] m_axi_arvalid,
    input  logic [NUM_MI-1:0] [0:0] m_axi_arready,
    // R
    input  logic [NUM_MI-1:0] [LOCAL_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [NUM_MI-1:0] [1:0] m_axi_rresp,
    input  logic [NUM_MI-1:0] [0:0] m_axi_rvalid,
    output logic [NUM_MI-1:0] [0:0] m_axi_rready
);

    // AXI-Lite struct types
    `AXI_LITE_TYPEDEF_ALL(
        lite,
        logic [LOCAL_ADDR_WIDTH-1:0],
        logic [LOCAL_DATA_WIDTH-1:0],
        logic [LOCAL_STRB_WIDTH-1:0]
    )

    lite_req_t  [NUM_SI-1:0] slv_req;
    lite_resp_t [NUM_SI-1:0] slv_rsp;
    lite_req_t  [NUM_MI-1:0] mst_req;
    lite_resp_t [NUM_MI-1:0] mst_rsp;

    // Address map from sim_addrmap_pkg (generated from the config CSVs —
    // single source of truth). RuleStart/RuleEnd are 64-bit in the package;
    // sliced to [31:0] for LOCAL_ADDR_WIDTH=32.
    // RuleIdx order (sorted by base addr) == Vivado IP M-port order ==
    // CONCAT slave array index (last CONCAT arg = idx 0). Verified ground-truth.
    localparam int unsigned NoAddrRules = sim_addrmap_pkg::PBUS_NumRules;
    axi_pkg::xbar_rule_32_t [NoAddrRules-1:0] AddrMap;
    for (genvar r = 0; r < NoAddrRules; r++) begin : gen_addr_map
        assign AddrMap[r] = '{
            idx:        sim_addrmap_pkg::PBUS_RuleIdx[r],
            start_addr: sim_addrmap_pkg::PBUS_RuleStart[r][31:0],
            end_addr:   sim_addrmap_pkg::PBUS_RuleEnd[r][31:0]
        };
    end

    // Crossbar configuration
    localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts:         NUM_SI,
        NoMstPorts:         NUM_MI,
        MaxMstTrans:        32'd8,
        MaxSlvTrans:        32'd8,
        FallThrough:        1'b0,
        // CUT_ALL_PORTS inserts spill registers on every channel, breaking the
        // wide combinational valid/ready cycle through the SoC fabric that can
        // trigger a Verilator 5.040 V3DfgBreakCycles internal error.
        LatencyMode:        axi_pkg::CUT_ALL_PORTS,
        PipelineStages:     32'd0,
        AxiIdWidthSlvPorts: 32'd0,  // unused for AXI-Lite
        AxiIdUsedSlvPorts:  32'd0,  // unused for AXI-Lite
        UniqueIds:          1'b0,
        AxiAddrWidth:       LOCAL_ADDR_WIDTH,
        AxiDataWidth:       LOCAL_DATA_WIDTH,
        NoAddrRules:        NoAddrRules
    };

    // --------- Slave side: flat array -> struct array ---------
    for (genvar i = 0; i < NUM_SI; i++) begin : gen_slv_map
        // request
        assign slv_req[i].aw.addr  = s_axi_awaddr[i];
        assign slv_req[i].aw.prot  = s_axi_awprot[i];
        assign slv_req[i].aw_valid = s_axi_awvalid[i];
        assign slv_req[i].w.data   = s_axi_wdata[i];
        assign slv_req[i].w.strb   = s_axi_wstrb[i];
        assign slv_req[i].w_valid  = s_axi_wvalid[i];
        assign slv_req[i].b_ready  = s_axi_bready[i];
        assign slv_req[i].ar.addr  = s_axi_araddr[i];
        assign slv_req[i].ar.prot  = s_axi_arprot[i];
        assign slv_req[i].ar_valid = s_axi_arvalid[i];
        assign slv_req[i].r_ready  = s_axi_rready[i];
        // response
        assign s_axi_awready[i] = slv_rsp[i].aw_ready;
        assign s_axi_wready[i]  = slv_rsp[i].w_ready;
        assign s_axi_bresp[i]   = slv_rsp[i].b.resp;
        assign s_axi_bvalid[i]  = slv_rsp[i].b_valid;
        assign s_axi_arready[i] = slv_rsp[i].ar_ready;
        assign s_axi_rdata[i]   = slv_rsp[i].r.data;
        assign s_axi_rresp[i]   = slv_rsp[i].r.resp;
        assign s_axi_rvalid[i]  = slv_rsp[i].r_valid;
    end

    // --------- Master side: struct array -> flat array ---------
    for (genvar i = 0; i < NUM_MI; i++) begin : gen_mst_map
        // request out
        assign m_axi_awaddr[i]  = mst_req[i].aw.addr;
        assign m_axi_awprot[i]  = mst_req[i].aw.prot;
        assign m_axi_awvalid[i] = mst_req[i].aw_valid;
        assign m_axi_wdata[i]   = mst_req[i].w.data;
        assign m_axi_wstrb[i]   = mst_req[i].w.strb;
        assign m_axi_wvalid[i]  = mst_req[i].w_valid;
        assign m_axi_bready[i]  = mst_req[i].b_ready;
        assign m_axi_araddr[i]  = mst_req[i].ar.addr;
        assign m_axi_arprot[i]  = mst_req[i].ar.prot;
        assign m_axi_arvalid[i] = mst_req[i].ar_valid;
        assign m_axi_rready[i]  = mst_req[i].r_ready;
        // response in
        assign mst_rsp[i].aw_ready = m_axi_awready[i];
        assign mst_rsp[i].w_ready  = m_axi_wready[i];
        assign mst_rsp[i].b.resp   = m_axi_bresp[i];
        assign mst_rsp[i].b_valid  = m_axi_bvalid[i];
        assign mst_rsp[i].ar_ready = m_axi_arready[i];
        assign mst_rsp[i].r.data   = m_axi_rdata[i];
        assign mst_rsp[i].r.resp   = m_axi_rresp[i];
        assign mst_rsp[i].r_valid  = m_axi_rvalid[i];
    end

    axi_lite_xbar #(
        .Cfg        ( XbarCfg                 ),
        .aw_chan_t  ( lite_aw_chan_t          ),
        .w_chan_t   ( lite_w_chan_t           ),
        .b_chan_t   ( lite_b_chan_t           ),
        .ar_chan_t  ( lite_ar_chan_t          ),
        .r_chan_t   ( lite_r_chan_t           ),
        .axi_req_t  ( lite_req_t              ),
        .axi_resp_t ( lite_resp_t             ),
        .rule_t     ( axi_pkg::xbar_rule_32_t )
    ) i_axi_lite_xbar (
        .clk_i                 ( aclk    ),
        .rst_ni                ( aresetn ),
        .test_i                ( 1'b0    ),
        .slv_ports_req_i       ( slv_req ),
        .slv_ports_resp_o      ( slv_rsp ),
        .mst_ports_req_o       ( mst_req ),
        .mst_ports_resp_i      ( mst_rsp ),
        .addr_map_i            ( AddrMap ),
        .en_default_mst_port_i ( '0      ),
        .default_mst_port_i    ( '0      )
    );

endmodule
