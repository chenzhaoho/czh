//=============================================================================
// File        : tb_pkg.sv
// Package     : tb_pkg
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 验证平台公共定义。
//   - ref_queue        : 参考队列 (金标准模型)，用于逐项比对数据顺序/完整性
//   - cov_bins         : 手写功能覆盖率收集器 (与工具无关，可移植)
//   - 随机激励辅助函数
//   说明: 为避免依赖 Questa 的 covergroup/randomize 许可特性，本平台用
//   SystemVerilog class + $urandom 手写覆盖率与约束随机，等价功能且更可移植。
//=============================================================================
`ifndef TB_PKG_SV
`define TB_PKG_SV

package tb_pkg;

    //-------------------------------------------------------------------------
    // 参考队列 (FIFO 金标准模型)
    //   教材式实现: 数组 + head/tail 指针，容量充足，先入先出。
    //-------------------------------------------------------------------------
    class ref_queue #(parameter int CAP = 4096, parameter int DW = 32);
        bit [DW-1:0] mem [0:CAP-1];
        int unsigned head;      // 出队位置
        int unsigned tail;      // 入队位置
        int unsigned num;       // 当前元素个数

        function new();
            head = 0;
            tail = 0;
            num  = 0;
        endfunction

        function void clear();
            head = 0;
            tail = 0;
            num  = 0;
        endfunction

        function bit full();
            return (num == CAP);
        endfunction

        function bit empty();
            return (num == 0);
        endfunction

        function void push(bit [DW-1:0] d);
            if (num < CAP) begin
                mem[tail] = d;
                tail = (tail + 1) % CAP;
                num  = num + 1;
            end
        endfunction

        function bit [DW-1:0] pop();
            bit [DW-1:0] d;
            d = mem[head];
            head = (head + 1) % CAP;
            num  = num - 1;
            return d;
        endfunction

        function bit [DW-1:0] front();
            return mem[head];
        endfunction
    endclass

    //-------------------------------------------------------------------------
    // 功能覆盖率收集器
    //   覆盖点: 状态、读写结果、almost 阈值、背压、双通道组合、
    //           边界数据、复位、时钟暂停、同步级数配置
    //-------------------------------------------------------------------------
    class cov_bins;
        // --- 状态 ---
        int unsigned a_full, a_empty, a_almost_full, a_almost_empty, a_normal;
        int unsigned b_full, b_empty, b_almost_full, b_almost_empty, b_normal;
        // --- 操作结果 ---
        int unsigned wr_ok, wr_reject;
        int unsigned rd_ok, rd_reject;
        int unsigned bp_active;
        // --- 阈值交叉 (双向) ---
        int unsigned af_rise, af_fall, ae_rise, ae_fall;
        // --- 数据模式 ---
        int unsigned data_zero, data_ones, data_alt, data_random;
        // --- 双通道组合 ---
        int unsigned both_full, both_empty, a_full_b_empty, a_empty_b_full;
        int unsigned both_af, both_ae, both_bp;
        // --- 复位/时钟 ---
        int unsigned reset_events, clk_pause_events;
        // --- 同步级数配置 ---
        int unsigned sync_cfg_2, sync_cfg_3;
        // --- 指针回卷 ---
        int unsigned ptr_wrap;

        function new();
            a_full = 0; a_empty = 0; a_almost_full = 0; a_almost_empty = 0; a_normal = 0;
            b_full = 0; b_empty = 0; b_almost_full = 0; b_almost_empty = 0; b_normal = 0;
            wr_ok = 0; wr_reject = 0; rd_ok = 0; rd_reject = 0; bp_active = 0;
            af_rise = 0; af_fall = 0; ae_rise = 0; ae_fall = 0;
            data_zero = 0; data_ones = 0; data_alt = 0; data_random = 0;
            both_full = 0; both_empty = 0; a_full_b_empty = 0; a_empty_b_full = 0;
            both_af = 0; both_ae = 0; both_bp = 0;
            reset_events = 0; clk_pause_events = 0;
            sync_cfg_2 = 0; sync_cfg_3 = 0; ptr_wrap = 0;
        endfunction

        // 单通道状态采样
        function void sample_state(bit is_a, bit full, bit empty, bit af, bit ae);
            if (is_a) begin
                if (full)            a_full = a_full + 1;
                else if (empty)      a_empty = a_empty + 1;
                else if (af)         a_almost_full = a_almost_full + 1;
                else if (ae)         a_almost_empty = a_almost_empty + 1;
                else                 a_normal = a_normal + 1;
            end else begin
                if (full)            b_full = b_full + 1;
                else if (empty)      b_empty = b_empty + 1;
                else if (af)         b_almost_full = b_almost_full + 1;
                else if (ae)         b_almost_empty = b_almost_empty + 1;
                else                 b_normal = b_normal + 1;
            end
        endfunction

        // 数据模式分类
        function void sample_data(bit [31:0] d);
            if (d === 32'h0000_0000)      data_zero = data_zero + 1;
            else if (d === 32'hFFFF_FFFF) data_ones = data_ones + 1;
            else if (d === 32'hAAAA_AAAA || d === 32'h5555_5555) data_alt = data_alt + 1;
            else                          data_random = data_random + 1;
        endfunction

        // 双通道组合采样 (由 tb 每 N 个周期调用一次)
        function void sample_dual(bit a_f, bit a_e, bit b_f, bit b_e, bit bp_a, bit bp_b);
            if (a_f && b_f)        both_full   = both_full + 1;
            if (a_e && b_e)        both_empty  = both_empty + 1;
            if (a_f && b_e)        a_full_b_empty = a_full_b_empty + 1;
            if (a_e && b_f)        a_empty_b_full = a_empty_b_full + 1;
            if (bp_a && bp_b)      both_bp     = both_bp + 1;
        endfunction

        function void report(string tag);
            int unsigned total_states, covered_states;
            int unsigned total_ops, covered_ops;
            real cov_state, cov_op, cov_total;

            total_states = 10;
            covered_states = 0;
            if (a_full > 0)         covered_states++;
            if (a_empty > 0)        covered_states++;
            if (a_almost_full > 0)  covered_states++;
            if (a_almost_empty > 0) covered_states++;
            if (a_normal > 0)       covered_states++;
            if (b_full > 0)         covered_states++;
            if (b_empty > 0)        covered_states++;
            if (b_almost_full > 0)  covered_states++;
            if (b_almost_empty > 0) covered_states++;
            if (b_normal > 0)       covered_states++;

            total_ops = 5;
            covered_ops = 0;
            if (wr_ok > 0)     covered_ops++;
            if (wr_reject > 0) covered_ops++;
            if (rd_ok > 0)     covered_ops++;
            if (rd_reject > 0) covered_ops++;
            if (bp_active > 0) covered_ops++;

            cov_state = 100.0 * covered_states / total_states;
            cov_op    = 100.0 * covered_ops / total_ops;

            $display("");
            $display("================ 功能覆盖率报告 [%s] ================", tag);
            $display(" -- 状态覆盖 (每通道 5 态 x 2) --");
            $display("   A: FULL=%-6d EMPTY=%-6d ALMOST_FULL=%-6d ALMOST_EMPTY=%-6d NORMAL=%-6d",
                     a_full, a_empty, a_almost_full, a_almost_empty, a_normal);
            $display("   B: FULL=%-6d EMPTY=%-6d ALMOST_FULL=%-6d ALMOST_EMPTY=%-6d NORMAL=%-6d",
                     b_full, b_empty, b_almost_full, b_almost_empty, b_normal);
            $display("   状态 bin 覆盖率 = %0.1f%% (%0d/%0d)", cov_state, covered_states, total_states);
            $display(" -- 操作结果覆盖 --");
            $display("   写入成功=%-8d 写入被拒(溢出)=%-8d 读出成功=%-8d 读出被拒(下溢)=%-8d 背压周期=%-8d",
                     wr_ok, wr_reject, rd_ok, rd_reject, bp_active);
            $display("   操作 bin 覆盖率 = %0.1f%% (%0d/%0d)", cov_op, covered_ops, total_ops);
            $display(" -- 阈值跨越 (双向) --");
            $display("   almost_full 上升=%-6d 下降=%-6d   almost_empty 上升=%-6d 下降=%-6d",
                     af_rise, af_fall, ae_rise, ae_fall);
            $display(" -- 数据模式 --");
            $display("   全0=%-6d 全1=%-6d 交替=%-6d 随机=%-6d", data_zero, data_ones, data_alt, data_random);
            $display(" -- 双通道组合 --");
            $display("   双满=%-6d 双空=%-6d A满B空=%-6d A空B满=%-6d 同时背压=%-6d 双almost_full=%-6d 双almost_empty=%-6d",
                     both_full, both_empty, a_full_b_empty, a_empty_b_full, both_bp, both_af, both_ae);
            $display(" -- 其它场景 --");
            $display("   复位次数=%-4d 时钟暂停=%-4d 指针回卷=%-4d 同步级数配置: 2级=%-4d 3级=%-4d",
                     reset_events, clk_pause_events, ptr_wrap, sync_cfg_2, sync_cfg_3);
            cov_total = (cov_state + cov_op) / 2.0;
            $display("   综合功能覆盖率(状态+操作) = %0.1f%%", cov_total);
            $display("======================================================");
            $display("");
        endfunction
    endclass

    //-------------------------------------------------------------------------
    // 随机激励辅助
    //-------------------------------------------------------------------------
    // 生成"随机/边界/交替"混合数据: 20% 边界值, 10% 交替模式, 70% 随机
    function automatic bit [31:0] gen_data(int unsigned mode);
        bit [31:0] d;
        case (mode % 10)
            0:       d = 32'h0000_0000;
            1:       d = 32'hFFFF_FFFF;
            2:       d = 32'h8000_0000;
            3:       d = 32'hAAAA_AAAA;
            4:       d = 32'h5555_5555;
            default: d = $urandom();
        endcase
        return d;
    endfunction

endpackage

`endif
