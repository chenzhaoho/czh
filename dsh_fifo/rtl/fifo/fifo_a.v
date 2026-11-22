//=============================================================================
// File        : fifo_a.v
// Module      : fifo_a
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 通道 A 包装层。32 bit x 256 异步 FIFO，读:写 = 5:3。
//               只做参数固化与端口绑定，不含任何独立逻辑；时钟由顶层接入
//               (建议 wr_clk 10 ns / rd_clk 6 ns，即 f_rd:f_wr = 5:3)。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module fifo_a #(
    parameter integer DW           = 32,
    parameter integer AW           = 8,
    parameter integer SYNC_STAGES  = 2,
    parameter integer CNT_W        = 32,
    parameter integer READ_MODE   = 0        // 0=FWFT(组合读) 1=Standard(同步读)
) (
    input  wire              rst_n_async,
    // 写时钟域
    input  wire              wr_clk,
    input  wire              wr_valid,
    input  wire [DW-1:0]     wr_data,
    output wire              wr_ready,
    output wire              wr_full,
    output wire              full_check,
    output wire              wr_almost_full,
    output wire [DW-1:0]     wr_data_committed,
    output wire              wr_data_valid,
    output wire [CNT_W-1:0]  wr_event_cnt,
    output wire [CNT_W-1:0]  overflow_cnt,
    output wire [CNT_W-1:0]  overflow_flag_cnt,
    output wire [AW:0]       wr_used_dbg,
    // 读时钟域
    input  wire              rd_clk,
    input  wire              rd_en,
    input  wire              rd_ready,
    output wire [DW-1:0]     rd_data,
    output wire              rd_valid,
    output wire              rd_data_valid,       // READ_MODE=1 时数据晚一拍, 由它指示
    output wire              rd_empty,
    output wire              rd_almost_empty,
    output wire [CNT_W-1:0]  rd_event_cnt,
    output wire [CNT_W-1:0]  underflow_cnt,
    output wire [CNT_W-1:0]  underflow_flag_cnt,
    output wire [CNT_W-1:0]  backpressure_cnt,
    output wire              backpressure_active,
    output wire [AW:0]       rd_used_dbg,
    // 监控时钟域
    input  wire              clk_mon,
    input  wire              rst_n_mon,
    output wire [CNT_W-1:0]  wr_event_cnt_sync,
    output wire [CNT_W-1:0]  rd_event_cnt_sync,
    output wire [CNT_W-1:0]  overflow_cnt_sync,
    output wire [CNT_W-1:0]  underflow_cnt_sync,
    output wire [CNT_W-1:0]  backpressure_cnt_sync,
    output wire [AW:0]       used_sync,
    output wire              full_sync,
    output wire              almost_full_sync,
    output wire              empty_sync,
    output wire              almost_empty_sync
);

    async_fifo #(
        .AW              (AW),
        .DW              (DW),
        .SYNC_STAGES     (SYNC_STAGES),
        .READ_MODE       (READ_MODE),
        .ALMOST_FULL_TH  (224),   // 7/8 x 256
        .ALMOST_EMPTY_TH (32),    // 1/8 x 256
        .DEADBAND        (2),
        .CNT_W           (CNT_W)
    ) u_fifo (
        .rst_n_async            (rst_n_async),
        .wr_clk                 (wr_clk),
        .wr_valid               (wr_valid),
        .wr_data                (wr_data),
        .wr_ready               (wr_ready),
        .wr_full                (wr_full),
        .full_check             (full_check),
        .wr_almost_full         (wr_almost_full),
        .wr_data_committed      (wr_data_committed),
        .wr_data_valid          (wr_data_valid),
        .wr_event_cnt           (wr_event_cnt),
        .overflow_cnt           (overflow_cnt),
        .overflow_flag_cnt      (overflow_flag_cnt),
        .wr_used_dbg            (wr_used_dbg),
        .rd_clk                 (rd_clk),
        .rd_en                  (rd_en),
        .rd_ready               (rd_ready),
        .rd_data                (rd_data),
        .rd_valid               (rd_valid),
        .rd_data_valid          (rd_data_valid),
        .rd_empty               (rd_empty),
        .rd_almost_empty        (rd_almost_empty),
        .rd_event_cnt           (rd_event_cnt),
        .underflow_cnt          (underflow_cnt),
        .underflow_flag_cnt     (underflow_flag_cnt),
        .backpressure_cnt       (backpressure_cnt),
        .backpressure_active    (backpressure_active),
        .rd_used_dbg            (rd_used_dbg),
        .clk_mon                (clk_mon),
        .rst_n_mon              (rst_n_mon),
        .wr_event_cnt_sync      (wr_event_cnt_sync),
        .rd_event_cnt_sync      (rd_event_cnt_sync),
        .overflow_cnt_sync      (overflow_cnt_sync),
        .underflow_cnt_sync     (underflow_cnt_sync),
        .backpressure_cnt_sync  (backpressure_cnt_sync),
        .used_sync              (used_sync),
        .full_sync              (full_sync),
        .almost_full_sync       (almost_full_sync),
        .empty_sync             (empty_sync),
        .almost_empty_sync      (almost_empty_sync)
    );

endmodule

`default_nettype wire
