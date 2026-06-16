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

echo "== [CI] config_sim regeneration =="
make -C config config_sim

echo "== [CI] embedded elaboration gate (Verilator lint-only) =="
make -C hw/xilinx sim_elab_embedded

# Verilator runs: smoke + every embedded example on the default core (ibex).
# Fast enough for CI.
for t in smoke hello_world echo interrupts xlnx_cdma_examples; do
  echo "== [CI] Verilator TEST=$t =="
  make -C hw/xilinx sim BACKEND=verilator TEST="$t"
done

# Per-core runs (validated coverage only). The 32-bit non-default cores assert
# hello_world (as in R2b-1); the 64-bit cores assert the full embedded suite
# (hello_world + echo/interrupts/cdma), which R2b-2 validated. With the lib-XLEN
# hygiene fix in sim.mk (libs rebuilt to each run's flags) the order is safe
# regardless; we still group rv32 before rv64. smoke is core-agnostic (run once above).
# Per-core test list. cv64a6_ara's CDMA run is the slowest (~25-30 min CPU); no
# per-command timeout is imposed, so it can't be false-failed.
for c in cv32e40p picorv32 cv64a6 cv64a6_ara; do
  case "$c" in
    cv64a6|cv64a6_ara) tests="hello_world echo interrupts xlnx_cdma_examples" ;;
    *)                 tests="hello_world" ;;   # rv32 non-default cores: hello_world (R2b-1 scope)
  esac
  for t in $tests; do
    echo "== [CI] Verilator CORE=$c TEST=$t =="
    make -C hw/xilinx sim BACKEND=verilator CORE="$c" TEST="$t"
  done
done

echo "[CI] ALL PASS"
