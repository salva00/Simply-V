# Description: Simulation targets — dual backend (Verilator + xsim).
# Always invoke via the main Makefile (`make -C hw/xilinx ...`) so that
# config.mk and environment.mk are included.
# See hw/xilinx/sim/README.md and hw/xilinx/sim/sim_manifest.md.

# All sim paths derive from XILINX_ROOT — no extra env vars in settings.sh
XILINX_SIM_ROOT           := ${XILINX_ROOT}/sim
XILINX_SIM_TCL_ROOT       := ${XILINX_SIM_ROOT}/tcl
XILINX_SIM_BUILD_DIR      := ${XILINX_SIM_ROOT}/build
XILINX_SIM_GENERATED_ROOT := ${XILINX_SIM_ROOT}/generated

# Vendor sim libraries compiled by sim_compile_simlib (consumed by compile_simlib.tcl / xsim).
# XILINX_VIVADO_ENV uses recursive '=' so this ?= is expanded at rule invocation time,
# even though environment.mk is included before sim.mk.
XILINX_SIMLIB_PATH ?= ${XILINX_SIM_BUILD_DIR}/simlib

# Backend dispatch: make sim BACKEND=verilator|xsim TEST=smoke
BACKEND ?= verilator
TEST    ?= smoke

# Per-TEST program + golden. Each example builds to
# sw/SoC/examples/<TEST>/bin/<TEST>.{hex,bin}; its golden lives in stimuli/golden/.
# These derive every embedded sim path from ${TEST} (default hello_world via the
# embedded dispatch target below, fully backward compatible).
TEST_PROG_DIR := ${SIMPLYV_ROOT_DIR}/sw/SoC/examples/${TEST}
TEST_HEX      := ${TEST_PROG_DIR}/bin/${TEST}.hex
TEST_BIN      := ${TEST_PROG_DIR}/bin/${TEST}.bin
TEST_GOLDEN   := ${XILINX_SIM_ROOT}/stimuli/golden/${TEST}.uart.golden
TEST_COE      := ${XILINX_SIM_BUILD_DIR}/${TEST}.coe
# Optional per-TEST UART RX stimulus (e.g. echo). Injected on uart_rx_i once the
# harness sees the prompt. Empty for tests without input (e.g. hello_world).
TEST_STIM     := ${XILINX_SIM_ROOT}/stimuli/${TEST}.in
TEST_STIM_ARG := $(if $(wildcard ${TEST_STIM}),+STIMULUS=${TEST_STIM},)

# Build the example program: the default `all` target produces only .bin/.dump,
# so the .hex (byte-granular Verilog preload) is requested explicitly.
# ponytail: interrupts uses real-time periods (~6s sim-time) -> impractical;
# build it sim-only with -DSIM_FAST (1000x shorter periods, same interrupt counts).
# Force a clean first so a stale non-SIM_FAST bin (which would loop forever) is
# never reused. Only the SIM_FAST #ifdef branch differs; the FPGA build is unchanged.
TEST_EXTRA_MACROS := $(if $(filter interrupts,${TEST}),-DSIM_FAST,)
${TEST_HEX} ${TEST_BIN}:
ifneq (${TEST_EXTRA_MACROS},)
	${MAKE} -C ${TEST_PROG_DIR} clean
endif
	${MAKE} -C ${TEST_PROG_DIR} bin/${TEST}.hex bin/${TEST}.bin PROGRAM_NAME=${TEST} EXTRA_MACROS=${TEST_EXTRA_MACROS}

VERILATOR ?= verilator
XVLOG     ?= xvlog
XELAB     ?= xelab
XSIM      ?= xsim

sim:
	${MAKE} sim_${BACKEND}_${TEST}

# Embedded-cone dispatch aliases: the embedded examples all share one build flow
# (sim_${BACKEND}_embedded), parametrized by ${TEST}. Map sim_${BACKEND}_<TEST>
# onto it for every embedded example so `make sim BACKEND=.. TEST=<example>` works.
# `smoke` keeps its own dedicated targets (sim_${BACKEND}_smoke) below.
EMBEDDED_TESTS := hello_world echo interrupts cdma xlnx_cdma_examples

