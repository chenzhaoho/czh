//=============================================================================
// File        : tb_coverage.sv
// Module      : tb_coverage
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 手工功能覆盖率收集器 (工具无关实现)。
//   覆盖模型 (共 25 个 bin):
//     C1  单通道状态覆盖     : A/B x {FULL, EMPTY, ALMOST_FULL, ALMOST_EMPTY, NORMAL} = 10
//     C2  操作结果覆盖       : 写成功/写被拒(溢出)/读成功/读被拒(下溢)/背压 = 5
//     C3  阈值双向穿越       : almost_full 上升/下降, almost_empty 上升/下降 = 4
//     C4  双通道组合         : 双满 / 双空 / A满B空 / A空B满 = 4
//     C5  边界数据模式       : 全0 / 全1 / 交替 = 3
//     C6  同步级数配置       : 2 级 / 3 级 = 2
//     C7  事件跨越           : 指针回卷(写指针越过 256) = 1
//   采样时钟: 监控时钟 clk_mon (统一状态输出域)
//=============================================================================
`timescale 1ns / 1ps

module tb_coverage (
    input wire        clk_mon,
    input wire        rst_n,
    // 监控域统一状态
    input wire [2:0]  a_status,
    input wire [2:0]  b_status,
    input wire        a_full, a_empty, a_almost_full, a_almost_empty,
    input wire        b_full, b_empty, b_almost_full, b_almost_empty,
    // 事件计数(本地域)
    input wire [31:0] a_wr_cnt, a_rd_cnt, a_ovf_cnt, a_unf_cnt, a_bp_cnt,
    input wire [31:0] b_wr_cnt, b_rd_cnt, b_ovf_cnt, b_unf_cnt, b_bp_cnt,
    input wire        bp_active_a, bp_active_b,
    // 数据模式观察
    input wire [31:0] wr_data_a, wr_data_b,
    input wire        wr_valid_a, wr_valid_b,
    // 配置
    input wire        is_3stage
);
    // 局部参数: 与 monitor 的状态编码一致
    localparam [2:0] S_NORMAL = 3'd0, S_AE = 3'd1, S_AF = 3'd2, S_FULL = 3'd3, S_EMPTY = 3'd4;

    integer a_full_c, a_empty_c, a_af_c, a_ae_c, a_normal_c;
    integer b_full_c, b_empty_c, b_af_c, b_ae_c, b_normal_c;
    integer wr_ok_c, wr_reject_c, rd_ok_c, rd_reject_c, bp_c;
    integer af_rise_c, af_fall_c, ae_rise_c, ae_fall_c;
    integer d_zero_c, d_ones_c, d_alt_c;
    integer both_full_c, both_empty_c, aFbE_c, aEbF_c;
    integer ptr_wrap_c;

    // 上一拍状态 (用于边沿检测与事件去重)
    reg [31:0] a_wr_d, a_rd_d, a_ovf_d, a_unf_d, a_bp_d;
    reg [31:0] b_wr_d, b_rd_d, b_ovf_d, b_unf_d, b_bp_d;
    reg        a_full_d, a_empty_d, a_af_d, a_ae_d;
    reg        b_full_d, b_empty_d, b_af_d, b_ae_d;
    reg        a_wr_fired_d, b_wr_fired_d;
    reg [8:0]  a_wr_ptr_hist, b_wr_ptr_hist;

    // 写指针回卷观察: 用写事务计数对 256 取模判断是否已跨越
    integer a_wr_mod_d, b_wr_mod_d;

    initial begin
        a_full_c = 0; a_empty_c = 0; a_af_c = 0; a_ae_c = 0; a_normal_c = 0;
        b_full_c = 0; b_empty_c = 0; b_af_c = 0; b_ae_c = 0; b_normal_c = 0;
        wr_ok_c = 0; wr_reject_c = 0; rd_ok_c = 0; rd_reject_c = 0; bp_c = 0;
        af_rise_c = 0; af_fall_c = 0; ae_rise_c = 0; ae_fall_c = 0;
        d_zero_c = 0; d_ones_c = 0; d_alt_c = 0;
        both_full_c = 0; both_empty_c = 0; aFbE_c = 0; aEbF_c = 0;
        ptr_wrap_c = 0;
        a_wr_d = 0; a_rd_d = 0; a_ovf_d = 0; a_unf_d = 0; a_bp_d = 0;
        b_wr_d = 0; b_rd_d = 0; b_ovf_d = 0; b_unf_d = 0; b_bp_d = 0;
        a_full_d = 0; a_empty_d = 0; a_af_d = 0; a_ae_d = 0;
        b_full_d = 0; b_empty_d = 0; b_af_d = 0; b_ae_d = 0;
        a_wr_fired_d = 0; b_wr_fired_d = 0;
        a_wr_ptr_hist = 0; b_wr_ptr_hist = 0;
        a_wr_mod_d = 0; b_wr_mod_d = 0;
    end

    //-------------------------------------------------- 状态与组合覆盖
    always @(posedge clk_mon) begin
        if (rst_n && !$isunknown({a_status, b_status})) begin
            // C1: 单通道状态
            case (a_status)
                S_FULL:   a_full_c   = a_full_c + 1;
                S_EMPTY:  a_empty_c  = a_empty_c + 1;
                S_AF:     a_af_c     = a_af_c + 1;
                S_AE:     a_ae_c     = a_ae_c + 1;
                default:  a_normal_c = a_normal_c + 1;
            endcase
            case (b_status)
                S_FULL:   b_full_c   = b_full_c + 1;
                S_EMPTY:  b_empty_c  = b_empty_c + 1;
                S_AF:     b_af_c     = b_af_c + 1;
                S_AE:     b_ae_c     = b_ae_c + 1;
                default:  b_normal_c = b_normal_c + 1;
            endcase

            // C4: 双通道组合 (按"状态变化"计数，避免海量重复计数)
            if ((a_full !== a_full_d) || (b_full !== b_full_d) ||
                (a_empty !== a_empty_d) || (b_empty !== b_empty_d)) begin
                if (a_full && b_full)  both_full_c  = both_full_c + 1;
                if (a_empty && b_empty) both_empty_c = both_empty_c + 1;
                if (a_full && b_empty) aFbE_c = aFbE_c + 1;
                if (a_empty && b_full) aEbF_c = aEbF_c + 1;
            end

            // C3: 阈值双向穿越
            if (a_almost_full && !a_af_d)  af_rise_c = af_rise_c + 1;
            if (!a_almost_full && a_af_d)  af_fall_c = af_fall_c + 1;
            if (a_almost_empty && !a_ae_d) ae_rise_c = ae_rise_c + 1;
            if (!a_almost_empty && a_ae_d) ae_fall_c = ae_fall_c + 1;
            if (b_almost_full && !b_af_d)  af_rise_c = af_rise_c + 1;
            if (!b_almost_full && b_af_d)  af_fall_c = af_fall_c + 1;
            if (b_almost_empty && !b_ae_d) ae_rise_c = ae_rise_c + 1;
            if (!b_almost_empty && b_ae_d) ae_fall_c = ae_fall_c + 1;

            a_full_d  <= a_full;  a_empty_d <= a_empty;
            a_af_d    <= a_almost_full; a_ae_d <= a_almost_empty;
            b_full_d  <= b_full;  b_empty_d <= b_empty;
            b_af_d    <= b_almost_full; b_ae_d <= b_almost_empty;
        end
    end

    //-------------------------------------------------- 操作结果覆盖
    always @(posedge clk_mon) begin
        if (rst_n) begin
            if (a_wr_cnt > a_wr_d) wr_ok_c     = wr_ok_c + 1;      // 写成功
            if (a_ovf_cnt > a_ovf_d) wr_reject_c = wr_reject_c + 1; // 写被拒(溢出)
            if (a_rd_cnt > a_rd_d) rd_ok_c     = rd_ok_c + 1;      // 读成功
            if (a_unf_cnt > a_unf_d) rd_reject_c = rd_reject_c + 1; // 读被拒(下溢)
            if (a_bp_cnt > a_bp_d) bp_c        = bp_c + 1;          // 背压
            if (b_wr_cnt > b_wr_d) wr_ok_c     = wr_ok_c + 1;
            if (b_ovf_cnt > b_ovf_d) wr_reject_c = wr_reject_c + 1;
            if (b_rd_cnt > b_rd_d) rd_ok_c     = rd_ok_c + 1;
            if (b_unf_cnt > b_unf_d) rd_reject_c = rd_reject_c + 1;
            if (b_bp_cnt > b_bp_d) bp_c        = bp_c + 1;

            a_wr_d <= a_wr_cnt; a_rd_d <= a_rd_cnt;
            a_ovf_d <= a_ovf_cnt; a_unf_d <= a_unf_cnt; a_bp_d <= a_bp_cnt;
            b_wr_d <= b_wr_cnt; b_rd_d <= b_rd_cnt;
            b_ovf_d <= b_ovf_cnt; b_unf_d <= b_unf_cnt; b_bp_d <= b_bp_cnt;

            // C7: 写指针回卷 (成功写入次数跨越 256 的整数倍)
            if ((a_wr_cnt / 256) > (a_wr_d / 256)) ptr_wrap_c = ptr_wrap_c + 1;
            if ((b_wr_cnt / 256) > (b_wr_d / 256)) ptr_wrap_c = ptr_wrap_c + 1;

            // 直接观察背压电平(补充 bin)
            if (bp_active_a || bp_active_b) bp_c = bp_c + 0;   // 由计数 bin 体现
        end
    end

    //-------------------------------------------------- 边界数据模式覆盖
    always @(posedge clk_mon) begin
        if (rst_n) begin
            if (wr_valid_a) begin
                if (wr_data_a === 32'h0000_0000)      d_zero_c = d_zero_c + 1;
                else if (wr_data_a === 32'hFFFF_FFFF) d_ones_c = d_ones_c + 1;
                else if (wr_data_a === 32'hAAAA_AAAA || wr_data_a === 32'h5555_5555)
                                                      d_alt_c  = d_alt_c + 1;
            end
            if (wr_valid_b) begin
                if (wr_data_b === 32'h0000_0000)      d_zero_c = d_zero_c + 1;
                else if (wr_data_b === 32'hFFFF_FFFF) d_ones_c = d_ones_c + 1;
                else if (wr_data_b === 32'hAAAA_AAAA || wr_data_b === 32'h5555_5555)
                                                      d_alt_c  = d_alt_c + 1;
            end
        end
    end

    //-------------------------------------------------- 覆盖率报告
    task automatic report(input [255:0] tag);
        integer hit, total;
        real    pct;
        begin
            hit = 0; total = 0;
            // C1 (10)
            total = total + 10;
            if (a_full_c > 0)  hit = hit + 1;
            if (a_empty_c > 0) hit = hit + 1;
            if (a_af_c > 0)    hit = hit + 1;
            if (a_ae_c > 0)    hit = hit + 1;
            if (a_normal_c > 0) hit = hit + 1;
            if (b_full_c > 0)  hit = hit + 1;
            if (b_empty_c > 0) hit = hit + 1;
            if (b_af_c > 0)    hit = hit + 1;
            if (b_ae_c > 0)    hit = hit + 1;
            if (b_normal_c > 0) hit = hit + 1;
            // C2 (5)
            total = total + 5;
            if (wr_ok_c > 0)     hit = hit + 1;
            if (wr_reject_c > 0) hit = hit + 1;
            if (rd_ok_c > 0)     hit = hit + 1;
            if (rd_reject_c > 0) hit = hit + 1;
            if (bp_c > 0)        hit = hit + 1;
            // C3 (4)
            total = total + 4;
            if (af_rise_c > 0) hit = hit + 1;
            if (af_fall_c > 0) hit = hit + 1;
            if (ae_rise_c > 0) hit = hit + 1;
            if (ae_fall_c > 0) hit = hit + 1;
            // C4 (4)
            total = total + 4;
            if (both_full_c > 0)  hit = hit + 1;
            if (both_empty_c > 0) hit = hit + 1;
            if (aFbE_c > 0)       hit = hit + 1;
            if (aEbF_c > 0)       hit = hit + 1;
            // C5 (3)
            total = total + 3;
            if (d_zero_c > 0) hit = hit + 1;
            if (d_ones_c > 0) hit = hit + 1;
            if (d_alt_c > 0)  hit = hit + 1;
            // C6 (2)
            total = total + 2;
            if (!is_3stage) hit = hit + 1;
            else            hit = hit + 1;   // 当前配置对应 1 个 bin
            // C7 (1)
            total = total + 1;
            if (ptr_wrap_c > 0) hit = hit + 1;

            pct = 100.0 * hit / total;

            $display("");
            $display("============ FUNCTIONAL COVERAGE REPORT [%0s] ============", tag);
            $display(" C1 per-channel state : A{FULL=%0d EMPTY=%0d AF=%0d AE=%0d NORM=%0d}",
                     a_full_c, a_empty_c, a_af_c, a_ae_c, a_normal_c);
            $display("                         B{FULL=%0d EMPTY=%0d AF=%0d AE=%0d NORM=%0d}",
                     b_full_c, b_empty_c, b_af_c, b_ae_c, b_normal_c);
            $display(" C2 operation outcome : wr_ok=%0d wr_reject=%0d rd_ok=%0d rd_reject=%0d bp=%0d",
                     wr_ok_c, wr_reject_c, rd_ok_c, rd_reject_c, bp_c);
            $display(" C3 threshold crossing: AF_rise=%0d AF_fall=%0d AE_rise=%0d AE_fall=%0d",
                     af_rise_c, af_fall_c, ae_rise_c, ae_fall_c);
            $display(" C4 dual-channel comb : both_full=%0d both_empty=%0d A_full_B_empty=%0d A_empty_B_full=%0d",
                     both_full_c, both_empty_c, aFbE_c, aEbF_c);
            $display(" C5 boundary data     : all0=%0d all1=%0d alt=%0d", d_zero_c, d_ones_c, d_alt_c);
            $display(" C6 sync-stage config : current=%0s (bin 1/1)", is_3stage ? "3-stage" : "2-stage");
            $display(" C7 pointer wrap      : %0d times", ptr_wrap_c);
            $display(" --------------------------------------------------------");
            $display(" FUNCTIONAL COVERAGE = %0.1f%%  (%0d/%0d bin)", pct, hit, total);
            $display("=========================================================");
            $display("");
        end
    endtask

endmodule
