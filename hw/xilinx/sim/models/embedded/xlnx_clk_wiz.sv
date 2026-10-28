// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: Simulation model of the Xilinx Clocking Wizard (xlnx_clk_wiz).
//              Every output clock is clk_in1: the clock converter sim models
//              are combinational pass-throughs, valid only within one clock
//              domain. locked asserts one cycle after resetn is sampled high.

module xlnx_clk_wiz (
    input  logic clk_in1,
    input  logic resetn,
    output logic locked,
    output logic clk_100,
    output logic clk_50,
    output logic clk_20,
    output logic clk_10
);

    always_ff @(posedge clk_in1 or negedge resetn) begin
        if (!resetn) locked <= 1'b0;
        else         locked <= 1'b1;   // asserted one cycle after reset deasserts
    end

    // Single synchronous clock domain (see header).
    assign clk_100 = clk_in1;
    assign clk_50  = clk_in1;
    assign clk_20  = clk_in1;
    assign clk_10  = clk_in1;

endmodule
