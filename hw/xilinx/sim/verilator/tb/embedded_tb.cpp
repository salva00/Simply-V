// embedded_tb.cpp — R1 C++ testbench for the embedded Simply-V SoC.
//
// Loads a bare-metal program (+BRAM0_INIT=<hexfile>) into the boot BRAM shim
// (xlnx_bram_0, base 0x0), runs the SoC, decodes uart_tx_o, and compares the
// captured UART byte stream against a golden file. Prints "[EMB] PASS" / exit 0
// on match, "[EMB] FAIL" / exit 1 otherwise.
//
// Clock / reset facts (verified from RTL):
//   * sys_reset_i is ACTIVE-HIGH: sys_master.sv drives the clk_wiz with
//     resetn(~sys_reset_i). So hold sys_reset_i = 1 to reset, drive 0 to run.
//   * sys_clock_i -> clk_wiz. In the sim clk_wiz shim every output clock
//     (clk_100/clk_50/clk_20/clk_10) is identical to clk_in1 (single
//     synchronous domain; the PBUS clock-converter shim is a combinational
//     passthrough). So 1 sys_clock_i posedge == 1 PBUS_clk cycle -> oversample 1.
//   * The uartlite shim emits one UART bit per SIM_UART_CYCLES_PER_BIT cycles
//     of its AXI clock. UartRx is fed once per sys_clock_i posedge.

#include "Vsimplyv.h"
#include "verilated.h"
#include "uart_rx.hpp"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

// sys_clock_i posedges per PBUS_clk cycle. The clk_wiz sim shim drives every
// output clock identical to sys_clock_i (single synchronous domain), so 1.
static constexpr int kOversample = 1;

// Generous cycle cap (sys_clock_i posedges). 14 bytes * 10 bits *
// SIM_UART_CYCLES_PER_BIT samples/bit of pure serialisation, plus the program's
// boot + crossbar latency (CUT_ALL_PORTS pipelining) and UART polling, so allow
// millions.
static constexpr long kMaxPosedges = 8'000'000L;

static std::string read_file(const char* path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static std::string escape(const std::string& s) {
    std::string out;
    char buf[8];
    for (unsigned char c : s) {
        if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else if (c >= 0x20 && c < 0x7f) out += static_cast<char>(c);
        else { std::snprintf(buf, sizeof(buf), "\\x%02x", c); out += buf; }
    }
    return out;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);   // forward +BRAM0_INIT to $value$plusargs

    // Last non-plusarg, non-flag argument is the golden file path.
    const char* golden_path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (argv[i][0] != '+' && argv[i][0] != '-') golden_path = argv[i];
    }
    if (!golden_path) {
        std::fprintf(stderr, "[EMB] usage: %s +BRAM0_INIT=<hex> <golden>\n", argv[0]);
        return 2;
    }
    const std::string golden = read_file(golden_path);
    if (golden.empty()) {
        std::fprintf(stderr, "[EMB] ERROR: golden file '%s' is empty/missing\n", golden_path);
        return 2;
    }

    Vsimplyv* top = new Vsimplyv;
    UartRx uart(kOversample);

    // Static inputs.
    top->uart_rx_i = 1;   // UART line idles high
    top->gpio_in_i = 0;

    // --- Reset sequence ---
    // sys_reset_i is active-high. Hold it asserted long enough for every divided
    // clock domain and the crossbar reset synchronisers to settle before the
    // core fetches.
    top->sys_reset_i = 1;
    top->sys_clock_i = 0;
    top->eval();
    for (int i = 0; i < 200; ++i) {
        top->sys_clock_i = 1; top->eval();
        top->sys_clock_i = 0; top->eval();
    }
    top->sys_reset_i = 0;   // release reset

    // --- Run ---
    bool passed = false;
    for (long n = 0; n < kMaxPosedges && !Verilated::gotFinish(); ++n) {
        // Rising edge.
        top->sys_clock_i = 1;
        top->eval();
        // Sample uart_tx_o on the posedge of sys_clock_i.
        uart.sample(static_cast<uint8_t>(top->uart_tx_o));
        // Falling edge.
        top->sys_clock_i = 0;
        top->eval();

        // Early exit once the golden has been fully captured.
        if (uart.captured().find(golden) != std::string::npos) {
            passed = true;
            break;
        }
    }

    const std::string& cap = uart.captured();
    top->final();
    delete top;

    if (passed) {
        std::printf("[EMB] captured: \"%s\"\n", escape(cap).c_str());
        std::printf("[EMB] PASS\n");
        return 0;
    }

    std::printf("[EMB] FAIL\n");
    std::printf("[EMB] expected (golden): \"%s\"\n", escape(golden).c_str());
    std::printf("[EMB] captured        : \"%s\"\n", escape(cap).c_str());
    return 1;
}
