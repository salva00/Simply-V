// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: Verilator testbench for the embedded SoC. Loads a program
//              (+BRAM0_INIT=<hexfile>) into xlnx_bram_0, runs the SoC, decodes
//              uart_tx_o and compares it to a golden file: "[EMB] PASS" / exit 0
//              on match, "[EMB] FAIL" / exit 1 otherwise. sys_reset_i is active
//              high; the sim clk_wiz drives every clock from sys_clock_i.
//              +UART_GAP_BITS=<n> and +MAX_POSEDGES=<n> override the RX frame
//              gap and the run limit (sim.mk sets them for CORE_MX).

#include "Vsimplyv.h"
#include "verilated.h"
#include "uart_rx.hpp"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

// UART bit period in uartlite AXI clock cycles, from sim.mk (same value as the SV model).
#ifndef SIM_UART_CYCLES_PER_BIT
#define SIM_UART_CYCLES_PER_BIT 16
#endif

// UART transmitter: serialises the stimulus onto uart_rx_i (8N1, one step()
// per sys_clock_i posedge), started by begin_tx() once the prompt is seen.
// The sim model's RX register is 1-deep, so frames are spaced by gap_bits idle
// bit periods to let the polling firmware drain each byte.
class UartTx {
public:
    // gap_bits: idle bit-periods inserted between consecutive frames so the
    // firmware's AXI-Lite poll-and-read loop can drain the 1-deep RX register in time.
    UartTx(int cycles_per_bit, int gap_bits)
        : cycles_per_bit_(cycles_per_bit), gap_bits_(gap_bits) {}

    // Load the stimulus to send (called once, after the prompt is seen).
    void begin_tx(const std::string& s) {
        data_       = s;
        byte_idx_   = 0;
        active_     = !data_.empty();
        load_frame();
    }

    bool active() const { return active_; }

    // Advance one sys_clock_i posedge; return the level to drive on uart_rx_i.
    uint8_t step() {
        if (!active_) return 1;          // idle high
        // Inter-byte idle gap: hold the line high for gap_bits_ bit-periods.
        if (gap_left_ > 0) {
            if (++cycle_ctr_ >= cycles_per_bit_) {
                cycle_ctr_ = 0;
                --gap_left_;
            }
            return 1;
        }
        uint8_t level = frame_bit();
        if (++cycle_ctr_ >= cycles_per_bit_) {
            cycle_ctr_ = 0;
            if (++bit_pos_ >= 10) {       // finished start+8data+stop
                bit_pos_ = 0;
                if (++byte_idx_ >= data_.size()) {
                    active_ = false;      // all bytes sent -> idle high
                    return 1;
                }
                load_frame();
                gap_left_ = gap_bits_;    // idle before the next frame
            }
        }
        return level;
    }

private:
    void load_frame() {
        if (byte_idx_ < data_.size())
            cur_byte_ = static_cast<uint8_t>(data_[byte_idx_]);
        bit_pos_   = 0;
        cycle_ctr_ = 0;
    }

    // Level for the current bit position: 0=start, 1..8=data LSB-first, 9=stop.
    uint8_t frame_bit() const {
        if (bit_pos_ == 0) return 0;                 // start bit
        if (bit_pos_ <= 8) return (cur_byte_ >> (bit_pos_ - 1)) & 0x1;
        return 1;                                    // stop bit
    }

    const int   cycles_per_bit_;
    const int   gap_bits_;
    std::string data_;
    size_t      byte_idx_  = 0;
    uint8_t     cur_byte_  = 0;
    int         bit_pos_   = 0;   // 0..9 within the current frame
    int         cycle_ctr_ = 0;   // cycles within the current bit
    int         gap_left_  = 0;   // remaining idle bit-periods before next frame
    bool        active_    = false;
};

// sys_clock_i posedges per PBUS_clk cycle (single clock domain in sim).
static constexpr int kOversample = 1;

// Generous cycle cap (sys_clock_i posedges). 14 bytes * 10 bits *
// SIM_UART_CYCLES_PER_BIT samples/bit of pure serialisation, plus the program's
// boot + crossbar latency (CUT_ALL_PORTS pipelining) and UART polling, so allow
// millions.
static constexpr long kMaxPosedges = 8'000'000L;
// Default RX inter-frame gap (bit periods).
static constexpr int kGapBits = 40;

// gpio_in toggle cadence (sys_clock_i posedges) for the interrupts example. Each
// toggle generates one GPIO_IN PLIC interrupt; period set so several fire over the
// run. Harmless for other examples (their firmware ignores gpio_in / has no IRQ).
static constexpr long kGpioTogglePeriod = 60'000L;

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
    // Optional +STIMULUS=<path>: a string injected on uart_rx_i once the prompt
    // appears in the captured TX stream (for interactive examples like echo).
    const char* golden_path   = nullptr;
    const char* stimulus_path = nullptr;
    const char* prompt        = "Please enter a string";
    int         gap_bits      = kGapBits;
    long        max_posedges  = kMaxPosedges;
    for (int i = 1; i < argc; ++i) {
        if (std::strncmp(argv[i], "+STIMULUS=", 10) == 0)
            stimulus_path = argv[i] + 10;
        else if (std::strncmp(argv[i], "+UART_GAP_BITS=", 15) == 0)
            gap_bits = std::atoi(argv[i] + 15);
        else if (std::strncmp(argv[i], "+MAX_POSEDGES=", 14) == 0)
            max_posedges = std::atol(argv[i] + 14);
        else if (argv[i][0] != '+' && argv[i][0] != '-')
            golden_path = argv[i];
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

    // Optional stimulus to inject on uart_rx_i after the prompt is observed.
    std::string stimulus;
    if (stimulus_path) {
        stimulus = read_file(stimulus_path);
        // Strip a trailing newline so we control the terminator: scanf("%s")
        // stops on whitespace, so append exactly one '\n' to end the token.
        while (!stimulus.empty() &&
               (stimulus.back() == '\n' || stimulus.back() == '\r'))
            stimulus.pop_back();
        stimulus.push_back('\n');
    }

    Vsimplyv* top = new Vsimplyv;
    UartRx uart(kOversample);
    UartTx tx_inject(SIM_UART_CYCLES_PER_BIT * kOversample, gap_bits);
    bool   tx_started = false;

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
    for (long n = 0; n < max_posedges && !Verilated::gotFinish(); ++n) {
        // Start injecting the stimulus once the prompt appears in the TX stream
        // (TX-sync, not a blind delay). Drive uart_rx_i one bit-level per
        // posedge from the harness UART transmitter.
        if (!stimulus.empty()) {
            if (!tx_started &&
                uart.captured().find(prompt) != std::string::npos) {
                tx_inject.begin_tx(stimulus);
                tx_started = true;
            }
            if (tx_started)
                top->uart_rx_i = tx_inject.step();
        }

        // interrupts example: the GPIO_IN sim model raises an IRQ on any change of
        // gpio_in_i, so toggle bit0 on a fixed cadence.
        if ((n % kGpioTogglePeriod) == 0)
            top->gpio_in_i ^= 0x1;

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
