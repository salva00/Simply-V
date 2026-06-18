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

## CSV-driven flow

Core selection and config are driven by `config/configs/common/config_system.csv`. `make sim`
(or `make -C hw/xilinx sim BACKEND=verilator`) auto-regenerates config on every call — no
manual step needed. Firmware and RTL cone self-specialize to the selected core.

`make sim CORE=<core>` is an equivalent quick override (used by CI); it generates a temporary
per-core CSV without modifying `config_system.csv`.

Validator constraints when editing the CSV by hand:
- **picorv32**: requires `VIO_RESETN_DEFAULT=0`.
- **cv64a6 / cv64a6_ara**: requires `XLEN=64`; sys_parser rejects a mismatch.

`settings.sh` is machine-agnostic. The caller provides the toolchains (`riscv32-unknown-elf-*`
and `riscv64-unknown-elf-*`) on `PATH` and an active Python env (`python3` → simply-v conda).

## Cores (Verilator) — `make sim BACKEND=verilator TEST=<test> CORE=<core>`

Cores are green for `hello_world` + `echo`/`interrupts`/`xlnx_cdma_examples`, except
picorv32 which skips `interrupts` (custom IRQ, see Notes).

| Core | XLEN | Notes |
|---|---|---|
| ibex (default, CORE empty) | 32 | baseline |
| cv32e40p | 32 | needed BRAM shim word-align fix (cv32e40p OBI sends byte addresses) |
| picorv32 | 32 | needs no-RVC firmware (CORE=picorv32 builds app+libs with C_EXTENSION=N) + crt0 CSR-skip (no standard mtvec/mstatus/mie). COMPRESSED_ISA=0, custom IRQ -> the standard `interrupts` example (CLINT/PLIC -> mtvec) does not run; hello_world/echo/cdma pass. |
| cv64a6 | 64 | CVA6 scalar; firmware rv64im/lp64 (CORE=cv64a6 builds app+libs with XLEN=64). |
| cv64a6_ara | 64 | CVA6 + Ara vector unit; same XLEN=64 firmware. Ara CDMA is the slowest run (~25-30 min CPU); CI skips it by default (`SIM_CI_FULL=1` to include). |

The 64-bit cores need the **riscv64 toolchain** (`riscv64-unknown-elf-`, on PATH via
`settings.sh`); the Ara RTL is vendored via `hw/units/custom_cv64a6_ara/fetch_sources.sh`.

Per-core cone is selected by `simply_config` (`SIM_CONE_UNITS[CORE_SELECTOR]`); the `CORE=`
override generates a temp per-core config CSV without touching the user's config_system.csv.
The firmware FORCE recipe (sim.mk) rebuilds the tinyio/simplyv static libs to each run's
XLEN/C_EXTENSION, so back-to-back multi-core runs (e.g. rv32 after rv64) link cleanly.
