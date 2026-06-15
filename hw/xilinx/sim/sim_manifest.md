# sim_manifest — registry of the filelist-swap HAL contract

Rule: every `xlnx_*` IP instantiated by the RTL has its row HERE. Whoever adds
an IP adds the row. Contract = module-name + ports (see the dual-toolchain spec).

Third-party provenance (constraint: only repos cataloged in openhwgroup/uap):
- `hw/deps/axi`               — pulp-platform/axi v0.39.6 (UAP: TRISTAN "AXI", Solderpad)
- `hw/deps/common_cells`      — v1.37.0 (declared dependency of axi)
- `hw/deps/tech_cells_generic`— v0.2.13 (declared dependency of axi)

Active backend: **Verilator only**. The vendor backend will be **Questa Sim** (Siemens,
pending license) — its SV testbench + Vivado export + COE flow are kept in `xsim/` as the
base to adapt (Questa is SV-native; xsim targets stay but are not in the active flow).
"State ✅" = green on Verilator.

| IP (module) | Vendor (Questa, pending) | Verilator (open) | Covered by test | State |
|---|---|---|---|---|
| smoke_dut (no IP) | shared rtl | shared rtl | smoke | R0 ✅ |
| xlnx_mbus_crossbar | export base ready | shim on pulp axi_xbar + sim_addrmap_pkg | hello_world | R1 ✅ |
| xlnx_pbus_crossbar | export base ready | shim on pulp axi_lite_xbar + sim_addrmap_pkg | hello_world | R1 ✅ |
| xlnx_clk_wiz | export base ready | behavioral shim (all clocks = clk_in1, single domain) | hello_world | R1 ✅ |
| xlnx_bram_0 (boot) | COE preload base ready | AXI4 shim + `+BRAM0_INIT=` plusarg | hello_world | R1 ✅ |
| xlnx_bram_1 (main mem) | export base ready | AXI4 shim (shared `sim_axi_bram` core, `+BRAM1_INIT=`) | hello_world | R1 ✅ |
| xlnx_axi_uartlite | export base ready | register-accurate shim (TX + RX) | hello_world, echo | R1/R2a ✅ |
| xlnx_axilite_timer | export base ready | functional shim (counter + IRQ) | interrupts | R2a ✅ |
| xlnx_axi_gpio_in / _out | export base ready | functional shim (IRQ on change) | interrupts | R2a ✅ |
| xlnx_axi_cdma | export base ready | functional shim (simple mem-to-mem) | xlnx_cdma_examples | R2a ✅ |
