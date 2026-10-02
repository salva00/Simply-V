#!/usr/bin/env bash
# Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
# Description: local CI. Config flow unit tests, sim config regeneration, then the
#              Verilator benches and the embedded SoC tests.
# Vendor backends (xsim, manual; Questa, pending license) are not in CI.
set -euo pipefail

: "${SIMPLYV_ROOT_DIR:?source settings.sh first}"
cd "${SIMPLYV_ROOT_DIR}"

# Python of the config flow env, passed to every make (the Makefiles use PYTHON ?=).
: "${PYTHON:?set PYTHON to the python of the config flow env}"
export PYTHON

echo "== [CI] config flow unit tests =="
(cd config/simply_config && "${PYTHON}" -m pytest -q tests)

echo "== [CI] mode: $([ "${SIM_CI_FULL:-0}" = 1 ] && echo 'FULL (incl. CDMA on ara)' || echo 'default (CDMA on ara skipped; SIM_CI_FULL=1 to include)') =="
echo "== [CI] Verilator TEST=smoke (regenerates the sim config) + elaboration gate =="
make -C hw/xilinx sim BACKEND=verilator TEST=smoke
make -C hw/xilinx sim_elab_embedded

echo "== [CI] crossbar bench (32/64-bit) =="
make -C hw/xilinx sim_verilator_xbar
make -C hw/xilinx sim_verilator_xbar XBAR_DW=64
make -C hw/xilinx sim_verilator_axilite_xbar
if [ -n "${XILINX_VIVADO:-}" ]; then
  echo "== [CI] crossbar benches with the AXI4 protocol checker =="
  make -C hw/xilinx sim_verilator_xbar AXI4PC=1
  make -C hw/xilinx sim_verilator_xbar XBAR_DW=64 AXI4PC=1
  make -C hw/xilinx sim_verilator_axilite_xbar AXI4PC=1
fi
make -C hw/xilinx sim_verilator_mx_bridge

# Explicit core per run (CI no longer depends on the user's config_system.csv). ibex and the
# 64-bit cores assert the full embedded suite; the rv32 non-default cores assert hello_world.
# The lib-XLEN hygiene in sim.mk makes back-to-back core order safe.
#
# cv64a6_ara skips xlnx_cdma_examples by default: that run is the long pole (~30 min, the whole
# idle Ara netlist is evaluated every cycle) and adds no unique coverage — CDMA mem2mem never
# touches the vector unit, and the 64-bit CDMA path is already asserted by cv64a6 (scalar). Set
# SIM_CI_FULL=1 to add it back (the manual run is always available).
for c in ibex cv32e40p picorv32 cv64a6 cv64a6_ara mx; do
  case "$c" in
    ibex|cv64a6) tests="hello_world echo interrupts xlnx_cdma_examples" ;;
    cv64a6_ara)  tests="hello_world echo interrupts"
                 [ "${SIM_CI_FULL:-0}" = 1 ] && tests="${tests} xlnx_cdma_examples" ;;
    # mx (VC0, GAP/UPV): hello_world + echo green. interrupts is held back — the
    # vendored L1D evicts a dirty line without writeback on a same-index conflict,
    # hanging printf("%u") before IRQs are even enabled.
    mx)          tests="hello_world echo" ;;
    *)           tests="hello_world" ;;
  esac
  for t in $tests; do
    echo "== [CI] Verilator CORE=$c TEST=$t =="
    make -C hw/xilinx sim BACKEND=verilator CORE="$c" TEST="$t"
  done
done

echo "[CI] ALL PASS"
