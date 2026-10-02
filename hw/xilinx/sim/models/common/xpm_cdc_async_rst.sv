// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: xpm_cdc_async_rst simulation stub: src_arst passes straight
//              to dest_arst.

module xpm_cdc_async_rst #(
    parameter int unsigned DEST_SYNC_FF    = 4,
    parameter int unsigned INIT_SYNC_FF    = 0,
    parameter int unsigned RST_ACTIVE_HIGH = 1
) (
    input  logic src_arst,
    input  logic dest_clk,
    output logic dest_arst
);
    assign dest_arst = src_arst;
endmodule
