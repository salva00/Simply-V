#!/usr/bin/env bash
# Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
# Description: local CI. Config flow unit tests, sim config regeneration, then the
#              Verilator benches and the embedded SoC tests.
# Vendor (Questa) is pending license — not in CI yet.
set -euo pipefail

: "${SIMPLYV_ROOT_DIR:?source settings.sh first}"
cd "${SIMPLYV_ROOT_DIR}"

# Python of the config flow env, passed to every make (the Makefiles use PYTHON ?=).
: "${PYTHON:?set PYTHON to the python of the config flow env}"
export PYTHON

echo "== [CI] config flow unit tests =="
(cd config/simply_config && "${PYTHON}" -m pytest -q tests)

echo "== [CI] config_sim regeneration =="
make -C config all config_sim

# Verilator runs: every embedded example on the default core (ibex).
# Fast enough for CI.
for t in hello_world echo interrupts xlnx_cdma_examples; do
  echo "== [CI] Verilator TEST=$t =="
  make -C hw/xilinx sim BACKEND=verilator TEST="$t"
done

# Explicit core per run. The 64-bit cores assert the full embedded suite; the rv32
# non-default cores assert hello_world. The lib-XLEN hygiene in sim.mk makes
# back-to-back core order safe.
# cv64a6_ara's CDMA run is the slowest (~25-30 min CPU); no per-command timeout is
# imposed, so it can't be false-failed.
for c in cv32e40p picorv32 cv64a6 cv64a6_ara; do
  case "$c" in
    cv64a6|cv64a6_ara) tests="hello_world echo interrupts xlnx_cdma_examples" ;;
    *)                 tests="hello_world" ;;
  esac
  for t in $tests; do
    echo "== [CI] Verilator CORE=$c TEST=$t =="
    make -C hw/xilinx sim BACKEND=verilator CORE="$c" TEST="$t"
  done
done

echo "[CI] ALL PASS"
