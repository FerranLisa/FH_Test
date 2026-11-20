set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root scripts vivado_local_bootstrap.tcl]
# Reuse an existing simulation work directory; no version-specific tree.
create_project -force test_tables [file join $root results pl_ring_sim] -part xczu7ev-ffvc1156-2-i
add_files [glob [file join $root ip gmax3412_emulator hdl *.v]]
add_files -fileset sim_1 [file join $root .. tests rtl tb_gmax3412_tables.sv]
add_files -fileset sim_1 [file join $root .. tests rtl tb_gmax3412_control.sv]
add_files -fileset sim_1 [file join $root .. tests rtl tb_gmax3412_sensor_timing.sv]
set_property top tb_gmax3412_tables [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
launch_simulation
close_sim
set fd [open [file join $root results pl_ring_sim test_tables.sim sim_1 behav xsim simulate.log] r]
set log [read $fd];close $fd
if {![string match *TABLES_PASS* $log] || [string match *Fatal:* $log]} {error "Parameter table regression failed"}
file copy -force [file join $root results pl_ring_sim test_tables.sim sim_1 behav xsim simulate.log] [file join $root results spec_tables_pass.log]
set_property top tb_gmax3412_control [get_filesets sim_1]
launch_simulation
close_sim
set fd [open [file join $root results pl_ring_sim test_tables.sim sim_1 behav xsim simulate.log] r]
set log [read $fd];close $fd
if {![string match *CONTROL_AXI_PASS* $log] || [string match *Fatal:* $log]} {error "Control AXI regression failed"}
file copy -force [file join $root results pl_ring_sim test_tables.sim sim_1 behav xsim simulate.log] [file join $root results spec_control_pass.log]
set_property top tb_gmax3412_sensor_timing [get_filesets sim_1]
launch_simulation
close_sim
set fd [open [file join $root results pl_ring_sim test_tables.sim sim_1 behav xsim simulate.log] r]
set log [read $fd];close $fd
if {![string match *SENSOR_TIMING_PASS* $log] || [string match *Fatal:* $log]} {error "Physical timing regression failed"}
file copy -force [file join $root results pl_ring_sim test_tables.sim sim_1 behav xsim simulate.log] [file join $root results sensor_timing_pass.log]
close_project
