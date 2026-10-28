#!/usr/bin/env bash
# Local CI: config flow unit tests, sim config regeneration, then the embedded
# SoC on Verilator.
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

echo "== [CI] Verilator embedded hello_world =="
make -C sw/SoC/examples/hello_world bin/hello_world.hex
make -C hw/xilinx sim BACKEND=verilator TEST=embedded

echo "[CI] ALL PASS"
