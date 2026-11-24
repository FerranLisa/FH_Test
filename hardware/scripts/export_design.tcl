# Output-product generation and hardware metadata only. No build runs/bitstream.
set hw [file normalize [file join [file dirname [info script]] ..]]
source [file join $hw scripts vivado_local_bootstrap.tcl]
open_project [file join $hw vivado FH_Firmware.xpr]
if {![llength [get_files -quiet */insert_receiver_ila.tcl]]} {
    add_files -fileset utils_1 -norecurse [file join $hw scripts insert_receiver_ila.tcl]
}
open_bd_design [get_files */design_1.bd]
source [file join $hw scripts connect_frame_time.tcl]
validate_bd_design
generate_target all [get_files */design_1.bd]
file mkdir [file join $hw exports]
write_hw_platform -fixed -force -file [file join $hw exports FH_Firmware_design.xsa]
puts "FH_CARRIER_DESIGN_HANDOFF_READY: no bitstream or compilation"
close_project
