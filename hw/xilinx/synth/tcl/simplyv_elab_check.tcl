# Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
# Description: RTL elaboration of the full simplyv top with the generated Xilinx IPs
#              (project flow of build_bitstream.tcl, up to synth_design -rtl).
#              Run from an empty build directory.

create_project -in_memory -part $::env(XILINX_PART_NUMBER)
catch { set_property board_part $::env(XILINX_BOARD_PART) [current_project] }
source $::env(XILINX_SYNTH_TCL_ROOT)/suppress_messages.tcl
source $::env(XILINX_SYNTH_TCL_ROOT)/verilog_defines.tcl
source $::env(XILINX_SYNTH_TCL_ROOT)/add_xilinx_sources.tcl
read_ip $::env(IP_LIST_XCI)
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
set_property top $::env(XILINX_PROJECT_NAME) [current_fileset]
update_compile_order -fileset sources_1

synth_design -rtl -top $::env(XILINX_PROJECT_NAME) -part $::env(XILINX_PART_NUMBER)
