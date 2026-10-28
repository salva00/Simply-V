// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: Xilinx BUFGMUX simulation stub. Behavioral clock mux for
//              tc_clk_mux2 (xilinx variant); glitch-free switching not modelled.

module BUFGMUX (
    input  logic S,
    input  logic I0,
    input  logic I1,
    output logic O
);
    assign O = S ? I1 : I0;
endmodule
