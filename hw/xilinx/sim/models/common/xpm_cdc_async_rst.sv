// Xilinx XPM CDC Async Reset synchronizer simulation stub.
// Passes src_arst directly to dest_arst (reset is already async —
// a pass-through is correct for functional sim; no #delays needed).
// Parameters match the instantiations in sys_master.sv (DEST_SYNC_FF=4,
// RST_ACTIVE_HIGH=0 for active-low reset from locked signal).

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
