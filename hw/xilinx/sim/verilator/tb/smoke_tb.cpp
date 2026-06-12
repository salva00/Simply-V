// C++ harness for the smoke DUT on Verilator.
// Holds reset low for 4 cycles, then counts 10 rising edges
// and checks that count_o == 10. Exit 0 = PASS, 1 = FAIL.
#include "Vsmoke_dut.h"
#include "verilated.h"
#include <cstdio>

static void posedge(Vsmoke_dut* dut) {
    dut->clk_i = 1; dut->eval();
    dut->clk_i = 0; dut->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vsmoke_dut* dut = new Vsmoke_dut;

    dut->rst_ni = 0; dut->clk_i = 0; dut->eval();
    for (int i = 0; i < 4; ++i) posedge(dut);   // reset active
    dut->rst_ni = 1;
    for (int i = 0; i < 10; ++i) posedge(dut);  // 10 increments

    const unsigned expected = 10;
    int rc = 0;
    if (dut->count_o != expected) {
        std::printf("[SMOKE] FAIL count_o=%u expected=%u\n",
                    (unsigned)dut->count_o, expected);
        rc = 1;
    } else {
        std::printf("[SMOKE] PASS count_o=%u\n", (unsigned)dut->count_o);
    }
    delete dut;
    return rc;
}
