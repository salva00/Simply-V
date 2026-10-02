// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: xsim testbench for the smoke DUT: 4 reset cycles, 10 edges,
//              checks count_o == 10 (same stimuli as the Verilator harness).

`timescale 1ns/1ps
module smoke_tb;
    logic        clk_i = 1'b0;
    logic        rst_ni = 1'b0;
    logic [31:0] count_o;

    smoke_dut dut (.clk_i(clk_i), .rst_ni(rst_ni), .count_o(count_o));

    always #5 clk_i = ~clk_i;

    initial begin
        rst_ni = 1'b0;
        repeat (4)  @(posedge clk_i);
        #1; // release reset between edges to avoid Active-region race with always_ff
        rst_ni = 1'b1;
        repeat (10) @(posedge clk_i);
        #1;
        if (count_o !== 32'd10) begin
            $display("[SMOKE] FAIL count_o=%0d expected=10", count_o);
            $fatal(1);
        end
        $display("[SMOKE] PASS count_o=%0d", count_o);
        $finish;
    end
endmodule
