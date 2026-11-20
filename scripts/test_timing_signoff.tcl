# Guard regression using the actual failed Vivado report as the baseline.
set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root hardware scripts timing_signoff.tcl]
proc read_text {path} {set fd [open $path]; set result [read $fd]; close $fd; return $result}
proc rejects {script pattern} {
    if {![catch {uplevel 1 $script} message] || ![string match $pattern $message]} {
        error "Expected rejection $pattern, got: $message"
    }
}
set run [file join $root hardware vivado FH_Emulator.runs impl_1]
set original [read_text [file join $run design_1_wrapper_timing_summary_routed.rpt]]
rejects {require_timing_summary $original} {*setup*}
# Isolate the table from the real report. Exercise each metric independently.
regexp {WNS\(ns\)[^\n]*WPWS\(ns\)[^\n]*\n[^\n]*\n} $original header
set good {0.539 0.000 0 372425 0.010 0.000 0 370763 0.006 0.000 0 117032}
require_timing_summary "$header$good\n"
foreach index {0 4 8} label {setup hold pulse-width/min-skew} {
    set bad [lreplace $good $index $index -0.001]
    rejects {require_timing_summary "$header$bad\n"} "*$label*"
}
set bad [lreplace $good 10 10 2]
rejects {require_timing_summary "$header$bad\n"} {*pulse-width/min-skew*}
rejects {require_timing_summary "missing"} {*Missing*}
require_bus_skew [read_text [file join $run design_1_wrapper_bus_skew_routed.rpt]]
rejects {require_bus_skew "Slow 8.333 8.334 -0.001\n"} {*Bus skew failed*}
rejects {require_bus_skew "missing"} {*No bus-skew*}
set reviewed [file join $root hardware results timing_review]
if {[file exists [file join $reviewed timing_summary.rpt]]} {
    rejects {require_timing_summary [read_text [file join $reviewed timing_summary.rpt]]} {*pulse-width/min-skew*}
    require_bus_skew [read_text [file join $reviewed bus_skew.rpt]]
}
puts TIMING_SIGNOFF_GUARD_TEST_PASS
