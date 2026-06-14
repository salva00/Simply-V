// Simulation shim for Xilinx AXI-Lite Timer (xlnx_axilite_timer).
// Quiescent AXI-Lite slave: accepts writes/reads, returns OKAY, no stalls.
// Functional outputs (interrupt, generateout*, pwm0) tied to 0.
// One module definition satisfies both tim0_u and tim1_u instantiations.
// NOT suitable for functional timer simulation.

module xlnx_axilite_timer (
    input  logic        s_axi_aclk,
    input  logic        s_axi_aresetn,

    // AXI-Lite slave write address channel
    input  logic [8:0]  s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    // AXI-Lite slave write data channel
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    // AXI-Lite slave write response channel
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    // AXI-Lite slave read address channel
    input  logic [8:0]  s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    // AXI-Lite slave read data channel
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // Timer-specific inputs (ignored)
    input  logic        capturetrig0,
    input  logic        capturetrig1,
    input  logic        freeze,

    // Timer-specific outputs (tied off)
    output logic        generateout0,
    output logic        generateout1,
    output logic        interrupt,
    output logic        pwm0
);

    assign generateout0 = 1'b0;
    assign generateout1 = 1'b0;
    assign interrupt    = 1'b0;
    assign pwm0         = 1'b0;

    // ----- AXI-Lite write FSM -----
    typedef enum logic [1:0] {IDLE, WDATA, WRESP, RRESP} state_t;
    state_t wr_state, rd_state;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) wr_state <= IDLE;
        else case (wr_state)
            IDLE:  if (s_axi_awvalid & s_axi_awready) wr_state <= WDATA;
            WDATA: if (s_axi_wvalid  & s_axi_wready)  wr_state <= WRESP;
            WRESP: if (s_axi_bready)                   wr_state <= IDLE;
            default: wr_state <= IDLE;
        endcase
    end

    assign s_axi_awready = (wr_state == IDLE);
    assign s_axi_wready  = (wr_state == WDATA);
    assign s_axi_bvalid  = (wr_state == WRESP);
    assign s_axi_bresp   = 2'b00; // OKAY

    // ----- AXI-Lite read FSM -----
    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) rd_state <= IDLE;
        else case (rd_state)
            IDLE:  if (s_axi_arvalid & s_axi_arready) rd_state <= RRESP;
            RRESP: if (s_axi_rready)                   rd_state <= IDLE;
            default: rd_state <= IDLE;
        endcase
    end

    assign s_axi_arready = (rd_state == IDLE);
    assign s_axi_rvalid  = (rd_state == RRESP);
    assign s_axi_rdata   = '0;
    assign s_axi_rresp   = 2'b00; // OKAY

endmodule
