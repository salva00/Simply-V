#!/usr/bin/env bash
# Local CI: regenerate sim configs, then run the Verilator backend (active).
# Vendor (Questa) is pending license — not in CI yet.
set -euo pipefail

: "${SIMPLYV_ROOT_DIR:?source settings.sh first}"
cd "${SIMPLYV_ROOT_DIR}"

# The config flow runs under the simply-v conda env (python3.10 is not on PATH in a
# bare shell). Resolve it once and export so every `make ... config_sim` picks it up
# (the Makefiles use PYTHON ?=). Override by presetting PYTHON.
export PYTHON="${PYTHON:-$(conda run -n simply-v which python)}"

echo "== [CI] mode: $([ "${SIM_CI_FULL:-0}" = 1 ] && echo 'FULL (incl. CDMA on ara)' || echo 'default (CDMA on ara skipped; SIM_CI_FULL=1 to include)') =="
echo "== [CI] config regen + elaboration gate =="
make -C hw/xilinx sim_config_regen
make -C hw/xilinx sim_elab_embedded

echo "== [CI] Verilator TEST=smoke =="
make -C hw/xilinx sim BACKEND=verilator TEST=smoke

# Explicit core per run (CI no longer depends on the user's config_system.csv). ibex and the
# 64-bit cores assert the full embedded suite; the rv32 non-default cores assert hello_world
# (R2b-1 scope). The lib-XLEN hygiene in sim.mk makes back-to-back core order safe.
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
    # mx (UPV/GAP VC0): hello_world + echo green. interrupts is held back — the
    # vendored L1D evicts a dirty line without writeback on a same-index conflict,
    # hanging printf("%u") before IRQs are even enabled (see docs residual-work).
    mx)          tests="hello_world echo" ;;
    *)           tests="hello_world" ;;
  esac
  for t in $tests; do
    echo "== [CI] Verilator CORE=$c TEST=$t =="
    make -C hw/xilinx sim BACKEND=verilator CORE="$c" TEST="$t"
  done
done

echo "[CI] ALL PASS"
