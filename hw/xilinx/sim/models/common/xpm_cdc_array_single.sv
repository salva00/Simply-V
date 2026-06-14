// Xilinx XPM CDC Array Single-bit synchronizer simulation stub.
// Passes src_in directly to dest_out (pass-through is correct for
// functional sim; no #delays needed).
// Parameters match the instantiation in pbus.sv (DEST_SYNC_FF=8,
// SRC_INPUT_REG=1, WIDTH=NUM_IRQ).

module xpm_cdc_array_single #(
    parameter int unsigned WIDTH          = 1,
    parameter int unsigned DEST_SYNC_FF   = 4,
    parameter int unsigned INIT_SYNC_FF   = 0,
    parameter int unsigned SIM_ASSERT_CHK = 0,
    parameter int unsigned SRC_INPUT_REG  = 1
) (
    input  logic [WIDTH-1:0] src_in,
    input  logic             src_clk,
    input  logic             dest_clk,
    output logic [WIDTH-1:0] dest_out
);
    assign dest_out = src_in;
endmodule
