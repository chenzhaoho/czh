//=============================================================================
// File        : monitor.v
// Module      : monitor
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 顶层统一监控模块。
//   职责:
//     1) 汇总两个通道的写入次数、读出次数、溢出/下溢错误、背压触发次数;
//     2) 采样两通道的空/满/几乎空/几乎满标志，产生统一状态字 status (3 bit/通道);
//     3) 对外输出"监控时钟域(clk_mon)采样副本"，供验证平台在容许同步延迟后与
//        各通道本地计数逐位比较，验证跨域计数通路;
//     4) 依据通道时钟周期参数给出理想吞吐上限，供吞吐瓶颈分析引用。
//
//   跨域规则:
//     - 事件计数进入本模块前已在各自源时钟域完成"二进制->格雷码"转换，
//       本模块只做 clk_mon 域多级打拍采样，绝不裸采样多位二进制总线。
//     - 统一状态字在打拍前先格雷编码，因此本模块对外输出不存在
//       "多比特同时跳变被采到"的窗口。
//
//   status 编码 (每通道 3 bit):
//     3'd0 STATUS_NORMAL       : 既非满/几乎满，也非空/几乎空
//     3'd1 STATUS_ALMOST_EMPTY : 占用量 <= ALMOST_EMPTY_TH
//     3'd2 STATUS_ALMOST_FULL  : 占用量 >= ALMOST_FULL_TH
//     3'd3 STATUS_FULL         : 占用量 == DEPTH  (写请求被拒绝)
//     3'd4 STATUS_EMPTY        : 占用量 == 0      (读请求被拒绝)
//   复位后默认 STATUS_NORMAL；空/满互斥(全满与全空不可能同时成立)。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module monitor #(
    parameter integer AW          = 8,
    parameter integer CNT_W       = 32,
    parameter integer SYNC_STAGES = 2,
    // 各时钟周期 (ps)，仅用于理想吞吐上限与监控延迟参数的定量说明
    parameter integer T_WR_A_PS   = 10000,   // 10 ns
    parameter integer T_RD_A_PS   = 6000,    // 6 ns
    parameter integer T_WR_B_PS   = 14000,   // 14 ns
    parameter integer T_RD_B_PS   = 4000,    // 4 ns
    parameter integer T_MON_PS    = 5000     // 5 ns
) (
    input  wire              clk_mon,
    input  wire              rst_n_mon,
    //-------------------------------------------- 通道 A 监控量 (mon 域已同步)
    input  wire [CNT_W-1:0]  a_wr_event_cnt,
    input  wire [CNT_W-1:0]  a_rd_event_cnt,
    input  wire [CNT_W-1:0]  a_overflow_cnt,
    input  wire [CNT_W-1:0]  a_underflow_cnt,
    input  wire [CNT_W-1:0]  a_backpressure_cnt,
    input  wire              a_bp_active,
    input  wire [AW:0]       a_used,
    input  wire              a_full,
    input  wire              a_almost_full,
    input  wire              a_empty,
    input  wire              a_almost_empty,
    //-------------------------------------------- 通道 B 监控量 (mon 域已同步)
    input  wire [CNT_W-1:0]  b_wr_event_cnt,
    input  wire [CNT_W-1:0]  b_rd_event_cnt,
    input  wire [CNT_W-1:0]  b_overflow_cnt,
    input  wire [CNT_W-1:0]  b_underflow_cnt,
    input  wire [CNT_W-1:0]  b_backpressure_cnt,
    input  wire              b_bp_active,
    input  wire [AW:0]       b_used,
    input  wire              b_full,
    input  wire              b_almost_full,
    input  wire              b_empty,
    input  wire              b_almost_empty,
    //-------------------------------------------- 统一状态输出接口 (mon 域)
    output wire [2:0]        a_status,
    output wire [2:0]        b_status,
    output wire [5:0]        status_word,          // {b_status, a_status}
    output wire              a_full_o,
    output wire              a_almost_full_o,
    output wire              a_empty_o,
    output wire              a_almost_empty_o,
    output wire [AW:0]       a_used_o,
    output wire [CNT_W-1:0]  a_wr_cnt_o,
    output wire [CNT_W-1:0]  a_rd_cnt_o,
    output wire [CNT_W-1:0]  a_ovf_cnt_o,
    output wire [CNT_W-1:0]  a_unf_cnt_o,
    output wire [CNT_W-1:0]  a_bp_cnt_o,
    output wire              b_full_o,
    output wire              b_almost_full_o,
    output wire              b_empty_o,
    output wire              b_almost_empty_o,
    output wire [AW:0]       b_used_o,
    output wire [CNT_W-1:0]  b_wr_cnt_o,
    output wire [CNT_W-1:0]  b_rd_cnt_o,
    output wire [CNT_W-1:0]  b_ovf_cnt_o,
    output wire [CNT_W-1:0]  b_unf_cnt_o,
    output wire [CNT_W-1:0]  b_bp_cnt_o,
    output wire [CNT_W-1:0]  total_err_cnt,
    output wire              any_full,
    output wire              any_empty,
    output wire              both_almost_full,
    output wire              both_almost_empty,
    output wire              any_backpressure,
    output wire [CNT_W-1:0]  bp_event_cnt,         // 监控域统计的"背压事件(段)"总数
    output wire [31:0]       mon_latency_cycles,
    output wire [31:0]       mon_latency_ns,       // 折算成绝对时间的监控采样延迟
    output wire [31:0]       a_ideal_max_wr_words,
    output wire [31:0]       b_ideal_max_wr_words
);
    //=====================================================================
    // 1. 统一状态字编码 (纯组合，输入已是 mon 域信号)
    //=====================================================================
    reg [2:0] a_status_c;
    reg [2:0] b_status_c;

    always @(*) begin
        // ---------- 通道 A: 满/空优先于几乎满/几乎空 ----------
        if (a_full)              a_status_c = 3'd3;   // FULL
        else if (a_empty)        a_status_c = 3'd4;   // EMPTY
        else if (a_almost_full)  a_status_c = 3'd2;   // ALMOST_FULL
        else if (a_almost_empty) a_status_c = 3'd1;   // ALMOST_EMPTY
        else                     a_status_c = 3'd0;   // NORMAL

        // ---------- 通道 B ----------
        if (b_full)              b_status_c = 3'd3;
        else if (b_empty)        b_status_c = 3'd4;
        else if (b_almost_full)  b_status_c = 3'd2;
        else if (b_almost_empty) b_status_c = 3'd1;
        else                     b_status_c = 3'd0;
    end

    //=====================================================================
    // 2. 状态字二次同步 (格雷编码 -> 打拍 -> 解码)，保证输出无多比特跳变窗口
    //=====================================================================
    wire [5:0] status_word_c = {b_status_c, a_status_c};
    wire [5:0] status_gray;
    wire [5:0] status_gray_sync;
    wire [5:0] status_bin;

    bin2gray #(.W(6)) u_bin2gray_status (.bin(status_word_c), .gray(status_gray));

    sync_2ff_s #(.STAGES(SYNC_STAGES)) u_sync_status_word (
        .clk     (clk_mon),
        .rst_n   (rst_n_mon),
        .d_async (status_gray),
        .q_sync  (status_gray_sync)
    );

    gray2bin #(.W(6)) u_gray2bin_status (.gray(status_gray_sync), .bin(status_bin));

    assign status_word = status_bin;
    assign a_status    = status_bin[2:0];
    assign b_status    = status_bin[5:3];

    //=====================================================================
    // 3. 位选通输出 (mon 域采样副本)
    //=====================================================================
    assign a_full_o         = a_full;
    assign a_almost_full_o  = a_almost_full;
    assign a_empty_o        = a_empty;
    assign a_almost_empty_o = a_almost_empty;
    assign a_used_o         = a_used;
    assign a_wr_cnt_o       = a_wr_event_cnt;
    assign a_rd_cnt_o       = a_rd_event_cnt;
    assign a_ovf_cnt_o      = a_overflow_cnt;
    assign a_unf_cnt_o      = a_underflow_cnt;
    assign a_bp_cnt_o       = a_backpressure_cnt;

    assign b_full_o         = b_full;
    assign b_almost_full_o  = b_almost_full;
    assign b_empty_o        = b_empty;
    assign b_almost_empty_o = b_almost_empty;
    assign b_used_o         = b_used;
    assign b_wr_cnt_o       = b_wr_event_cnt;
    assign b_rd_cnt_o       = b_rd_event_cnt;
    assign b_ovf_cnt_o      = b_overflow_cnt;
    assign b_unf_cnt_o      = b_underflow_cnt;
    assign b_bp_cnt_o       = b_backpressure_cnt;

    //=====================================================================
    // 4. 跨通道组合事件与合计错误计数 (饱和)
    //=====================================================================
    // 背压"事件(段)"统计: 在监控域对 a_bp_active/b_bp_active 的上升沿计数。
    // 该计数与各通道本地背压"周期数"互为佐证(事件数 <= 周期数)。
    wire a_bp_sync, b_bp_sync;
    reg  a_bp_sync_d, b_bp_sync_d;
    reg  [CNT_W-1:0] bp_event_cnt_r;

    sync_2ff_1 #(.STAGES(SYNC_STAGES)) u_s_bp_a (
        .clk(clk_mon), .rst_n(rst_n_mon), .d_async(a_bp_active), .q_sync(a_bp_sync));
    sync_2ff_1 #(.STAGES(SYNC_STAGES)) u_s_bp_b (
        .clk(clk_mon), .rst_n(rst_n_mon), .d_async(b_bp_active), .q_sync(b_bp_sync));

    always @(posedge clk_mon or negedge rst_n_mon) begin
        if (!rst_n_mon) begin
            a_bp_sync_d   <= 1'b0;
            b_bp_sync_d   <= 1'b0;
            bp_event_cnt_r <= {CNT_W{1'b0}};
        end else begin
            a_bp_sync_d <= a_bp_sync;
            b_bp_sync_d <= b_bp_sync;
            if (((a_bp_sync & ~a_bp_sync_d) || (b_bp_sync & ~b_bp_sync_d)) &&
                (bp_event_cnt_r != {CNT_W{1'b1}})) begin
                bp_event_cnt_r <= bp_event_cnt_r + {{(CNT_W-1){1'b0}}, 1'b1};
            end
        end
    end

    assign bp_event_cnt = bp_event_cnt_r;

    assign any_full          = a_full | b_full;
    assign any_empty         = a_empty | b_empty;
    assign both_almost_full  = a_almost_full & b_almost_full;
    assign both_almost_empty = a_almost_empty & b_almost_empty;
    assign any_backpressure  = (a_backpressure_cnt != {CNT_W{1'b0}}) |
                               (b_backpressure_cnt != {CNT_W{1'b0}});

    wire [CNT_W+1:0] err_sum = {2'b00, a_overflow_cnt} + {2'b00, a_underflow_cnt} +
                               {2'b00, b_overflow_cnt} + {2'b00, b_underflow_cnt};
    assign total_err_cnt = (err_sum > {{2{1'b0}}, {CNT_W{1'b1}}}) ? {CNT_W{1'b1}}
                                                                  : err_sum[CNT_W-1:0];

    //=====================================================================
    // 5. 监控采样延迟参数 (clk_mon 周期数)
    //    源域标志 -> 源域/监控域多级同步器(SYNC_STAGES) -> 本模块状态字打拍(2)
    //    监控时钟周期 T_MON_PS 同时用于把该延迟折算成绝对时间(见报告)
    //=====================================================================
    assign mon_latency_cycles = SYNC_STAGES + 2;
    assign mon_latency_ns     = (SYNC_STAGES + 2) * (T_MON_PS / 1000);

    //=====================================================================
    // 6. 理想吞吐上限 (供报告吞吐瓶颈分析引用)
    //    存储体为"写时钟写、读时钟组合读"的简单双端口结构，
    //    可持续吞吐受较慢一侧限制: 每 1 us 理想最大写入字数 = 1000 / max(T_wr, T_rd) (ns)
    //=====================================================================
    localparam integer T_WR_A_NS = T_WR_A_PS / 1000;
    localparam integer T_RD_A_NS = T_RD_A_PS / 1000;
    localparam integer T_WR_B_NS = T_WR_B_PS / 1000;
    localparam integer T_RD_B_NS = T_RD_B_PS / 1000;

    assign a_ideal_max_wr_words = (T_WR_A_NS >= T_RD_A_NS) ? (1000 / T_WR_A_NS)
                                                           : (1000 / T_RD_A_NS);
    assign b_ideal_max_wr_words = (T_WR_B_NS >= T_RD_B_NS) ? (1000 / T_WR_B_NS)
                                                           : (1000 / T_RD_B_NS);

endmodule

`default_nettype wire
