# Source from the GUI after Generate Bitstream succeeds. Never launches a build.
set hw [file normalize [file join [file dirname [info script]] ..]]
if {[get_property NAME [current_project]] ne "FH_Emulator"} {
    error "Open FH_Emulator.xpr first"
}
foreach run {synth_1 impl_1} {
    if {[get_property PROGRESS [get_runs $run]] ne "100%" ||
        ![string match *Complete* [get_property STATUS [get_runs $run]]] ||
        [get_property NEEDS_REFRESH [get_runs $run]]} {
        error "$run is incomplete or stale; build it in the GUI first"
    }
}
open_run impl_1
file mkdir [file join $hw exports]
report_timing_summary -report_unconstrained -file [file join $hw exports timing_summary.rpt]
report_pulse_width -file [file join $hw exports pulse_width.rpt]
report_bus_skew -file [file join $hw exports bus_skew.rpt]
report_drc -file [file join $hw exports drc.rpt]
report_methodology -file [file join $hw exports methodology.rpt]
source [file join $hw scripts timing_signoff.tcl]
require_calibration_sync
foreach filename {timing_summary bus_skew} check {require_timing_summary require_bus_skew} {
    set fd [open [file join $hw exports ${filename}.rpt] r]
    set report [read $fd]
    close $fd
    $check $report
}
foreach delay {max min} {
    set paths [get_timing_paths -delay_type $delay -max_paths 1]
    if {![llength $paths] || [get_property SLACK $paths]<0} {error "Timing failed ($delay)"}
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {
    error "DRC signoff failed"
}
if {[llength [get_methodology_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {
    error "Methodology signoff failed"
}
set stem [file join $hw exports FH_Emulator]
set native_bit [file join [get_property DIRECTORY [get_runs impl_1]] FH_Carrier_Bringup_top.bit]
if {![file exists $native_bit]} {error "Generate Bitstream in the GUI first"}
file copy -force $native_bit ${stem}.bit
write_debug_probes -force ${stem}.ltx
write_hw_platform -fixed -include_bit -force -file ${stem}.xsa
puts "FH_CARRIER_EXPORT_COMPLETE: use this XSA to update the Vitis platform"
