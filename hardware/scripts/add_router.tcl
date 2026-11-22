# Source in the Vivado GUI with design_1 open. No build or output generation.
set router_hw [file normalize [file join [file dirname [info script]] ..]]
foreach router_src {fh_router_dma.v fh_router_live.v fh_router.v} {
    if {![llength [get_files -quiet */$router_src]]} {
        add_files -norecurse [file join $router_hw rtl $router_src]
    }
}
update_compile_order -fileset sources_1
if {![llength [get_bd_cells -quiet fh_router_0]]} {
    create_bd_cell -type module -reference fh_router fh_router_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 fh_export_dma
    set_property -dict [list CONFIG.c_addr_width {64} CONFIG.c_include_sg {0} \
        CONFIG.c_include_mm2s {1} CONFIG.c_include_s2mm {1} \
        CONFIG.c_m_axi_mm2s_data_width {64} CONFIG.c_m_axi_s2mm_data_width {64} \
        CONFIG.c_m_axis_mm2s_tdata_width {16} CONFIG.c_s_axis_s2mm_tdata_width {16} \
        CONFIG.c_include_mm2s_dre {1} CONFIG.c_include_s2mm_dre {1} \
        CONFIG.c_sg_length_width {26}] [get_bd_cells fh_export_dma]
    set_property CONFIG.NUM_MI 15 [get_bd_cells axi_smc]
    set_property CONFIG.NUM_SI 4 [get_bd_cells pl_ddr_smc]
    set_property CONFIG.PSU__USE__S_AXI_GP2 1 [get_bd_cells zynq_ultra_ps_e_0]
    set_property CONFIG.NUM_SI 2 [get_bd_cells gmax_ddr_smc]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M13_AXI] [get_bd_intf_pins fh_router_0/s_axi]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M14_AXI] [get_bd_intf_pins fh_export_dma/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins fh_export_dma/M_AXI_MM2S] [get_bd_intf_pins pl_ddr_smc/S03_AXI]
    connect_bd_intf_net [get_bd_intf_pins fh_export_dma/M_AXIS_MM2S] [get_bd_intf_pins fh_router_0/s_axis]
    connect_bd_intf_net [get_bd_intf_pins fh_router_0/m_axis] [get_bd_intf_pins fh_export_dma/S_AXIS_S2MM]
    connect_bd_intf_net [get_bd_intf_pins fh_export_dma/M_AXI_S2MM] [get_bd_intf_pins gmax_ddr_smc/S01_AXI]
    foreach pin {fh_router_0/clk fh_export_dma/s_axi_lite_aclk fh_export_dma/m_axi_mm2s_aclk fh_export_dma/m_axi_s2mm_aclk} {
        connect_bd_net [get_bd_pins gmax_emu_clock/clk_out1] [get_bd_pins $pin]
    }
    foreach pin {fh_router_0/resetn fh_export_dma/axi_resetn} {
        connect_bd_net [get_bd_pins gmax_emu_reset/peripheral_aresetn] [get_bd_pins $pin]
    }
    assign_bd_address -offset 0xA00C0000 -range 64K -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs fh_router_0/s_axi/*]
    assign_bd_address -offset 0xA00D0000 -range 64K -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs fh_export_dma/S_AXI_LITE/Reg]
    assign_bd_address -offset 0x1000000000 -range 4G -target_address_space [get_bd_addr_spaces fh_export_dma/Data_MM2S] [get_bd_addr_segs pl_ddr4/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK]
    assign_bd_address -offset 0 -range 2G -target_address_space [get_bd_addr_spaces fh_export_dma/Data_S2MM] [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW]
    exclude_bd_addr_seg -target_address_space [get_bd_addr_spaces gmax_dual_ring/m_axi] [get_bd_addr_segs fh_router_0/s_axi/*]
    exclude_bd_addr_seg -target_address_space [get_bd_addr_spaces gmax_dual_ring/m_axi] [get_bd_addr_segs fh_export_dma/S_AXI_LITE/Reg]
}
validate_bd_design
save_bd_design
puts "Router sources and BD updated; no compilation performed."
