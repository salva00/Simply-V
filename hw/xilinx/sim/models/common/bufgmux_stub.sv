// Xilinx BUFGMUX simulation stub.
// Minimal behavioral clock-mux model for Verilator elaboration of tech_cells
// tc_clk_mux2 (xilinx variant), used e.g. by custom_clint's RTC clock path.
// Glitch-free switching is NOT modelled — sufficient for functional sim.

module BUFGMUX (
    input  logic S,
    input  logic I0,
    input  logic I1,
    output logic O
);
    assign O = S ? I1 : I0;
endmodule
