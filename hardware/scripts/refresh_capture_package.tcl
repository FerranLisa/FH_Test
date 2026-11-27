set hw [file normalize [file join [file dirname [info script]] ..]]
source [file join $hw scripts vivado_local_bootstrap.tcl]
ipx::open_core [file join $hw ip gmax3412_capture component.xml]
set core [ipx::current_core]
set xml [file join $hw ip gmax3412_capture component.xml]
set fd [open $xml r]
set before [read $fd]
close $fd
ipx::update_checksums $core
ipx::save_core $core
set fd [open $xml r]
set changed [expr {[read $fd] ne $before}]
close $fd
if {$changed} {set_property core_revision [expr {[get_property core_revision $core]+1}] $core}
ipx::save_core $core
