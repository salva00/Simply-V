// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: Xilinx VIO simulation stub. Drives probe_out0 = 1 (resetn
//              released) and probe_out1 = 0, ignores inputs.

module xlnx_vio (
    input  logic clk,
    output logic probe_out0,
    output logic probe_out1,
    input  logic probe_in0
);
    assign probe_out0 = 1'b1;
    assign probe_out1 = 1'b0;
endmodule
