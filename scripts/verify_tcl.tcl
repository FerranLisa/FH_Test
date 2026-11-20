# Plain Tcl static check; no Vivado commands or compilation.
set root [file normalize [file join [file dirname [info script]] ..]]
foreach path [glob [file join $root hardware scripts *.tcl]] {
    set fd [open $path r]; set text [read $fd]; close $fd
    if {![info complete $text]} {error "Incomplete Tcl: $path"}
}
# Evaluate the generated subsystem against recording stubs. This checks Tcl
# list construction and command syntax, not Vivado properties/IP elaboration.
proc create_bd_design {name} {}
proc create_bd_cell {args} {}
proc create_bd_intf_port {args} {}
proc set_property {args} {}
proc connect_bd_net {args} {}
proc connect_bd_intf_net {args} {}
proc assign_bd_address {args} {}
proc exclude_bd_addr_seg {args} {}
proc validate_bd_design {args} {}
proc save_bd_design {} {}
foreach cmd {get_bd_cells get_bd_intf_ports get_bd_intf_pins get_bd_ports get_bd_pins get_bd_addr_spaces get_bd_addr_segs get_files} {
    proc $cmd {name} {return $name}
}
source [file join $root hardware scripts subsystem.tcl]
puts "TCL_STATIC_PARSE_PASS (not Vivado validation)"
