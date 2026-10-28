# Description: Simulation targets — dual backend (Verilator + xsim).
# Always invoke via the main Makefile (`make -C hw/xilinx ...`) so that
# config.mk and environment.mk are included.

# All sim paths derive from XILINX_ROOT — no extra env vars in settings.sh
XILINX_SIM_ROOT           := ${XILINX_ROOT}/sim
XILINX_SIM_TCL_ROOT       := ${XILINX_SIM_ROOT}/tcl
XILINX_SIM_BUILD_DIR      := ${XILINX_SIM_ROOT}/build
XILINX_SIM_GENERATED_ROOT := ${XILINX_SIM_ROOT}/generated

# Vendor sim libraries, compiled by sim_compile_simlib (Questa).
# XILINX_VIVADO_ENV uses recursive '=' so this ?= is expanded at rule invocation time,
# even though environment.mk is included before sim.mk.
XILINX_SIMLIB_PATH ?= ${XILINX_SIM_BUILD_DIR}/simlib

# Backend dispatch: make sim BACKEND=verilator|xsim|questa TEST=embedded
BACKEND ?= verilator
TEST    ?= embedded
ifeq (${BACKEND},questa)
$(error BACKEND=questa is not available yet)
endif

VERILATOR ?= verilator
XVLOG     ?= xvlog
XELAB     ?= xelab
XSIM      ?= xsim

sim:
	${MAKE} sim_${BACKEND}_${TEST}

#########################
# Vendor sim libraries  #
#########################

# Questa
sim_compile_simlib:
	${XILINX_VIVADO_BATCH} -source ${XILINX_SIM_TCL_ROOT}/compile_simlib.tcl

sim_export_%: ${XILINX_IPS_ROOT}/%/questa/compile.do
${XILINX_IPS_ROOT}/%/questa/compile.do: ${XILINX_SIM_IP_ROOT}
	cd ${XILINX_SIMLIB_PATH}; \
	VIVADO_PROJECT=${XILINX_IPS_ROOT}/$*/build/$*.xpr \
	${XILINX_VIVADO_BATCH} -source ${XILINX_SIM_TCL_ROOT}/export_simulation.tcl

${XILINX_SIM_IP_ROOT}/ips:
	mkdir -p $@

#########################
# Embedded SoC — xsim   #
#########################

# COE file for preloading xlnx_bram_0 with the ${TEST} firmware.
# The .bin (flat little-endian) is produced by the sw build; bin2coe.py
# converts it to a 32-bit hex COE for the Xilinx BRAM sim-model.
XS_EMB_COE := ${XILINX_SIM_BUILD_DIR}/hello_world.coe
VL_EMB_BIN := ${SIMPLYV_ROOT_DIR}/sw/SoC/examples/hello_world/bin/hello_world.bin

sim_coe_embedded: ${XS_EMB_COE}
${XS_EMB_COE}: ${VL_EMB_BIN}
	mkdir -p ${XILINX_SIM_BUILD_DIR}
	python3 ${XILINX_SIM_ROOT}/stimuli/bin2coe.py ${VL_EMB_BIN} ${XS_EMB_COE} --word-bytes 4

.PHONY: sim_coe_embedded

# Real simplyv (embedded, ibex) on Vivado xsim with the real Xilinx IP sim-models:
# assemble a sim project, export standalone xsim scripts, run them and check
# uart_tx_o against the shared golden. Needs Vivado 2024.2. Invoke via the main
# Makefile so environment.mk (XILINX_VIVADO_BATCH, IP_LIST_XCI) is included.

