// Author: Simply-V simulation shim (Verilator)
// Description: Wrapper for the Xilinx AXI4 main crossbar (MBUS).
//              Wraps the pulp-platform axi_xbar module: flat Xilinx-style
//              packed-array ports on the outside, pulp struct types inside.
//              EMBEDDED MBUS: 5 slave ports, 6 master ports, id=5, addr=32,
//              data=32.
//
// Port contract transcribed from:
//   hw/xilinx/rtl/simplyv.sv:198
// The instantiation drives packed-array AXI4 signals (DECLARE_AXI_BUS_ARRAY
// layout: [WIDTH-1:0][SIZE-1:0]) on bare s_axi_*/m_axi_* names, so the port
// list is written explicitly to match.
//
// Slave-port (xbar) order (MBUS_masters concat LSB-first):
//   [0]=SYS_MASTER [1]=RV_SOCKET_DATA [2]=RV_SOCKET_INSTR [3]=DBG_MASTER [4]=CDMA
// Master-port (xbar) order (MBUS_slaves concat LSB-first):
//   [0]=BRAM_0 [1]=DMmem [2]=PBUS [3]=CLINT [4]=CDMA [5]=PLIC
// Address map comes from sim_addrmap_pkg (generated from config CSVs).
//
// NOTES:
//  - The pulp xbar expands the master-port AXI id to
//    AxiIdWidthSlvPorts + clog2(NoSlvPorts) = 1 + 3 = 4 bits internally.
//    SlvIdWidth is kept at 1 so the expanded master id (4 bits) fits BOTH
//    the BRAM master-port wire (4-bit) and the 5-bit MBUS wires WITHOUT
//    truncating the slave-index bits the xbar needs to route read/write
//    responses back to the originating master.
//  - LatencyMode = CUT_ALL_PORTS inserts spill registers on every channel.
//    This is functionally fine for simulation and breaks the wide
//    combinational valid/ready cycle through the SoC fabric that otherwise
//    triggers a Verilator 5.040 V3DfgBreakCycles internal error
//    ("Wrong result width") at the default optimization level.
//  - s_axi_arid is an input on this shim (AR channel flows master->slave).
//    The RTL instantiation comment in simplyv.sv marks it "// output" from
//    the wire's perspective in the RTL context, but it is an input to the
//    crossbar module — kept as input here.

`include "simplyv_axi.svh"
`include "axi/typedef.svh"

