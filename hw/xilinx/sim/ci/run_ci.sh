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

# Verilator runs: every embedded example. Fast enough for CI.
for t in hello_world echo interrupts xlnx_cdma_examples; do
  echo "== [CI] Verilator TEST=$t =="
  make -C hw/xilinx sim BACKEND=verilator TEST="$t"
done

echo "[CI] ALL PASS"
