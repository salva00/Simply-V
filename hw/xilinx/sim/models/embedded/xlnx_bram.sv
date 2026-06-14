// Simulation shims for Xilinx Block Memory Generator — dual-BRAM variant.
//
// This file defines THREE modules:
//   sim_axi_bram      -- internal parametric implementation (not instantiated directly)
//   xlnx_bram_0       -- boot BRAM  (MEM_BYTES=2^16, plusarg +BRAM0_INIT=<hexfile>)
//   xlnx_bram_1       -- main memory BRAM (MEM_BYTES=2^16, plusarg +BRAM1_INIT=<hexfile>)
//
// Memory sizes come from the CSV RANGE_ADDR_WIDTH field:
//   BRAM_0 (boot):   RANGE_ADDR_WIDTH=16 -> 2^16 = 65536 bytes
//   BRAM_1 (DMmem):  RANGE_ADDR_WIDTH=16 -> 2^16 = 65536 bytes
// These are passed as MEM_BYTES parameters — no literals in the body.
//
// Supports $readmemh pre-load at time 0 via separate plusargs:
//   xlnx_bram_0 <- +BRAM0_INIT=<verilog hex file>   (used by Verilator TB)
//   xlnx_bram_1 <- +BRAM1_INIT=<verilog hex file>   (not pre-loaded by default)
//
// AXI4 Full slave, 32-bit data, 32-bit address, 4-bit ID.
// Handles one outstanding transaction per direction (sufficient for ibex).
// NO #-delays (Verilator --no-timing).

