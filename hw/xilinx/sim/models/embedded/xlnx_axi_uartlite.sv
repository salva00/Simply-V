// Simulation shim for Xilinx AXI UART Lite (xlnx_axi_uartlite).
// AXI-Lite slave + functional UART TX serializer.
// NO #-delays (Verilator --no-timing).
//
// Register map (byte offsets on s_axi_araddr/awaddr[3:0]):
//   0x00  RX_FIFO  (read)  -- returns the received byte; clears RX_VALID on read
//   0x04  TX_FIFO  (write) -- write byte to transmit
//   0x08  STATUS   (read)  -- bit0=RX_VALID (RX_NOT_EMPTY), bit2=TX_EMPTY,
//                             bit3=TX_FULL (active when busy)
//   0x0C  CTRL     (write) -- ignored
//
// RX (Phase R2a): a serial receiver samples the `rx` input at the SAME bit
// timing the TX uses (SIM_UART_CYCLES_PER_BIT). It detects the start bit
// (idle 1 -> 0), samples 8 data bits LSB-first at bit centres, checks the stop
// bit, and latches the byte into a 1-deep RX holding register. STATUS bit0
// (RX_VALID) is set while a byte is held; a read of RX_FIFO@0x00 returns the
// byte and clears the bit. This is register-accurate to the tinyio driver
// (uart_get_char polls STATUS bit0, then reads RX@0x00).
//
// CONTRACT: SIM_UART_CYCLES_PER_BIT controls bit timing.
// The value is injected from sim.mk via +define+SIM_UART_CYCLES_PER_BIT=<N>
// (for Verilator SV side) and -DSIM_UART_CYCLES_PER_BIT=<N> (C++ TB side).
// Single source of truth: the variable in sim.mk (Task A7).
// Default 16 preserves the original 1A behaviour when no override is supplied.

