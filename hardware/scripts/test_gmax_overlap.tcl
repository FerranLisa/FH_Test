# Standalone XSim regression. Does not open or modify the firmware project.
set hw [file normalize [file join [file dirname [info script]] ..]]
set out [file join $hw results overlap_sim]
source [file join $hw scripts vivado_local_bootstrap.tcl]
create_project -force overlap_test $out -part xczu7ev-ffvc1156-2-i
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO} [current_project]
add_files [file join $hw rtl gmax3412_dual_ring.v]
add_files [glob [file join $hw ip gmax3412_capture hdl *.v]]
add_files -fileset sim_1 [file join $hw .. tests rtl tb_gmax_overlap.sv]
set sim [get_filesets sim_1]
set_property top tb_gmax_overlap $sim
set_property xsim.simulate.runtime all $sim
set cases {
    native {WIDTH=4096 RATE=120 FOT=6000 EXP=3600} {PASS overlap=2}
    nominal {WIDTH=4096 RATE=120 FOT=6000 EXP=1000} {PASS overlap=0}
    fot {FOT=1100} {PASS overlap=0}
    missed_sof {LATE_SOF_FAULT=1} {PASS missed SOF rejected}
    late_readout {LONG_READOUT=1} {PASS previous readout still active}
}
if {"transitions" in $argv} {
    set cases {}
    foreach {name gap fot drain} {
        control         1 6000     0
        line_2p4us     32 6048     0
        longer_line    82 6000     0
        delayed_dma     1 6000 95000
    } {
        lappend cases $name [list WIDTH=4096 RATE=120 EXP=1000 TRACE_TRANSITIONS=1 \
            ROW_GAP=$gap FOT=$fot DMA_DELAY=$drain] {PASS overlap=}
    }
    lappend cases board_sequence {WIDTH=4096 RATE=120 EXP=1000 R=24 TRACE_TRANSITIONS=1 ROW_GAP=146 FOT=6000} {PASS overlap=24 TP gaps=24 frames=27}
    lappend cases board_250 {WIDTH=4096 RATE=120 EXP=1000 R=24 TRACE_TRANSITIONS=1 ROW_GAP=44 FOT=7200 DMA_DELAY=420} {PASS overlap=2 TP gaps=2 frames=27}
    lappend cases missed_window {EXP=1000 ROW_GAP=5 FOT=100 TRACE_TRANSITIONS=1 WINDOW_FAULT=1} {PASS missed window rejected}
    lappend cases missed_roi_window {EXP=1000 ROW_GAP=4 FOT=120 TRACE_TRANSITIONS=1 WINDOW_FAULT=2} {PASS missed window rejected}
    lappend cases low_margin {EXP=1000 ROW_GAP=6 FOT=100 TRACE_TRANSITIONS=1} {PASS overlap=2}
}
foreach {name settings expected} $cases {
    set_property generic $settings $sim
    launch_simulation
    close_sim
    set logfile [file join $out overlap_test.sim sim_1 behav xsim simulate.log]
    set fd [open $logfile r]
    set result [read $fd]
    close $fd
    file copy -force $logfile [file join $out ${name}.log]
    if {[string first $expected $result]<0 || [string first "Fatal:" $result]>=0} {
        error "Overlap regression failed: $name"
    }
    if {$name eq "board_sequence"} {
        foreach {frame slot} {0 1 1 4 24 27 25 28 26 31} {
            if {[string first "frame $frame slot $slot width " $result]<0} {
                error "Transition timing mismatch for frame $frame (expected tick $slot)"
            }
        }
    }
    if {$name eq "low_margin" && [string first "frame 4 slot 8 width " $result]<0} {
        error "Expected conservative ROI-to-FULL transition when the measured margin is too small"
    }
    if {$name eq "board_250"} {
        foreach {frame slot} {0 1 1 3 24 26 25 27 26 29} {
            if {[string first "frame $frame slot $slot width " $result]<0} {
                error "250-cycle line timing mismatch for frame $frame"
            }
        }
    }
}
close_project
