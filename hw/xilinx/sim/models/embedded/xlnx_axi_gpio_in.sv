// Simulation shim for Xilinx AXI GPIO input-only (xlnx_axi_gpio_in).
// AXI-Lite slave + functional DATA read + change-detect interrupt.
//
// Register map (byte offsets on s_axi_a*addr[8:0], driver xlnx_gpio_in.c):
//   0x00  DATA (read)        -- returns gpio_io_i
//   0x11C GIER (write)       -- bit31 = global interrupt enable
//   0x120 ISR  (read/write)  -- bit0 = channel-1 status; write-1-to-clear
//   0x128 IER  (write)       -- bit0 = channel-1 interrupt enable
//
// Interrupt: when IER[0] & GIER[31] are set, ANY change on gpio_io_i sets
// ISR[0] and asserts ip2intc_irpt (level, stays high until ISR[0] is cleared
// by writing 1 to it). This matches the driver: init() writes IER=0x01 and
// GIER=0x80000000, the handler reads nothing here but clears via ISR=0x1.
//
// ponytail: only DATA/GIER/ISR/IER and channel-1 (bit0) are modelled; TRI,
// GPIO2_* and the 16-bit width's per-pin interrupt detail are not used by the
// driver. Upgrade path: add TRI/edge-mode if a future driver configures them.

module xlnx_axi_gpio_in #(
    parameter int unsigned GPIO_WIDTH = 16
) (
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

    // GPIO input
    input  logic [GPIO_WIDTH-1:0] gpio_io_i,

    // Interrupt output (level, to PLIC)
    output logic        ip2intc_irpt
);

    // Interrupt-control registers (only the bits the driver uses).
    logic        ier0;    // IER[0]   channel-1 interrupt enable
    logic        gier;    // GIER[31] global interrupt enable
    logic        isr0;    // ISR[0]   channel-1 interrupt status

    // Change detector: remember the last sampled input value.
    logic [GPIO_WIDTH-1:0] gpio_prev;

    assign ip2intc_irpt = isr0; // level-sensitive: high while status pending

    // ----- AXI-Lite write FSM -----
    typedef enum logic [1:0] {WR_IDLE, WR_DATA, WR_RESP} wr_state_t;
    wr_state_t  wr_state;
    logic [8:0] wr_addr_lat;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            wr_state      <= WR_IDLE;
            wr_addr_lat   <= '0;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            ier0          <= 1'b0;
            gier          <= 1'b0;
            isr0          <= 1'b0;
            gpio_prev     <= '0;
        end else begin
            // Change detection: set ISR[0] when input changes and IRQs enabled.
            if (gpio_io_i != gpio_prev) begin
                gpio_prev <= gpio_io_i;
                if (ier0 && gier)
                    isr0 <= 1'b1;
            end

            case (wr_state)
                WR_IDLE: begin
                    s_axi_bvalid  <= 1'b0;
                    s_axi_awready <= 1'b1;
                    s_axi_wready  <= 1'b0;
                    if (s_axi_awvalid && s_axi_awready) begin
                        wr_addr_lat   <= s_axi_awaddr;
                        s_axi_awready <= 1'b0;
                        s_axi_wready  <= 1'b1;
                        wr_state      <= WR_DATA;
                    end
                end
                WR_DATA: begin
                    if (s_axi_wvalid && s_axi_wready) begin
                        s_axi_wready <= 1'b0;
                        case (wr_addr_lat)
                            9'h128: ier0 <= s_axi_wdata[0];   // IER
                            9'h11C: gier <= s_axi_wdata[31];  // GIER
                            9'h120: if (s_axi_wdata[0]) isr0 <= 1'b0; // ISR w1c
                            default: ; // ignore
                        endcase
                        s_axi_bvalid <= 1'b1;
                        wr_state     <= WR_RESP;
                    end
                end
                WR_RESP: begin
                    if (s_axi_bready && s_axi_bvalid) begin
                        s_axi_bvalid  <= 1'b0;
                        s_axi_awready <= 1'b1;
                        wr_state      <= WR_IDLE;
                    end
                end
                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    assign s_axi_bresp = 2'b00; // OKAY

    // ----- AXI-Lite read FSM (DATA@0x00 -> gpio_io_i; ISR@0x120 -> status) -----
    typedef enum logic [0:0] {RD_IDLE, RD_RESP} rd_state_t;
    rd_state_t rd_state;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rd_state      <= RD_IDLE;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= '0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    s_axi_rvalid  <= 1'b0;
                    s_axi_arready <= 1'b1;
                    if (s_axi_arvalid && s_axi_arready) begin
                        s_axi_arready <= 1'b0;
                        case (s_axi_araddr)
                            9'h000:  s_axi_rdata <= {{(32-GPIO_WIDTH){1'b0}}, gpio_io_i};
                            9'h120:  s_axi_rdata <= {31'd0, isr0};
                            default: s_axi_rdata <= 32'd0;
                        endcase
                        s_axi_rvalid <= 1'b1;
                        rd_state     <= RD_RESP;
                    end
                end
                RD_RESP: begin
                    if (s_axi_rready && s_axi_rvalid) begin
                        s_axi_rvalid  <= 1'b0;
                        s_axi_arready <= 1'b1;
                        rd_state      <= RD_IDLE;
                    end
                end
                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    assign s_axi_rresp = 2'b00; // OKAY

endmodule