// =============================================================================
// Internal parametric implementation
// =============================================================================
module sim_axi_bram #(
    parameter int          MEM_BYTES  = 65536,    // byte-addressable memory size
    parameter string       INIT_PLUSARG = "BRAM0_INIT"  // plusarg name (no leading +)
) (
    // Status outputs (tied low — reset not modelled)
    output logic        rsta_busy,
    output logic        rstb_busy,

    // Clock / reset
    input  logic        s_aclk,
    input  logic        s_aresetn,

    // AXI4 write address channel
    input  logic [3:0]  s_axi_awid,
    input  logic [31:0] s_axi_awaddr,
    input  logic [7:0]  s_axi_awlen,
    input  logic [2:0]  s_axi_awsize,
    input  logic [1:0]  s_axi_awburst,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    // AXI4 write data channel
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wlast,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    // AXI4 write response channel
    output logic [3:0]  s_axi_bid,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    // AXI4 read address channel
    input  logic [3:0]  s_axi_arid,
    input  logic [31:0] s_axi_araddr,
    input  logic [7:0]  s_axi_arlen,
    input  logic [2:0]  s_axi_arsize,
    input  logic [1:0]  s_axi_arburst,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    // AXI4 read data channel
    output logic [3:0]  s_axi_rid,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rlast,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready
);

    // -------------------------------------------------------------------------
    // Internal memory: MEM_BYTES bytes, byte-addressed
    // -------------------------------------------------------------------------
    localparam int ADDR_BITS = $clog2(MEM_BYTES);

    logic [7:0] mem [0:MEM_BYTES-1];

    initial begin
        string init_file;
        if ($value$plusargs({INIT_PLUSARG, "=%s"}, init_file))
            $readmemh(init_file, mem);
    end

    // Tie off status signals (reset not modelled in simulation)
    assign rsta_busy = 1'b0;
    assign rstb_busy = 1'b0;

    // -------------------------------------------------------------------------
    // Write FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {WR_IDLE, WR_DATA, WR_RESP} wr_state_t;
    wr_state_t wr_state;

    logic [3:0]           wr_id;
    logic [ADDR_BITS-1:0] wr_addr;        // current beat byte address (low ADDR_BITS)
    logic [7:0]           wr_beats_left;

    always_ff @(posedge s_aclk or negedge s_aresetn) begin
        if (!s_aresetn) begin
            wr_state      <= WR_IDLE;
            wr_id         <= '0;
            wr_addr       <= '0;
            wr_beats_left <= '0;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bid     <= '0;
            s_axi_bresp   <= 2'b00;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    s_axi_bvalid  <= 1'b0;
                    s_axi_awready <= 1'b1;
                    s_axi_wready  <= 1'b0;
                    if (s_axi_awvalid && s_axi_awready) begin
                        wr_id         <= s_axi_awid;
                        wr_addr       <= s_axi_awaddr[ADDR_BITS-1:0];
                        wr_beats_left <= s_axi_awlen;
                        s_axi_awready <= 1'b0;
                        s_axi_wready  <= 1'b1;
                        wr_state      <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (s_axi_wvalid && s_axi_wready) begin
                        // Apply byte enables (32-bit word, little-endian)
                        if (s_axi_wstrb[0]) mem[wr_addr + ADDR_BITS'(0)] <= s_axi_wdata[7:0];
                        if (s_axi_wstrb[1]) mem[wr_addr + ADDR_BITS'(1)] <= s_axi_wdata[15:8];
                        if (s_axi_wstrb[2]) mem[wr_addr + ADDR_BITS'(2)] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) mem[wr_addr + ADDR_BITS'(3)] <= s_axi_wdata[31:24];
                        wr_addr <= wr_addr + ADDR_BITS'(4);

                        if (s_axi_wlast || wr_beats_left == 8'd0) begin
                            s_axi_wready <= 1'b0;
                            s_axi_bvalid <= 1'b1;
                            s_axi_bid    <= wr_id;
                            s_axi_bresp  <= 2'b00; // OKAY
                            wr_state     <= WR_RESP;
                        end else begin
                            wr_beats_left <= wr_beats_left - 8'd1;
                        end
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
    // Read FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {RD_IDLE, RD_DATA} rd_state_t;
    rd_state_t rd_state;

    logic [3:0]           rd_id;
    logic [ADDR_BITS-1:0] rd_addr;
    logic [7:0]           rd_beats_left;

    always_ff @(posedge s_aclk or negedge s_aresetn) begin
        if (!s_aresetn) begin
            rd_state      <= RD_IDLE;
            rd_id         <= '0;
            rd_addr       <= '0;
            rd_beats_left <= '0;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rlast   <= 1'b0;
            s_axi_rid     <= '0;
            s_axi_rdata   <= '0;
            s_axi_rresp   <= 2'b00;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    s_axi_rvalid  <= 1'b0;
                    s_axi_rlast   <= 1'b0;
                    s_axi_arready <= 1'b1;
                    if (s_axi_arvalid && s_axi_arready) begin
                        rd_id         <= s_axi_arid;
                        rd_beats_left <= s_axi_arlen;
                        s_axi_arready <= 1'b0;
                        // Present first beat immediately
                        s_axi_rid   <= s_axi_arid;
                        s_axi_rdata <= {mem[s_axi_araddr[ADDR_BITS-1:0] + ADDR_BITS'(3)],
                                        mem[s_axi_araddr[ADDR_BITS-1:0] + ADDR_BITS'(2)],
                                        mem[s_axi_araddr[ADDR_BITS-1:0] + ADDR_BITS'(1)],
                                        mem[s_axi_araddr[ADDR_BITS-1:0] + ADDR_BITS'(0)]};
                        s_axi_rresp  <= 2'b00; // OKAY
                        s_axi_rlast  <= (s_axi_arlen == 8'd0);
                        s_axi_rvalid <= 1'b1;
                        rd_addr       <= s_axi_araddr[ADDR_BITS-1:0] + ADDR_BITS'(4);
                        rd_state      <= RD_DATA;
                    end
                end

                RD_DATA: begin
                    if (s_axi_rvalid && s_axi_rready) begin
                        if (s_axi_rlast) begin
                            // Transaction complete
                            s_axi_rvalid  <= 1'b0;
                            s_axi_rlast   <= 1'b0;
                            s_axi_arready <= 1'b1;
                            rd_state      <= RD_IDLE;
                        end else begin
                            // Present next beat
                            rd_beats_left <= rd_beats_left - 8'd1;
                            s_axi_rid   <= rd_id;
                            s_axi_rdata <= {mem[rd_addr + ADDR_BITS'(3)],
                                            mem[rd_addr + ADDR_BITS'(2)],
                                            mem[rd_addr + ADDR_BITS'(1)],
                                            mem[rd_addr + ADDR_BITS'(0)]};
                            s_axi_rresp  <= 2'b00;
                            s_axi_rlast  <= (rd_beats_left == 8'd1);
                            s_axi_rvalid <= 1'b1;
                            rd_addr      <= rd_addr + ADDR_BITS'(4);
                        end
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule // sim_axi_bram


// =============================================================================
// xlnx_bram_0: boot BRAM
//   MEM_BYTES  = 2^16 = 65536  (from CSV RANGE_ADDR_WIDTH=16 for BRAM_0)
//   INIT_PLUSARG = "BRAM0_INIT" (+BRAM0_INIT=<hexfile> from the Verilator TB)
// =============================================================================
module xlnx_bram_0 (
    output logic        rsta_busy,
    output logic        rstb_busy,
    input  logic        s_aclk,
    input  logic        s_aresetn,
    input  logic [3:0]  s_axi_awid,
    input  logic [31:0] s_axi_awaddr,
    input  logic [7:0]  s_axi_awlen,
    input  logic [2:0]  s_axi_awsize,
    input  logic [1:0]  s_axi_awburst,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wlast,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [3:0]  s_axi_bid,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [3:0]  s_axi_arid,
    input  logic [31:0] s_axi_araddr,
    input  logic [7:0]  s_axi_arlen,
    input  logic [2:0]  s_axi_arsize,
    input  logic [1:0]  s_axi_arburst,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [3:0]  s_axi_rid,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rlast,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready
);
    sim_axi_bram #(
        .MEM_BYTES   (1 << 16),      // 65536 bytes — from CSV RANGE_ADDR_WIDTH=16
        .INIT_PLUSARG("BRAM0_INIT")  // +BRAM0_INIT=<hexfile>
    ) u (.*);
endmodule


// =============================================================================
// xlnx_bram_1: main memory BRAM (DMmem)
//   MEM_BYTES  = 2^16 = 65536  (from CSV RANGE_ADDR_WIDTH=16 for bram_1/DMmem)
//   INIT_PLUSARG = "BRAM1_INIT" (+BRAM1_INIT=<hexfile>, not pre-loaded by default)
// =============================================================================
module xlnx_bram_1 (
    output logic        rsta_busy,
    output logic        rstb_busy,
    input  logic        s_aclk,
    input  logic        s_aresetn,
    input  logic [3:0]  s_axi_awid,
    input  logic [31:0] s_axi_awaddr,
    input  logic [7:0]  s_axi_awlen,
    input  logic [2:0]  s_axi_awsize,
    input  logic [1:0]  s_axi_awburst,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wlast,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [3:0]  s_axi_bid,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [3:0]  s_axi_arid,
    input  logic [31:0] s_axi_araddr,
    input  logic [7:0]  s_axi_arlen,
    input  logic [2:0]  s_axi_arsize,
    input  logic [1:0]  s_axi_arburst,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [3:0]  s_axi_rid,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rlast,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready
);
    sim_axi_bram #(
        .MEM_BYTES   (1 << 16),      // 65536 bytes — from CSV RANGE_ADDR_WIDTH=16
        .INIT_PLUSARG("BRAM1_INIT")  // +BRAM1_INIT=<hexfile>
    ) u (.*);
endmodule
