# Description: Make target for simulation
# TODO: The simulation flow is not yet supported, this file is just a placeholder

sim_compile_simlib:
	${XILINX_VIVADO_BATCH} -source ${XILINX_SIM_TCL_ROOT}/compile_simlib.tcl

sim_export_%: ${XILINX_IPS_ROOT}/%/questa/compile.do
${XILINX_IPS_ROOT}/%/questa/compile.do: ${XILINX_SIM_IP_ROOT}
	cd ${XILINX_SIMLIB_PATH}; \
	VIVADO_PROJECT=${XILINX_IPS_ROOT}/$*/build/$*.xpr \
	${XILINX_VIVADO_BATCH} -source ${XILINX_SIM_TCL_ROOT}/export_simulation.tcl

${XILINX_SIM_IP_ROOT}/ips:
	mkdir -p $@


# PHONIES
.PHONY: sim_compile_simlib

# Standalone RTL benches (Verilator)
XILINX_SIM_ROOT      := ${XILINX_ROOT}/sim
XILINX_SIM_BUILD_DIR := ${XILINX_SIM_ROOT}/build
VERILATOR ?= verilator

# Standalone crossbar bench (self-checking, no firmware). XBAR_DW=64 for the 64-bit
# data path; AXI4PC=1 binds the ARM AXI4 protocol checker shipped with Vivado.
# XBAR_ATOMICS enables the atomics_tests in the TB, exercising the
# simplyv_axi_atomics unit the crossbar instantiates on MI0/MI1.
VL_XBAR_DIR := ${XILINX_SIM_BUILD_DIR}/verilator/xbar
XBAR_DW     ?= 32
AXI4PC      ?= 0
XBAR_RTL    := ${XILINX_ROOT}/rtl/simplyv_axi_err_slv.sv ${XILINX_ROOT}/rtl/simplyv_axi_atomics.sv ${XILINX_ROOT}/rtl/simplyv_axi_xbar.sv
XBAR_PC_SRC := $(if $(filter 1,${AXI4PC}),+define+AXI4PC ${XILINX_VIVADO}/data/xilinx_vip/hdl/axi_vip_axi4pc.sv,)
sim_verilator_xbar:
	mkdir -p ${VL_XBAR_DIR}
	${VERILATOR} --binary --timing --assert -j 0 -Wno-fatal -Mdir ${VL_XBAR_DIR} \
		--top-module xbar_tb +define+XBAR_DW=${XBAR_DW} +define+XBAR_ATOMICS ${XBAR_PC_SRC} \
		${XBAR_RTL} ${XILINX_SIM_ROOT}/verilator/tb/xbar_tb.sv
	${VL_XBAR_DIR}/Vxbar_tb | tee ${VL_XBAR_DIR}/run.log
	grep -q '\[XBAR\] PASS' ${VL_XBAR_DIR}/run.log && ! grep -q FAIL ${VL_XBAR_DIR}/run.log
.PHONY: sim_verilator_xbar
