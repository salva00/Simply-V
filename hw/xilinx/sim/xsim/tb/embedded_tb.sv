`timescale 1ns/1ps
// R1 vendor testbench: real simplyv (EMBEDDED, ibex) on xsim with real Xilinx
// IP sim-models. The program is preloaded in the real xlnx_bram_0 via its COE;
// the CPU fetches it through the real crossbar. We only drive clk/reset and
// decode uart_tx_o at the real 9600 baud, 8N1, comparing to the shared golden
// (same stimuli as the Verilator harness).
module embedded_tb;
    // ---- real timing constants ----
    localparam real BIT_NS      = 1.0e9 / 9600.0;   // 104166.667 ns/bit (uartlite 9600)
    localparam int  TIMEOUT_MS  = 50;               // watchdog: boot + ~14 chars + margin

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
    int    nrx = 0;
    bit    failed = 0;

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
    initial begin
        byte got;
        load_golden();
        // Wait until reset is released and the TX line is idle-high, so we don't
        // latch an X->0 glitch during reset as a false start bit.
        wait (sys_reset_i === 1'b0);
        wait (uart_tx_o   === 1'b1);
        forever begin
            uart_get(got);
            if (nrx < expected.size() && got !== expected[nrx]) begin
                $display("[EMB] FAIL: byte %0d got %02x exp %02x", nrx, got, expected[nrx]);
                failed = 1;
            end
            nrx++;
            if (nrx == expected.size()) begin
                #(2 * BIT_NS);
                // NB: terminate with $finish (xsim's $fatal does not reliably halt
                // here, which would let a failed run fall through to PASS). The make
                // gate decides PASS/FAIL by grepping for "[EMB] FAIL" / "[EMB] PASS".
                if (failed) $display("[EMB] FAIL");
                else        $display("[EMB] PASS: %0d bytes match golden", nrx);
                $finish;
            end
        end
    end
endmodule
