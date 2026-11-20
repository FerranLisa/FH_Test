# Parse Vivado's aggregate table, including device pulse-width/min-skew checks.
# Fail closed if the report format changes or a required result is missing.
proc require_calibration_sync {} {
    set pins [get_pins -hier -regexp {.*gmax_dual_ring.*/calibrated_reg\[0\]/D}]
    if {[llength $pins] != 1} {error "Expected exactly one calibration synchronizer input"}
}

proc require_timing_summary {report} {
    if {![regexp {WNS\(ns\)[^\n]*WPWS\(ns\)[^\n]*\n[^\n]*\n([^\n]+)} $report all row]} {
        error "Missing timing summary table"
    }
    set values [regexp -all -inline {\S+} $row]
    if {[llength $values] != 12} {error "Unexpected timing summary format"}
    foreach v $values {
        if {![string is double -strict $v]} {error "Missing/non-numeric timing result: $v"}
    }
    foreach offset {0 4 8} label {setup hold pulse-width/min-skew} {
        set slack [lindex $values $offset]
        set failing [lindex $values [expr {$offset+2}]]
        set total [lindex $values [expr {$offset+3}]]
        if {$slack < 0 || $failing != 0 || $total <= 0} {
            error "Timing failed ($label): slack=$slack ns, failing=$failing/$total"
        }
    }
}

proc require_bus_skew {report} {
    # This design has XPM/SmartConnect bus-skew constraints. Require their rows.
    set count 0
    foreach line [split $report \n] {
        if {[regexp {^\s*(?:Slow|Fast)\s+([0-9.]+)\s+([0-9.]+)\s+(-?[0-9.]+)\s*$} $line all required actual slack]} {
            incr count
            if {$slack < 0} {error "Bus skew failed: slack=$slack ns"}
        }
    }
    if {!$count} {error "No bus-skew summary results found"}
    if {[string match *VIOLATED* $report]} {error "Bus skew violation reported"}
}
