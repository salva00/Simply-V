// Simulation shim for Xilinx AXI Central DMA (xlnx_axi_cdma).
// Functional SIMPLE (mem-to-mem) transfer: AXI-Lite slave control regs + an
// AXI4 master that copies BTT bytes from SRCADDR to DSTADDR word-by-word.
//
// Register map (byte offsets on s_axi_lite_awaddr/araddr, driver xlnx_cdma.c):
//   0x00  CR  (read/write) -- control; bit2=RESET (self-clearing in this model),
//                             bit3=SGMODE (unused). IRQ-enable bits ignored.
//   0x04  SR  (read)       -- status; bit1=IDLE (driver polls this for done),
//                             bit3=SGINCLD reads 0 (=> SimpleOnlyBuild path).
//   0x18  SRCADDR (write)  -- source address (lower 32 bits)
//   0x20  DSTADDR (write)  -- destination address (lower 32 bits)
//   0x28  BTT     (write)  -- bytes-to-transfer; the write triggers the copy.
//
// On a BTT write the master reads BTT/4 words from SRCADDR (AR/R, INCR) and
// writes them to DSTADDR (AW/W/B, INCR), single-beat each; SR.IDLE drops to 0
// while busy and returns to 1 when done, with a one-cycle cdma_introut pulse.
//
// ponytail: SIMPLE mode only -- no scatter-gather, no SG/descriptor regs, no
//   IRQ-enable masking (driver polls IDLE; introut pulse is harmless to PLIC).
// ponytail: single-beat AR/R then AW/W copy loop (no AXI bursts); upgrade to
//   awlen/arlen bursts only if sim throughput ever matters.
// ponytail: word-granular copy (BTT is bytes, examples use 4-byte multiples);
//   upgrade with wstrb/byte handling if a sub-word transfer is ever needed.
// ponytail: master runs on s_axi_lite_aclk -- CDMA_clk==MBUS_clk in this SoC
//   (both clk_MBUS_20MHz), so one clock domain; split if they ever diverge.
//
// PORT NOTE: s_axi_lite_wstrb is NOT present in the real Xilinx CDMA IP
// (confirmed from simplyv.sv:981 comment "// not present") -- omitted here.

