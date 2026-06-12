#!/usr/bin/env bash
# Local CI: run the smoke on both available backends + regenerate sim configs.
# Verilator: mandatory. xsim: only if Vivado (xvlog) is in PATH.
set -euo pipefail

: "${SIMPLYV_ROOT_DIR:?source settings.sh first}"
cd "${SIMPLYV_ROOT_DIR}"

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

echo "[CI] ALL PASS"
