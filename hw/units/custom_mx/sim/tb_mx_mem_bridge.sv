`timescale 1ns/1ps
module tb_mx_mem_bridge;
  localparam BLOCK_WORDS = 16;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  // bridge MX side
  logic core_read, core_read_block, core_read_vector, core_write;
  logic [31:0] core_addr, core_wdata; logic [3:0] core_be; logic [4:0] core_vl;
  logic core_valid; logic core_wack; logic [31:0] core_rdata; logic core_wait;
  // bridge bus side
  logic m_req, m_gnt, m_valid, m_we; logic [31:0] m_addr, m_rdata, m_wdata; logic [3:0] m_be; logic m_err;

  mx_mem_bridge dut(.clk_i(clk), .rst_ni(rst_n),
    .core_read_i(core_read), .core_read_block_i(core_read_block),
    .core_read_vector_i(core_read_vector), .core_write_i(core_write),
    .core_addr_i(core_addr), .core_wdata_i(core_wdata), .core_be_i(core_be),
    .core_vl_i(core_vl), .core_valid_o(core_valid), .core_wack_o(core_wack), .core_rdata_o(core_rdata),
    .core_wait_o(core_wait),
    .m_mem_req(m_req), .m_mem_gnt(m_gnt), .m_mem_valid(m_valid),
    .m_mem_addr(m_addr), .m_mem_rdata(m_rdata), .m_mem_wdata(m_wdata),
    .m_mem_we(m_we), .m_mem_be(m_be), .m_mem_error(m_err));

  // behavioral word slave: mem[addr>>2] = addr (so rdata is predictable)
  logic [31:0] mem [int]; assign m_gnt = m_req; assign m_err = 1'b0;
  always_ff @(posedge clk) begin
    m_valid <= 1'b0;
    if (m_req && m_gnt) begin
      if (m_we) mem[m_addr>>2]  = m_wdata;  // blocking: assoc array not allowed nonblocking in Verilator
      else begin m_rdata <= mem.exists(m_addr>>2) ? mem[m_addr>>2] : m_addr; m_valid <= 1'b1; end
    end
  end

  integer beats; integer errors=0;

  // Single-word MMIO write must reach the bus straight through (no block buffering).
  // Mirrors what L1D drives for an uncached store (addr >= 0x20000): one write_mem_o
  // beat with word_mem_o set. Here we drive the bridge's single-word write port and
  // check m_mem_req && m_mem_we && m_mem_addr match on the next cycle.
  // A single-word MMIO store (what L1D drives for addr >= UNCACHED_BASE: write_mem_o
  // with word_mem_o, never write_block_mem_o) must reach the bus as exactly ONE write
  // beat carrying the requested addr/wdata - no 16-word block ramp-up, no buffering.
  task automatic do_word_write(input [31:0] addr, input [31:0] wdata);
    integer beats_wr; integer k; logic [31:0] seen_addr, seen_wdata;
    beats_wr = 0; seen_addr = 'x; seen_wdata = 'x;
    @(posedge clk); core_addr<=addr; core_wdata<=wdata; core_be<=4'hF; core_write<=1'b1;
    // The bridge accepts the request on the assert cycle, so the write beat shows up on
    // the FIRST negedge after asserting core_write. Sample negedges (away from the
    // posedge race) across a full block-length window: a single-word store produces
    // exactly one (req & we) beat; a block store would produce BLOCK_WORDS beats.
    for (k = 0; k <= BLOCK_WORDS + 1; k = k + 1) begin
      @(negedge clk);
      if (k == 0) core_write<=1'b0;     // hold core_write for exactly one cycle
      if (m_req && m_we) begin
        beats_wr = beats_wr + 1; seen_addr = m_addr; seen_wdata = m_wdata;
      end
    end
    if (beats_wr != 1) begin
      $display("WORD_WR: expected exactly 1 single-word write beat, observed %0d", beats_wr); errors++;
    end else begin
      if (seen_addr  !== addr ) begin $display("WORD_WR: addr  got %h exp %h", seen_addr,  addr ); errors++; end
      if (seen_wdata !== wdata) begin $display("WORD_WR: wdata got %h exp %h", seen_wdata, wdata); errors++; end
    end
  endtask

  task automatic do_block_read(input [31:0] base);
    beats=0; @(posedge clk); core_addr<=base; core_read_block<=1'b1;
    @(posedge clk); core_read_block<=1'b0;
    while (beats < BLOCK_WORDS) begin
      @(posedge clk);
      if (core_valid) begin
        if (core_rdata !== (base + beats*4)) begin
          $display("BLOCK beat %0d: got %h exp %h", beats, core_rdata, base+beats*4); errors++; end
        beats++;
      end
    end
  endtask

  initial begin
    core_read=0; core_read_block=0; core_read_vector=0; core_write=0;
    core_addr=0; core_wdata=0; core_be=4'hF; core_vl=0;
    repeat(3) @(posedge clk); rst_n=1; @(posedge clk);
    do_block_read(32'h0000_1000);            // 16 sequential beats
    do_word_write(32'h0002_0000, 32'hCAFEBABE); // single-word MMIO write to UART base -> bus next cycle
    if (errors==0) $display("TB_MX_BRIDGE: PASS"); else $display("TB_MX_BRIDGE: FAIL (%0d)", errors);
    if (errors!=0) $fatal(1); $finish;
  end
endmodule