module xlnx_axi_cdma #(
    parameter int unsigned C_M_AXI_ADDR_WIDTH = 32,
    parameter int unsigned C_M_AXI_DATA_WIDTH = 32
) (
    // Clocks & resets
    input  logic        s_axi_lite_aclk,
    input  logic        s_axi_lite_aresetn,
    input  logic        m_axi_aclk,

    // Interrupt
    output logic        cdma_introut,

    // AXI-Lite control slave interface (no wstrb — not present in real IP)
    input  logic        s_axi_lite_awvalid,
    output logic        s_axi_lite_awready,
    input  logic [31:0] s_axi_lite_awaddr,

    input  logic        s_axi_lite_wvalid,
    output logic        s_axi_lite_wready,
    input  logic [31:0] s_axi_lite_wdata,

    output logic        s_axi_lite_bvalid,
    input  logic        s_axi_lite_bready,
    output logic [1:0]  s_axi_lite_bresp,

    input  logic        s_axi_lite_arvalid,
    output logic        s_axi_lite_arready,
    input  logic [31:0] s_axi_lite_araddr,

    output logic        s_axi_lite_rvalid,
    input  logic        s_axi_lite_rready,
    output logic [31:0] s_axi_lite_rdata,
    output logic [1:0]  s_axi_lite_rresp,

    // AXI4 master write address channel
    output logic [C_M_AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic [2:0]  m_axi_awprot,
    output logic [3:0]  m_axi_awcache,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,

    // AXI4 master write data channel
    output logic [C_M_AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output logic [C_M_AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,

    // AXI4 master write response channel
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    input  logic [1:0]  m_axi_bresp,

    // AXI4 master read address channel
    output logic [C_M_AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic [2:0]  m_axi_arprot,
    output logic [3:0]  m_axi_arcache,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,

    // AXI4 master read data channel
    input  logic [C_M_AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    // Scatter-gather (unused, left open at instantiation)
    output logic        cdma_tvect_out
);

    localparam int unsigned WSIZE = $clog2(C_M_AXI_DATA_WIDTH/8); // awsize/arsize

    assign cdma_tvect_out = 1'b0;

    // ----- Control/status registers -----
    logic [31:0] src_addr, dst_addr, btt;
    logic        idle;          // SR bit1: 1=idle/done, 0=busy

    // ----- Master copy engine FSM -----
    typedef enum logic [2:0] {
        M_IDLE, M_AR, M_R, M_AW, M_W, M_B
    } m_state_t;
    m_state_t   m_state;
    logic [31:0] rd_ptr, wr_ptr;   // running source/dest addresses
    logic [31:0] words_left;       // words still to move
    logic [31:0] data_word;        // word in flight (read -> write)
    logic        start_xfer;       // 1-cycle pulse from BTT write

    // ----- AXI-Lite write FSM (CR/SRC/DST/BTT) -----
    typedef enum logic [1:0] {WR_IDLE, WR_DATA, WR_RESP} wr_state_t;
    wr_state_t   wr_state;
    logic [31:0] wr_addr_lat;

    always_ff @(posedge s_axi_lite_aclk or negedge s_axi_lite_aresetn) begin
        if (!s_axi_lite_aresetn) begin
            wr_state      <= WR_IDLE;
            wr_addr_lat   <= '0;
            s_axi_lite_awready <= 1'b0;
            s_axi_lite_wready  <= 1'b0;
            s_axi_lite_bvalid  <= 1'b0;
            src_addr      <= '0;
            dst_addr      <= '0;
            btt           <= '0;
            start_xfer    <= 1'b0;
        end else begin
            start_xfer <= 1'b0; // default: single-cycle pulse
            case (wr_state)
                WR_IDLE: begin
                    s_axi_lite_bvalid <= 1'b0;
                    s_axi_lite_awready <= 1'b1;
                    s_axi_lite_wready  <= 1'b0;
                    if (s_axi_lite_awvalid && s_axi_lite_awready) begin
                        wr_addr_lat   <= s_axi_lite_awaddr;
                        s_axi_lite_awready <= 1'b0;
                        s_axi_lite_wready  <= 1'b1;
                        wr_state      <= WR_DATA;
                    end
                end
                WR_DATA: begin
                    if (s_axi_lite_wvalid && s_axi_lite_wready) begin
                        s_axi_lite_wready <= 1'b0;
                        case (wr_addr_lat[7:0])
                            8'h00: ; // CR: RESET self-clears, SG/IRQ bits ignored
                            8'h18: src_addr <= s_axi_lite_wdata;
                            8'h20: dst_addr <= s_axi_lite_wdata;
                            8'h28: begin // BTT write triggers the transfer
                                btt        <= s_axi_lite_wdata;
                                start_xfer <= 1'b1;
                            end
                            default: ; // ignore
                        endcase
                        s_axi_lite_bvalid <= 1'b1;
                        wr_state          <= WR_RESP;
                    end
                end
                WR_RESP: begin
                    if (s_axi_lite_bready && s_axi_lite_bvalid) begin
                        s_axi_lite_bvalid  <= 1'b0;
                        s_axi_lite_awready <= 1'b1;
                        wr_state           <= WR_IDLE;
                    end
                end
                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    assign s_axi_lite_bresp = 2'b00; // OKAY

    // ----- AXI-Lite read FSM (SR primarily; CR/SRC/DST/BTT read-back) -----
    logic [31:0] sr_val;
    always_comb begin
        sr_val    = 32'd0;
        sr_val[1] = idle; // IDLE; bit3 SGINCLD stays 0 => SimpleOnlyBuild
    end

    typedef enum logic [0:0] {RD_IDLE, RD_RESP} rd_state_t;
    rd_state_t rd_state;

    always_ff @(posedge s_axi_lite_aclk or negedge s_axi_lite_aresetn) begin
        if (!s_axi_lite_aresetn) begin
            rd_state      <= RD_IDLE;
            s_axi_lite_arready <= 1'b0;
            s_axi_lite_rvalid  <= 1'b0;
            s_axi_lite_rdata   <= '0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    s_axi_lite_rvalid  <= 1'b0;
                    s_axi_lite_arready <= 1'b1;
                    if (s_axi_lite_arvalid && s_axi_lite_arready) begin
                        s_axi_lite_arready <= 1'b0;
                        case (s_axi_lite_araddr[7:0])
                            8'h04:   s_axi_lite_rdata <= sr_val;
                            8'h18:   s_axi_lite_rdata <= src_addr;
                            8'h20:   s_axi_lite_rdata <= dst_addr;
                            8'h28:   s_axi_lite_rdata <= btt;
                            default: s_axi_lite_rdata <= 32'd0; // CR etc. read 0
                        endcase
                        s_axi_lite_rvalid <= 1'b1;
                        rd_state          <= RD_RESP;
                    end
                end
                RD_RESP: begin
                    if (s_axi_lite_rready && s_axi_lite_rvalid) begin
                        s_axi_lite_rvalid  <= 1'b0;
                        s_axi_lite_arready <= 1'b1;
                        rd_state           <= RD_IDLE;
                    end
                end
                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    assign s_axi_lite_rresp = 2'b00; // OKAY

    // ----- AXI4 master copy engine (single-beat read-then-write per word) -----
    // Same clock as the slave (CDMA_clk==MBUS_clk); start_xfer crosses safely.
    assign m_axi_awsize  = WSIZE[2:0];
    assign m_axi_arsize  = WSIZE[2:0];
    assign m_axi_awburst = 2'b01; // INCR
    assign m_axi_arburst = 2'b01; // INCR
    assign m_axi_awlen   = 8'd0;  // single beat
    assign m_axi_arlen   = 8'd0;  // single beat
    assign m_axi_awprot  = 3'b000;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_wstrb   = '1;    // full-word writes
    assign m_axi_wlast   = 1'b1;  // single-beat burst
    assign m_axi_bready  = 1'b1;

    assign m_axi_araddr  = rd_ptr;
    assign m_axi_awaddr  = wr_ptr;
    assign m_axi_wdata   = data_word;

    assign m_axi_arvalid = (m_state == M_AR);
    assign m_axi_rready  = (m_state == M_R);
    assign m_axi_awvalid = (m_state == M_AW);
    assign m_axi_wvalid  = (m_state == M_W);

    always_ff @(posedge m_axi_aclk or negedge s_axi_lite_aresetn) begin
        if (!s_axi_lite_aresetn) begin
            m_state      <= M_IDLE;
            rd_ptr       <= '0;
            wr_ptr       <= '0;
            words_left   <= '0;
            data_word    <= '0;
            idle         <= 1'b1;
            cdma_introut <= 1'b0;
        end else begin
            cdma_introut <= 1'b0; // single-cycle completion pulse
            case (m_state)
                M_IDLE: begin
                    if (start_xfer && (btt >= 32'd4)) begin
                        rd_ptr     <= src_addr;
                        wr_ptr     <= dst_addr;
                        words_left <= {2'b00, btt[31:2]}; // BTT bytes / 4 (word multiples)
                        idle       <= 1'b0;
                        m_state    <= M_AR;
                    end
                end
                M_AR: if (m_axi_arready) m_state <= M_R;
                M_R:  if (m_axi_rvalid) begin
                          data_word <= m_axi_rdata;
                          m_state   <= M_AW;
                      end
                M_AW: if (m_axi_awready) m_state <= M_W;
                M_W:  if (m_axi_wready) m_state <= M_B;
                M_B:  if (m_axi_bvalid) begin
                          rd_ptr     <= rd_ptr + 32'd4;
                          wr_ptr     <= wr_ptr + 32'd4;
                          words_left <= words_left - 32'd1;
                          if (words_left == 32'd1) begin
                              idle         <= 1'b1;
                              cdma_introut <= 1'b1; // completion pulse
                              m_state      <= M_IDLE;
                          end else begin
                              m_state <= M_AR;
                          end
                      end
                default: m_state <= M_IDLE;
            endcase
        end
    end

endmodule
