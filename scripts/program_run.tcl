# Invoked by FH_Test, using preflight-checked paths in environment variables.
# Loads volatile PL configuration and PS RAM only. No compilation or flash write.
proc launch_application {} {
    connect -url $::env(FH_PROGRAM_HW_SERVER_URL)
    # -set refuses ambiguous multi-board targets before any reset/program action.
    targets -set -filter {name =~ "Cortex-A53 #0"} -timeout 10
    puts "FH_JTAG: resetting system"
    rst -system -stop
    after 1500
    targets -set -filter {name =~ "Cortex-A53 #0"} -timeout 10
    puts "FH_JTAG: programming PL bitstream"
    fpga -file $::env(FH_PROGRAM_BIT)
    targets -set -filter {name =~ "Cortex-A53 #0"} -timeout 10
    rst -processor
    puts "FH_JTAG: initializing PS with FSBL"
    dow $::env(FH_PROGRAM_FSBL)
    set bp [bpadd -addr $::env(FH_PROGRAM_FSBL_EXIT) -type hw]
    try {
        con -block -timeout 60
        set registers [rrd pc]
        if {![regexp -nocase {pc\s*:\s*(?:0x)?([0-9a-f]+)} $registers unused pc_hex]} {
            error "Cannot parse FSBL stop PC: $registers"
        }
        # Tcl scan %x may sign-extend a 32-bit address such as 0xfffc0c08.
        set pc [expr 0x$pc_hex]
        if {$pc != $::env(FH_PROGRAM_FSBL_EXIT)} {
            error "FSBL stopped unexpectedly at PC=$pc instead of XFsbl_Exit"
        }
    } finally {
        bpremove $bp
    }
    puts "FH_JTAG: downloading A53 application"
    rst -processor
    dow $::env(FH_PROGRAM_ELF)
    con
    puts "FH_PROGRAM_RUN_OK"
    disconnect
}
if {[catch {launch_application} message options]} {
    puts stderr "FH_PROGRAM_RUN_ERROR: $message"
    catch {disconnect}
    exit 1
}
exit 0
