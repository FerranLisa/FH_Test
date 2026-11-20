# V16.3 audit correction, 2026-10-03. Implementation only, PROCESSING_ORDER=LATE.
# Clock waveform, RTL, pins, electrical settings and PCIe constraints preserved.

# V16.3 review: complete clock families and constrain the existing CDC circuits.
# Include the receiver descendants, including /5 and inverted /4. The 120 MHz
# capture clock derived from clk_pl_0 is deliberately excluded from this broad
# exception: its XPM FIFO/CDC constraints must retain their max-delay bounds.
set_clock_groups -name FH_ASYNC_PL_GMAX_FAMILIES -asynchronous \
    -group [get_clocks clk_pl_0] \
    -group [get_clocks -include_generated_clocks GMX_A_CLK0] \
    -group [get_clocks -include_generated_clocks GMX_B_CLK0] \
    -group [get_clocks -include_generated_clocks GMX_B_CLK1] \
    -group [get_clocks -include_generated_clocks GMX_A_CLK1]

# Preserve /4 and /5 as related clocks. Only the input to each deliberate
# synchronizer is excepted; all later synchronizer stages remain timed.
set fh_pixel [get_clocks -of_objects [get_pins u_gmax_a_rx/u_training/u_gmax3412_iob_clock/BUFGCE_RXG_DIV5_inst/O]]
set fh_first [get_pins -hier -regexp {u_gmax_a_rx/u_training/loopi\[[0-9]+\]\.u_iserdes/(rst_iserdes_q_reg|bitslip_sync_reg\[0\]|idelay_ld_sync_reg\[0\]|idelay_valuein_q_reg\[[0-9]+\]|reg_bit_width_q_reg\[[0-9]+\])/D}]
set_false_path -from $fh_pixel -to $fh_first

# The custom dual-clock RAM is read only after the Gray write pointer passes
# two synchronization stages and the empty test. Its data does not require
# the next /4-to-/5 phase edge. Bound same-family RAM data propagation to one
# write-clock period; do not except read-address or read-domain logic.
set fh_ramout [get_pins -hier -regexp {u_gmax_a_rx/u_training/loopi\[[0-9]+\]\.u_iserdes/u_fifo/mem_reg.*/(DO[A-Z][0-9]*|O)}]
set fh_dout [get_pins -hier -regexp {u_gmax_a_rx/u_training/loopi\[[0-9]+\]\.u_iserdes/u_fifo/dout_reg\[[0-9]+\]/D}]
set_max_delay -datapath_only 6.668 -from [get_clocks -of_objects [get_pins u_gmax_a_rx/u_training/u_gmax3412_iob_clock/BUFGCE0_DIV_inst/O]] -through $fh_ramout -to $fh_dout


