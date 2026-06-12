// Smoke DUT: 32-bit counter used to validate the build/run chain
// of the two simulation backends. No IP dependencies.
module smoke_dut (
    input  logic        clk_i,
    input  logic        rst_ni,
    output logic [31:0] count_o
);
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) count_o <= '0;
        else         count_o <= count_o + 32'd1;
    end
endmodule
