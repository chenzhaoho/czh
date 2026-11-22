# wave_view_a.do -- A 通道波形观察配置（在 ModelSim Transcript 里执行）
# 用法:  do wave_view_a.do
#
# 说明: 只加"能说明设计正确"的关键信号, 并且按功能分组、指定显示格式,
#       避免一次加几百个信号看不出重点。

delete wave *

add wave -divider "1. CLOCKS   A: wr=10ns rd=6ns | B: wr=14ns rd=4ns | mon=5ns"
add wave -radix binary /tb_top/h/wr_clk_a
add wave -radix binary /tb_top/h/rd_clk_a
add wave -radix binary /tb_top/h/wr_clk_b
add wave -radix binary /tb_top/h/rd_clk_b
add wave -radix binary /tb_top/h/clk_mon

add wave -divider "2. RESET   async assert / sync release (must lag 2 clocks)"
add wave -radix binary /tb_top/h/rst_n_async
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/u_rst_sync_wr/rst_n_sync
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/u_rst_sync_rd/rst_n_sync

add wave -divider "3. POINTERS   binary count vs gray code"
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_bin
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_bin
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_gray
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_gray

add wave -divider "4. CDC SYNC   gray crossing the clock boundary"
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_gray_sync
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_bin_sync
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_gray_sync
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_bin_sync

add wave -divider "5. OCCUPANCY + FLAGS   full=256 almost_full 224/222"
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_occupancy_r
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_occupancy_r
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_full
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_empty
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_almost_full
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_almost_empty

add wave -divider "6. HANDSHAKE + EVENTS"
add wave -radix binary /tb_top/h/wr_valid_a
add wave -radix binary /tb_top/h/wr_ready_a
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_fire
add wave -radix binary /tb_top/h/rd_en_a
add wave -radix binary /tb_top/h/rd_ready_a
add wave -radix binary /tb_top/h/rd_valid_a
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_pop
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/ovf_try
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/unf_try
add wave -radix binary /tb_top/h/u_dut/u_fifo_a/u_fifo/bp_cyc

add wave -divider "7. DATA PATH + ERROR COUNTERS"
add wave -radix hex /tb_top/h/wr_data_a
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_addr
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_addr
add wave -radix hex /tb_top/h/u_dut/u_fifo_a/u_fifo/rd_data
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/u_fifo/wr_event_cnt
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/overflow_cnt
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/underflow_cnt
add wave -radix unsigned /tb_top/h/u_dut/u_fifo_a/backpressure_cnt

configure wave -namecolwidth 250
configure wave -signalnamewidth 1
configure wave -timelineunits ns
wave zoom full
echo "wave_view_a.do loaded -- see the 7 groups in the Wave window"