define EMBEDDED_DISPATCH
sim_verilator_$(1): sim_verilator_embedded
sim_xsim_$(1):      sim_xsim_embedded
.PHONY: sim_verilator_$(1) sim_xsim_$(1)
endef
$(foreach t,${EMBEDDED_TESTS},$(eval $(call EMBEDDED_DISPATCH,$(t))))

#########################
# Vendor sim libraries  #
#########################

sim_compile_simlib:
	${XILINX_VIVADO_BATCH} -source ${XILINX_SIM_TCL_ROOT}/compile_simlib.tcl

################################
# Embedded SoC — xsim (R1)    #
################################

# COE file for preloading xlnx_bram_0 with the hello_world firmware.
# The .bin (flat little-endian) is produced by the sw build; bin2coe.py
# converts it to a 32-bit hex COE for the Xilinx BRAM sim-model.
XS_EMB_COE := ${TEST_COE}
VL_EMB_BIN := ${TEST_BIN}

sim_coe_embedded: ${TEST_COE}
${TEST_COE}: ${TEST_BIN}
	mkdir -p ${XILINX_SIM_BUILD_DIR}
	python3 ${XILINX_SIM_ROOT}/stimuli/bin2coe.py ${TEST_BIN} ${TEST_COE} --word-bytes 4

.PHONY: sim_coe_embedded

###############################################################################
# Embedded SoC — real simplyv (embedded, ibex) on Vivado xsim with real       #
# Xilinx IP sim-models. Assemble a sim project + export standalone xsim        #
# scripts (B2 tcl), then run them and check uart_tx_o against the shared       #
# golden. Needs Vivado 2024.2. Invoke via the main Makefile so environment.mk  #
# (XILINX_VIVADO_BATCH, IP_LIST_XCI) is included.                              #
###############################################################################

XS_EMB_EXPORT_TCL := ${XILINX_SIM_ROOT}/xsim/tcl/export_xsim_embedded.tcl
# launch_simulation -scripts_only writes the standalone scripts under the
# project's .sim dir: <proj>.sim/<simset>/behav/xsim/{compile,elaborate,simulate}.sh
XS_EMB_SIM_DIR    := ${XILINX_SIM_BUILD_DIR}/xsim_proj/xsim_embedded.sim/sim_1/behav/xsim
XS_EMB_SNAPSHOT   := embedded_tb_behav
XS_EMB_GOLDEN     := ${TEST_GOLDEN}
XS_EMB_LOG        := ${XILINX_SIM_BUILD_DIR}/xsim_embedded.log

# Assemble the sim project (real IP sim-models + base RTL + COE + TB) and export
# the standalone xsim compile/elaborate/simulate scripts. XS_EMB_COE is read by
# add_sim_sources.tcl to preload xlnx_bram_0.
sim_export_embedded: ${XS_EMB_COE}
	XS_EMB_COE=${XS_EMB_COE} ${XILINX_VIVADO_BATCH} -source ${XS_EMB_EXPORT_TCL}

# Run the exported scripts standalone (--log instead of a pipe). The TB reads the
# golden via +GOLDEN and prints [EMB] PASS/FAIL. No `env -u XILINX_VIVADO`: the
# make var is XILINX_VIVADO_RUN now (R0 root-fix), so the real XILINX_VIVADO env
# var (Vivado install path) reaches xsim intact.
sim_xsim_embedded: sim_export_embedded
	cd ${XS_EMB_SIM_DIR} && bash compile.sh
	cd ${XS_EMB_SIM_DIR} && bash elaborate.sh
	cd ${XS_EMB_SIM_DIR} && ${XSIM} ${XS_EMB_SNAPSHOT} \
		-testplusarg GOLDEN=${XS_EMB_GOLDEN} \
		$(if $(wildcard ${TEST_STIM}),-testplusarg STIMULUS=${TEST_STIM},) \
		-runall --log ${XS_EMB_LOG}
	cat ${XS_EMB_LOG}
	grep -q '\[EMB\] PASS' ${XS_EMB_LOG} && ! grep -q '\[EMB\] FAIL' ${XS_EMB_LOG}

.PHONY: sim_export_embedded sim_xsim_embedded

####################
# Smoke: Verilator #
####################

VL_SMOKE_DIR := ${XILINX_SIM_BUILD_DIR}/verilator/smoke

