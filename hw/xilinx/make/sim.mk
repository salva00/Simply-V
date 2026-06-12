# Description: Simulation targets — dual backend (Verilator + xsim).
# Always invoke via the main Makefile (`make -C hw/xilinx ...`) so that
# config.mk and environment.mk are included.
# See hw/xilinx/sim/README.md and hw/xilinx/sim/sim_manifest.md.

# All sim paths derive from XILINX_ROOT — no extra env vars in settings.sh
XILINX_SIM_ROOT           := ${XILINX_ROOT}/sim
XILINX_SIM_TCL_ROOT       := ${XILINX_SIM_ROOT}/tcl
XILINX_SIM_BUILD_DIR      := ${XILINX_SIM_ROOT}/build
XILINX_SIM_GENERATED_ROOT := ${XILINX_SIM_ROOT}/generated

# Backend dispatch: make sim BACKEND=verilator|xsim TEST=smoke
BACKEND ?= verilator
TEST    ?= smoke

VERILATOR ?= verilator
XVLOG     ?= xvlog
XELAB     ?= xelab
XSIM      ?= xsim

sim:
	${MAKE} sim_${BACKEND}_${TEST}

#########################
# Vendor sim libraries  #
#########################

sim_compile_simlib:
	${XILINX_VIVADO_BATCH} -source ${XILINX_SIM_TCL_ROOT}/compile_simlib.tcl

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

sim_clean:
	rm -rf ${XILINX_SIM_BUILD_DIR}

# PHONIES
.PHONY: sim sim_compile_simlib sim_verilator_smoke sim_xsim_smoke sim_clean
