# Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
# Description: Elaborate the in-tree crossbar RTL out of context, both the
#              standalone units and the generated wrappers on their CUSTOM
#              branch. No project, no IP: a parse/elaboration gate only. The
#              Xilinx IP branch of the wrappers is elaborated by
#              simplyv_elab_check.tcl.
set rtl      $::env(XILINX_ROOT)/rtl
set wrappers $rtl/wrappers

read_verilog -sv [list $rtl/simplyv_pkg.sv $rtl/simplyv_axi_err_slv.sv $rtl/simplyv_axi_atomics.sv \
    $rtl/simplyv_axi_xbar.sv $rtl/simplyv_axilite_xbar.sv \
    $wrappers/mbus_crossbar_wrapper.sv $wrappers/pbus_crossbar_wrapper.sv]
set_property include_dirs $rtl/headers [current_fileset]

foreach top {simplyv_axi_err_slv simplyv_axi_atomics simplyv_axi_xbar simplyv_axilite_xbar \
             mbus_crossbar_wrapper pbus_crossbar_wrapper} {
    synth_design -top $top -part $::env(XILINX_PART_NUMBER) -mode out_of_context -rtl -verilog_define XBAR_IMPL=XBAR_CUSTOM \
        -verilog_define MBUS_DATA_WIDTH=32 -verilog_define MBUS_ADDR_WIDTH=32 -verilog_define MBUS_ID_WIDTH=5 \
        -verilog_define PBUS_ID_WIDTH=5 -verilog_define HBUS_ID_WIDTH=0 -verilog_define MBUS_NUM_SI=5 -verilog_define MBUS_NUM_MI=6 \
        -verilog_define PBUS_NUM_SI=1 -verilog_define PBUS_NUM_MI=5 -verilog_define HBUS_NUM_SI=0 -verilog_define HBUS_NUM_MI=0 \
        -verilog_define CORE_SELECTOR=CORE_IBEX -verilog_define MAIN_CLOCK_FREQ_MHZ=20 -verilog_define EMBEDDED=1
    close_design
}