XS_EMB_EXPORT_TCL := ${XILINX_SIM_ROOT}/xsim/tcl/export_xsim_embedded.tcl
# launch_simulation -scripts_only writes the standalone scripts under the
# project's .sim dir: <proj>.sim/<simset>/behav/xsim/{compile,elaborate,simulate}.sh
XS_EMB_SIM_DIR    := ${XILINX_SIM_BUILD_DIR}/xsim_proj/xsim_embedded.sim/sim_1/behav/xsim
XS_EMB_SNAPSHOT   := embedded_tb_behav
XS_EMB_GOLDEN     := ${XILINX_SIM_ROOT}/stimuli/golden/hello_world.uart.golden
XS_EMB_LOG        := ${XILINX_SIM_BUILD_DIR}/xsim_embedded.log

# Assemble the sim project (real IP sim-models + base RTL + COE + TB) and export
# the standalone xsim compile/elaborate/simulate scripts. XS_EMB_COE is read by
# add_xsim_sources.tcl to preload xlnx_bram_0.
sim_export_embedded: ${XS_EMB_COE}
	XS_EMB_COE=${XS_EMB_COE} ${XILINX_VIVADO_BATCH} -source ${XS_EMB_EXPORT_TCL}

# Run the exported scripts standalone (--log instead of a pipe). The TB reads the
# golden via +GOLDEN and prints [EMB] PASS/FAIL.
sim_xsim_embedded: sim_export_embedded
	cd ${XS_EMB_SIM_DIR} && bash compile.sh
	cd ${XS_EMB_SIM_DIR} && bash elaborate.sh
	cd ${XS_EMB_SIM_DIR} && ${XSIM} ${XS_EMB_SNAPSHOT} \
		-testplusarg GOLDEN=${XS_EMB_GOLDEN} -runall --log ${XS_EMB_LOG}
	cat ${XS_EMB_LOG}
	grep -q '\[EMB\] PASS' ${XS_EMB_LOG} && ! grep -q '\[EMB\] FAIL' ${XS_EMB_LOG}

.PHONY: sim_export_embedded sim_xsim_embedded

##############################
# Embedded SoC — Verilator   #
##############################

VL_EMB_DIR      := ${XILINX_SIM_BUILD_DIR}/verilator/embedded
VL_EMB_FLIST    := ${XILINX_SIM_GENERATED_ROOT}/verilator_embedded.f

# UART bit period (cycles of the uartlite AXI clock), passed to both the SV sim
# model (+define+) and the C++ TB (-CFLAGS -D).
SIM_UART_CYCLES_PER_BIT ?= 16
VL_EMB_TB     := ${XILINX_SIM_ROOT}/verilator/tb/embedded_tb.cpp
# Same defines as synth/tcl/verilog_defines.tcl; the Verilator cone has no Xilinx IP.
# ASSERTS_OFF disables the SVA in the unit-vendored cells.
VL_EMB_DEFINES := $(if $(filter hpc,${SIMPLYV_PROFILE}),HPC,EMBEDDED)=1 \
	$(foreach v,MBUS_DATA_WIDTH MBUS_ADDR_WIDTH MBUS_ID_WIDTH MBUS_NUM_SI MBUS_NUM_MI \
	            PBUS_NUM_MI PBUS_NUM_SI HBUS_NUM_MI HBUS_NUM_SI HBUS_ID_WIDTH CORE_SELECTOR MAIN_CLOCK_FREQ_MHZ,$(v)=${$(v)}) \
	PBUS_ID_WIDTH=${MBUS_ID_WIDTH} $(foreach d,${RANGE_CLOCK_DOMAINS},$(d)=$(d)) \
	XBAR_IMPL=XBAR_CUSTOM ASSERTS_OFF SIM_UART_CYCLES_PER_BIT=${SIM_UART_CYCLES_PER_BIT}
VL_EMB_HEX    := ${SIMPLYV_ROOT_DIR}/sw/SoC/examples/hello_world/bin/hello_world.hex
VL_EMB_GOLDEN := ${XILINX_SIM_ROOT}/stimuli/golden/hello_world.uart.golden

