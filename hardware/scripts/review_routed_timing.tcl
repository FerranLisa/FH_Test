# Reanalyse the existing route in memory; never place, route, or export hardware.
set hw [file normalize [file join [file dirname [info script]] ..]]
source [file join $hw scripts vivado_local_bootstrap.tcl]
open_project [file join $hw vivado FH_Firmware.xpr]
source [file join $hw scripts register_cdc_constraint.tcl]
set checkpoint [file join [get_property DIRECTORY [get_runs impl_1]] FH_Carrier_Bringup_top_routed.dcp]
close_project
open_checkpoint $checkpoint
source [file join $hw scripts timing_signoff.tcl]
require_calibration_sync
read_xdc [file join $hw constraints emulator_cdc.xdc]
set out [file join $hw results timing_review]
file mkdir $out
report_methodology -file [file join $out methodology.rpt]
report_timing_summary -report_unconstrained -file [file join $out timing_summary.rpt]
report_pulse_width -file [file join $out pulse_width.rpt]
report_bus_skew -file [file join $out bus_skew.rpt]
report_cdc -file [file join $out cdc.rpt]
report_route_status -file [file join $out route_status.rpt]
puts "FH_FIRMWARE_TIMING_REVIEW_COMPLETE: existing route only, no hardware export"
close_design
