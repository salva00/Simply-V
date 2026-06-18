`timescale 1ns/1ps
module tb_mx_mem_bridge;
  localparam BLOCK_WORDS = 16;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  // bridge MX side
  logic core_read, core_read_block, core_read_vector, core_write;
  logic [31:0] core_addr, core_wdata; logic [3:0] core_be; logic [4:0] core_vl;
  logic core_valid; logic [31:0] core_rdata; logic core_wait;
  // bridge bus side
  logic m_req, m_gnt, m_valid, m_we; logic [31:0] m_addr, m_rdata, m_wdata; logic [3:0] m_be; logic m_err;

  mx_mem_bridge dut(.clk_i(clk), .rst_ni(rst_n),
    .core_read_i(core_read), .core_read_block_i(core_read_block),
    .core_read_vector_i(core_read_vector), .core_write_i(core_write),
    .core_addr_i(core_addr), .core_wdata_i(core_wdata), .core_be_i(core_be),
    .core_vl_i(core_vl), .core_valid_o(core_valid), .core_rdata_o(core_rdata),
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
    if (errors==0) $display("TB_MX_BRIDGE: PASS"); else $display("TB_MX_BRIDGE: FAIL (%0d)", errors);
    if (errors!=0) $fatal(1); $finish;
  end
endmodule
