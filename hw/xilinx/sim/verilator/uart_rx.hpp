// uart_rx.hpp — UART receive/decoder for the Verilator C++ testbench.
//
// Reconstructs bytes from the SoC's uart_tx_o line (the functional serializer
// in hw/xilinx/sim/models/embedded/xlnx_axi_uartlite.sv).
//
// ---------------------------------------------------------------------------
// CONTRACT — SIM_UART_CYCLES_PER_BIT must match the uartlite shim.
//
//   The uartlite shim (xlnx_axi_uartlite.sv) emits one UART bit every
//   SIM_UART_CYCLES_PER_BIT cycles of its AXI clock s_axi_aclk. In the embedded
//   SoC that clock is PBUS_clk (= clk_10). Both the SV shim and this decoder
//   read the value from the SAME -D macro injected by sim.mk, so there is a
//   single source of truth (the SIM_UART_CYCLES_PER_BIT variable in sim.mk).
//
//   Frame: 1 start bit (0) + 8 data bits (LSB first) + 1 stop bit (1) = 10 bits.
// ---------------------------------------------------------------------------
//
// Sampling model
//   The testbench cannot directly observe PBUS_clk; it feeds this decoder one
//   sample per posedge of the top-level sys_clock_i. Because the UART AXI clock
//   is a (possibly) divided version of sys_clock_i, each shim "cycle" spans
//   `oversample` testbench samples. The effective bit period in testbench
//   samples is therefore  kCyclesPerBit * oversample.  The testbench passes
//   `oversample` (sys_clock_i posedges per PBUS_clk cycle) at construction.
//
//   Decoding is self-synchronising: we wait for the idle->start falling edge,
//   then sample each of the 10 bits at the MIDDLE of its bit period, which
//   tolerates the divided-clock phase relationship between sys_clock_i and the
//   shim's AXI clock.

#ifndef SIMPLYV_UART_RX_HPP
#define SIMPLYV_UART_RX_HPP

#include <cstdint>
#include <string>

// Single source of truth: injected from sim.mk via -DSIM_UART_CYCLES_PER_BIT.
// The fallback default mirrors the SV shim's `ifndef default (16).
#ifndef SIM_UART_CYCLES_PER_BIT
#define SIM_UART_CYCLES_PER_BIT 16
#endif

class UartRx {
public:
    // CONTRACT: must equal CYCLES_PER_BIT in xlnx_axi_uartlite.sv. Both come
    // from the SIM_UART_CYCLES_PER_BIT macro defined in sim.mk.
    static constexpr int kCyclesPerBit = SIM_UART_CYCLES_PER_BIT;

    // oversample = number of testbench samples (sys_clock_i posedges) per one
    // shim AXI-clock (PBUS_clk) cycle. In this redesigned repo the clk_wiz sim
    // shim drives every output clock identical to clk_in1 (single synchronous
    // domain), so the embedded TB passes oversample = 1.
    explicit UartRx(int oversample = 1)
        : oversample_(oversample),
          bit_samples_(kCyclesPerBit * oversample),
          state_(IDLE),
          sample_ctr_(0),
          bit_idx_(0),
          cur_byte_(0),
          prev_line_(1) {}

    // Feed one line sample (the current value of uart_tx_o). Call once per
    // sys_clock_i posedge.
    void sample(uint8_t line) {
        line &= 0x1;
        switch (state_) {
        case IDLE:
            // Detect the start bit: idle line is 1, start bit is 0.
            if (prev_line_ == 1 && line == 0) {
                state_      = START;
                // Align to the middle of the start bit.
                sample_ctr_ = 0;
                bit_idx_    = 0;
                cur_byte_   = 0;
            }
            break;

        case START:
            // Count to the middle of the start bit to confirm it.
            if (++sample_ctr_ >= bit_samples_ / 2) {
                if (line == 0) {
                    // Valid start bit confirmed at mid-bit; advance to data.
                    state_      = DATA;
                    sample_ctr_ = 0;
                } else {
                    // Glitch, not a real start bit.
                    state_ = IDLE;
                }
            }
            break;

        case DATA:
            // Step a full bit period from the middle of the previous bit to the
            // middle of this data bit.
            if (++sample_ctr_ >= bit_samples_) {
                sample_ctr_ = 0;
                // LSB first.
                cur_byte_ |= static_cast<uint8_t>(line << bit_idx_);
                if (++bit_idx_ == 8) {
                    state_ = STOP;
                }
            }
            break;

        case STOP:
            // Sample the stop bit at its midpoint, then emit the byte.
            if (++sample_ctr_ >= bit_samples_) {
                sample_ctr_ = 0;
                captured_.push_back(static_cast<char>(cur_byte_));
                state_ = IDLE;
            }
            break;
        }
        prev_line_ = line;
    }

    const std::string& captured() const { return captured_; }
    void clear() { captured_.clear(); }

private:
    enum State { IDLE, START, DATA, STOP };

    const int   oversample_;
    const int   bit_samples_;   // testbench samples per UART bit period
    State       state_;
    int         sample_ctr_;
    int         bit_idx_;
    uint8_t     cur_byte_;
    uint8_t     prev_line_;
    std::string captured_;
};

#endif // SIMPLYV_UART_RX_HPP