# Full build + run: hello_world boots from BRAM_0, UART output is compared to
# the golden by the C++ TB ([EMB] PASS / exit 0 on match, [EMB] FAIL / exit 1).
sim_verilator_embedded:
	mkdir -p ${VL_EMB_DIR}
	${VERILATOR} -cc --exe --build -j 0 -sv -Wno-fatal --no-timing \
		--top-module simplyv \
		$(addprefix +define+,${VL_EMB_DEFINES}) \
		-Mdir ${VL_EMB_DIR} \
		-f ${VL_EMB_FLIST} \
		${VL_EMB_TB} \
		-CFLAGS "-I${XILINX_SIM_ROOT}/verilator -DSIM_UART_CYCLES_PER_BIT=${SIM_UART_CYCLES_PER_BIT}"
	${VL_EMB_DIR}/Vsimplyv +BRAM0_INIT=${VL_EMB_HEX} ${VL_EMB_GOLDEN}

.PHONY: sim_verilator_embedded

# Standalone crossbar bench (self-checking, no firmware). XBAR_DW=64 for the 64-bit
# data path; AXI4PC=1 binds the ARM AXI4 protocol checker shipped with Vivado.
VL_XBAR_DIR := ${XILINX_SIM_BUILD_DIR}/verilator/xbar
XBAR_DW     ?= 32
AXI4PC      ?= 0
XBAR_RTL    := ${XILINX_ROOT}/rtl/simplyv_axi_err_slv.sv ${XILINX_ROOT}/rtl/simplyv_axi_xbar.sv
XBAR_PC_SRC := $(if $(filter 1,${AXI4PC}),+define+AXI4PC ${XILINX_VIVADO}/data/xilinx_vip/hdl/axi_vip_axi4pc.sv,)
sim_verilator_xbar:
	mkdir -p ${VL_XBAR_DIR}
	${VERILATOR} --binary --timing --assert -j 0 -Wno-fatal -Mdir ${VL_XBAR_DIR} \
		--top-module xbar_tb +define+XBAR_DW=${XBAR_DW} ${XBAR_PC_SRC} \
		${XBAR_RTL} ${XILINX_SIM_ROOT}/verilator/tb/xbar_tb.sv
	${VL_XBAR_DIR}/Vxbar_tb | tee ${VL_XBAR_DIR}/run.log
	grep -q '\[XBAR\] PASS' ${VL_XBAR_DIR}/run.log && ! grep -q FAIL ${VL_XBAR_DIR}/run.log
.PHONY: sim_verilator_xbar

# Standalone AXI-Lite crossbar bench (self-checking, no firmware).
# AXI4PC=1 binds the ARM AXI4 protocol checker shipped with Vivado.
VL_LITE_XBAR_DIR := ${XILINX_SIM_BUILD_DIR}/verilator/axilite_xbar
LITE_XBAR_RTL    := ${XILINX_ROOT}/rtl/simplyv_axilite_xbar.sv
sim_verilator_axilite_xbar:
	mkdir -p ${VL_LITE_XBAR_DIR}
	${VERILATOR} --binary --timing --assert -j 0 -Wno-fatal -Mdir ${VL_LITE_XBAR_DIR} \
		--top-module axilite_xbar_tb ${XBAR_PC_SRC} \
		${LITE_XBAR_RTL} ${XILINX_SIM_ROOT}/verilator/tb/axilite_xbar_tb.sv
	${VL_LITE_XBAR_DIR}/Vaxilite_xbar_tb | tee ${VL_LITE_XBAR_DIR}/run.log
	grep -q '\[AXILITE_XBAR\] PASS' ${VL_LITE_XBAR_DIR}/run.log && ! grep -q FAIL ${VL_LITE_XBAR_DIR}/run.log
.PHONY: sim_verilator_axilite_xbar

sim_clean:
	rm -rf ${XILINX_SIM_BUILD_DIR}

# PHONIES
.PHONY: sim sim_compile_simlib sim_clean
