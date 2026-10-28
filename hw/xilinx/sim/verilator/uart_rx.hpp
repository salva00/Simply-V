// Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
// Description: UART 8N1 decoder for the Verilator testbench. Reconstructs bytes
//              from uart_tx_o (xlnx_axi_uartlite sim model), one sample per
//              sys_clock_i posedge, sampling each bit at the middle of its period.
//              SIM_UART_CYCLES_PER_BIT comes from sim.mk, as in the SV model.

#ifndef SIMPLYV_UART_RX_HPP
#define SIMPLYV_UART_RX_HPP

#include <cstdint>
#include <string>

class UartRx {
public:
    UartRx()
        : bit_samples_(SIM_UART_CYCLES_PER_BIT),
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

    const int   bit_samples_;   // testbench samples per UART bit period
    State       state_;
    int         sample_ctr_;
    int         bit_idx_;
    uint8_t     cur_byte_;
    uint8_t     prev_line_;
    std::string captured_;
};

#endif // SIMPLYV_UART_RX_HPP
