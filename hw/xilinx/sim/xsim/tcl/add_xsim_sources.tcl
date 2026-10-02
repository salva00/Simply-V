# Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
# Description: Add the base SoC RTL + the real Xilinx IP sim-models + the COE
#              program preload + the SystemVerilog testbench to the currently
#              open Vivado (sim) project. Assumes a project is open and the
#              Verilog defines have already been applied (see export_xsim_embedded.tcl).
#
# Sourced by export_xsim_embedded.tcl. Sim paths are derived from XILINX_ROOT.
# XS_EMB_COE is passed by the sim_export_embedded make target.

set sim_xsim_root $::env(XILINX_ROOT)/sim/xsim

# 1) Base SoC RTL — reuse the synth source list verbatim (packages / headers /
#    .svinc / .sv, ending with simplyv.sv), added to sources_1 (current fileset).
source $::env(XILINX_SYNTH_TCL_ROOT)/add_xilinx_sources.tcl

# 2) Custom (user-packaged) IPs — register their IP repos so the fresh project can
#    resolve/regenerate them (each custom_* IP keeps its component.xml under
#    build/<ip>_prj.srcs/sources_1/imports). Without this the custom cores import
#    "locked" -> "could not find IP source file". Must precede import_ip.
set custom_repos [glob -nocomplain \
    $::env(XILINX_IPS_ROOT)/*/custom_*/build/*_prj.srcs/sources_1/imports]
if {[llength $custom_repos]} {
    puts "\[add_xsim_sources\] ip_repo_paths += [llength $custom_repos] custom IP repos"
    set_property ip_repo_paths $custom_repos [current_project]
    update_ip_catalog
}

# 3) Real IP sim-models: import the profile IP .xci, excluding the IPs outside the
#    EMBEDDED+CORE_IBEX cone (other cores, MicroBlaze-V debug, HPC-only IPs).
set skip_pat {microblaze cv32e40p cv64a6 picorv32 rv64_dbg \
              xdma ddr4 hbus system_cache 512 clk_wiz_hpc d64_clock hls_conv}
set import_xci {}
foreach xci $::env(IP_LIST_XCI) {
    set drop 0
    foreach s $skip_pat { if {[string match -nocase *$s* $xci]} { set drop 1; break } }
    if {!$drop} { lappend import_xci $xci }
}
puts "\[add_xsim_sources\] Importing [llength $import_xci] IPs (embedded/ibex cone)"
import_ip $import_xci
set_property XPM_LIBRARIES XPM_MEMORY [current_project]

# 3b) Preload the program into xlnx_bram_0 via its native COE mechanism.
#     xlnx_bram_1 (data RAM) gets no preload.
set bram [get_ips -quiet xlnx_bram_0]
if {[llength $bram]} {
    puts "\[add_xsim_sources\] Setting xlnx_bram_0 COE = $::env(XS_EMB_COE)"
    set_property -dict [list \
        CONFIG.Load_Init_File {true} \
        CONFIG.Coe_File $::env(XS_EMB_COE) \
        CONFIG.Fill_Remaining_Memory_Locations {true}] $bram
} else {
    puts "\[add_xsim_sources\] WARNING: xlnx_bram_0 not found — BRAM not preloaded"
}

# 4) Synth-side top + compile order.
set_property top $::env(XILINX_PROJECT_NAME) [get_filesets sources_1]
update_compile_order -fileset sources_1

# 5) Sim-only top: the native SV testbench, into the simulation fileset.
add_files -fileset sim_1 -norecurse $sim_xsim_root/tb/embedded_tb.sv
set_property top embedded_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1
