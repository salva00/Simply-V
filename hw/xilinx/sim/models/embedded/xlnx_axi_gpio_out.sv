// Simulation shim for Xilinx AXI GPIO output-only (xlnx_axi_gpio_out).
// AXI-Lite slave + functional DATA register driving gpio_io_o.
//
// Register map (byte offsets on s_axi_a*addr[8:0], driver xlnx_gpio_out.c):
//   0x00  DATA (read/write) -- low GPIO_WIDTH bits drive gpio_io_o
//   0x04  TRI  (write)      -- accepted and ignored
//
// ponytail: only DATA is modelled; the driver writes DATA (iowrite16) and
// reads it back (toggle). TRI/interrupt registers are never touched by the
// driver, so they are write-ignore / not modelled. Upgrade path: add TRI to
// gate the output direction if a future driver configures it.

module xlnx_axi_gpio_out #(
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

    // GPIO output
    output logic [GPIO_WIDTH-1:0] gpio_io_o
);

    logic [GPIO_WIDTH-1:0] data_reg;
    assign gpio_io_o = data_reg;

    // ----- AXI-Lite write FSM (DATA@0x00 captured; other offsets ignored) -----
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
            data_reg      <= '0;
        end else begin
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
                        if (wr_addr_lat == 9'h000) // DATA
                            data_reg <= s_axi_wdata[GPIO_WIDTH-1:0];
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

    // ----- AXI-Lite read FSM (DATA read-back for toggle) -----
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
                        // DATA@0x00 returns the register; others read 0.
                        s_axi_rdata   <= (s_axi_araddr == 9'h000)
                                         ? {{(32-GPIO_WIDTH){1'b0}}, data_reg}
                                         : 32'd0;
                        s_axi_rvalid  <= 1'b1;
                        rd_state      <= RD_RESP;
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
