view wave
add wave -divider {Two independent clocks: A=10ns, B=14ns}
add wave /tb_terminal_live/clk_a /tb_terminal_live/clk_b /tb_terminal_live/rst_n
add wave -divider {A to B - write at A, read at B}
add wave /tb_terminal_live/receive_b /tb_terminal_live/av /tb_terminal_live/at
add wave -radix hexadecimal /tb_terminal_live/ad
add wave /tb_terminal_live/af
add wave -radix unsigned /tb_terminal_live/atu
add wave /tb_terminal_live/bx /tb_terminal_live/br
add wave -radix hexadecimal /tb_terminal_live/bq
add wave -radix unsigned /tb_terminal_live/dut/u_ab/wr_bin /tb_terminal_live/dut/u_ab/rd_bin
add wave -radix binary /tb_terminal_live/dut/u_ab/wr_gray /tb_terminal_live/dut/u_ab/rd_gray
add wave -radix binary /tb_terminal_live/dut/u_ab/wr_gray_sync /tb_terminal_live/dut/u_ab/rd_gray_sync
add wave -divider {B to A - write at B, read at A}
add wave /tb_terminal_live/receive_a /tb_terminal_live/bv /tb_terminal_live/bt
add wave -radix hexadecimal /tb_terminal_live/bd
add wave /tb_terminal_live/bf
add wave -radix unsigned /tb_terminal_live/btu
add wave /tb_terminal_live/ax /tb_terminal_live/ar
add wave -radix hexadecimal /tb_terminal_live/aq
add wave -radix unsigned /tb_terminal_live/dut/u_ba/wr_bin /tb_terminal_live/dut/u_ba/rd_bin
add wave -radix binary /tb_terminal_live/dut/u_ba/wr_gray /tb_terminal_live/dut/u_ba/rd_gray
add wave -radix binary /tb_terminal_live/dut/u_ba/wr_gray_sync /tb_terminal_live/dut/u_ba/rd_gray_sync
configure wave -namecolwidth 340
configure wave -valuecolwidth 110
configure wave -timelineunits ns
wave zoom full
