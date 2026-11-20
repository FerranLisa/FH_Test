# Run from the Tcl Console of the existing Vivado project. No builds.
set router_hw [file normalize [file join [file dirname [info script]] ..]]
open_bd_design [get_files */design_1.bd]
source [file join $router_hw scripts add_router.tcl]
set router_tb [file normalize [file join $router_hw .. tests rtl tb_fh_router.sv]]
if {![llength [get_files -quiet $router_tb]]} {
    add_files -fileset sim_1 -norecurse $router_tb
}
set_property top tb_fh_router [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sim_1
puts "Router is ready for GUI simulation and builds; none were launched."
