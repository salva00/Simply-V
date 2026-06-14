# Author: Simply-V (R1 vendor xsim sim — redesign)
# Description: Add the base SoC RTL + the real Xilinx IP sim-models + the COE
#              program preload + the SystemVerilog testbench to the currently
#              open Vivado (sim) project. Assumes a project is open and the
#              Verilog defines have already been applied (see export_xsim_embedded.tcl).
#
# Sourced by export_xsim_embedded.tcl. Sim paths are re-derived from XILINX_ROOT
# (the new repo keeps sim paths out of the Vivado env; only XILINX_ROOT is
# guaranteed). XS_EMB_COE is passed explicitly by the B3 make target.

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
    puts "\[add_sim_sources\] ip_repo_paths += [llength $custom_repos] custom IP repos"
    set_property ip_repo_paths $custom_repos [current_project]
    update_ip_catalog
}

# 3) Real IP sim-models: import the profile IP .xci, but EXCLUDE IPs not in the
#    EMBEDDED+CORE_IBEX cone (the non-selected RISC-V cores and the MicroBlaze-V
#    debug modules in the common list). They are never instantiated here; importing
#    them only forces extra (at-risk) sim-model generation and makes the export scan
#    IPs whose sources don't exist ("Could not find IP source file").
#
#    NOTE: IP_LIST_XCI is already profile-filtered upstream (environment.mk), so with
#    SIMPLYV_PROFILE=embedded the HPC IPs (xlnx_xdma, xlnx_ddr4_mig, xlnx_hbus_*,
#    xlnx_system_cache*, *512*, xlnx_clk_wiz_hpc, xlnx_axi_d64_clock_converter,
#    custom_hls_conv_hbus, custom_cv64a6_ara) are absent from this list to begin with.
#    The patterns below additionally drop them defensively, plus the non-ibex cores
#    and MicroBlaze debug modules that DO live in the common list.
set skip_pat {microblaze cv32e40p cv64a6 picorv32 rv64_dbg \
              xdma ddr4 hbus system_cache 512 clk_wiz_hpc d64_clock hls_conv}
set import_xci {}
foreach xci $::env(IP_LIST_XCI) {
    set drop 0
    foreach s $skip_pat { if {[string match -nocase *$s* $xci]} { set drop 1; break } }
    if {!$drop} { lappend import_xci $xci }
}
puts "\[add_sim_sources\] Importing [llength $import_xci] IPs (embedded/ibex cone)"
import_ip $import_xci
set_property XPM_LIBRARIES XPM_MEMORY [current_project]

# 3b) Preload hello_world into the REAL xlnx_bram_0 via its native COE mechanism.
#     The CPU then fetches the program through the real crossbar. xlnx_bram_1 gets
#     NO preload (data RAM). REDESIGN: target is xlnx_bram_0 (was xlnx_blk_mem_gen_0).
set bram [get_ips -quiet xlnx_bram_0]
if {[llength $bram]} {
    puts "\[add_sim_sources\] Setting xlnx_bram_0 COE = $::env(XS_EMB_COE)"
    set_property -dict [list \
        CONFIG.Load_Init_File {true} \
        CONFIG.Coe_File $::env(XS_EMB_COE) \
        CONFIG.Fill_Remaining_Memory_Locations {true}] $bram
} else {
    puts "\[add_sim_sources\] WARNING: xlnx_bram_0 not found — BRAM not preloaded"
}

# 4) Synth-side top + compile order.
set_property top $::env(XILINX_PROJECT_NAME) [get_filesets sources_1]
update_compile_order -fileset sources_1

# 5) Sim-only top: the native SV testbench, into the simulation fileset.
#    The TB is added in B3 at hw/xilinx/sim/xsim/tb/embedded_tb.sv; this export is
#    only RUN in B3, so the file is expected to exist by then.
add_files -fileset sim_1 -norecurse $sim_xsim_root/tb/embedded_tb.sv
set_property top embedded_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1
