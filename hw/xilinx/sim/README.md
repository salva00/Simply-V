# SoC Simulation

The same RTL runs on two backends, selected with `BACKEND`:

1. **Verilator** (default, in CI): the `xlnx_*` IPs are resolved by the sim models in `models/`
   and the crossbars by the in-tree RTL (`XBAR_IMPL=CUSTOM`).
2. **xsim** (Vivado, manual, ibex only): the real Xilinx IP sim models, with the SV testbench,
   Vivado export and COE flow in `xsim/`.

       make -C hw/xilinx sim BACKEND=xsim CORE=ibex TEST=hello_world

`BACKEND=questa` is reserved for the Questa flow (`sim_compile_simlib`, `sim_export_<ip>`) and
is not available yet.

## Choosing the core

Set `CORE_SELECTOR` in `config/configs/common/config_system.csv`, then run:

    make sim TEST=hello_world          # from repo root

This works for ibex, cv32e40p, picorv32, cv64a6 and cv64a6_ara. The MicroBlaze-V cores have
no Verilator cone; `config_sim` rejects them.

`make sim` regenerates the config from the CSVs, so the firmware and the RTL cone follow the
selected core. The tracked files the regen rewrites (`config.mk`, linker scripts,
`simplyv_conf.h`, IP `config.tcl`, crossbar wrappers, `rtl/generated/*`) are restored when the
run ends, also on Ctrl-C; a backup left by a killed run is restored by the next `make sim`.
One sim per checkout: a second concurrent one fails on a lock.

Quick override without touching the CSV (used by CI):

    make sim CORE=ibex       TEST=hello_world
    make sim CORE=cv64a6_ara TEST=xlnx_cdma_examples

`CORE=` generates a temporary per-core CSV; `config_system.csv` is not modified.
When setting the core in the CSV by hand: picorv32 needs `VIO_RESETN_DEFAULT=0`, cv64a6 and
cv64a6_ara need `XLEN=64` (sys_parser rejects other values).

### Prerequisites

- `riscv32-unknown-elf-*` and `riscv64-unknown-elf-*` toolchains on `PATH`.
- `python3` resolving to the simply-v environment (or `PYTHON=...`; `run_ci.sh` requires it).

## Tests

    make sim TEST=<hello_world|echo|interrupts|xlnx_cdma_examples>

Each `TEST` builds `sw/SoC/examples/<TEST>` and checks the UART output against
`stimuli/golden/<TEST>.uart.golden`. In simulation `interrupts` runs with shorter timer/sleep
periods and `xlnx_cdma_examples` with one round. The config flow writes the Verilator filelist
and `siminc/` to `generated/` (gitignored).

## Crossbar benches

Standalone benches on the in-tree crossbar RTL (no firmware):

    make -C hw/xilinx sim_verilator_xbar [XBAR_DW=64] [AXI4PC=1]   # simplyv_axi_xbar
    make -C hw/xilinx sim_verilator_axilite_xbar [AXI4PC=1]        # simplyv_axilite_xbar
    make -C hw/xilinx sim_xsim_xbar                                # simplyv_axi_xbar, xsim + Xilinx AXI VIP

`AXI4PC=1` binds the ARM AXI4 protocol checker shipped with Vivado (needs `XILINX_VIVADO`).

## Local CI

    PYTHON=<python of the simply-v env> bash hw/xilinx/sim/ci/run_ci.sh

Runs pytest, the crossbar benches (also with `AXI4PC=1` when `XILINX_VIVADO` is set), then
Verilator on every core: the full suite on ibex, cv64a6 and cv64a6_ara, `hello_world` on
cv32e40p and picorv32. xsim is not in CI.

`cv64a6_ara` skips `xlnx_cdma_examples` by default (~30 min, the idle Ara netlist is evaluated
every cycle; the 64-bit CDMA path is already covered by cv64a6). `SIM_CI_FULL=1` includes it.
