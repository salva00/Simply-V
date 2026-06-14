// Simulation shim for Xilinx Clocking Wizard IP (xlnx_clk_wiz).
// Provides behavioural clocks with no #-delays (Verilator --no-timing).
//
// All output clocks are made IDENTICAL to clk_in1 (single synchronous domain).
// WHY: the embedded SoC puts the PBUS on a separate clock (clk_10) and bridges
// it with xlnx_axi_d32_clock_converter, whose sim shim is a COMBINATIONAL
// pass-through. A combinational AXI pass-through is only valid between
// synchronous, same-frequency clocks — across different frequencies the faster
// side completes a handshake (e.g. a single W beat) in a cycle the slower side
// misses, losing the beat and deadlocking. Driving every domain from one clock
// makes the pass-through correct. Exact frequency ratios are NOT needed for the
// hello_world UART functional test (the plan sanctions this).
// locked asserts one cycle after resetn is sampled high.

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