# Per-FIFO Gray pointer skew bounds; unrolled for the XDC command subset.
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[0\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[0\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[0\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[0\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[1\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[1\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[1\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[1\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[2\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[2\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[2\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[2\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[3\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[3\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[3\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[3\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[4\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[4\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[4\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[4\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[5\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[5\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[5\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[5\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[6\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[6\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[6\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[6\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[7\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[7\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[7\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[7\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[8\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[8\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[8\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[8\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[9\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[9\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[9\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[9\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[10\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[10\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[10\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[10\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[11\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[11\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[11\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[11\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[12\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[12\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[12\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[12\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[13\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[13\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[13\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[13\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[14\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[14\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[14\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[14\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[15\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[15\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[15\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[15\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]

# Bound IDELAY data/load arrival spread below the extra destination pipeline delay.
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[0\]\[[0-9]+\]|idelay_ld_reg\[0\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[0\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[1\]\[[0-9]+\]|idelay_ld_reg\[1\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[1\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[2\]\[[0-9]+\]|idelay_ld_reg\[2\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[2\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[3\]\[[0-9]+\]|idelay_ld_reg\[3\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[3\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[4\]\[[0-9]+\]|idelay_ld_reg\[4\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[4\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[5\]\[[0-9]+\]|idelay_ld_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[5\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[6\]\[[0-9]+\]|idelay_ld_reg\[6\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[6\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[7\]\[[0-9]+\]|idelay_ld_reg\[7\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[7\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[8\]\[[0-9]+\]|idelay_ld_reg\[8\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[8\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[9\]\[[0-9]+\]|idelay_ld_reg\[9\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[9\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[10\]\[[0-9]+\]|idelay_ld_reg\[10\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[10\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[11\]\[[0-9]+\]|idelay_ld_reg\[11\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[11\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[12\]\[[0-9]+\]|idelay_ld_reg\[12\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[12\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[13\]\[[0-9]+\]|idelay_ld_reg\[13\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[13\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[14\]\[[0-9]+\]|idelay_ld_reg\[14\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[14\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_a_rx/u_training/(idelay_valuein_reg\[15\]\[[0-9]+\]|idelay_ld_reg\[15\])}] -to [get_cells -hier -regexp {u_gmax_a_rx/u_training/loopi\[15\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]

# ---------------------------------------------------------------------------
# PCIe reference-clock monitor
# ---------------------------------------------------------------------------
# M2_PCIE_REFCLK_SOM_100M is the primary 100 MHz PCIe reference clock.
# Explicit /2 matches IBUFDS_GTE4 REFCLK_HROW_CK_SEL=01.
# Avoid rename-only commands that fail during constraint reevaluation.
create_generated_clock -name pcie_refclk_odiv2 -source [get_ports M2_PCIE_REFCLK_SOM_P_0] -divide_by 2 \
    [get_pins {u_design_1_wrapper/design_1_i/fh_pcie_refclk_monit_0/inst/u_ibufds_gte4_pcie_refclk/ODIV2}]

# The 100 MHz primary and 50 MHz derivative remain related within one group.
# The complete PCIe reference-clock family is asynchronous to clk_pl_0.
set_clock_groups -name FH_ASYNC_PL_PCIE_REFCLK_FAMILY -asynchronous \
    -group [get_clocks {clk_pl_0}] \
    -group [get_clocks {M2_PCIE_REFCLK_SOM_100M pcie_refclk_odiv2}]

# sys_resetn is generated in the clk_pl_0 domain and intentionally drives the
# asynchronous assertion input of the first 50 MHz reset synchronizer stage.
# Deassertion is synchronized by the following stage.  Exclude only that first
# asynchronous CLR endpoint from recovery/removal timing.
set_false_path -to [get_pins -hierarchical -regexp {.*fh_pcie_refclk_monit_0.*/rst50_sync_reg\[0\]/CLR}]

# v24: DDR calibration crosses from the DDR UI clock into the 120 MHz scheduler.
# Only the first ASYNC_REG stage is excepted; the second stage remains timed.
set_false_path -to [get_pins -hier -regexp {.*gmax_pl_ring.*/calibrated_reg\[0\]/D}]
set_false_path -to [get_pins -hier -regexp {.*pl_ddr_dci_reset.*/lock_sync_reg\[0\]/D}]

# V25: DDR calibration enters the dual controller through its own two-flop synchronizer.
set_false_path -to [get_pins -hier -regexp {.*gmax_dual_ring.*/calibrated_reg\[0\]/D}]

# Bound the registered PCIe Gray-counter CDC bus.

set_bus_skew 10.000 -from [get_cells -hier -regexp {.*fh_pcie_refclk_monit_0/inst/u_pcie_gray_cdc/src_ff_reg\[[0-9]+\]}] -to [get_cells -hier -regexp {.*fh_pcie_refclk_monit_0/inst/u_pcie_gray_cdc/syncstages_ff_reg\[0\]\[[0-9]+\]}]

# GMAX-A receiver word clock and the same 16 lane words sampled by checker_inst.
# probeN is lane DN. List each bit LSB first to preserve the sensor word order.
create_debug_core ila_gmax_a_rx ila
set_property C_DATA_DEPTH 2048 [get_debug_cores ila_gmax_a_rx]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores ila_gmax_a_rx]
connect_debug_port ila_gmax_a_rx/clk [get_nets -of_objects [get_pins u_gmax_a_rx/u_training/u_gmax3412_iob_clock/BUFGCE_RXG_DIV5_inst/O]]
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe0]
connect_debug_port ila_gmax_a_rx/probe0 [get_nets [list \
    {u_gmax_a_rx/data_train[0]} {u_gmax_a_rx/data_train[1]} {u_gmax_a_rx/data_train[2]} {u_gmax_a_rx/data_train[3]} \
    {u_gmax_a_rx/data_train[4]} {u_gmax_a_rx/data_train[5]} {u_gmax_a_rx/data_train[6]} {u_gmax_a_rx/data_train[7]} \
    {u_gmax_a_rx/data_train[8]} {u_gmax_a_rx/data_train[9]} {u_gmax_a_rx/data_train[10]} {u_gmax_a_rx/data_train[11]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe1]
connect_debug_port ila_gmax_a_rx/probe1 [get_nets [list \
    {u_gmax_a_rx/data_train[12]} {u_gmax_a_rx/data_train[13]} {u_gmax_a_rx/data_train[14]} {u_gmax_a_rx/data_train[15]} \
    {u_gmax_a_rx/data_train[16]} {u_gmax_a_rx/data_train[17]} {u_gmax_a_rx/data_train[18]} {u_gmax_a_rx/data_train[19]} \
    {u_gmax_a_rx/data_train[20]} {u_gmax_a_rx/data_train[21]} {u_gmax_a_rx/data_train[22]} {u_gmax_a_rx/data_train[23]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe2]
connect_debug_port ila_gmax_a_rx/probe2 [get_nets [list \
    {u_gmax_a_rx/data_train[24]} {u_gmax_a_rx/data_train[25]} {u_gmax_a_rx/data_train[26]} {u_gmax_a_rx/data_train[27]} \
    {u_gmax_a_rx/data_train[28]} {u_gmax_a_rx/data_train[29]} {u_gmax_a_rx/data_train[30]} {u_gmax_a_rx/data_train[31]} \
    {u_gmax_a_rx/data_train[32]} {u_gmax_a_rx/data_train[33]} {u_gmax_a_rx/data_train[34]} {u_gmax_a_rx/data_train[35]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe3]
connect_debug_port ila_gmax_a_rx/probe3 [get_nets [list \
    {u_gmax_a_rx/data_train[36]} {u_gmax_a_rx/data_train[37]} {u_gmax_a_rx/data_train[38]} {u_gmax_a_rx/data_train[39]} \
    {u_gmax_a_rx/data_train[40]} {u_gmax_a_rx/data_train[41]} {u_gmax_a_rx/data_train[42]} {u_gmax_a_rx/data_train[43]} \
    {u_gmax_a_rx/data_train[44]} {u_gmax_a_rx/data_train[45]} {u_gmax_a_rx/data_train[46]} {u_gmax_a_rx/data_train[47]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe4]
connect_debug_port ila_gmax_a_rx/probe4 [get_nets [list \
    {u_gmax_a_rx/data_train[48]} {u_gmax_a_rx/data_train[49]} {u_gmax_a_rx/data_train[50]} {u_gmax_a_rx/data_train[51]} \
    {u_gmax_a_rx/data_train[52]} {u_gmax_a_rx/data_train[53]} {u_gmax_a_rx/data_train[54]} {u_gmax_a_rx/data_train[55]} \
    {u_gmax_a_rx/data_train[56]} {u_gmax_a_rx/data_train[57]} {u_gmax_a_rx/data_train[58]} {u_gmax_a_rx/data_train[59]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe5]
connect_debug_port ila_gmax_a_rx/probe5 [get_nets [list \
    {u_gmax_a_rx/data_train[60]} {u_gmax_a_rx/data_train[61]} {u_gmax_a_rx/data_train[62]} {u_gmax_a_rx/data_train[63]} \
    {u_gmax_a_rx/data_train[64]} {u_gmax_a_rx/data_train[65]} {u_gmax_a_rx/data_train[66]} {u_gmax_a_rx/data_train[67]} \
    {u_gmax_a_rx/data_train[68]} {u_gmax_a_rx/data_train[69]} {u_gmax_a_rx/data_train[70]} {u_gmax_a_rx/data_train[71]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe6]
connect_debug_port ila_gmax_a_rx/probe6 [get_nets [list \
    {u_gmax_a_rx/data_train[72]} {u_gmax_a_rx/data_train[73]} {u_gmax_a_rx/data_train[74]} {u_gmax_a_rx/data_train[75]} \
    {u_gmax_a_rx/data_train[76]} {u_gmax_a_rx/data_train[77]} {u_gmax_a_rx/data_train[78]} {u_gmax_a_rx/data_train[79]} \
    {u_gmax_a_rx/data_train[80]} {u_gmax_a_rx/data_train[81]} {u_gmax_a_rx/data_train[82]} {u_gmax_a_rx/data_train[83]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe7]
connect_debug_port ila_gmax_a_rx/probe7 [get_nets [list \
    {u_gmax_a_rx/data_train[84]} {u_gmax_a_rx/data_train[85]} {u_gmax_a_rx/data_train[86]} {u_gmax_a_rx/data_train[87]} \
    {u_gmax_a_rx/data_train[88]} {u_gmax_a_rx/data_train[89]} {u_gmax_a_rx/data_train[90]} {u_gmax_a_rx/data_train[91]} \
    {u_gmax_a_rx/data_train[92]} {u_gmax_a_rx/data_train[93]} {u_gmax_a_rx/data_train[94]} {u_gmax_a_rx/data_train[95]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe8]
connect_debug_port ila_gmax_a_rx/probe8 [get_nets [list \
    {u_gmax_a_rx/data_train[96]} {u_gmax_a_rx/data_train[97]} {u_gmax_a_rx/data_train[98]} {u_gmax_a_rx/data_train[99]} \
    {u_gmax_a_rx/data_train[100]} {u_gmax_a_rx/data_train[101]} {u_gmax_a_rx/data_train[102]} {u_gmax_a_rx/data_train[103]} \
    {u_gmax_a_rx/data_train[104]} {u_gmax_a_rx/data_train[105]} {u_gmax_a_rx/data_train[106]} {u_gmax_a_rx/data_train[107]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe9]
connect_debug_port ila_gmax_a_rx/probe9 [get_nets [list \
    {u_gmax_a_rx/data_train[108]} {u_gmax_a_rx/data_train[109]} {u_gmax_a_rx/data_train[110]} {u_gmax_a_rx/data_train[111]} \
    {u_gmax_a_rx/data_train[112]} {u_gmax_a_rx/data_train[113]} {u_gmax_a_rx/data_train[114]} {u_gmax_a_rx/data_train[115]} \
    {u_gmax_a_rx/data_train[116]} {u_gmax_a_rx/data_train[117]} {u_gmax_a_rx/data_train[118]} {u_gmax_a_rx/data_train[119]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe10]
connect_debug_port ila_gmax_a_rx/probe10 [get_nets [list \
    {u_gmax_a_rx/data_train[120]} {u_gmax_a_rx/data_train[121]} {u_gmax_a_rx/data_train[122]} {u_gmax_a_rx/data_train[123]} \
    {u_gmax_a_rx/data_train[124]} {u_gmax_a_rx/data_train[125]} {u_gmax_a_rx/data_train[126]} {u_gmax_a_rx/data_train[127]} \
    {u_gmax_a_rx/data_train[128]} {u_gmax_a_rx/data_train[129]} {u_gmax_a_rx/data_train[130]} {u_gmax_a_rx/data_train[131]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe11]
connect_debug_port ila_gmax_a_rx/probe11 [get_nets [list \
    {u_gmax_a_rx/data_train[132]} {u_gmax_a_rx/data_train[133]} {u_gmax_a_rx/data_train[134]} {u_gmax_a_rx/data_train[135]} \
    {u_gmax_a_rx/data_train[136]} {u_gmax_a_rx/data_train[137]} {u_gmax_a_rx/data_train[138]} {u_gmax_a_rx/data_train[139]} \
    {u_gmax_a_rx/data_train[140]} {u_gmax_a_rx/data_train[141]} {u_gmax_a_rx/data_train[142]} {u_gmax_a_rx/data_train[143]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe12]
connect_debug_port ila_gmax_a_rx/probe12 [get_nets [list \
    {u_gmax_a_rx/data_train[144]} {u_gmax_a_rx/data_train[145]} {u_gmax_a_rx/data_train[146]} {u_gmax_a_rx/data_train[147]} \
    {u_gmax_a_rx/data_train[148]} {u_gmax_a_rx/data_train[149]} {u_gmax_a_rx/data_train[150]} {u_gmax_a_rx/data_train[151]} \
    {u_gmax_a_rx/data_train[152]} {u_gmax_a_rx/data_train[153]} {u_gmax_a_rx/data_train[154]} {u_gmax_a_rx/data_train[155]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe13]
connect_debug_port ila_gmax_a_rx/probe13 [get_nets [list \
    {u_gmax_a_rx/data_train[156]} {u_gmax_a_rx/data_train[157]} {u_gmax_a_rx/data_train[158]} {u_gmax_a_rx/data_train[159]} \
    {u_gmax_a_rx/data_train[160]} {u_gmax_a_rx/data_train[161]} {u_gmax_a_rx/data_train[162]} {u_gmax_a_rx/data_train[163]} \
    {u_gmax_a_rx/data_train[164]} {u_gmax_a_rx/data_train[165]} {u_gmax_a_rx/data_train[166]} {u_gmax_a_rx/data_train[167]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe14]
connect_debug_port ila_gmax_a_rx/probe14 [get_nets [list \
    {u_gmax_a_rx/data_train[168]} {u_gmax_a_rx/data_train[169]} {u_gmax_a_rx/data_train[170]} {u_gmax_a_rx/data_train[171]} \
    {u_gmax_a_rx/data_train[172]} {u_gmax_a_rx/data_train[173]} {u_gmax_a_rx/data_train[174]} {u_gmax_a_rx/data_train[175]} \
    {u_gmax_a_rx/data_train[176]} {u_gmax_a_rx/data_train[177]} {u_gmax_a_rx/data_train[178]} {u_gmax_a_rx/data_train[179]}]]
create_debug_port ila_gmax_a_rx probe
set_property port_width 12 [get_debug_ports ila_gmax_a_rx/probe15]
connect_debug_port ila_gmax_a_rx/probe15 [get_nets [list \
    {u_gmax_a_rx/data_train[180]} {u_gmax_a_rx/data_train[181]} {u_gmax_a_rx/data_train[182]} {u_gmax_a_rx/data_train[183]} \
    {u_gmax_a_rx/data_train[184]} {u_gmax_a_rx/data_train[185]} {u_gmax_a_rx/data_train[186]} {u_gmax_a_rx/data_train[187]} \
    {u_gmax_a_rx/data_train[188]} {u_gmax_a_rx/data_train[189]} {u_gmax_a_rx/data_train[190]} {u_gmax_a_rx/data_train[191]}]]


set fh_pixel [get_clocks -of_objects [get_pins u_gmax_b_rx/u_training/u_gmax3412_iob_clock/BUFGCE_RXG_DIV5_inst/O]]
set fh_first [get_pins -hier -regexp {u_gmax_b_rx/u_training/loopi\[[0-9]+\]\.u_iserdes/(rst_iserdes_q_reg|bitslip_sync_reg\[0\]|idelay_ld_sync_reg\[0\]|idelay_valuein_q_reg\[[0-9]+\]|reg_bit_width_q_reg\[[0-9]+\])/D}]
set_false_path -from $fh_pixel -to $fh_first
set fh_ramout [get_pins -hier -regexp {u_gmax_b_rx/u_training/loopi\[[0-9]+\]\.u_iserdes/u_fifo/mem_reg.*/(DO[A-Z][0-9]*|O)}]
set fh_dout [get_pins -hier -regexp {u_gmax_b_rx/u_training/loopi\[[0-9]+\]\.u_iserdes/u_fifo/dout_reg\[[0-9]+\]/D}]
set_max_delay -datapath_only 6.668 -from [get_clocks -of_objects [get_pins u_gmax_b_rx/u_training/u_gmax3412_iob_clock/BUFGCE0_DIV_inst/O]] -through $fh_ramout -to $fh_dout
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[0\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[0\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[0\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[0\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[1\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[1\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[1\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[1\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[2\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[2\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[2\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[2\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[3\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[3\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[3\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[3\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[4\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[4\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[4\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[4\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[5\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[5\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[5\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[5\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[6\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[6\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[6\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[6\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[7\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[7\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[7\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[7\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[8\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[8\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[8\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[8\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[9\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[9\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[9\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[9\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[10\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[10\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[10\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[10\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[11\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[11\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[11\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[11\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[12\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[12\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[12\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[12\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[13\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[13\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[13\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[13\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[14\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[14\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[14\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[14\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[15\]\.u_iserdes/u_fifo/(wr_gray_reg\[[0-4]\]|wr_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[15\]\.u_iserdes/u_fifo/u_sync_wr_gray_to_rd/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[15\]\.u_iserdes/u_fifo/(rd_gray_reg\[[0-4]\]|rd_bin_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[15\]\.u_iserdes/u_fifo/u_sync_rd_gray_to_wr/syncstages_ff_reg\[0\]\[[0-9]+\]}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[0\]\[[0-9]+\]|idelay_ld_reg\[0\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[0\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[1\]\[[0-9]+\]|idelay_ld_reg\[1\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[1\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[2\]\[[0-9]+\]|idelay_ld_reg\[2\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[2\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[3\]\[[0-9]+\]|idelay_ld_reg\[3\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[3\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[4\]\[[0-9]+\]|idelay_ld_reg\[4\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[4\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[5\]\[[0-9]+\]|idelay_ld_reg\[5\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[5\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[6\]\[[0-9]+\]|idelay_ld_reg\[6\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[6\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[7\]\[[0-9]+\]|idelay_ld_reg\[7\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[7\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[8\]\[[0-9]+\]|idelay_ld_reg\[8\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[8\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[9\]\[[0-9]+\]|idelay_ld_reg\[9\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[9\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[10\]\[[0-9]+\]|idelay_ld_reg\[10\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[10\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[11\]\[[0-9]+\]|idelay_ld_reg\[11\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[11\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[12\]\[[0-9]+\]|idelay_ld_reg\[12\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[12\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[13\]\[[0-9]+\]|idelay_ld_reg\[13\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[13\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[14\]\[[0-9]+\]|idelay_ld_reg\[14\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[14\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
set_bus_skew 6.668 -from [get_cells -hier -regexp {u_gmax_b_rx/u_training/(idelay_valuein_reg\[15\]\[[0-9]+\]|idelay_ld_reg\[15\])}] -to [get_cells -hier -regexp {u_gmax_b_rx/u_training/loopi\[15\]\.u_iserdes/(idelay_valuein_q_reg\[[0-9]+\]|idelay_ld_sync_reg\[0\])}]
