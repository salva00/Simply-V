// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: xpm_cdc_array_single simulation stub: src_in passes straight
//              to dest_out (single clock domain in sim).

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
