set hw [file normalize [file join [file dirname [info script]] ..]]
source [file join $hw scripts vivado_local_bootstrap.tcl]
set stage [lindex $argv 0]
if {$stage ni {synth implement export}} {error "Stage must be synth, implement or export"}
open_project [file join $hw vivado FH_Firmware.xpr]
set_param general.maxThreads 8
if {$stage eq "synth"} {
    # An edited .bd can still be marked validated with stale Verilog and checkpoints.
    # Start a requested synthesis from regenerated HDL, including its dependent impl run.
    set bd_file [get_files */design_1.bd]
    foreach run {synth_1 impl_1} {
        if {[regexp -nocase {running|queued|launching} [get_property STATUS [get_runs $run]]]} {
            error "Cannot regenerate the design while $run is active"
        }
    }
    if {[get_property STATUS [get_runs synth_1]] ne "Not started"} {reset_run synth_1}
	set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
	set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
    update_ip_catalog -rebuild
    open_bd_design $bd_file
    source [file join $hw scripts upgrade_capture_cells.tcl]
    source [file join $hw scripts connect_frame_time.tcl]
    reset_target all $bd_file
    validate_bd_design -force
    save_bd_design
    generate_target -force all $bd_file

    # Inspect each generated IP manifest, including the actual shared HDL it references.
    # XCI names of the two capture bridges in design_1.bd.
    foreach instance {design_1_gmax_capture_0 design_1_gmax_capture_b_0} {
        set directory [file join $hw bd gen ip $instance]
        set fd [open [file join $directory ${instance}.xml] r]
        set manifest [read $fd]
        close $fd
        foreach source [glob [file join $hw ip gmax3412_capture hdl *.v]] {
            set filename [file tail $source]
            set pattern [format {<[^<>]*name>([^<>]*/%s)</[^<>]*name>} [string map {. {\.}} $filename]]
            if {![regexp $pattern $manifest -> relative]} {error "$instance does not reference $filename"}
            set generated [file normalize [file join $directory $relative]]
            set fd [open $source r]
            set expected [read $fd]
            close $fd
            set fd [open $generated r]
            set actual [read $fd]
            close $fd
            if {$actual ne $expected} {error "Stale $instance HDL: $generated differs from $source"}
        }
        puts "Verified generated capture HDL: $instance"
    }
    set fd [open [file join $hw bd gen synth design_1.v] r]
    set hdl [read $fd]
    close $fd
    if {![regexp {\.texp_drive\s*\(\s*(\w+)(?:\[3:0\])?\s*\)} $hdl -> pulse_net] ||
        ($pulse_net ne "texp_drive" &&
        ![regexp [format {assign\s+texp_drive(?:\[3:0\])?\s*=\s*%s(?:\[3:0\])?\s*;} $pulse_net] $hdl])} {
        error "Generated design_1.v does not connect the FPGA exposure driver to texp_drive"
    }
}
proc require_complete {run} {
    if {[get_property PROGRESS [get_runs $run]] ne "100%" ||
        ![string match *Complete* [get_property STATUS [get_runs $run]]]} {
        error "$run did not complete: [get_property STATUS [get_runs $run]]"
    }
    if {[get_property NEEDS_REFRESH [get_runs $run]]} {error "$run is stale; reset and rebuild it"}
}
proc build_run {run final_step args} {
    set obj [get_runs $run]
    set status [get_property STATUS $obj]
    if {[regexp -nocase {running|queued|launching} $status]} {
        error "$run is already active: $status"
    }
    if {[string match "$final_step Complete*" $status] &&
        [get_property PROGRESS $obj] eq "100%" && ![get_property NEEDS_REFRESH $obj]} {
        puts "Reusing current $run ($status)"
        return
    }
    if {$status ne "Not started"} {
        puts "Resetting $run before rebuild ($status)"
        reset_run $run
    }
    launch_runs $run {*}$args -jobs 8
    wait_on_run $run
    require_complete $run
}
if {$stage eq "synth"} {
    build_run synth_1 synth_design
} elseif {$stage eq "implement"} {
    require_complete synth_1
    build_run impl_1 write_bitstream -to_step write_bitstream
} else {
    require_complete synth_1
    require_complete impl_1
    open_run impl_1
    file mkdir [file join $hw exports]
    report_timing_summary -report_unconstrained -file [file join $hw exports timing_summary.rpt]
    report_pulse_width -file [file join $hw exports pulse_width.rpt]
    report_bus_skew -file [file join $hw exports bus_skew.rpt]
    report_drc -file [file join $hw exports drc.rpt]
    source [file join $hw scripts timing_signoff.tcl]
    require_calibration_sync
    foreach filename {timing_summary bus_skew} check {require_timing_summary require_bus_skew} {
        set fd [open [file join $hw exports ${filename}.rpt] r]
        set report [read $fd]
        close $fd
        $check $report
    }
    require_routed_paths
    # Methodology reprocesses XDC. Run it after checking the routed timing view.
    report_methodology -file [file join $hw exports methodology.rpt]
    set violations [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
    if {[llength $violations]} {error "DRC errors/critical warnings; inspect drc.rpt"}
    set violations [get_methodology_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
    if {[llength $violations]} {error "Methodology errors/critical warnings; inspect methodology.rpt"}
    set stem [file join $hw exports FH_Firmware]
    set native_bit [file join [get_property DIRECTORY [get_runs impl_1]] FH_Carrier_Bringup_top.bit]
    if {![file exists $native_bit]} {error "Implementation has not produced a bitstream"}
    file copy -force $native_bit ${stem}.bit
    write_debug_probes -force ${stem}.ltx
    write_hw_platform -fixed -include_bit -force -file ${stem}.xsa
    puts "FH_FIRMWARE_EXPORT_COMPLETE"
}
close_project
