`timescale 1ns/1ps
// R1 vendor testbench: real simplyv (EMBEDDED, ibex) on xsim with real Xilinx
// IP sim-models. The program is preloaded in the real xlnx_bram_0 via its COE;
// the CPU fetches it through the real crossbar. We only drive clk/reset and
// decode uart_tx_o at the real 9600 baud, 8N1, comparing to the shared golden
// (same stimuli as the Verilator harness).

module embedded_tb;
    // ponytail: xsim drives the REAL uartlite IP (not the Verilator shim), so it
    // RX and TX at the same 9600 baud — inject on uart_rx_i at BIT_NS too.
    localparam real BIT_NS      = 1.0e9 / 9600.0;   // 104166.667 ns/bit (uartlite 9600)
    // Watchdog: boot + prompt TX (~1 ms/char) + RX injection + echo TX + margin.
    localparam int  TIMEOUT_MS  = 200;

    logic        sys_clock_i = 1'b0;
    logic        sys_reset_i = 1'b1;
    logic        uart_rx_i   = 1'b1;     // idle high
    logic        uart_tx_o;
    logic [15:0] gpio_in_i   = '0;       // GPIO_IN_WIDTH  (simplyv_pkg)
    logic [15:0] gpio_out_o;             // GPIO_OUT_WIDTH (simplyv_pkg)

    // DUT — the real top, instantiated by named ports.
    simplyv dut (
        .sys_clock_i (sys_clock_i),
        .sys_reset_i (sys_reset_i),
        .uart_rx_i   (uart_rx_i),
        .uart_tx_o   (uart_tx_o),
        .gpio_in_i   (gpio_in_i),
        .gpio_out_o  (gpio_out_o)
    );

    // 100 MHz input clock.
    always #5 sys_clock_i = ~sys_clock_i;

    // ---- golden ----
    string golden_path;
    int    gfd;
    byte   expected[$];
    int    nrx = 0;       // total UART bytes received (for the watchdog message)
    int    mi  = 0;       // incremental substring-match index into expected[]

    // ---- captured RX stream (for prompt-gated stimulus injection) ----
    // Every byte decoded from uart_tx_o is appended here so the injection
    // process can wait until the SoC has printed the prompt before driving
    // the stimulus onto uart_rx_i (TX-sync, not a blind delay).
    byte   captured[$];

    // ---- stimulus to inject on uart_rx_i (optional, e.g. echo) ----
    string stim_path;
    int    sfd;
    byte   stimulus[$];

    task automatic load_golden();
        int c;
        if (!$value$plusargs("GOLDEN=%s", golden_path)) begin
            $display("[EMB] FAIL: no +GOLDEN=<path>"); $finish;
        end
        gfd = $fopen(golden_path, "rb");
        if (gfd == 0) begin
            $display("[EMB] FAIL: cannot open golden %s", golden_path); $finish;
        end
        forever begin
            c = $fgetc(gfd);
            if (c == -1) break;
            expected.push_back(byte'(c));
        end
        $fclose(gfd);
        $display("[EMB] golden bytes = %0d", expected.size());
    endtask

    // Sample one 8N1 frame from uart_tx_o, return the data byte.
    task automatic uart_get(output byte b);
        @(negedge uart_tx_o);            // start bit edge
        #(0.5 * BIT_NS);                 // move to center of start bit
        if (uart_tx_o !== 1'b0) $display("[EMB] WARN: false start at %t", $time);
        b = 8'h00;
        for (int i = 0; i < 8; i++) begin
            #(BIT_NS);                   // center of data bit i
            b[i] = uart_tx_o;            // LSB first
        end
        #(BIT_NS);                       // into the stop bit
    endtask

    // ---- reset / bring-up ----
    initial begin
        sys_reset_i = 1'b1;
        #5000;                           // hold reset 5 us (margin for clk_wiz model)
        sys_reset_i = 1'b0;              // release -> clk_wiz locks -> rstn_* deassert
    end

    // ---- watchdog ----
    initial begin
        #(TIMEOUT_MS * 1_000_000.0);
        $display("[EMB] FAIL: timeout after %0d ms (received %0d/%0d bytes)",
                 TIMEOUT_MS, nrx, expected.size());
        $finish;
    end

    // ---- receive + compare ----
    // Golden-match semantics: PASS when the golden byte sequence appears as a
    // CONTIGUOUS SUBSTRING anywhere in the received UART stream (same as the
    // Verilator harness, golden subset-of captured). This tolerates examples
    // that emit a non-deterministic prefix/suffix around the deterministic
    // golden region (e.g. R2a interrupts' variable "sleeping..." lines).
    //
    // Incremental sliding-window matcher: keep a match index `mi` into
    // expected[]. On each received byte b: if it extends the current match
    // advance mi; otherwise restart the window (mi = (b == expected[0]) ? 1 : 0).
    // PASS as soon as mi reaches expected.size().
    initial begin
        byte got;
        load_golden();
        // Wait until reset is released and the TX line is idle-high, so we don't
        // latch an X->0 glitch during reset as a false start bit.
        wait (sys_reset_i === 1'b0);
        wait (uart_tx_o   === 1'b1);
        if (expected.size() == 0) begin
            $display("[EMB] FAIL: empty golden");
            $finish;
        end
        forever begin
            uart_get(got);
            nrx++;
            captured.push_back(got);     // feed the prompt detector
            if (got === expected[mi]) begin
                mi++;
            end else begin
                // Mismatch: restart the window. For these goldens a single-step
                // backtrack (check only against expected[0]) is sufficient.
                mi = (got === expected[0]) ? 1 : 0;
            end
            if (mi == expected.size()) begin
                #(2 * BIT_NS);
                // NB: terminate with $finish (xsim's $fatal does not reliably halt
                // here). The make gate greps for "[EMB] FAIL" / "[EMB] PASS".
                $display("[EMB] PASS: golden (%0d bytes) found in UART stream", expected.size());
                $finish;
            end
        end
    end

    // ---- stimulus load (optional +STIMULUS=<path>) ----
    // The stimulus is the word to send; we strip trailing CR/LF and append a
    // single '\n' so scanf("%s") sees exactly one whitespace terminator.
    task automatic load_stimulus();
        int c;
        if (!$value$plusargs("STIMULUS=%s", stim_path))
            return;                       // no stimulus for this test
        sfd = $fopen(stim_path, "rb");
        if (sfd == 0) begin
            $display("[EMB] WARN: cannot open stimulus %s", stim_path);
            return;
        end
        forever begin
            c = $fgetc(sfd);
            if (c == -1) break;
            stimulus.push_back(byte'(c));
        end
        $fclose(sfd);
        // Strip trailing CR/LF, then append exactly one newline terminator.
        while (stimulus.size() > 0 &&
               (stimulus[stimulus.size()-1] == 8'h0A ||
                stimulus[stimulus.size()-1] == 8'h0D))
            void'(stimulus.pop_back());
        stimulus.push_back(8'h0A);
        $display("[EMB] stimulus bytes = %0d", stimulus.size());
    endtask

    // True once the captured TX stream contains the prompt as a substring.
    function automatic bit prompt_seen(input string p);
        int j;
        bit ok;
        if (captured.size() < p.len()) return 1'b0;
        for (int s = 0; s <= captured.size() - p.len(); s++) begin
            ok = 1'b1;
            for (j = 0; j < p.len(); j++)
                if (captured[s+j] !== byte'(p.getc(j))) begin
                    ok = 1'b0;
                    break;
                end
            if (ok) return 1'b1;
        end
        return 1'b0;
    endfunction

    // Drive one 8N1 frame (start + 8 data LSB-first + stop) onto uart_rx_i.
    task automatic uart_put(input byte b);
        uart_rx_i = 1'b0;                 // start bit
        #(BIT_NS);
        for (int i = 0; i < 8; i++) begin
            uart_rx_i = b[i];             // LSB first
            #(BIT_NS);
        end
        uart_rx_i = 1'b1;                 // stop bit
        #(BIT_NS);
    endtask

    // ---- gpio_in injection (interrupts example) ----
    // The GPIO_IN shim raises an IRQ on ANY change of gpio_in_i while enabled, so
    // toggle bit0 on a fixed cadence to generate deterministic GPIO_IN PLIC
    // interrupts. Matched to the Verilator harness EXACTLY in sys_clock cycles
    // (kGpioTogglePeriod = 60000): the 100 MHz sys_clock has a 10 ns period, so
    // 60000 cycles = 600000 ns. Identical schedule => identical ext/timer split.
    // ponytail: hardcoded periodic toggle (no stimulus file).
    localparam real GPIO_TOGGLE_NS = 60000.0 * 10.0;   // 60000 sys_clock cycles
    initial begin
        wait (sys_reset_i === 1'b0);
        forever begin
            #(GPIO_TOGGLE_NS);
            gpio_in_i[0] = ~gpio_in_i[0];
        end
    end

    // ---- stimulus injection (prompt-gated, TX-synced) ----
    initial begin
        load_stimulus();
        if (stimulus.size() == 0) begin
            uart_rx_i = 1'b1;             // nothing to inject; keep line idle
        end else begin
            wait (sys_reset_i === 1'b0);
            // Poll the captured TX stream until the SoC has printed the prompt
            // (a wait() on a queue-reading function is not reliably re-evaluated
            // on queue writes, so poll on a fixed cadence instead).
            while (!prompt_seen("Please enter a string"))
                #(BIT_NS);
            // ponytail: real uartlite has a 16-deep RX FIFO; SimplyV+\n is 8 bytes,
            // so stream back-to-back — no inter-byte gap needed.
            foreach (stimulus[i])
                uart_put(stimulus[i]);
        end
    end
endmodule
