// Two independent, opposite-direction CDC queues. Status is local to its port.
`timescale 1ns / 1ps
`default_nettype none
module dual_fifo_link #(
    parameter integer AW = 8,
    parameter integer DW = 32,
    parameter integer SYNC_STAGES = 2,
    parameter integer READ_MODE = 0  // 0: FWFT using LUTRAM, 1: synchronous read using BRAM
) (
    input wire clk_a, clk_b, rst_n_async,
    input wire a_tx_valid,
    output wire a_tx_ready,
    input wire [DW-1:0] a_tx_data,
    output wire a_rx_valid,
    input wire a_rx_ready,
    output wire [DW-1:0] a_rx_data,
    input wire b_tx_valid,
    output wire b_tx_ready,
    input wire [DW-1:0] b_tx_data,
    output wire b_rx_valid,
    input wire b_rx_ready,
    output wire [DW-1:0] b_rx_data,
    output wire a_tx_full, b_tx_full,
    output wire [AW:0] a_tx_used, b_tx_used, a_rx_used, b_rx_used
);
    // The course top also uses the core's synchronous request/response mode.
    // This link always presents a ready/valid data stream.
    localparam integer FIFO_READ_MODE = READ_MODE == 1 ? 2 : 0;

    wire rst_a, rst_b, ab_ready, ba_ready, ab_valid, ba_valid;
    rst_sync #(.STAGES(SYNC_STAGES)) u_rst_a
        (.clk(clk_a), .rst_n_async(rst_n_async), .rst_n_sync(rst_a));
    rst_sync #(.STAGES(SYNC_STAGES)) u_rst_b
        (.clk(clk_b), .rst_n_async(rst_n_async), .rst_n_sync(rst_b));
    assign a_tx_ready = rst_a & ab_ready;
    assign b_tx_ready = rst_b & ba_ready;
    assign a_rx_valid = rst_a & ba_valid;
    assign b_rx_valid = rst_b & ab_valid;

    // A held valid during backpressure is legal, not an overflow attempt.
    async_fifo #(.AW(AW), .DW(DW), .SYNC_STAGES(SYNC_STAGES),
        .ALMOST_FULL_TH(7*(1<<AW)/8), .ALMOST_EMPTY_TH((1<<AW)/8),
        .DEADBAND(2), .READ_MODE(FIFO_READ_MODE)) u_ab (
        .rst_n_async(rst_n_async), .wr_clk(clk_a),
        .wr_valid(a_tx_valid & a_tx_ready), .wr_data(a_tx_data),
        .wr_ready(ab_ready), .wr_full(a_tx_full), .wr_used_dbg(a_tx_used),
        .rd_clk(clk_b), .rd_en(b_rx_valid), .rd_ready(b_rx_ready),
        .rd_data(b_rx_data), .rd_valid(ab_valid), .rd_used_dbg(b_rx_used),
        .clk_mon(clk_a), .rst_n_mon(rst_a),
        .full_check(), .wr_almost_full(), .wr_data_committed(), .wr_data_valid(),
        .wr_event_cnt(), .overflow_cnt(), .overflow_flag_cnt(),
        .rd_data_valid(), .rd_empty(), .rd_almost_empty(), .rd_event_cnt(),
        .underflow_cnt(), .underflow_flag_cnt(), .backpressure_cnt(), .backpressure_active(),
        .wr_event_cnt_sync(), .rd_event_cnt_sync(), .overflow_cnt_sync(),
        .underflow_cnt_sync(), .backpressure_cnt_sync(), .used_sync(),
        .full_sync(), .almost_full_sync(), .empty_sync(), .almost_empty_sync()
    );
    async_fifo #(.AW(AW), .DW(DW), .SYNC_STAGES(SYNC_STAGES),
        .ALMOST_FULL_TH(7*(1<<AW)/8), .ALMOST_EMPTY_TH((1<<AW)/8),
        .DEADBAND(2), .READ_MODE(FIFO_READ_MODE)) u_ba (
        .rst_n_async(rst_n_async), .wr_clk(clk_b),
        .wr_valid(b_tx_valid & b_tx_ready), .wr_data(b_tx_data),
        .wr_ready(ba_ready), .wr_full(b_tx_full), .wr_used_dbg(b_tx_used),
        .rd_clk(clk_a), .rd_en(a_rx_valid), .rd_ready(a_rx_ready),
        .rd_data(a_rx_data), .rd_valid(ba_valid), .rd_used_dbg(a_rx_used),
        .clk_mon(clk_b), .rst_n_mon(rst_b),
        .full_check(), .wr_almost_full(), .wr_data_committed(), .wr_data_valid(),
        .wr_event_cnt(), .overflow_cnt(), .overflow_flag_cnt(),
        .rd_data_valid(), .rd_empty(), .rd_almost_empty(), .rd_event_cnt(),
        .underflow_cnt(), .underflow_flag_cnt(), .backpressure_cnt(), .backpressure_active(),
        .wr_event_cnt_sync(), .rd_event_cnt_sync(), .overflow_cnt_sync(),
        .underflow_cnt_sync(), .backpressure_cnt_sync(), .used_sync(),
        .full_sync(), .almost_full_sync(), .empty_sync(), .almost_empty_sync()
    );
endmodule
`default_nettype wire
