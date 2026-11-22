# Upgrade both existing Vivado projects and fresh checkouts.
set time_ps [get_bd_cells zynq_ultra_ps_e_0]
if {![get_property CONFIG.PSU__IRQ_P2F_RTC_SECONDS__INT $time_ps]} {
    set_property CONFIG.PSU__IRQ_P2F_RTC_SECONDS__INT 1 $time_ps
}
if {![llength [get_bd_pins -quiet gmax_dual_ring/texp_drive]]} {
    update_module_reference [get_ips design_1_gmax_dual_ring_0]
}
if {![llength [get_bd_ports -quiet texp_pins]]} {
    create_bd_port -dir I -from 1 -to 0 texp_pins
}
foreach {source target} {zynq_ultra_ps_e_0/ps_pl_irq_rtc_seconds rtc_seconds_irq texp_pins texp_pins} {
    set sink [get_bd_pins gmax_dual_ring/$target]
    if {![llength [get_bd_nets -quiet -of_objects $sink]]} {
        if {$source eq "texp_pins"} {set driver [get_bd_ports $source]} else {set driver [get_bd_pins $source]}
        connect_bd_net $driver $sink
    }
}
if {![llength [get_bd_ports -quiet texp_drive]]} {
    create_bd_port -dir O -from 3 -to 0 texp_drive
}
set pulse_driver [get_bd_pins gmax_dual_ring/texp_drive]
set pulse_port [get_bd_ports texp_drive]
set port_net [get_bd_nets -quiet -of_objects $pulse_port]
set driver_net [get_bd_nets -quiet -of_objects $pulse_driver]
if {$port_net eq ""} {
    connect_bd_net $pulse_driver $pulse_port
} elseif {$driver_net eq ""} {
    # Updating the module reference can leave the external port on a driverless net.
    connect_bd_net -net [get_property NAME $port_net] $pulse_driver
}
set driver_net [get_bd_nets -quiet -of_objects $pulse_driver]
if {$driver_net eq "" || $driver_net ne [get_bd_nets -quiet -of_objects $pulse_port]} {
    error "TEXP output port must be driven by gmax_dual_ring/texp_drive"
}
source [file join [file dirname [info script]] connect_monitor.tcl]
save_bd_design
make_wrapper -files [get_files */design_1.bd] -top -force
