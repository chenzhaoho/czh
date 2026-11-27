# Standalone OOC synthesis defaults. The consumer supplies its actual clocks.
create_clock -name clk_a -period 10.000 [get_ports clk_a]
create_clock -name clk_b -period 14.000 [get_ports clk_b]
