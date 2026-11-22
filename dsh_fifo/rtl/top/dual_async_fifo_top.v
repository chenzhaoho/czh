//=============================================================================
// File        : dual_async_fifo_top.v
// Module      : dual_async_fifo_top
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 双异步 FIFO 顶层。
//   +-------------------------------------------------------------+
//   |  dual_async_fifo_top                                        |
//   |   +-----------+     +-----------+     +------------------+  |
//   |   |  fifo_a   |---->|           |---->|                  |  |
//   |   | 32x256    |     |  monitor  |     |  统一状态接口     |  |
//   |   | 5:3       |---->| (clk_mon) |---->|  status/counters |  |
//   |   +-----------+     |           |     +------------------+  |
//   |   +-----------+     |           |                           |
//   |   |  fifo_b   |---->|           |                           |
//   |   | 32x256    |     |           |                           |
//   |   | 7:2       |     |           |                           |
//   |   +-----------+     +-----------+                           |
//   +-------------------------------------------------------------+
//   四个独立时钟域: wr_clk_a / rd_clk_a / wr_clk_b / rd_clk_b，
//   监控时钟 clk_mon 独立，仅用于统一状态输出与跨域采样。
//   两通道之间没有任何共享逻辑，只共享同一套参数化 RTL。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module dual_async_fifo_top #(
    parameter integer DW          = 32,
    parameter integer AW          = 8,
    parameter integer CNT_W       = 32,
    parameter integer SYNC_STAGES = 2,
    parameter integer READ_MODE     = 0,   // 0=组合读(FWFT) 1=同步读(可用 BRAM)
    // 时钟周期参数 (ps)，仅用于监控模块的理想吞吐计算
    parameter integer T_WR_A_PS   = 10000,
    parameter integer T_RD_A_PS   = 6000,
    parameter integer T_WR_B_PS   = 14000,
    parameter integer T_RD_B_PS   = 4000,
    parameter integer T_MON_PS    = 5000
) (
    //-------------------------------------------------------------- 复位
    input  wire              rst_n_async,
    //------------------------------------------------ 通道 A 写时钟域 (3)
    input  wire              wr_clk_a,
    input  wire              wr_valid_a,
    input  wire [DW-1:0]     wr_data_a,
    output wire              wr_ready_a,
    output wire              wr_full_a,
    output wire              full_check_a,
    output wire              wr_almost_full_a,
    output wire [DW-1:0]     wr_data_committed_a,
    output wire              wr_data_valid_a,
    output wire [CNT_W-1:0]  a_wr_event_cnt,
    output wire [CNT_W-1:0]  a_overflow_cnt,
    output wire [CNT_W-1:0]  a_overflow_flag_cnt,
    //------------------------------------------------ 通道 A 读时钟域 (5)
    input  wire              rd_clk_a,
    input  wire              rd_en_a,
    input  wire              rd_ready_a,
    output wire [DW-1:0]     rd_data_a,
    output wire              rd_valid_a,
    output wire              rd_data_valid_a,  // 同步读模式下数据有效指示
    output wire              rd_empty_a,
    output wire              rd_almost_empty_a,
    output wire [CNT_W-1:0]  a_rd_event_cnt,
    output wire [CNT_W-1:0]  a_underflow_cnt,
    output wire [CNT_W-1:0]  a_underflow_flag_cnt,
    output wire [CNT_W-1:0]  a_backpressure_cnt,
    output wire              a_backpressure_active,
    //------------------------------------------------ 通道 B 写时钟域 (3)
    input  wire              wr_clk_b,
    input  wire              wr_valid_b,
    input  wire [DW-1:0]     wr_data_b,
    output wire              wr_ready_b,
    output wire              wr_full_b,
    output wire              full_check_b,
    output wire              wr_almost_full_b,
    output wire [DW-1:0]     wr_data_committed_b,
    output wire              wr_data_valid_b,
    output wire [CNT_W-1:0]  b_wr_event_cnt,
    output wire [CNT_W-1:0]  b_overflow_cnt,
    output wire [CNT_W-1:0]  b_overflow_flag_cnt,
    //------------------------------------------------ 通道 B 读时钟域 (7)
    input  wire              rd_clk_b,
    input  wire              rd_en_b,
    input  wire              rd_ready_b,
    output wire [DW-1:0]     rd_data_b,
    output wire              rd_valid_b,
    output wire              rd_data_valid_b,  // 同步读模式下数据有效指示
    output wire              rd_empty_b,
    output wire              rd_almost_empty_b,
    output wire [CNT_W-1:0]  b_rd_event_cnt,
    output wire [CNT_W-1:0]  b_underflow_cnt,
    output wire [CNT_W-1:0]  b_underflow_flag_cnt,
    output wire [CNT_W-1:0]  b_backpressure_cnt,
    output wire              b_backpressure_active,
    //------------------------------------------------ 监控时钟域 clk_mon
    input  wire              clk_mon,
    output wire [2:0]        mon_a_status,
    output wire [2:0]        mon_b_status,
    output wire [5:0]        mon_status_word,
    output wire              mon_a_full,
    output wire              mon_a_almost_full,
    output wire              mon_a_empty,
    output wire              mon_a_almost_empty,
    output wire [AW:0]       a_used_wr_est,
    output wire [AW:0]       a_used_rd_est,
    output wire [AW:0]       b_used_wr_est,
    output wire [AW:0]       b_used_rd_est,
    output wire [AW:0]       mon_a_used,
    output wire [CNT_W-1:0]  mon_a_wr_cnt,
    output wire [CNT_W-1:0]  mon_a_rd_cnt,
    output wire [CNT_W-1:0]  mon_a_ovf_cnt,
    output wire [CNT_W-1:0]  mon_a_unf_cnt,
    output wire [CNT_W-1:0]  mon_a_bp_cnt,
    output wire              mon_b_full,
    output wire              mon_b_almost_full,
    output wire              mon_b_empty,
    output wire              mon_b_almost_empty,
    output wire [AW:0]       mon_b_used,
    output wire [CNT_W-1:0]  mon_b_wr_cnt,
    output wire [CNT_W-1:0]  mon_b_rd_cnt,
    output wire [CNT_W-1:0]  mon_b_ovf_cnt,
    output wire [CNT_W-1:0]  mon_b_unf_cnt,
    output wire [CNT_W-1:0]  mon_b_bp_cnt,
    output wire [CNT_W-1:0]  mon_total_err_cnt,
    output wire              mon_any_full,
    output wire              mon_any_empty,
    output wire              mon_both_almost_full,
    output wire              mon_both_almost_empty,
    output wire              mon_any_backpressure,
    output wire [CNT_W-1:0]  mon_bp_event_cnt,
    output wire [31:0]       mon_latency_ns,
    output wire [31:0]       mon_latency_cycles,
    output wire [31:0]       mon_a_ideal_max_wr_words,
    output wire [31:0]       mon_b_ideal_max_wr_words,
    output wire              mon_status_valid
);
    //=====================================================================
    // 1. 监控时钟域复位同步释放
    //=====================================================================
    wire rst_n_mon;
    rst_sync #(.STAGES(SYNC_STAGES)) u_rst_sync_mon (
        .clk         (clk_mon),
        .rst_n_async (rst_n_async),
        .rst_n_sync  (rst_n_mon)
    );

    //=====================================================================
    // 2. 通道 A / 通道 B 例化 (同一套参数化 RTL，状态完全独立)
    //=====================================================================
    wire [CNT_W-1:0] a_wr_cnt_sync, a_rd_cnt_sync, a_ovf_cnt_sync;
    wire [CNT_W-1:0] a_unf_cnt_sync, a_bp_cnt_sync;
    wire [AW:0]      a_used_sync;
    wire             a_full_sync, a_af_sync, a_empty_sync, a_ae_sync;

    wire [AW:0] a_wr_used_dbg, a_rd_used_dbg, b_wr_used_dbg, b_rd_used_dbg;

    fifo_a #(
        .DW(DW), .AW(AW), .SYNC_STAGES(SYNC_STAGES), .CNT_W(CNT_W), .READ_MODE(READ_MODE)
    ) u_fifo_a (
        .rst_n_async           (rst_n_async),
        .wr_clk                (wr_clk_a),
        .wr_valid              (wr_valid_a),
        .wr_data               (wr_data_a),
        .wr_ready              (wr_ready_a),
        .wr_full               (wr_full_a),
        .full_check            (full_check_a),
        .wr_almost_full        (wr_almost_full_a),
        .wr_data_committed     (wr_data_committed_a),
        .wr_data_valid         (wr_data_valid_a),
        .wr_event_cnt          (a_wr_event_cnt),
        .overflow_cnt          (a_overflow_cnt),
        .overflow_flag_cnt     (a_overflow_flag_cnt),
        .wr_used_dbg           (a_wr_used_dbg),
        .rd_clk                (rd_clk_a),
        .rd_en                 (rd_en_a),
        .rd_ready              (rd_ready_a),
        .rd_data               (rd_data_a),
        .rd_valid              (rd_valid_a),
        .rd_data_valid          (rd_data_valid_a),
        .rd_empty              (rd_empty_a),
        .rd_almost_empty       (rd_almost_empty_a),
        .rd_event_cnt          (a_rd_event_cnt),
        .underflow_cnt         (a_underflow_cnt),
        .underflow_flag_cnt    (a_underflow_flag_cnt),
        .backpressure_cnt      (a_backpressure_cnt),
        .backpressure_active   (a_backpressure_active),
        .rd_used_dbg           (a_rd_used_dbg),
        .clk_mon               (clk_mon),
        .rst_n_mon             (rst_n_mon),
        .wr_event_cnt_sync     (a_wr_cnt_sync),
        .rd_event_cnt_sync     (a_rd_cnt_sync),
        .overflow_cnt_sync     (a_ovf_cnt_sync),
        .underflow_cnt_sync    (a_unf_cnt_sync),
        .backpressure_cnt_sync (a_bp_cnt_sync),
        .used_sync             (a_used_sync),
        .full_sync             (a_full_sync),
        .almost_full_sync      (a_af_sync),
        .empty_sync            (a_empty_sync),
        .almost_empty_sync     (a_ae_sync)
    );

    wire [CNT_W-1:0] b_wr_cnt_sync, b_rd_cnt_sync, b_ovf_cnt_sync;
    wire [CNT_W-1:0] b_unf_cnt_sync, b_bp_cnt_sync;
    wire [AW:0]      b_used_sync;
    wire             b_full_sync, b_af_sync, b_empty_sync, b_ae_sync;

    fifo_b #(
        .DW(DW), .AW(AW), .SYNC_STAGES(SYNC_STAGES), .CNT_W(CNT_W), .READ_MODE(READ_MODE)
    ) u_fifo_b (
        .rst_n_async           (rst_n_async),
        .wr_clk                (wr_clk_b),
        .wr_valid              (wr_valid_b),
        .wr_data               (wr_data_b),
        .wr_ready              (wr_ready_b),
        .wr_full               (wr_full_b),
        .full_check            (full_check_b),
        .wr_almost_full        (wr_almost_full_b),
        .wr_data_committed     (wr_data_committed_b),
        .wr_data_valid         (wr_data_valid_b),
        .wr_event_cnt          (b_wr_event_cnt),
        .overflow_cnt          (b_overflow_cnt),
        .overflow_flag_cnt     (b_overflow_flag_cnt),
        .wr_used_dbg           (b_wr_used_dbg),
        .rd_clk                (rd_clk_b),
        .rd_en                 (rd_en_b),
        .rd_ready              (rd_ready_b),
        .rd_data               (rd_data_b),
        .rd_valid              (rd_valid_b),
        .rd_data_valid          (rd_data_valid_b),
        .rd_empty              (rd_empty_b),
        .rd_almost_empty       (rd_almost_empty_b),
        .rd_event_cnt          (b_rd_event_cnt),
        .underflow_cnt         (b_underflow_cnt),
        .underflow_flag_cnt    (b_underflow_flag_cnt),
        .backpressure_cnt      (b_backpressure_cnt),
        .backpressure_active   (b_backpressure_active),
        .rd_used_dbg           (b_rd_used_dbg),
        .clk_mon               (clk_mon),
        .rst_n_mon             (rst_n_mon),
        .wr_event_cnt_sync     (b_wr_cnt_sync),
        .rd_event_cnt_sync     (b_rd_cnt_sync),
        .overflow_cnt_sync     (b_ovf_cnt_sync),
        .underflow_cnt_sync    (b_unf_cnt_sync),
        .backpressure_cnt_sync (b_bp_cnt_sync),
        .used_sync             (b_used_sync),
        .full_sync             (b_full_sync),
        .almost_full_sync      (b_af_sync),
        .empty_sync            (b_empty_sync),
        .almost_empty_sync     (b_ae_sync)
    );

    //=====================================================================
    // 3. 统一监控模块
    //=====================================================================
    monitor #(
        .AW(AW), .CNT_W(CNT_W), .SYNC_STAGES(SYNC_STAGES),
        .T_WR_A_PS(T_WR_A_PS), .T_RD_A_PS(T_RD_A_PS),
        .T_WR_B_PS(T_WR_B_PS), .T_RD_B_PS(T_RD_B_PS), .T_MON_PS(T_MON_PS)
    ) u_monitor (
        .clk_mon               (clk_mon),
        .rst_n_mon             (rst_n_mon),
        .a_wr_event_cnt        (a_wr_cnt_sync),
        .a_rd_event_cnt        (a_rd_cnt_sync),
        .a_overflow_cnt        (a_ovf_cnt_sync),
        .a_underflow_cnt       (a_unf_cnt_sync),
        .a_backpressure_cnt    (a_bp_cnt_sync),
        .a_bp_active           (a_backpressure_active),
        .a_used                (a_used_sync),
        .a_full                (a_full_sync),
        .a_almost_full         (a_af_sync),
        .a_empty               (a_empty_sync),
        .a_almost_empty        (a_ae_sync),
        .b_wr_event_cnt        (b_wr_cnt_sync),
        .b_rd_event_cnt        (b_rd_cnt_sync),
        .b_overflow_cnt        (b_ovf_cnt_sync),
        .b_underflow_cnt       (b_unf_cnt_sync),
        .b_backpressure_cnt    (b_bp_cnt_sync),
        .b_bp_active           (b_backpressure_active),
        .b_used                (b_used_sync),
        .b_full                (b_full_sync),
        .b_almost_full         (b_af_sync),
        .b_empty               (b_empty_sync),
        .b_almost_empty        (b_ae_sync),
        .a_status              (mon_a_status),
        .b_status              (mon_b_status),
        .status_word           (mon_status_word),
        .a_full_o              (mon_a_full),
        .a_almost_full_o       (mon_a_almost_full),
        .a_empty_o             (mon_a_empty),
        .a_almost_empty_o      (mon_a_almost_empty),
        .a_used_o              (mon_a_used),
        .a_wr_cnt_o            (mon_a_wr_cnt),
        .a_rd_cnt_o            (mon_a_rd_cnt),
        .a_ovf_cnt_o           (mon_a_ovf_cnt),
        .a_unf_cnt_o           (mon_a_unf_cnt),
        .a_bp_cnt_o            (mon_a_bp_cnt),
        .b_full_o              (mon_b_full),
        .b_almost_full_o       (mon_b_almost_full),
        .b_empty_o             (mon_b_empty),
        .b_almost_empty_o      (mon_b_almost_empty),
        .b_used_o              (mon_b_used),
        .b_wr_cnt_o            (mon_b_wr_cnt),
        .b_rd_cnt_o            (mon_b_rd_cnt),
        .b_ovf_cnt_o           (mon_b_ovf_cnt),
        .b_unf_cnt_o           (mon_b_unf_cnt),
        .b_bp_cnt_o            (mon_b_bp_cnt),
        .total_err_cnt         (mon_total_err_cnt),
        .any_full              (mon_any_full),
        .any_empty             (mon_any_empty),
        .both_almost_full      (mon_both_almost_full),
        .both_almost_empty     (mon_both_almost_empty),
        .any_backpressure      (mon_any_backpressure),
        .bp_event_cnt          (mon_bp_event_cnt),
        .mon_latency_cycles    (mon_latency_cycles),
        .mon_latency_ns        (mon_latency_ns),
        .a_ideal_max_wr_words  (mon_a_ideal_max_wr_words),
        .b_ideal_max_wr_words  (mon_b_ideal_max_wr_words)
    );

    // 本域占用量估计观测点 (供验证平台与监控域估计值做交叉比对)
    assign a_used_wr_est = a_wr_used_dbg;
    assign a_used_rd_est = a_rd_used_dbg;
    assign b_used_wr_est = b_wr_used_dbg;
    assign b_used_rd_est = b_rd_used_dbg;

    //=====================================================================
    // 4. 监控状态有效指示: clk_mon 域运行满 (2*SYNC_STAGES + 4) 拍后有效
    //=====================================================================
    reg [7:0] mon_ready_cnt;
    always @(posedge clk_mon or negedge rst_n_mon) begin
        if (!rst_n_mon) begin
            mon_ready_cnt <= 8'd0;
        end else if (mon_ready_cnt != 8'hFF) begin
            mon_ready_cnt <= mon_ready_cnt + 8'd1;
        end
    end
    // 就绪门限: 用 integer 常量再取其低 8 位, 使比较两侧同为 8 位,
    // 既避免 SV 位宽转换语法(8'(...)) 也避免位宽不匹配警告
    localparam integer MON_READY_TH_I = 2*SYNC_STAGES + 4;
    wire [7:0] mon_ready_th = MON_READY_TH_I[7:0];
    assign mon_status_valid = (mon_ready_cnt >= mon_ready_th);
endmodule

`default_nettype wire
