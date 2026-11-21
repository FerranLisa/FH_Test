# Native FH_Carrier project preparation only; no synthesis/implementation.
set hw [file normalize [file join [file dirname [info script]] ..]]
source [file join $hw scripts vivado_local_bootstrap.tcl]
if {![string match 2025.2* [version -short]]} {error "Use Vivado 2025.2"}
if {[llength [get_projects -quiet]]} {error "Close the current project first"}
if {[file exists [file join $hw vivado FH_Emulator.xpr]]} {
    error "Open the existing FH_Emulator.xpr instead of recreating it"
}
create_project FH_Emulator [file join $hw vivado] -part xczu7ev-ffvc1156-2-i
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO} [current_project]
set_property ip_repo_paths [list [file join $hw ip]] [current_project]
update_ip_catalog
add_files -norecurse [glob [file join $hw rtl *.v]]
add_files -norecurse [file join $hw bd design_1.bd]
open_bd_design [get_files */design_1.bd]
source [file join $hw scripts connect_frame_time.tcl]
source [file join $hw scripts add_router.tcl]
set_property SYNTH_CHECKPOINT_MODE None [get_files */design_1.bd]
set wrapper [make_wrapper -files [get_files */design_1.bd] -top -force]
add_files -norecurse $wrapper
set_property top FH_Carrier_Bringup_top [get_filesets sources_1]
add_files -fileset constrs_1 -norecurse [glob [file join $hw constraints *.xdc]]
foreach name {FH_Carrier_Bringup_impl.xdc emulator_cdc.xdc} {
    set f [get_files */$name]
    set_property USED_IN_SYNTHESIS false $f
    set_property PROCESSING_ORDER LATE $f
}
add_files -fileset utils_1 -norecurse [file join $hw scripts insert_receiver_ila.tcl]
set_property STEPS.INIT_DESIGN.TCL.POST [file join $hw scripts insert_receiver_ila.tcl] [get_runs impl_1]
set_property strategy Performance_Explore [get_runs impl_1]
update_compile_order -fileset sources_1
validate_bd_design -force
save_bd_design
puts "FH_CARRIER_PROJECT_READY: no synthesis or implementation launched"
close_project
