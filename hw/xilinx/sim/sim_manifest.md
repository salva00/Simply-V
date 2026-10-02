# sim_manifest — registry of the filelist-swap HAL contract

Rule: every `xlnx_*` IP instantiated in a Verilator sim cone (`SIM_CONE_UNITS`) has its row
HERE. Whoever adds an IP to a cone adds the row. Contract = module name + ports.

Active backend (CI): **Verilator**. Vendor backend in use today: Vivado **xsim** (manual,
ibex only; SV testbench + Vivado export + COE flow in `xsim/`). Intended vendor backend:
**Questa Sim** (Siemens, pending license).

| IP (module) | Vendor (xsim; Questa pending) | Verilator (open) | Covered by test |
|---|---|---|---|
| smoke_dut (no IP) | shared rtl | shared rtl | smoke |
| mbus_crossbar_wrapper | `xlnx_mbus_crossbar` IP | `XBAR_IMPL` selects the Xilinx IP or `simplyv_axi_xbar`; Verilator always CUSTOM | hello_world (CUSTOM on Verilator, XILINX on xsim) |
| pbus_crossbar_wrapper | `xlnx_pbus_crossbar` IP | `XBAR_IMPL` selects the Xilinx IP or `simplyv_axilite_xbar`; Verilator always CUSTOM | hello_world (CUSTOM on Verilator, XILINX on xsim) |
| xlnx_clk_wiz | export base ready | behavioral sim model (all clocks = clk_in1, single domain) | hello_world |
| xlnx_bram_0 (boot) | COE preload base ready | AXI4 sim model + `+BRAM0_INIT=` plusarg | hello_world |
| xlnx_bram_1 (main mem) | export base ready | AXI4 sim model (shared `sim_axi_bram` core, `+BRAM1_INIT=`) | hello_world |
| xlnx_axi_uartlite | export base ready | register-accurate sim model (TX + RX) | hello_world, echo |
| xlnx_axilite_timer | export base ready | functional sim model (counter + IRQ) | interrupts |
| xlnx_axi_gpio_in / _out | export base ready | functional sim model (IRQ on change) | interrupts |
| xlnx_axi_cdma | export base ready | functional sim model (simple mem-to-mem) | xlnx_cdma_examples |
| xlnx_axi4_to_axilite_d32_converter | export base ready | sim model | hello_world |
| xlnx_axi_d32_clock_converter / xlnx_axi_d64_clock_converter | export base ready | sim model (pass-through, single domain) | hello_world |
| xlnx_axi_dwidth_32_to_64_converter / xlnx_axi_dwidth_64_to_32_converter | export base ready | sim model (64-bit MBUS only) | hello_world on cv64a6 |
| xlnx_jtag_axi | export base ready | quiescent stub (idle master) | hello_world (idle) |
| xlnx_vio | export base ready | stub (`probe_out0` = 1, resetn released) | hello_world |

## Crossbar benches

Standalone benches on the in-tree crossbar RTL (no firmware):

- `sim_verilator_xbar [XBAR_DW=64] [AXI4PC=1]` — `simplyv_axi_xbar` AXI4 crossbar.
- `sim_verilator_axilite_xbar [AXI4PC=1]` — `simplyv_axilite_xbar` AXI4-Lite crossbar.
- `sim_xsim_xbar` — same AXI4 crossbar, on xsim with the Xilinx AXI VIP. Manual, needs Vivado, not in CI.
- `xbar_synth_check` — Vivado out-of-context RTL elaboration of the crossbar units and the
  `mbus_crossbar_wrapper`/`pbus_crossbar_wrapper` CUSTOM branch. Parse/elaboration gate only,
  no project, no IP.
- `simplyv_elab_check` — Vivado `synth_design -rtl` of the full `simplyv` top with the generated
  Xilinx IPs (XILINX branch of the wrappers). Needs `make ips`.

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

CI runs `hello_world`, `echo`, `interrupts` and `xlnx_cdma_examples` on ibex and cv64a6, the
same without `xlnx_cdma_examples` on cv64a6_ara (`SIM_CI_FULL=1` adds it), and `hello_world`
only on cv32e40p and picorv32; `hello_world` and `echo` on mx (see its row).

| Core | XLEN | Notes |
|---|---|---|
| ibex | 32 | baseline |
| cv32e40p | 32 | needed BRAM sim model word-align fix (cv32e40p OBI sends byte addresses) |
| picorv32 | 32 | needs no-RVC firmware (CORE=picorv32 builds app+libs with C_EXTENSION=N) + crt0 CSR-skip (no standard mtvec/mstatus/mie). COMPRESSED_ISA=0, custom IRQ -> the standard `interrupts` example (CLINT/PLIC -> mtvec) does not run. |
| mx | 32 | VC0 (GAP, UPV), simulation only (no FPGA IP; fetched by `make units MX=1`). `hello_world` and `echo` only: the vendored L1D drops a dirty line on a same-index conflict, so `interrupts` is excluded (see README). |
| cv64a6 | 64 | CVA6 scalar; firmware rv64im/lp64 (CORE=cv64a6 builds app+libs with XLEN=64). |
| cv64a6_ara | 64 | CVA6 + Ara vector unit; same XLEN=64 firmware. Ara CDMA is the slowest run (~25-30 min CPU); CI skips it by default (`SIM_CI_FULL=1` to include). |

The 64-bit cores need the **riscv64 toolchain** (`riscv64-unknown-elf-`, on PATH, provided
by the caller); the Ara RTL is vendored via `hw/units/custom_cv64a6_ara/fetch_sources.sh`.

Per-core cone is selected by `simply_config` (`SIM_CONE_UNITS[CORE_SELECTOR]`); the `CORE=`
override generates a temp per-core config CSV without touching the user's config_system.csv.
The firmware FORCE recipe (sim.mk) rebuilds the tinyio/simplyv static libs to each run's
XLEN/C_EXTENSION, so back-to-back multi-core runs (e.g. rv32 after rv64) link cleanly.
