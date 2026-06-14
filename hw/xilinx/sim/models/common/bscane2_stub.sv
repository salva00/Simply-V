// Xilinx BSCANE2 simulation stub.
// Minimal no-op model for Verilator elaboration of custom_rv32_dbg_bscane.
// NOT suitable for functional JTAG simulation.

module BSCANE2 #(
    parameter integer JTAG_CHAIN = 1
) (
    output logic CAPTURE,
    output logic DRCK,
    output logic RESET,
    output logic RUNTEST,
    output logic SEL,
    output logic SHIFT,
    output logic TCK,
    output logic TDI,
    output logic TMS,
    output logic UPDATE,
    input  logic TDO
);
    assign CAPTURE = 1'b0;
    assign DRCK    = 1'b0;
    assign RESET   = 1'b0;
    assign RUNTEST = 1'b0;
    assign SEL     = 1'b0;
    assign SHIFT   = 1'b0;
    assign TCK     = 1'b0;
    assign TDI     = 1'b0;
    assign TMS     = 1'b0;
    assign UPDATE  = 1'b0;
endmodule
