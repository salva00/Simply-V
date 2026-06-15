#!/usr/bin/env bash
# Local CI: regenerate sim configs, then run the Verilator backend (active).
# Vendor (Questa) is pending license — not in CI yet.
set -euo pipefail

: "${SIMPLYV_ROOT_DIR:?source settings.sh first}"
cd "${SIMPLYV_ROOT_DIR}"

echo "== [CI] config_sim regeneration =="
make -C config config_sim

echo "== [CI] embedded elaboration gate (Verilator lint-only) =="
make -C hw/xilinx sim_elab_embedded

# Verilator runs: smoke + every embedded example. Fast enough for CI.
for t in smoke hello_world echo interrupts xlnx_cdma_examples; do
  echo "== [CI] Verilator TEST=$t =="
  make -C hw/xilinx sim BACKEND=verilator TEST="$t"
done

echo "[CI] ALL PASS"