`ifndef SIM_UART_CYCLES_PER_BIT
`define SIM_UART_CYCLES_PER_BIT 16
`endif

module xlnx_axi_uartlite (
    // AXI-Lite clock / reset
    input  logic        s_axi_aclk,
    input  logic        s_axi_aresetn,

    // Interrupt (tied off)
    output logic        interrupt,

    // AXI-Lite write address channel
    input  logic [3:0]  s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    // AXI-Lite write data channel
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    // AXI-Lite write response channel
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    // AXI-Lite read address channel
    input  logic [3:0]  s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    // AXI-Lite read data channel
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // UART physical signals
    input  logic        rx,
    output logic        tx
);

    // -------------------------------------------------------------------------
    // Bit timing: use the macro injected at compile time (see header).
    // FRAME_BITS: 1 start + 8 data + 1 stop = 10.
    // -------------------------------------------------------------------------
    localparam int CYCLES_PER_BIT = `SIM_UART_CYCLES_PER_BIT;
    localparam int FRAME_BITS     = 10;

    assign interrupt = 1'b0;

    // -------------------------------------------------------------------------
    // UART TX serializer
    // -------------------------------------------------------------------------
    logic        tx_busy;       // 1 while serializing
    logic [9:0]  tx_shift;      // {stop, d7..d0, start}
    logic [3:0]  tx_bit_idx;    // which bit we are sending (0..9)
    logic [7:0]  tx_cycle_cnt;  // cycles within current bit period

    // tx idles high
    assign tx = tx_busy ? tx_shift[0] : 1'b1;

    // -------------------------------------------------------------------------
    // UART RX deserializer (mirror of the TX serializer timing).
    // Samples `rx` at bit centres, CYCLES_PER_BIT apart. 1-deep holding reg.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_t;
    rx_state_t   rx_state;
    logic [7:0]  rx_shift;       // assembling the incoming byte (LSB first)
    logic [2:0]  rx_bit_idx;     // which data bit (0..7)
    logic [7:0]  rx_cycle_cnt;   // cycles within the current bit period
    logic [7:0]  rx_holding;     // 1-deep RX holding register
    logic        rx_valid;       // a byte is held (STATUS bit0 = RX_NOT_EMPTY)
    logic        rx_meta;        // synchroniser stage for the async rx line
    logic        rx_sync;        // synchronised rx

    // Pulse raised by the read FSM when RX_FIFO@0x00 is read, to clear rx_valid.
    logic        rx_read_ack;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rx_state     <= RX_IDLE;
            rx_shift     <= '0;
            rx_bit_idx   <= '0;
            rx_cycle_cnt <= '0;
            rx_holding   <= '0;
            rx_valid     <= 1'b0;
            rx_meta      <= 1'b1;
            rx_sync      <= 1'b1;
        end else begin
            // Two-stage synchroniser for the rx input (idles high).
            rx_meta <= rx;
            rx_sync <= rx_meta;

            // Clear the holding register when the CPU reads RX_FIFO.
            if (rx_read_ack)
                rx_valid <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    rx_cycle_cnt <= '0;
                    rx_bit_idx   <= '0;
                    // Start bit: idle high -> low.
                    if (rx_sync == 1'b0) begin
                        rx_state     <= RX_START;
                        rx_cycle_cnt <= '0;
                    end
                end

                // Advance to the centre of the start bit and confirm it.
                RX_START: begin
                    if (rx_cycle_cnt == (CYCLES_PER_BIT/2 - 1)) begin
                        rx_cycle_cnt <= '0;
                        if (rx_sync == 1'b0)
                            rx_state <= RX_DATA;   // valid start, go sample data
                        else
                            rx_state <= RX_IDLE;   // glitch, abort
                    end else begin
                        rx_cycle_cnt <= rx_cycle_cnt + 8'd1;
                    end
                end

                // Sample each data bit one full bit period after the previous
                // sample point (so at the centre of each data bit).
                RX_DATA: begin
                    if (rx_cycle_cnt == (CYCLES_PER_BIT - 1)) begin
                        rx_cycle_cnt        <= '0;
                        rx_shift[rx_bit_idx] <= rx_sync;   // LSB first
                        if (rx_bit_idx == 3'd7)
                            rx_state <= RX_STOP;
                        else
                            rx_bit_idx <= rx_bit_idx + 3'd1;
                    end else begin
                        rx_cycle_cnt <= rx_cycle_cnt + 8'd1;
                    end
                end

                // Sample the stop bit at its centre, then latch the byte.
                RX_STOP: begin
                    if (rx_cycle_cnt == (CYCLES_PER_BIT - 1)) begin
                        rx_cycle_cnt <= '0;
                        // Accept the frame regardless of stop-bit value (sim is
                        // glitch-free); latch into the 1-deep holding register.
                        rx_holding <= rx_shift;
                        rx_valid   <= 1'b1;
                        rx_state   <= RX_IDLE;
                    end else begin
                        rx_cycle_cnt <= rx_cycle_cnt + 8'd1;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // STATUS bits:
    //   bit0 = RX_VALID  (RX_NOT_EMPTY: a byte is held)
    //   bit1 = RX_FULL   (always 0)
    //   bit2 = TX_EMPTY  (1 when idle, 0 when busy)
    //   bit3 = TX_FULL   (1 when busy, 0 when idle)
    logic [31:0] status_reg;
    assign status_reg = {28'd0,
                         tx_busy,     // bit3: TX_FULL when busy
                         ~tx_busy,    // bit2: TX_EMPTY when idle
                         1'b0,        // bit1: RX_FULL
                         rx_valid};   // bit0: RX_VALID (RX_NOT_EMPTY)

    // -------------------------------------------------------------------------
    // AXI-Lite write FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {WR_IDLE, WR_DATA, WR_RESP} wr_state_t;
    wr_state_t wr_state;

    logic [3:0] wr_addr_lat;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            wr_state      <= WR_IDLE;
            wr_addr_lat   <= '0;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            // serializer
            tx_busy       <= 1'b0;
            tx_shift      <= 10'h3FF; // all 1s = idle
            tx_bit_idx    <= '0;
            tx_cycle_cnt  <= '0;
        end else begin

            // ---- UART serializer tick ----
            if (tx_busy) begin
                if (tx_cycle_cnt == (CYCLES_PER_BIT - 1)) begin
                    tx_cycle_cnt <= '0;
                    if (tx_bit_idx == (FRAME_BITS - 1)) begin
                        tx_busy    <= 1'b0;
                        tx_bit_idx <= '0;
                    end else begin
                        tx_shift   <= {1'b1, tx_shift[9:1]}; // shift right
                        tx_bit_idx <= tx_bit_idx + 4'd1;
                    end
                end else begin
                    tx_cycle_cnt <= tx_cycle_cnt + 8'd1;
                end
            end

            // ---- AXI-Lite write FSM ----
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
                        // TX_FIFO at offset 0x04
                        if (wr_addr_lat[3:2] == 2'b01) begin
                            // Load serializer: {stop=1, data[7:0], start=0}
                            tx_shift     <= {1'b1, s_axi_wdata[7:0], 1'b0};
                            tx_bit_idx   <= '0;
                            tx_cycle_cnt <= '0;
                            tx_busy      <= 1'b1;
                        end
                        s_axi_bvalid <= 1'b1;
                        s_axi_bresp  <= 2'b00; // OKAY
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

    // -------------------------------------------------------------------------
    // AXI-Lite read FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {RD_IDLE, RD_RESP} rd_state_t;
    rd_state_t rd_state;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rd_state      <= RD_IDLE;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= '0;
            s_axi_rresp   <= 2'b00;
            rx_read_ack   <= 1'b0;
        end else begin
            rx_read_ack <= 1'b0;   // single-cycle pulse by default
            case (rd_state)
                RD_IDLE: begin
                    s_axi_rvalid  <= 1'b0;
                    s_axi_arready <= 1'b1;
                    if (s_axi_arvalid && s_axi_arready) begin
                        s_axi_arready <= 1'b0;
                        // Decode register address (bits [3:2])
                        case (s_axi_araddr[3:2])
                            // RX_FIFO: return the held byte and clear RX_VALID.
                            2'b00: begin
                                s_axi_rdata <= {24'd0, rx_holding};
                                rx_read_ack <= 1'b1;
                            end
                            2'b10: s_axi_rdata <= status_reg;   // STATUS
                            default: s_axi_rdata <= 32'd0;
                        endcase
                        s_axi_rresp  <= 2'b00; // OKAY
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

endmodule