module xlnx_mbus_crossbar #(
    parameter int unsigned LOCAL_DATA_WIDTH = 32,
    parameter int unsigned LOCAL_ADDR_WIDTH = 32,
    parameter int unsigned LOCAL_ID_WIDTH   = 5,   // MBUS slave-port id width
    parameter int unsigned NUM_SI           = 5,   // MBUS masters (xbar slave ports)
    parameter int unsigned NUM_MI           = 6,   // MBUS slaves  (xbar master ports)
    localparam int unsigned LOCAL_STRB_WIDTH = LOCAL_DATA_WIDTH / 8
) (
    input logic aclk,
    input logic aresetn,

    // Slave port array (flat s_axi_*, element-major: [NUM_SI-1:0][WIDTH-1:0])
    // AW
    input  logic [NUM_SI-1:0] [LOCAL_ID_WIDTH-1:0] s_axi_awid,
    input  logic [NUM_SI-1:0] [LOCAL_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [NUM_SI-1:0] [7:0] s_axi_awlen,
    input  logic [NUM_SI-1:0] [2:0] s_axi_awsize,
    input  logic [NUM_SI-1:0] [1:0] s_axi_awburst,
    input  logic [NUM_SI-1:0] [0:0] s_axi_awlock,
    input  logic [NUM_SI-1:0] [3:0] s_axi_awcache,
    input  logic [NUM_SI-1:0] [2:0] s_axi_awprot,
    input  logic [NUM_SI-1:0] [3:0] s_axi_awqos,
    input  logic [NUM_SI-1:0] [0:0] s_axi_awvalid,
    output logic [NUM_SI-1:0] [0:0] s_axi_awready,
    // W
    input  logic [NUM_SI-1:0] [LOCAL_DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [NUM_SI-1:0] [LOCAL_STRB_WIDTH-1:0] s_axi_wstrb,
    input  logic [NUM_SI-1:0] [0:0] s_axi_wlast,
    input  logic [NUM_SI-1:0] [0:0] s_axi_wvalid,
    output logic [NUM_SI-1:0] [0:0] s_axi_wready,
    // B
    output logic [NUM_SI-1:0] [LOCAL_ID_WIDTH-1:0] s_axi_bid,
    output logic [NUM_SI-1:0] [1:0] s_axi_bresp,
    output logic [NUM_SI-1:0] [0:0] s_axi_bvalid,
    input  logic [NUM_SI-1:0] [0:0] s_axi_bready,
    // AR — s_axi_arid is input (AR channel flows from master to crossbar)
    input  logic [NUM_SI-1:0] [LOCAL_ID_WIDTH-1:0] s_axi_arid,
    input  logic [NUM_SI-1:0] [LOCAL_ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [NUM_SI-1:0] [7:0] s_axi_arlen,
    input  logic [NUM_SI-1:0] [2:0] s_axi_arsize,
    input  logic [NUM_SI-1:0] [1:0] s_axi_arburst,
    input  logic [NUM_SI-1:0] [0:0] s_axi_arlock,
    input  logic [NUM_SI-1:0] [3:0] s_axi_arcache,
    input  logic [NUM_SI-1:0] [2:0] s_axi_arprot,
    input  logic [NUM_SI-1:0] [3:0] s_axi_arqos,
    input  logic [NUM_SI-1:0] [0:0] s_axi_arvalid,
    output logic [NUM_SI-1:0] [0:0] s_axi_arready,
    // R
    output logic [NUM_SI-1:0] [LOCAL_ID_WIDTH-1:0] s_axi_rid,
    output logic [NUM_SI-1:0] [LOCAL_DATA_WIDTH-1:0] s_axi_rdata,
    output logic [NUM_SI-1:0] [1:0] s_axi_rresp,
    output logic [NUM_SI-1:0] [0:0] s_axi_rlast,
    output logic [NUM_SI-1:0] [0:0] s_axi_rvalid,
    input  logic [NUM_SI-1:0] [0:0] s_axi_rready,

    // Master port array (flat m_axi_*, element-major: [NUM_MI-1:0][WIDTH-1:0])
    // AW
    output logic [NUM_MI-1:0] [LOCAL_ID_WIDTH-1:0] m_axi_awid,
    output logic [NUM_MI-1:0] [LOCAL_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [NUM_MI-1:0] [7:0] m_axi_awlen,
    output logic [NUM_MI-1:0] [2:0] m_axi_awsize,
    output logic [NUM_MI-1:0] [1:0] m_axi_awburst,
    output logic [NUM_MI-1:0] [0:0] m_axi_awlock,
    output logic [NUM_MI-1:0] [3:0] m_axi_awcache,
    output logic [NUM_MI-1:0] [2:0] m_axi_awprot,
    output logic [NUM_MI-1:0] [3:0] m_axi_awregion,
    output logic [NUM_MI-1:0] [3:0] m_axi_awqos,
    output logic [NUM_MI-1:0] [0:0] m_axi_awvalid,
    input  logic [NUM_MI-1:0] [0:0] m_axi_awready,
    // W
    output logic [NUM_MI-1:0] [LOCAL_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [NUM_MI-1:0] [LOCAL_STRB_WIDTH-1:0] m_axi_wstrb,
    output logic [NUM_MI-1:0] [0:0] m_axi_wlast,
    output logic [NUM_MI-1:0] [0:0] m_axi_wvalid,
    input  logic [NUM_MI-1:0] [0:0] m_axi_wready,
    // B
    input  logic [NUM_MI-1:0] [LOCAL_ID_WIDTH-1:0] m_axi_bid,
    input  logic [NUM_MI-1:0] [1:0] m_axi_bresp,
    input  logic [NUM_MI-1:0] [0:0] m_axi_bvalid,
    output logic [NUM_MI-1:0] [0:0] m_axi_bready,
    // AR
    output logic [NUM_MI-1:0] [LOCAL_ID_WIDTH-1:0] m_axi_arid,
    output logic [NUM_MI-1:0] [LOCAL_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [NUM_MI-1:0] [7:0] m_axi_arlen,
    output logic [NUM_MI-1:0] [2:0] m_axi_arsize,
    output logic [NUM_MI-1:0] [1:0] m_axi_arburst,
    output logic [NUM_MI-1:0] [0:0] m_axi_arlock,
    output logic [NUM_MI-1:0] [3:0] m_axi_arcache,
    output logic [NUM_MI-1:0] [2:0] m_axi_arprot,
    output logic [NUM_MI-1:0] [3:0] m_axi_arregion,
    output logic [NUM_MI-1:0] [3:0] m_axi_arqos,
    output logic [NUM_MI-1:0] [0:0] m_axi_arvalid,
    input  logic [NUM_MI-1:0] [0:0] m_axi_arready,
    // R
    input  logic [NUM_MI-1:0] [LOCAL_ID_WIDTH-1:0] m_axi_rid,
    input  logic [NUM_MI-1:0] [LOCAL_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [NUM_MI-1:0] [1:0] m_axi_rresp,
    input  logic [NUM_MI-1:0] [0:0] m_axi_rlast,
    input  logic [NUM_MI-1:0] [0:0] m_axi_rvalid,
    output logic [NUM_MI-1:0] [0:0] m_axi_rready
);

    // SlvIdWidth=1: ibex (via axi_from_mem) drives AXI id=0, so a 1-bit slave
    // id is sufficient. The expanded master id (SlvIdWidth + clog2(NoSlvPorts)
    // = 1 + 3 = 4 bits) then fits BOTH the BRAM 4-bit wire AND the 5-bit MBUS
    // wires without truncating the slave-index bits needed for response routing.
    localparam int unsigned SlvIdWidth = 1;
    localparam int unsigned MstIdWidth = SlvIdWidth + $clog2(NUM_SI);

    // Slave-port struct types (effective id = SlvIdWidth)
    `AXI_TYPEDEF_ALL(
        slv,
        logic [LOCAL_ADDR_WIDTH-1:0],
        logic [SlvIdWidth-1:0],
        logic [LOCAL_DATA_WIDTH-1:0],
        logic [LOCAL_STRB_WIDTH-1:0],
        logic [0:0]
    )
    // Master-port struct types (expanded id = MstIdWidth)
    `AXI_TYPEDEF_ALL(
        mst,
        logic [LOCAL_ADDR_WIDTH-1:0],
        logic [MstIdWidth-1:0],
        logic [LOCAL_DATA_WIDTH-1:0],
        logic [LOCAL_STRB_WIDTH-1:0],
        logic [0:0]
    )

    slv_req_t  [NUM_SI-1:0] slv_req;
    slv_resp_t [NUM_SI-1:0] slv_rsp;
    mst_req_t  [NUM_MI-1:0] mst_req;
    mst_resp_t [NUM_MI-1:0] mst_rsp;

    // Address map from sim_addrmap_pkg (generated from the config CSVs —
    // single source of truth). RuleStart/RuleEnd are 64-bit in the package;
    // sliced to [31:0] for LOCAL_ADDR_WIDTH=32.
    // RuleIdx order (sorted by base addr) == Vivado IP M-port order ==
    // CONCAT slave array index (last CONCAT arg = idx 0). Verified ground-truth.
    localparam int unsigned NoAddrRules = sim_addrmap_pkg::MBUS_NumRules;
    axi_pkg::xbar_rule_32_t [NoAddrRules-1:0] AddrMap;
    for (genvar r = 0; r < NoAddrRules; r++) begin : gen_addr_map
        assign AddrMap[r] = '{
            idx:        sim_addrmap_pkg::MBUS_RuleIdx[r],
            start_addr: sim_addrmap_pkg::MBUS_RuleStart[r][31:0],
            end_addr:   sim_addrmap_pkg::MBUS_RuleEnd[r][31:0]
        };
    end

    localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts:         NUM_SI,
        NoMstPorts:         NUM_MI,
        MaxMstTrans:        32'd8,
        MaxSlvTrans:        32'd8,
        FallThrough:        1'b0,
        LatencyMode:        axi_pkg::CUT_ALL_PORTS,
        PipelineStages:     32'd0,
        AxiIdWidthSlvPorts: SlvIdWidth,
        AxiIdUsedSlvPorts:  SlvIdWidth,
        UniqueIds:          1'b0,
        AxiAddrWidth:       LOCAL_ADDR_WIDTH,
        AxiDataWidth:       LOCAL_DATA_WIDTH,
        NoAddrRules:        NoAddrRules
    };

    // --------- Slave side: flat array <-> struct array ---------
    for (genvar i = 0; i < NUM_SI; i++) begin : gen_slv_map
        // AW request
        assign slv_req[i].aw.id     = s_axi_awid[i][SlvIdWidth-1:0];
        assign slv_req[i].aw.addr   = s_axi_awaddr[i];
        assign slv_req[i].aw.len    = s_axi_awlen[i];
        assign slv_req[i].aw.size   = s_axi_awsize[i];
        assign slv_req[i].aw.burst  = s_axi_awburst[i];
        assign slv_req[i].aw.lock   = s_axi_awlock[i];
        assign slv_req[i].aw.cache  = s_axi_awcache[i];
        assign slv_req[i].aw.prot   = s_axi_awprot[i];
        assign slv_req[i].aw.qos    = s_axi_awqos[i];
        assign slv_req[i].aw.region = '0;
        assign slv_req[i].aw.atop   = '0;
        assign slv_req[i].aw.user   = '0;
        assign slv_req[i].aw_valid  = s_axi_awvalid[i];
        // W request
        assign slv_req[i].w.data    = s_axi_wdata[i];
        assign slv_req[i].w.strb    = s_axi_wstrb[i];
        assign slv_req[i].w.last    = s_axi_wlast[i];
        assign slv_req[i].w.user    = '0;
        assign slv_req[i].w_valid   = s_axi_wvalid[i];
        // B request
        assign slv_req[i].b_ready   = s_axi_bready[i];
        // AR request
        assign slv_req[i].ar.id     = s_axi_arid[i][SlvIdWidth-1:0];
        assign slv_req[i].ar.addr   = s_axi_araddr[i];
        assign slv_req[i].ar.len    = s_axi_arlen[i];
        assign slv_req[i].ar.size   = s_axi_arsize[i];
        assign slv_req[i].ar.burst  = s_axi_arburst[i];
        assign slv_req[i].ar.lock   = s_axi_arlock[i];
        assign slv_req[i].ar.cache  = s_axi_arcache[i];
        assign slv_req[i].ar.prot   = s_axi_arprot[i];
        assign slv_req[i].ar.qos    = s_axi_arqos[i];
        assign slv_req[i].ar.region = '0;
        assign slv_req[i].ar.user   = '0;
        assign slv_req[i].ar_valid  = s_axi_arvalid[i];
        // R request
        assign slv_req[i].r_ready   = s_axi_rready[i];

        // responses
        assign s_axi_awready[i] = slv_rsp[i].aw_ready;
        assign s_axi_wready[i]  = slv_rsp[i].w_ready;
        assign s_axi_bid[i]     = {{(LOCAL_ID_WIDTH-SlvIdWidth){1'b0}}, slv_rsp[i].b.id};
        assign s_axi_bresp[i]   = slv_rsp[i].b.resp;
        assign s_axi_bvalid[i]  = slv_rsp[i].b_valid;
        assign s_axi_arready[i] = slv_rsp[i].ar_ready;
        assign s_axi_rid[i]     = {{(LOCAL_ID_WIDTH-SlvIdWidth){1'b0}}, slv_rsp[i].r.id};
        assign s_axi_rdata[i]   = slv_rsp[i].r.data;
        assign s_axi_rresp[i]   = slv_rsp[i].r.resp;
        assign s_axi_rlast[i]   = slv_rsp[i].r.last;
        assign s_axi_rvalid[i]  = slv_rsp[i].r_valid;
    end

    // --------- Master side: struct array <-> flat array ---------
    for (genvar i = 0; i < NUM_MI; i++) begin : gen_mst_map
        // AW request out (truncate expanded id to flat LOCAL_ID_WIDTH wire)
        assign m_axi_awid[i]     = {{(LOCAL_ID_WIDTH-MstIdWidth){1'b0}}, mst_req[i].aw.id};
        assign m_axi_awaddr[i]   = mst_req[i].aw.addr;
        assign m_axi_awlen[i]    = mst_req[i].aw.len;
        assign m_axi_awsize[i]   = mst_req[i].aw.size;
        assign m_axi_awburst[i]  = mst_req[i].aw.burst;
        assign m_axi_awlock[i]   = mst_req[i].aw.lock;
        assign m_axi_awcache[i]  = mst_req[i].aw.cache;
        assign m_axi_awprot[i]   = mst_req[i].aw.prot;
        assign m_axi_awqos[i]    = mst_req[i].aw.qos;
        assign m_axi_awregion[i] = mst_req[i].aw.region;
        assign m_axi_awvalid[i]  = mst_req[i].aw_valid;
        // W request out
        assign m_axi_wdata[i]    = mst_req[i].w.data;
        assign m_axi_wstrb[i]    = mst_req[i].w.strb;
        assign m_axi_wlast[i]    = mst_req[i].w.last;
        assign m_axi_wvalid[i]   = mst_req[i].w_valid;
        // B request out
        assign m_axi_bready[i]   = mst_req[i].b_ready;
        // AR request out
        assign m_axi_arid[i]     = {{(LOCAL_ID_WIDTH-MstIdWidth){1'b0}}, mst_req[i].ar.id};
        assign m_axi_araddr[i]   = mst_req[i].ar.addr;
        assign m_axi_arlen[i]    = mst_req[i].ar.len;
        assign m_axi_arsize[i]   = mst_req[i].ar.size;
        assign m_axi_arburst[i]  = mst_req[i].ar.burst;
        assign m_axi_arlock[i]   = mst_req[i].ar.lock;
        assign m_axi_arcache[i]  = mst_req[i].ar.cache;
        assign m_axi_arprot[i]   = mst_req[i].ar.prot;
        assign m_axi_arqos[i]    = mst_req[i].ar.qos;
        assign m_axi_arregion[i] = mst_req[i].ar.region;
        assign m_axi_arvalid[i]  = mst_req[i].ar_valid;
        // R request out
        assign m_axi_rready[i]   = mst_req[i].r_ready;

        // responses in (zero-extend flat id to expanded struct width)
        assign mst_rsp[i].aw_ready = m_axi_awready[i];
        assign mst_rsp[i].w_ready  = m_axi_wready[i];
        assign mst_rsp[i].b.id     = m_axi_bid[i][MstIdWidth-1:0];
        assign mst_rsp[i].b.resp   = m_axi_bresp[i];
        assign mst_rsp[i].b.user   = '0;
        assign mst_rsp[i].b_valid  = m_axi_bvalid[i];
        assign mst_rsp[i].ar_ready = m_axi_arready[i];
        assign mst_rsp[i].r.id     = m_axi_rid[i][MstIdWidth-1:0];
        assign mst_rsp[i].r.data   = m_axi_rdata[i];
        assign mst_rsp[i].r.resp   = m_axi_rresp[i];
        assign mst_rsp[i].r.last   = m_axi_rlast[i];
        assign mst_rsp[i].r.user   = '0;
        assign mst_rsp[i].r_valid  = m_axi_rvalid[i];
    end

    axi_xbar #(
        .Cfg           ( XbarCfg                 ),
        .ATOPs         ( 1'b0                    ),
        .slv_aw_chan_t ( slv_aw_chan_t           ),
        .mst_aw_chan_t ( mst_aw_chan_t           ),
        .w_chan_t      ( slv_w_chan_t            ),
        .slv_b_chan_t  ( slv_b_chan_t            ),
        .mst_b_chan_t  ( mst_b_chan_t            ),
        .slv_ar_chan_t ( slv_ar_chan_t           ),
        .mst_ar_chan_t ( mst_ar_chan_t           ),
        .slv_r_chan_t  ( slv_r_chan_t            ),
        .mst_r_chan_t  ( mst_r_chan_t            ),
        .slv_req_t     ( slv_req_t               ),
        .slv_resp_t    ( slv_resp_t              ),
        .mst_req_t     ( mst_req_t               ),
        .mst_resp_t    ( mst_resp_t              ),
        .rule_t        ( axi_pkg::xbar_rule_32_t )
    ) i_axi_xbar (
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
