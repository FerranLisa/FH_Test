# Live taps are internal to the BD; the existing RX ports also feed RAW capture.
set mhw [file normalize [file join [file dirname [info script]] ..]]
set monitor_amp [expr {[info exists ::env(FH_MONITOR_AMP)] && $::env(FH_MONITOR_AMP) eq "1"}]
foreach src {fh_router_dma fh_router_live fh_monitor_eye fh_monitor_input} {
    if {![llength [get_files -quiet */$src.v]]} {
        add_files -norecurse [file join $mhw rtl $src.v]
    }
}
update_compile_order -fileset sources_1
if {![llength [get_bd_pins -quiet gmax_dual_ring/monitor_full_trigger]]} {
    update_module_reference [get_ips design_1_gmax_dual_ring_0]
}
if {[llength [get_bd_cells -quiet monitor_ctrl]]} {
    foreach endpoint {monitor_a_dma/S_AXIS_S2MM monitor_b_dma/S_AXIS_S2MM} {
        if {![llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins -quiet $endpoint]]]} {
            error "Incomplete monitor BD at $endpoint; reopen the last saved design before retrying"
        }
    }
    if {$monitor_amp && ![llength [get_bd_cells -quiet monitor_vcu]]} {error "Use a fresh BD for the AMP/VCU profile"}
    return
}
proc mon_pin {src dst} {connect_bd_net [get_bd_pins $src] [get_bd_pins $dst]}
proc mon_bus {src dst} {connect_bd_intf_net [get_bd_intf_pins $src] [get_bd_intf_pins $dst]}
proc mon_addr {cell addr} {
    assign_bd_address -offset $addr -range 64K -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs $cell]
}
set mclk gmax_emu_clock/clk_out1
set mrst gmax_emu_reset/peripheral_aresetn
set_property CONFIG.NUM_MI 16 [get_bd_cells axi_smc]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 monitor_ctrl
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI [expr {$monitor_amp ? 7 : 6}]] [get_bd_cells monitor_ctrl]
mon_bus axi_smc/M15_AXI monitor_ctrl/S00_AXI
mon_pin $mclk monitor_ctrl/aclk
mon_pin $mrst monitor_ctrl/aresetn
set_property CONFIG.NUM_SI [expr {$monitor_amp ? 7 : 4}] [get_bd_cells gmax_ddr_smc]
foreach eye {a b} idx {0 1} prefix {capture_rx capture_b_rx} {
    set tap monitor_${eye}
    create_bd_cell -type module -reference fh_monitor_input $tap
    foreach sig {clk fval lval data} pin {rx_clk fval lval pixels} {
        connect_bd_net [get_bd_ports ${prefix}_${sig}] [get_bd_pins $tap/$pin]
    }
    mon_pin $mclk $tap/ctrl_clk
    mon_pin $mrst $tap/resetn
    foreach sig {full_trigger frame_id} {mon_pin gmax_dual_ring/monitor_$sig $tap/$sig}
    set base [expr {0xA1000000 + $idx*0x40000}]
    foreach gpio {cfg info} pos {0 1} {
        set g ${tap}_${gpio}
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 $g
        set_property CONFIG.C_IS_DUAL 1 [get_bd_cells $g]
        if {$gpio eq "cfg"} {
            set_property -dict {CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_ALL_OUTPUTS_2 1} [get_bd_cells $g]
            mon_pin $g/gpio_io_o $tap/cfg_xy
            mon_pin $g/gpio2_io_o $tap/cfg_mode
        } else {
            set_property -dict {CONFIG.C_ALL_INPUTS 1 CONFIG.C_ALL_INPUTS_2 1} [get_bd_cells $g]
            mon_pin $tap/status $g/gpio_io_i
            mon_pin $tap/captured_id $g/gpio2_io_i
        }
        mon_bus [format "monitor_ctrl/M%02d_AXI" [expr {$idx*3+$pos}]] $g/S_AXI
        mon_pin $mclk $g/s_axi_aclk
        mon_pin $mrst $g/s_axi_aresetn
        mon_addr $g/S_AXI/Reg [expr {$base+$pos*0x10000}]
    }
    set dma ${tap}_dma
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 $dma
    set_property -dict {CONFIG.c_include_mm2s 0 CONFIG.c_include_sg 0 CONFIG.c_addr_width 32 CONFIG.c_sg_length_width 24 CONFIG.c_m_axi_s2mm_data_width 128 CONFIG.c_s_axis_s2mm_tdata_width 128} [get_bd_cells $dma]
    mon_bus $tap/M_AXIS $dma/S_AXIS_S2MM
    mon_bus [format "monitor_ctrl/M%02d_AXI" [expr {$idx*3+2}]] $dma/S_AXI_LITE
    mon_bus $dma/M_AXI_S2MM [format "gmax_ddr_smc/S%02d_AXI" [expr {2+$idx}]]
    foreach pin {s_axi_lite_aclk m_axi_s2mm_aclk} {mon_pin $mclk $dma/$pin}
    mon_pin $mrst $dma/axi_resetn
    mon_addr $dma/S_AXI_LITE/Reg [expr {$base+0x20000}]
    assign_bd_address -offset 0 -range 2G -target_address_space [get_bd_addr_spaces $dma/Data_S2MM] [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW]
}
if {!$monitor_amp} {return}
create_bd_cell -type ip -vlnv xilinx.com:ip:vcu:1.2 monitor_vcu
set_property -dict {CONFIG.ENABLE_ENCODER TRUE CONFIG.ENABLE_DECODER FALSE CONFIG.NO_OF_STREAMS 2} [get_bd_cells monitor_vcu]
mon_bus monitor_ctrl/M06_AXI monitor_vcu/S_AXI_LITE
foreach bus {M_AXI_ENC0 M_AXI_ENC1 M_AXI_MCU} dest {S04_AXI S05_AXI S06_AXI} {
    mon_bus monitor_vcu/$bus gmax_ddr_smc/$dest
    assign_bd_address -offset 0 -range 2G -target_address_space [get_bd_addr_spaces -of_objects [get_bd_intf_pins monitor_vcu/$bus]] [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW]
}
foreach pin {s_axi_lite_aclk m_axi_enc_aclk m_axi_mcu_aclk} {mon_pin $mclk monitor_vcu/$pin}
mon_pin $mrst monitor_vcu/vcu_resetn
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 monitor_pll_ref
set_property -dict {CONFIG.PRIM_IN_FREQ 120.000 CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 33.333 CONFIG.USE_RESET false} [get_bd_cells monitor_pll_ref]
mon_pin $mclk monitor_pll_ref/clk_in1
mon_pin monitor_pll_ref/clk_out1 monitor_vcu/pll_ref_clk
set_property CONFIG.PSU__USE__IRQ0 1 [get_bd_cells zynq_ultra_ps_e_0]
mon_pin monitor_vcu/vcu_host_interrupt zynq_ultra_ps_e_0/pl_ps_irq0
assign_bd_address -offset 0xA2000000 -range 1M -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs monitor_vcu/S_AXI_LITE/*]
