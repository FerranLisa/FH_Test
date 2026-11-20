set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root scripts vivado_local_bootstrap.tcl]
create_project -force test_dual_live [file join $root results pl_ring_live_sim] -part xczu7ev-ffvc1156-2-i
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO} [current_project]
add_files [glob [file join $root ip gmax3412_emulator hdl *.v]]
add_files [glob [file join $root ip gmax3412_capture hdl *.v]]
add_files [file join $root rtl gmax3412_dual_ring.v]
add_files -fileset sim_1 [file join $root .. tests rtl tb_gmax3412_dual.sv]
set_property top tb_gmax3412_dual [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
foreach config {{0 1000 0} {1 1000 0} {24 1000 0} {1 4000 0} {1 9000 0} {24 1000 1} {24 1000 2} {24 1000 0 4294967294}} {
lassign $config ratio exposure fault pulse_base
if {$pulse_base eq ""} {set pulse_base 0}
set_property generic "LIVE=1 LIVE_R=$ratio EXPOSURE=$exposure FAULT=$fault PULSE_BASE=$pulse_base" [get_filesets sim_1]
launch_simulation
close_sim
set fd [open [file join $root results pl_ring_live_sim test_dual_live.sim sim_1 behav xsim simulate.log] r]
set log [read $fd];close $fd
if {(![string match *DUAL_LIVE_PASS* $log] && ![string match *DUAL_FAULT_PASS* $log]) || [string match *Fatal:* $log]} {error "Dual scheduler regression failed"}
file copy -force [file join $root results pl_ring_live_sim test_dual_live.sim sim_1 behav xsim simulate.log] [file join $root results dual_live_R${ratio}_E${exposure}_fault${fault}_base${pulse_base}.log]
}
close_project
