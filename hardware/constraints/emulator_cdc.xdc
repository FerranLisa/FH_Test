# DDR calibration is asynchronous to the 120 MHz acquisition controller.
# calibrated[0:1] is an ASYNC_REG two-flop synchronizer. Exempt ONLY its
# first-stage input; retain timing between stages and all AXI CDC constraints.
set_false_path -to [get_pins -hier -regexp {.*gmax_dual_ring.*/calibrated_reg\[0\]/D}]

# Independent sensor pixel clocks feed registered FVAL levels into the
# acquisition clock. Only the first destination stage is asynchronous.
set_false_path -to [get_pins -hier -regexp {.*gmax_dual_ring.*/fv_meta_reg\[[01]\]/D}]
set_false_path -to [get_pins -hier -regexp {.*gmax_dual_ring.*/.*line_measure.*sync_line_reg\[0\]/D}]

# The RTC seconds interrupt crosses from the battery-backed clock domain.
# Constrain the second synchronizer stage normally.
set_false_path -to [get_pins -hier -regexp {.*gmax_dual_ring.*/edge_meta_reg\[2\]/D}]

# Each receiver latches lane activity until reset. Only stage 1 (index 1)
# feeds the diagnostic mux. Exempt the transfer into stage 0, one lane at a time.
set_false_path -from [get_cells {u_gmax_a_rx/u_training/loopi[0].u_iserdes/raw_activity_reg}] -to [get_pins {u_gmax_a_rx/u_training/dbg_raw0_sync_reg[0]/D}]
set_false_path -from [get_cells {u_gmax_a_rx/u_training/loopi[1].u_iserdes/raw_activity_reg}] -to [get_pins {u_gmax_a_rx/u_training/dbg_raw1_sync_reg[0]/D}]
set_false_path -from [get_cells {u_gmax_b_rx/u_training/loopi[0].u_iserdes/raw_activity_reg}] -to [get_pins {u_gmax_b_rx/u_training/dbg_raw0_sync_reg[0]/D}]
set_false_path -from [get_cells {u_gmax_b_rx/u_training/loopi[1].u_iserdes/raw_activity_reg}] -to [get_pins {u_gmax_b_rx/u_training/dbg_raw1_sync_reg[0]/D}]

# Clock-activity toggles change once per 256 divided-clock cycles. Bound
# routing into the two-flop level synchronizer to one 150 MHz source period.
set_max_delay -datapath_only 6.668 -from [get_cells {u_gmax_a_rx/u_training/dbg_clk0_toggle_reg}] -to [get_pins {u_gmax_a_rx/u_training/dbg_clk0_sync_reg[0]/D}]
set_max_delay -datapath_only 6.668 -from [get_cells {u_gmax_a_rx/u_training/dbg_clk1_toggle_reg}] -to [get_pins {u_gmax_a_rx/u_training/dbg_clk1_sync_reg[0]/D}]
set_max_delay -datapath_only 6.668 -from [get_cells {u_gmax_b_rx/u_training/dbg_clk0_toggle_reg}] -to [get_pins {u_gmax_b_rx/u_training/dbg_clk0_sync_reg[0]/D}]
set_max_delay -datapath_only 6.668 -from [get_cells {u_gmax_b_rx/u_training/dbg_clk1_toggle_reg}] -to [get_pins {u_gmax_b_rx/u_training/dbg_clk1_sync_reg[0]/D}]
