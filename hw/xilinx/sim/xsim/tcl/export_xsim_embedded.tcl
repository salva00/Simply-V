# Author: Simply-V (R1 vendor xsim sim — redesign)
# Description: Create a throwaway xsim simulation project for the EMBEDDED simplyv
#              SoC, assemble base RTL + real Xilinx IP sim-models + COE preload + SV
#              TB, apply the fixes needed for flat xsim elaboration of the project's
#              custom (user-packaged) IPs, and export standalone xsim scripts.
#              Does NOT launch xsim (that is the B3 make target).
#
# Required env vars (all provided by settings.sh / XILINX_VIVADO_ENV):
#   XILINX_ROOT, XILINX_IPS_ROOT, XILINX_SYNTH_TCL_ROOT, XILINX_PROJECT_NAME,
#   XILINX_PART_NUMBER, XILINX_BOARD_PART (optional), IP_LIST_XCI, SIMPLYV_PROFILE
# Additionally passed explicitly by the B3 make target:
#   XS_EMB_COE  — path to the hello_world COE preloaded into xlnx_bram_0
#
# Why the extra steps (vs a plain export): the project's custom_* IPs are open RTL
# packaged as IP, each vendoring its OWN full copy of shared pulp/opentitan deps and
# naming its inner module `custom_top_wrapper`. Compiled flat for simulation they
# collide; the Xilinx catalog IPs also ship VHDL sim-models whose narrow AXI-Lite
# ports clash with the 32-bit bus under xsim's strict VHDL<->Verilog binding. The
# mitigations below mirror what the Verilator flow does. Every step here was a
# paid-for bug fix in Phase 1B — do not drop any of them.

# ---- helper: rename a whole-word token in a file (Tcl, no shell escaping) ----
proc rename_token {file from to} {
    if {![file exists $file]} { return }
    set fp [open $file r]; set data [read $fp]; close $fp
    regsub -all "\\m${from}\\M" $data $to data
    set fp [open $file w]; puts -nonewline $fp $data; close $fp
}

# ---- derive sim paths from XILINX_ROOT (the new repo keeps sim paths out of the
#      Vivado env; only XILINX_ROOT is guaranteed). Mirrors sim.mk. ----
set xilinx_root    $::env(XILINX_ROOT)
set sim_root       $xilinx_root/sim
set sim_tcl_root   $sim_root/tcl
set sim_xsim_root  $sim_root/xsim
set sim_build_dir  $sim_root/build

set proj_dir $sim_build_dir/xsim_proj
file delete -force $proj_dir
file mkdir $proj_dir

# Throwaway project under the gitignored sim build dir.
create_project -force xsim_embedded $proj_dir -part $::env(XILINX_PART_NUMBER)
catch { set_property board_part $::env(XILINX_BOARD_PART) [current_project] }

# Prefer Verilog sim-models so VHDL<->Verilog port-width strictness does not fail
# elaboration (Verilog binding truncates a 32-bit actual onto a narrow IP port,
# like synthesis; glbl handles gate-level GSR init).
set_property simulator_language Verilog [current_project]
set_property target_language    Verilog [current_project]

# Quieten the usual IP/info noise.
catch { source $::env(XILINX_SYNTH_TCL_ROOT)/suppress_messages.tcl }

# Verilog defines (EMBEDDED + bus widths + core + clock domains). verilog_defines.tcl
# sets them on [current_fileset] (= sources_1) and leaves the list in $verilog_defines.
source $::env(XILINX_SYNTH_TCL_ROOT)/verilog_defines.tcl
# VERILATOR + SYNTHESIS strip the simulator-incompatible sim-only blocks in the
# custom units' vendored pulp/opentitan RTL: SVA like `default disable iff` (under
# `ifndef SYNTHESIS`/`ifndef VERILATOR`) and the ibex prefetch scramble DPI export
# (`ifndef SYNTHESIS` in ibex_if_stage.sv, whose generate-scoped name makes xsim
# emit invalid C++). SYNTHESIS yields the real synthesizable RTL (the on-FPGA
# behavior). Base RTL and the Xilinx IP sim-models reference neither macro, so this
# only affects the custom open-RTL blocks.
lappend verilog_defines VERILATOR SYNTHESIS
set_property verilog_define $verilog_defines [get_filesets sources_1]
set_property verilog_define $verilog_defines [get_filesets sim_1]

# Base RTL + real IP sim-models + COE + TB.
source $sim_tcl_root/add_sim_sources.tcl

# Generate the IP simulation products (incl. the bram .mif from the new COE).
puts "\[export\] generate_target simulation for: [get_ips]"
generate_target simulation [get_ips]

set ipgen $proj_dir/xsim_embedded.gen/sources_1/ip
# Custom IP cone (UNCHANGED from 1B): only the embedded/ibex custom cores.
set custom_ips {custom_ibex custom_clint custom_rv_plic custom_axi_from_mem custom_rv32_dbg_bscane}

# ---- per-IP libraries for the custom IPs (must precede script generation) ----
# Each custom IP vendors its own copy of shared packages (cf_math_pkg, axi_pkg,
# ...). In one library they overwrite each other and Vivado drops the dependent
# wrapper units. Give each custom IP its own library so the copies do not collide;
# xelab resolves the (now-unique) wrapper instances across the generated -L libs.
foreach ip $custom_ips {
    set ipo [get_ips -quiet $ip]
    if {![llength $ipo]} { continue }
    set hdl {}
    foreach f [get_files -quiet -all -of_objects $ipo] {
        if {[regexp {\.(sv|v|vhd|vhdl)$} $f]} { lappend hdl $f }
    }
    if {[llength $hdl]} {
        set_property library ${ip}_lib $hdl
        puts "\[export\] $ip -> library ${ip}_lib ([llength $hdl] files)"
    }
}

# Generate standalone xsim scripts (compile/elaborate/simulate) WITHOUT launching
# xsim inside Vivado, so they can be run standalone later (B3).
launch_simulation -scripts_only -simset sim_1

# ---- post-generation source fixes (LAST, so script generation cannot undo them;
#      the .prj references these files in place, read at compile time) ----
foreach ip $custom_ips {
    set d $ipgen/$ip
    if {![file isdirectory $d]} { continue }
    # (a) Give the inner wrapper a unique per-IP name so the shared module name
    #     custom_top_wrapper (different ports per unit) does not cross-bind.
    if {![catch {exec find $d -name *.sv} sv_files]} {
        foreach f [split $sv_files "\n"] { rename_token $f custom_top_wrapper ${ip}_ctw }
    }
    # (b) Free the type name axi_resp_t for the pulp AXI_TYPEDEF struct by renaming
    #     simplyv's 2-bit response typedef in the vendored header (and its macros).
    #     REDESIGN: the header now lives under rtl/headers/ (was rtl/ in 1B).
    rename_token $d/hw/xilinx/rtl/headers/simplyv_axi.svh axi_resp_t axi_resp_code_t
}

puts "EXPORT_XSIM_EMBEDDED_DONE"
