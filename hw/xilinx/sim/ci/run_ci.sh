#!/usr/bin/env bash
# Local CI: config flow unit tests, then the smoke on both available backends +
# regenerate sim configs.
# Verilator: mandatory. xsim: only if Vivado (xvlog) is in PATH.
set -euo pipefail

: "${SIMPLYV_ROOT_DIR:?source settings.sh first}"
cd "${SIMPLYV_ROOT_DIR}"

# Python of the config flow env, passed to every make (the Makefiles use PYTHON ?=).
: "${PYTHON:?set PYTHON to the python of the config flow env}"
export PYTHON

echo "== [CI] config flow unit tests =="
(cd config/simply_config && "${PYTHON}" -m pytest -q tests)

echo "== [CI] config_sim regeneration =="
make -C config config_sim

echo "== [CI] Verilator smoke (mandatory) =="
make -C hw/xilinx sim BACKEND=verilator TEST=smoke

if command -v xvlog >/dev/null 2>&1; then
  echo "== [CI] xsim smoke (Vivado present) =="
  make -C hw/xilinx sim BACKEND=xsim TEST=smoke
else
  echo "== [CI] xsim smoke SKIPPED (Vivado not in PATH) =="
fi

# Cheap drift-catcher: elaborate the full embedded cone on Verilator (lint-only,
# no simulation run).  Catches port mismatches between sim models and RTL early.
echo "== [CI] embedded elaboration gate (Verilator lint-only) =="
make -C hw/xilinx sim_elab_embedded

echo "[CI] ALL PASS"