sim_verilator_smoke:
	mkdir -p ${VL_SMOKE_DIR}
	${VERILATOR} -cc --exe --build -j 0 \
		-Wall -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME \
		--top-module smoke_dut \
		-Mdir ${VL_SMOKE_DIR} \
		${XILINX_SIM_ROOT}/smoke/rtl/smoke_dut.sv \
		${XILINX_SIM_ROOT}/verilator/tb/smoke_tb.cpp
	${VL_SMOKE_DIR}/Vsmoke_dut

###############
# Smoke: xsim #
###############

XS_SMOKE_DIR := ${XILINX_SIM_BUILD_DIR}/xsim/smoke

# No `env -u XILINX_VIVADO` needed: the make var is XILINX_VIVADO_RUN now,
# so the real XILINX_VIVADO env var (Vivado install path) reaches xsim intact.
sim_xsim_smoke:
	mkdir -p ${XS_SMOKE_DIR}
	cd ${XS_SMOKE_DIR} && ${XVLOG} -sv \
		${XILINX_SIM_ROOT}/smoke/rtl/smoke_dut.sv \
		${XILINX_SIM_ROOT}/xsim/tb/smoke_tb.sv
	cd ${XS_SMOKE_DIR} && ${XELAB} smoke_tb -s smoke_snap -timescale 1ns/1ps
	cd ${XS_SMOKE_DIR} && ${XSIM} smoke_snap -runall --log ${XS_SMOKE_DIR}/smoke.log
	cat ${XS_SMOKE_DIR}/smoke.log
	grep -q '\[SMOKE\] PASS' ${XS_SMOKE_DIR}/smoke.log && ! grep -q '\[SMOKE\] FAIL' ${XS_SMOKE_DIR}/smoke.log

####################################
# Embedded SoC — Verilator (R1)   #
####################################

VL_EMB_DIR      := ${XILINX_SIM_BUILD_DIR}/verilator/embedded
VL_EMB_FLIST    := ${XILINX_SIM_GENERATED_ROOT}/verilator_embedded.f

# Elaboration-only gate: catches port drift between shims and RTL
sim_elab_embedded:
	${VERILATOR} --lint-only -sv -Wno-fatal --no-timing --top-module simplyv \
		-f ${VL_EMB_FLIST}

.PHONY: sim_elab_embedded

# UART bit period (cycles of the uartlite AXI clock). SINGLE SOURCE OF TRUTH:
# passed to the SV shim (+define+) and to the C++ TB (-CFLAGS -D) so they can
# never drift. Both fall back to 16 if unset.
SIM_UART_CYCLES_PER_BIT ?= 16
VL_EMB_TB     := ${XILINX_SIM_ROOT}/verilator/tb/embedded_tb.cpp
VL_EMB_HEX    := ${TEST_HEX}
VL_EMB_GOLDEN := ${TEST_GOLDEN}

# Full build + run: the ${TEST} program boots from BRAM_0, UART output is compared
# to the golden by the C++ TB ([EMB] PASS / exit 0 on match, [EMB] FAIL / exit 1).
# ${TEST_HEX} is a prerequisite so the example program is built on demand.
sim_verilator_embedded: ${TEST_HEX}
	mkdir -p ${VL_EMB_DIR}
	${VERILATOR} -cc --exe --build -j 0 -sv -Wno-fatal --no-timing \
		--top-module simplyv \
		+define+SIM_UART_CYCLES_PER_BIT=${SIM_UART_CYCLES_PER_BIT} \
		-Mdir ${VL_EMB_DIR} \
		-f ${VL_EMB_FLIST} \
		${VL_EMB_TB} \
		-CFLAGS "-I${XILINX_SIM_ROOT}/verilator -DSIM_UART_CYCLES_PER_BIT=${SIM_UART_CYCLES_PER_BIT}"
	${VL_EMB_DIR}/Vsimplyv +BRAM0_INIT=${VL_EMB_HEX} ${TEST_STIM_ARG} ${VL_EMB_GOLDEN}

.PHONY: sim_verilator_embedded

sim_clean:
	rm -rf ${XILINX_SIM_BUILD_DIR}

# PHONIES
.PHONY: sim sim_compile_simlib sim_verilator_smoke sim_xsim_smoke sim_clean \
	sim_export_embedded sim_xsim_embedded
