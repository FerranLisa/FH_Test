# Shared by project creation and the one-time update of existing projects.
set cdc_file [file normalize [file join $hw constraints emulator_cdc.xdc]]
if {![llength [get_files -quiet $cdc_file]]} {
    add_files -fileset constrs_1 -norecurse $cdc_file
}
set_property USED_IN_SYNTHESIS false [get_files $cdc_file]
set_property PROCESSING_ORDER LATE [get_files $cdc_file]
