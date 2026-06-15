// Simulation shim for Xilinx AXI-Lite Timer (xlnx_axilite_timer).
// AXI-Lite slave + functional 32-bit counter with interrupt generation.
// One module definition serves both tim0_u and tim1_u instantiations.
//
// Register map (byte offsets on s_axi_a*addr[8:0], driver xlnx_tim.c):
//   0x00  CSR (read/write) -- control/status bits:
//           bit1 = DOWN       count direction (1=down, 0=up)
//           bit4 = ARELOAD    auto-reload from TLR on terminal count
//           bit5 = LOAD       load counter from TLR while set (holds counter)
//           bit6 = EN_INT     gate the interrupt output
//           bit7 = ENABLE     run the counter
//           bit8 = INT        terminal-count status; write-1-to-clear
//   0x04  TLR (write)      -- load value
//
// Counter: runs when ENABLE & !LOAD. On terminal count (down->0, up->rollover)
// INT is set and `interrupt` asserts if EN_INT; if ARELOAD the counter reloads
// from TLR, otherwise it holds. CSR reads back the control bits + INT so the
// driver's read-modify-write sequences (start/enable_int/clear_int) work.
//
// ponytail: only CSR/TLR and the bits the driver touches are modelled; the
// second timer regs (TCR1/TLR1/PWM/cascade) and generateout/pwm outputs are
// unused by xlnx_tim.c. Upgrade path: add cascade/PWM if a driver needs them.

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

    // Timer-specific outputs (interrupt functional; rest tied off)
    output logic        generateout0,
    output logic        generateout1,
    output logic        interrupt,
    output logic        pwm0
);

    assign generateout0 = 1'b0;
    assign generateout1 = 1'b0;
    assign pwm0         = 1'b0;

    // CSR control/status bits and TLR load value.
    logic        csr_down;     // bit1
    logic        csr_areload;  // bit4
    logic        csr_load;     // bit5
    logic        csr_en_int;   // bit6
    logic        csr_enable;   // bit7
    logic        csr_int;      // bit8 (status, write-1-clear)
    logic [31:0] tlr;
    logic [31:0] counter;

    assign interrupt = csr_int & csr_en_int;

    // ----- Counter (runs when ENABLE & !LOAD; LOAD holds counter at TLR) -----
    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            counter <= '0;
        end else if (csr_load) begin
            counter <= tlr;                       // held at load value
        end else if (csr_enable) begin
            if (csr_down) begin                   // count down
                if (counter == 32'd0)
                    counter <= csr_areload ? tlr : 32'd0;
                else
                    counter <= counter - 32'd1;
            end else begin                        // count up
                if (counter == 32'hFFFF_FFFF)
                    counter <= csr_areload ? tlr : 32'hFFFF_FFFF;
                else
                    counter <= counter + 32'd1;
            end
        end
    end

    // Terminal-count detect (one cycle ahead of the reload above): set INT.
    logic terminal;
    assign terminal = csr_enable & ~csr_load &
                      (csr_down ? (counter == 32'd0)
                                : (counter == 32'hFFFF_FFFF));

    // ----- AXI-Lite write FSM (CSR@0x00, TLR@0x04) -----
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
            csr_down      <= 1'b0;
            csr_areload   <= 1'b0;
            csr_load      <= 1'b0;
            csr_en_int    <= 1'b0;
            csr_enable    <= 1'b0;
            csr_int       <= 1'b0;
            tlr           <= '0;
        end else begin
            // Terminal count sets INT (a register write in the same cycle still
            // wins for the write-1-clear, handled in WR_DATA below).
            if (terminal)
                csr_int <= 1'b1;

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
                            9'h000: begin // CSR
                                csr_down    <= s_axi_wdata[1];
                                csr_areload <= s_axi_wdata[4];
                                csr_load    <= s_axi_wdata[5];
                                csr_en_int  <= s_axi_wdata[6];
                                csr_enable  <= s_axi_wdata[7];
                                // INT (bit8) is write-1-clear; takes priority
                                // over a concurrent terminal-count set.
                                if (s_axi_wdata[8])
                                    csr_int <= 1'b0;
                            end
                            9'h004: tlr <= s_axi_wdata; // TLR
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

    // CSR read-back: control bits + INT status (drives the driver RMW reads).
    logic [31:0] csr_rd;
    always_comb begin
        csr_rd       = 32'd0;
        csr_rd[8]    = csr_int;
        csr_rd[7]    = csr_enable;
        csr_rd[6]    = csr_en_int;
        csr_rd[5]    = csr_load;
        csr_rd[4]    = csr_areload;
        csr_rd[1]    = csr_down;
    end

    // ----- AXI-Lite read FSM -----
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
                            9'h000:  s_axi_rdata <= csr_rd;
                            9'h004:  s_axi_rdata <= tlr;
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
