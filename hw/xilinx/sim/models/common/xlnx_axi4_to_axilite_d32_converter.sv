// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: Simulation model of the Xilinx AXI4-to-AXI4-Lite protocol
//              converter (32-bit). Bursts are split into single AXI-Lite
//              transfers; the worst response is returned. One outstanding
//              transaction per channel.

`include "simplyv_axi.svh"

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

    // Write: AW -> per beat {lite AW+W concurrently -> lite B} -> B. AW and W
    // are presented together and tracked by independent done flags, so
    // neither's handshake depends on the other's (a slave may legally
    // accept them in either order, or wait for both).
    typedef enum logic [2:0] {W_IDLE, W_BEAT, W_LITE, W_LB, W_RESP} wst_t;
    wst_t                        wst;
    logic [LOCAL_ID_WIDTH-1:0]   w_id;
    logic [LOCAL_ADDR_WIDTH-1:0] w_addr;
    logic [2:0]                  w_prot;
    logic [7:0]                  w_cnt;
    logic [2:0]                  w_size;
    logic [1:0]                  w_burst, w_resp;
    logic [LOCAL_DATA_WIDTH-1:0] w_data;
    logic [LOCAL_STRB_WIDTH-1:0] w_strb;
    logic                        w_last;
    logic                        aw_lite_done, w_lite_done;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            wst <= W_IDLE; w_id <= '0; w_addr <= '0; w_prot <= '0; w_cnt <= '0; w_size <= '0; w_burst <= '0; w_resp <= '0; w_data <= '0; w_strb <= '0; w_last <= 1'b0;
            aw_lite_done <= 1'b0; w_lite_done <= 1'b0;
        end else begin
            case (wst)
                W_IDLE: if (s_axi_awvalid) begin
                    w_id <= s_axi_awid; w_addr <= s_axi_awaddr; w_prot <= s_axi_awprot; w_cnt <= s_axi_awlen; w_size <= s_axi_awsize; w_burst <= s_axi_awburst; w_resp <= 2'b00;
                    wst <= W_BEAT;
                end
                W_BEAT: if (s_axi_wvalid) begin
                    w_data <= s_axi_wdata; w_strb <= s_axi_wstrb; w_last <= s_axi_wlast;
                    aw_lite_done <= 1'b0; w_lite_done <= 1'b0;
                    wst <= W_LITE;
                end
                W_LITE: begin
                    if (m_axi_awvalid && m_axi_awready) aw_lite_done <= 1'b1;
                    if (m_axi_wvalid  && m_axi_wready)  w_lite_done  <= 1'b1;
                    if ((aw_lite_done || (m_axi_awvalid && m_axi_awready)) &&
                        (w_lite_done  || (m_axi_wvalid  && m_axi_wready)))
                        wst <= W_LB;
                end
                W_LB:   if (m_axi_bvalid) begin
                    w_resp <= w_resp | m_axi_bresp;
                    if (w_burst == 2'b01) w_addr <= w_addr + (LOCAL_ADDR_WIDTH'(1) << w_size);
                    w_cnt <= w_cnt - 8'd1;
                    wst <= (w_last || w_cnt == 8'd0) ? W_RESP : W_BEAT;
                end
                W_RESP: if (s_axi_bready) wst <= W_IDLE;
                default: wst <= W_IDLE;
            endcase
        end
    end

    assign s_axi_awready = (wst == W_IDLE);
    assign s_axi_wready  = (wst == W_BEAT);
    assign m_axi_awvalid = (wst == W_LITE) && !aw_lite_done;
    assign m_axi_awaddr  = w_addr;
    assign m_axi_awprot  = w_prot;
    assign m_axi_wvalid  = (wst == W_LITE) && !w_lite_done;
    assign m_axi_wdata   = w_data;
    assign m_axi_wstrb   = w_strb;
    assign m_axi_bready  = (wst == W_LB);
    assign s_axi_bvalid  = (wst == W_RESP);
    assign s_axi_bid     = w_id;
    assign s_axi_bresp   = axi_resp_code_t'(w_resp);

    // Read: AR -> per beat {lite AR, lite R} -> R beat to master
    typedef enum logic [1:0] {R_IDLE, R_LAR, R_LR, R_OUT} rst_t;
    rst_t                        rst;
    logic [LOCAL_ID_WIDTH-1:0]   r_id;
    logic [LOCAL_ADDR_WIDTH-1:0] r_addr;
    logic [2:0]                  r_prot;
    logic [7:0]                  r_cnt;
    logic [2:0]                  r_size;
    logic [1:0]                  r_burst, r_resp;
    logic [LOCAL_DATA_WIDTH-1:0] r_data;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            rst <= R_IDLE; r_id <= '0; r_addr <= '0; r_prot <= '0; r_cnt <= '0; r_size <= '0; r_burst <= '0; r_resp <= '0; r_data <= '0;
        end else begin
            case (rst)
                R_IDLE: if (s_axi_arvalid) begin
                    r_id <= s_axi_arid; r_addr <= s_axi_araddr; r_prot <= s_axi_arprot; r_cnt <= s_axi_arlen; r_size <= s_axi_arsize; r_burst <= s_axi_arburst;
                    rst <= R_LAR;
                end
                R_LAR: if (m_axi_arready) rst <= R_LR;
                R_LR:  if (m_axi_rvalid) begin r_data <= m_axi_rdata; r_resp <= m_axi_rresp; rst <= R_OUT; end
                R_OUT: if (s_axi_rready) begin
                    if (r_burst == 2'b01) r_addr <= r_addr + (LOCAL_ADDR_WIDTH'(1) << r_size);
                    r_cnt <= r_cnt - 8'd1;
                    rst <= (r_cnt == 8'd0) ? R_IDLE : R_LAR;
                end
                default: rst <= R_IDLE;
            endcase
        end
    end

    assign s_axi_arready = (rst == R_IDLE);
    assign m_axi_arvalid = (rst == R_LAR);
    assign m_axi_araddr  = r_addr;
    assign m_axi_arprot  = r_prot;
    assign m_axi_rready  = (rst == R_LR);
    assign s_axi_rvalid  = (rst == R_OUT);
    assign s_axi_rid     = r_id;
    assign s_axi_rdata   = r_data;
    assign s_axi_rresp   = axi_resp_code_t'(r_resp);
    assign s_axi_rlast   = (r_cnt == 8'd0);

endmodule
