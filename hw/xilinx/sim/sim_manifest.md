# sim_manifest — registry of the filelist-swap HAL contract

Rule: every `xlnx_*` IP instantiated by the RTL has its row HERE. Whoever adds
an IP adds the row. Contract = module-name + ports (see the dual-toolchain spec).

Third-party provenance (constraint: only repos cataloged in openhwgroup/uap):
- `hw/deps/axi`               — pulp-platform/axi v0.39.6 (UAP: TRISTAN "AXI", Solderpad)
- `hw/deps/common_cells`      — v1.37.0 (declared dependency of axi)
- `hw/deps/tech_cells_generic`— v0.2.13 (declared dependency of axi)

| IP (module) | Vendor (xsim) | Verilator (open) | Covered by test | State |
|---|---|---|---|---|
| smoke_dut (no IP) | shared rtl | shared rtl | smoke | R0 |
| xlnx_mbus_crossbar | Vivado sim-model | shim on pulp axi_xbar + sim_addrmap_pkg | hello_world | R1 |
| xlnx_pbus_crossbar | Vivado sim-model | shim on pulp axi_lite_xbar + sim_addrmap_pkg | hello_world | R1 |
| xlnx_clk_wiz | Vivado sim-model | behavioral shim (sim-only) | hello_world | R1 |
| xlnx_blk_mem_gen_0 | sim-model + COE | AXI4 shim + plusarg preload | hello_world | R1 |
| xlnx_axi_uartlite | Vivado sim-model | register-accurate shim | hello_world | R1 |
| xlnx_axilite_timer | Vivado sim-model | functional shim | timer test | R2 |
| xlnx_axi_gpio_in / _out | Vivado sim-model | functional shim | gpio test | R2 |
| xlnx_axi_cdma | Vivado sim-model | functional shim | cdma test | R2 |
