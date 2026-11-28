# Scoped to one IP instance. Discover the clocks on the synthesized register
# pins, which also works when the IP boundary clock ports were renamed.
set duplex_a_q [get_cells -hier -regexp {(.*/)?(u_ab/wr|u_ba/rd)_gray_reg\[[0-9]+\]}]
set duplex_b_q [get_cells -hier -regexp {(.*/)?(u_ab/rd|u_ba/wr)_gray_reg\[[0-9]+\]}]
set duplex_a_c [get_pins -of_objects $duplex_a_q -filter {REF_PIN_NAME == C}]
set duplex_b_c [get_pins -of_objects $duplex_b_q -filter {REF_PIN_NAME == C}]
set duplex_clka [get_clocks -of_objects $duplex_a_c]
set duplex_clkb [get_clocks -of_objects $duplex_b_c]
# One pin can carry multiple timing clocks. Use the shortest possible period,
# and keep the full clock collections for bounding the RAM read paths below.
set duplex_ta [get_property -min PERIOD $duplex_clka]
set duplex_tb [get_property -min PERIOD $duplex_clkb]
set duplex_budget [expr {min($duplex_ta,$duplex_tb)}]

set ab_wr_q [get_cells -hier -regexp {(.*/)?u_ab/wr_gray_reg\[[0-9]+\]}]
set ab_rd_q [get_cells -hier -regexp {(.*/)?u_ab/rd_gray_reg\[[0-9]+\]}]
set ba_wr_q [get_cells -hier -regexp {(.*/)?u_ba/wr_gray_reg\[[0-9]+\]}]
set ba_rd_q [get_cells -hier -regexp {(.*/)?u_ba/rd_gray_reg\[[0-9]+\]}]
set ab_wr_d [get_pins -of_objects [get_cells -hier -regexp {(.*/)?u_ab/u_sync_wr_ptr/sync_chain_reg\[0\]\[[0-9]+\]}] -filter {REF_PIN_NAME == D}]
set ab_rd_d [get_pins -of_objects [get_cells -hier -regexp {(.*/)?u_ab/u_sync_rd_ptr/sync_chain_reg\[0\]\[[0-9]+\]}] -filter {REF_PIN_NAME == D}]
set ba_wr_d [get_pins -of_objects [get_cells -hier -regexp {(.*/)?u_ba/u_sync_wr_ptr/sync_chain_reg\[0\]\[[0-9]+\]}] -filter {REF_PIN_NAME == D}]
set ba_rd_d [get_pins -of_objects [get_cells -hier -regexp {(.*/)?u_ba/u_sync_rd_ptr/sync_chain_reg\[0\]\[[0-9]+\]}] -filter {REF_PIN_NAME == D}]

set_max_delay -datapath_only $duplex_budget -from $ab_wr_q -to $ab_wr_d
set_max_delay -datapath_only $duplex_budget -from $ab_rd_q -to $ab_rd_d
set_max_delay -datapath_only $duplex_budget -from $ba_wr_q -to $ba_wr_d
set_max_delay -datapath_only $duplex_budget -from $ba_rd_q -to $ba_rd_d
set_bus_skew $duplex_budget -from $ab_wr_q -to $ab_wr_d
set_bus_skew $duplex_budget -from $ab_rd_q -to $ab_rd_d
set_bus_skew $duplex_budget -from $ba_wr_q -to $ba_wr_d
set_bus_skew $duplex_budget -from $ba_rd_q -to $ba_rd_d

# Limit paths launched by the write clock through each RAM to the reader.
# The synchronous BRAM output is launched by its read clock and stays timed
# as a local path. In FWFT mode this exception bounds the LUTRAM data crossing.
set ab_mem [get_cells -hier -filter {NAME =~ *u_ab/mem_reg* && (REF_NAME =~ RAMD* || REF_NAME =~ RAMS* || REF_NAME =~ RAMB*) && IS_PRIMITIVE}]
set ba_mem [get_cells -hier -filter {NAME =~ *u_ba/mem_reg* && (REF_NAME =~ RAMD* || REF_NAME =~ RAMS* || REF_NAME =~ RAMB*) && IS_PRIMITIVE}]
set ab_data [get_pins -of_objects $ab_mem -filter {DIRECTION == OUT}]
set ba_data [get_pins -of_objects $ba_mem -filter {DIRECTION == OUT}]
set_max_delay -datapath_only $duplex_budget -from $duplex_clka -through $ab_data -to $duplex_clkb
set_max_delay -datapath_only $duplex_budget -from $duplex_clkb -through $ba_data -to $duplex_clka
