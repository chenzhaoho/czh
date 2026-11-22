//=============================================================================
// File        : tb_harness.sv
// Module      : tb_harness
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : DUT 接线骨架。集中声明四个时钟域 + 监控域的全部激励/观测信号，
//               例化双异步 FIFO 顶层。
//
//   说明: 参考模型(参考序列/比对器)与激励驱动器都在 tb_top 中实现，与驱动器
//         同域，避免"任务与 always 进程共享数组"带来的竞争。本文件只保留
//         DUT 接线、观测信号与时钟使能。
//=============================================================================
`timescale 1ns / 1ps

module tb_harness;

    //====================================================== 时钟 / 复位
    reg wr_clk_a = 0, rd_clk_a = 0, wr_clk_b = 0, rd_clk_b = 0, clk_mon = 0;
    reg rst_n_async = 0;
    reg clk_a_en = 1, clk_b_en = 1;     // 时钟暂停测试用

    //====================================================== 通道 A 激励
    reg  [31:0] wr_data_a     = 0;
    reg         wr_valid_a    = 0;
    reg         rd_en_a       = 0;
    reg         rd_ready_a    = 0;
    // 同步到本地时钟域的握手副本(消除组合毛刺，保证与 DUT 采样一致)
    reg         wr_valid_a_r  = 0;
    reg  [31:0] wr_data_a_r   = 0;
    reg         rd_en_a_r     = 0;
    reg         rd_ready_a_r  = 0;

    //====================================================== 通道 B 激励
    reg  [31:0] wr_data_b     = 0;
    reg         wr_valid_b    = 0;
    reg         rd_en_b       = 0;
    reg         rd_ready_b    = 0;
    reg         wr_valid_b_r  = 0;
    reg  [31:0] wr_data_b_r   = 0;
    reg         rd_en_b_r     = 0;
    reg         rd_ready_b_r  = 0;

    //====================================================== 通道 A 观测
    wire        wr_ready_a, wr_full_a, full_check_a, wr_almost_full_a, wr_data_valid_a;
    wire [31:0] wr_data_committed_a, rd_data_a;
    wire        rd_valid_a, rd_empty_a, rd_almost_empty_a, a_backpressure_active;
    wire [31:0] a_wr_event_cnt, a_overflow_cnt, a_overflow_flag_cnt;
    wire [31:0] a_rd_event_cnt, a_underflow_cnt, a_underflow_flag_cnt, a_backpressure_cnt;
    wire [8:0]  a_used_wr_est, a_used_rd_est;

    //====================================================== 通道 B 观测
    wire        wr_ready_b, wr_full_b, full_check_b, wr_almost_full_b, wr_data_valid_b;
    wire [31:0] wr_data_committed_b, rd_data_b;
    wire        rd_valid_b, rd_empty_b, rd_almost_empty_b, b_backpressure_active;
    wire [31:0] b_wr_event_cnt, b_overflow_cnt, b_overflow_flag_cnt;
    wire [31:0] b_rd_event_cnt, b_underflow_cnt, b_underflow_flag_cnt, b_backpressure_cnt;
    wire [8:0]  b_used_wr_est, b_used_rd_est;

    //====================================================== 监控域观测
    wire [2:0]  mon_a_status, mon_b_status;
    wire [5:0]  mon_status_word;
    wire        mon_a_full, mon_a_almost_full, mon_a_empty, mon_a_almost_empty;
    wire [8:0]  mon_a_used;
    wire [31:0] mon_a_wr_cnt, mon_a_rd_cnt, mon_a_ovf_cnt, mon_a_unf_cnt, mon_a_bp_cnt;
    wire        mon_b_full, mon_b_almost_full, mon_b_empty, mon_b_almost_empty;
    wire [8:0]  mon_b_used;
    wire [31:0] mon_b_wr_cnt, mon_b_rd_cnt, mon_b_ovf_cnt, mon_b_unf_cnt, mon_b_bp_cnt;
    wire [31:0] mon_total_err_cnt, mon_bp_event_cnt;
    wire [31:0] mon_latency_cycles, mon_latency_ns;
    wire [31:0] mon_a_ideal, mon_b_ideal;
    wire        mon_any_full, mon_any_empty, mon_both_almost_full, mon_both_almost_empty;
    wire        mon_any_backpressure, mon_status_valid;

    //====================================================== DUT
`ifdef DUT_SYNC_STAGES
    dual_async_fifo_top #(
        .DW(32), .AW(8), .CNT_W(32), .SYNC_STAGES(`DUT_SYNC_STAGES)
    ) u_dut (
`else
    dual_async_fifo_top #(
        .DW(32), .AW(8), .CNT_W(32), .SYNC_STAGES(2)
    ) u_dut (
`endif
        .rst_n_async(rst_n_async),
        .wr_clk_a(wr_clk_a), .wr_valid_a(wr_valid_a_r), .wr_data_a(wr_data_a_r),
        .wr_ready_a(wr_ready_a), .wr_full_a(wr_full_a), .full_check_a(full_check_a),
        .wr_almost_full_a(wr_almost_full_a),
        .wr_data_committed_a(wr_data_committed_a), .wr_data_valid_a(wr_data_valid_a),
        .a_wr_event_cnt(a_wr_event_cnt), .a_overflow_cnt(a_overflow_cnt),
        .a_overflow_flag_cnt(a_overflow_flag_cnt),
        .rd_clk_a(rd_clk_a), .rd_en_a(rd_en_a_r), .rd_ready_a(rd_ready_a_r),
        .rd_data_a(rd_data_a), .rd_valid_a(rd_valid_a), .rd_empty_a(rd_empty_a),
        .rd_almost_empty_a(rd_almost_empty_a), .a_rd_event_cnt(a_rd_event_cnt),
        .a_underflow_cnt(a_underflow_cnt), .a_underflow_flag_cnt(a_underflow_flag_cnt),
        .a_backpressure_cnt(a_backpressure_cnt), .a_backpressure_active(a_backpressure_active),
        .wr_clk_b(wr_clk_b), .wr_valid_b(wr_valid_b_r), .wr_data_b(wr_data_b_r),
        .wr_ready_b(wr_ready_b), .wr_full_b(wr_full_b), .full_check_b(full_check_b),
        .wr_almost_full_b(wr_almost_full_b),
        .wr_data_committed_b(wr_data_committed_b), .wr_data_valid_b(wr_data_valid_b),
        .b_wr_event_cnt(b_wr_event_cnt), .b_overflow_cnt(b_overflow_cnt),
        .b_overflow_flag_cnt(b_overflow_flag_cnt),
        .rd_clk_b(rd_clk_b), .rd_en_b(rd_en_b_r), .rd_ready_b(rd_ready_b_r),
        .rd_data_b(rd_data_b), .rd_valid_b(rd_valid_b), .rd_empty_b(rd_empty_b),
        .rd_almost_empty_b(rd_almost_empty_b), .b_rd_event_cnt(b_rd_event_cnt),
        .b_underflow_cnt(b_underflow_cnt), .b_underflow_flag_cnt(b_underflow_flag_cnt),
        .b_backpressure_cnt(b_backpressure_cnt), .b_backpressure_active(b_backpressure_active),
        .clk_mon(clk_mon),
        .mon_a_status(mon_a_status), .mon_b_status(mon_b_status),
        .mon_status_word(mon_status_word),
        .mon_a_full(mon_a_full), .mon_a_almost_full(mon_a_almost_full),
        .mon_a_empty(mon_a_empty), .mon_a_almost_empty(mon_a_almost_empty),
        .mon_a_used(mon_a_used), .mon_a_wr_cnt(mon_a_wr_cnt), .mon_a_rd_cnt(mon_a_rd_cnt),
        .mon_a_ovf_cnt(mon_a_ovf_cnt), .mon_a_unf_cnt(mon_a_unf_cnt), .mon_a_bp_cnt(mon_a_bp_cnt),
        .mon_b_full(mon_b_full), .mon_b_almost_full(mon_b_almost_full),
        .mon_b_empty(mon_b_empty), .mon_b_almost_empty(mon_b_almost_empty),
        .mon_b_used(mon_b_used), .mon_b_wr_cnt(mon_b_wr_cnt), .mon_b_rd_cnt(mon_b_rd_cnt),
        .mon_b_ovf_cnt(mon_b_ovf_cnt), .mon_b_unf_cnt(mon_b_unf_cnt), .mon_b_bp_cnt(mon_b_bp_cnt),
        .mon_total_err_cnt(mon_total_err_cnt), .mon_any_full(mon_any_full),
        .mon_any_empty(mon_any_empty), .mon_both_almost_full(mon_both_almost_full),
        .mon_both_almost_empty(mon_both_almost_empty),
        .mon_any_backpressure(mon_any_backpressure), .mon_bp_event_cnt(mon_bp_event_cnt),
        .mon_latency_cycles(mon_latency_cycles), .mon_latency_ns(mon_latency_ns),
        .mon_a_ideal_max_wr_words(mon_a_ideal), .mon_b_ideal_max_wr_words(mon_b_ideal),
        .mon_status_valid(mon_status_valid),
        .a_used_wr_est(a_used_wr_est), .a_used_rd_est(a_used_rd_est),
        .b_used_wr_est(b_used_wr_est), .b_used_rd_est(b_used_rd_est)
    );

    //====================================================== 激励寄存器打拍
    // 在各自时钟域把激励打一拍再送入 DUT，使 TB 与 DUT 采样到完全相同的值，
    // 从而可以对计数类结果做"逐周期精确"比对而不需要额外容差。
    always @(posedge wr_clk_a) begin
        wr_valid_a_r <= wr_valid_a;
        wr_data_a_r  <= wr_data_a;
    end
    always @(posedge rd_clk_a) begin
        rd_en_a_r    <= rd_en_a;
        rd_ready_a_r <= rd_ready_a;
    end
    always @(posedge wr_clk_b) begin
        wr_valid_b_r <= wr_valid_b;
        wr_data_b_r  <= wr_data_b;
    end
    always @(posedge rd_clk_b) begin
        rd_en_b_r    <= rd_en_b;
        rd_ready_b_r <= rd_ready_b;
    end

endmodule
