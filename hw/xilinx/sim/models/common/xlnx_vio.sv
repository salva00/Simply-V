// Xilinx Virtual I/O (VIO) simulation stub.
// Drives probe_out0 = 1 (resetn released), probe_out1 = 0, ignores inputs.
// Port contract verified against simplyv.sv:190.
// NOT suitable for functional VIO simulation.

module xlnx_vio (
    input  logic clk,
    output logic probe_out0,
    output logic probe_out1,
    input  logic probe_in0
);
    assign probe_out0 = 1'b1;
    assign probe_out1 = 1'b0;
endmodule
