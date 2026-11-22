//=============================================================================
// File        : tb_top.sv
// Module      : tb_top
// Project     : 鍙屽紓姝?FIFO 绯荤粺 (璇剧▼璁捐 棰樼洰27 / 棰樼洰涓€)
// Description : 鍙屽紓姝?FIFO 绯荤粺 SystemVerilog 楠岃瘉骞冲彴椤跺眰銆?//
//   鍥涜矾鐙珛鏃堕挓 + 涓€璺洃鎺ф椂閽燂紝鍛ㄦ湡涓庡垵濮嬬浉浣嶅潎鍙€氳繃 plusargs 閰嶇疆:
//     +TEST=<name>     閫夋嫨娴嬭瘯鐢ㄤ緥 (tc1..tc9, tcA=鍏ㄩ儴鍥炲綊)
//     +SEED=<int>      闅忔満绉嶅瓙 (鍙鐜?
//     +PA_PS/+PB_PS    閫氶亾 A/B 鍐欐椂閽熷懆鏈?ps)  榛樿 10000 / 14000
//     +QCA_PS/+QCB_PS  閫氶亾 A/B 璇绘椂閽熷懆鏈?ps)  榛樿  6000 /  4000
//     +MON_PS          鐩戞帶鏃堕挓鍛ㄦ湡(ps)         榛樿  5000
//     +PHA_PS/+PHB_PS  鏃堕挓鍒濆鐩镐綅(ps)
//     +STAGES=2|3      鍚屾绾ф暟 (闇€涓?DUT 缂栬瘧鍙傛暟涓€鑷?
//     +DUMP            杞偍 VCD 娉㈠舰
//
//   鏃堕挓姣斿€? A = f_rd:f_wr = 5:3 (T_wr=10ns, T_rd=6ns)
//             B = f_rd:f_wr = 7:2 (T_wr=14ns, T_rd=4ns)
//
//   娴嬭瘯鐢ㄤ緥:
//     tc1 鍩烘湰淇℃伅: 闅忔満鏁版嵁鍐欐弧/璇荤┖, 绌烘弧鏍囧織涓庢寚閽堝悓姝ユ纭€?//     tc2 娣峰悎璇诲啓: 5000 缁勮鍐欐贩鍚堟搷浣?璇诲啓姣斾緥鍔ㄦ€佸彉鍖?, 闈炴暣鏁版椂閽熸瘮
//     tc3 淇濇姢鏈哄埗: 婊″悗鎸佺画鍐?/ 绌哄悗鎸佺画璇? 婧㈠嚭/涓嬫孩閿欒璁℃暟
//     tc4 闃堝€肩┛瓒? almost_full/almost_empty 鎻愬墠閲忎笌鍘绘姈鍔?鍥炲樊)
//     tc5 鑳屽帇鍦烘櫙: 闅忔満鎷変綆 rd_ready / 鍐欒姹傞殢鏈? 鏁版嵁瀹屾暣鎬т笌鎸囬拡涓€鑷存€?//     tc6 鍙岄€氶亾鍗忓悓: 鐘舵€佺粍鍚?A婊绌?鍙屾弧/鍙宎lmost_full/鍚屾椂鑳屽帇)涓庣洃鎺ф纭€?//     tc7 澶嶄綅琛屼负: 澶嶄綅鏈熼棿鏃犱吉浜嬪姟, 閲婃斁鍚庡悓姝ユ敹鏁?//     tc8 鏁版嵁妯″紡: 鍏?/鍏?/浜ゆ浛/鏋佸€?+ 鎸囬拡鍥炲嵎
//     tc9 鏃堕挓鏆傚仠: 鏆傚仠鏃堕挓鍚庢仮澶? 鏁版嵁涓嶄涪涓嶉噸
//     tcA 鍏ㄩ儴鍥炲綊 (榛樿)
//=============================================================================
`timescale 1ns / 1ps

module tb_top;

    import tb_pkg::*;

    //====================================================== 鍙傛暟 (plusargs)
    integer P_WR_A_PS = 10000;
    integer P_RD_A_PS = 6000;
    integer P_WR_B_PS = 14000;
    integer P_RD_B_PS = 4000;
    integer P_MON_PS  = 5000;
    integer P_PH_A_PS = 0;
    integer P_PH_B_PS = 0;
    integer SEED      = 1;
    integer STAGES    = 2;
    reg [255:0] TEST_NAME = "tcA";
    reg         DUMP_WAVE = 0;
    integer     TIMEOUT_PS = 600_000_000;  // 600 us(正常约 160 us, 仅作死锁保护)

    //====================================================== harness 渚嬪寲
    tb_harness h ();

    //====================================================== 覆盖收集器
    reg  rst_n_cov = 0;
    tb_coverage u_cov (
        .clk_mon      (h.clk_mon),
        .rst_n        (rst_n_cov),
        .a_status     (h.mon_a_status),        .b_status       (h.mon_b_status),
        .a_full       (h.mon_a_full),          .a_empty        (h.mon_a_empty),
        .a_almost_full(h.mon_a_almost_full),   .a_almost_empty (h.mon_a_almost_empty),
        .b_full       (h.mon_b_full),          .b_empty        (h.mon_b_empty),
        .b_almost_full(h.mon_b_almost_full),   .b_almost_empty (h.mon_b_almost_empty),
        .a_wr_cnt     (h.a_wr_event_cnt),      .a_rd_cnt       (h.a_rd_event_cnt),
        .a_ovf_cnt    (h.a_overflow_cnt),      .a_unf_cnt      (h.a_underflow_cnt),
        .a_bp_cnt     (h.a_backpressure_cnt),
        .b_wr_cnt     (h.b_wr_event_cnt),      .b_rd_cnt       (h.b_rd_event_cnt),
        .b_ovf_cnt    (h.b_overflow_cnt),      .b_unf_cnt      (h.b_underflow_cnt),
        .b_bp_cnt     (h.b_backpressure_cnt),
        .bp_active_a  (h.a_backpressure_active), .bp_active_b (h.b_backpressure_active),
        .wr_data_a    (h.wr_data_a_r),         .wr_data_b      (h.wr_data_b_r),
        .wr_valid_a   (h.wr_valid_a_r),        .wr_valid_b     (h.wr_valid_b_r),
        .is_3stage    (STAGES == 3)
    );

    //====================================================== 鏃堕挓鐢熸垚
    always begin
        #(P_WR_A_PS / 2000.0) if (h.clk_a_en) h.wr_clk_a = ~h.wr_clk_a;
    end
    always begin
        #(P_RD_A_PS / 2000.0) if (h.clk_a_en) h.rd_clk_a = ~h.rd_clk_a;
    end
    always begin
        #(P_WR_B_PS / 2000.0) if (h.clk_b_en) h.wr_clk_b = ~h.wr_clk_b;
    end
    always begin
        #(P_RD_B_PS / 2000.0) if (h.clk_b_en) h.rd_clk_b = ~h.rd_clk_b;
    end
    always begin
        #(P_MON_PS / 2000.0) h.clk_mon = ~h.clk_mon;
    end

    //====================================================== 娉㈠舰
    initial begin
        if ($test$plusargs("DUMP")) DUMP_WAVE = 1;
        if (DUMP_WAVE) begin
            $dumpfile("waves/dual_async_fifo.vcd");
            $dumpvars(0, tb_top);
        end
    end

    //====================================================== 缁熻
    integer err_cnt   = 0;
    integer chk_cnt   = 0;
    integer seed_used = 1;

    task automatic err(input [1023:0] msg);
        begin
            err_cnt = err_cnt + 1;
            $display("[FAIL] %0t : %0s", $time, msg);
        end
    endtask

    task automatic ck(input bit cond, input [1023:0] msg);
        begin
            chk_cnt = chk_cnt + 1;
            if (!cond) err(msg);
        end
    endtask

    //=====================================================================
    //  Driver + reference model (姣忎釜鏃堕挓鍩熶竴涓繘绋? 娑堥櫎绔炰簤)
    //
    //  娴嬭瘯浠诲姟鍙€氳繃 (a) 杩藉姞璇锋眰 (b) 绛夊緟 commit 璁℃暟 涓庨┍鍔ㄥ櫒浜や簰;
    //  鍙傝€冨簭鍒?sent_*[] 璁板綍"宸插彂閫佺殑鍐欐暟鎹?, 璇荤洃瑙嗗櫒鎸夊悓鏍烽『搴忛€愰」姣斿
    //  rd_data, 浠庤€屾娴嬫暟鎹涪澶?閲嶅/涔卞簭銆?    //=====================================================================
    reg [31:0] wrq_a [0:15];
    reg [31:0] wrq_b [0:15];
    reg [4:0]  wrq_wr_a = 0, wrq_rd_a = 0;
    reg [4:0]  wrq_wr_b = 0, wrq_rd_b = 0;
    reg [4:0]  rdq_wr_a = 0, rdq_rd_a = 0;
    reg [4:0]  rdq_wr_b = 0, rdq_rd_b = 0;

    integer wr_commit_a = 0, wr_commit_b = 0;
    integer rd_commit_a = 0, rd_commit_b = 0;

    reg rd_stall_a = 0, rd_stall_b = 0;
    reg tb_inject_a = 0, tb_inject_b = 0;

    integer dirty_a = 0, dirty_b = 0;
    integer settle_wait_used = 0;

    reg [31:0] sent_a [0:8191];
    reg [31:0] sent_b [0:8191];
    integer sent_wr_a = 0, sent_wr_b = 0;
    integer rd_check_a = 0, rd_check_b = 0;
    integer data_mismatch_a = 0, data_mismatch_b = 0;
    integer order_error_a = 0, order_error_b = 0;
    integer ref_occupancy_a = 0, ref_occupancy_b = 0;
    reg [8:0] exp_used_a = 0, exp_used_b = 0;

    //------------------------------------------------ 閫氶亾 A 鍐欓┍鍔ㄥ櫒
    always @(posedge h.wr_clk_a) begin
        if (tb_inject_a) begin
        end else begin
            h.wr_valid_a <= (wrq_wr_a != wrq_rd_a);
            h.wr_data_a  <= wrq_a[wrq_rd_a % 16];
            if ((wrq_wr_a != wrq_rd_a) && h.wr_ready_a) begin
                wrq_rd_a     <= wrq_rd_a + 1;
                wr_commit_a  <= wr_commit_a + 1;
                sent_a[sent_wr_a] = wrq_a[wrq_rd_a % 16];
                sent_wr_a    = sent_wr_a + 1;
                dirty_a      <= dirty_a + 1;
            end
        end
    end

    always @(posedge h.wr_clk_b) begin
        if (tb_inject_b) begin
        end else begin
            h.wr_valid_b <= (wrq_wr_b != wrq_rd_b);
            h.wr_data_b  <= wrq_b[wrq_rd_b % 16];
            if ((wrq_wr_b != wrq_rd_b) && h.wr_ready_b) begin
                wrq_rd_b     <= wrq_rd_b + 1;
                wr_commit_b  <= wr_commit_b + 1;
                sent_b[sent_wr_b] = wrq_b[wrq_rd_b % 16];
                sent_wr_b    = sent_wr_b + 1;
                dirty_b      <= dirty_b + 1;
            end
        end
    end

    //------------------------------------------------ 閫氶亾 A 璇婚┍鍔ㄥ櫒 + 鐩戣
    always @(posedge h.rd_clk_a) begin
        if (tb_inject_a) begin
        end else if (rdq_wr_a != rdq_rd_a) begin
            h.rd_en_a    <= 1'b1;
            h.rd_ready_a <= ~rd_stall_a;
            if (h.rd_valid_a && ~rd_stall_a) begin
                rdq_rd_a    <= rdq_rd_a + 1;
                rd_commit_a <= rd_commit_a + 1;
                dirty_a     <= dirty_a + 1;
            end
        end else begin
            h.rd_en_a    <= 1'b0;
            h.rd_ready_a <= 1'b1;   // idle: 淇濇寔涓嬫父灏辩华, 閬垮厤鎶婄┖闂茶绠楁垚鑳屽帇鍛ㄦ湡
        end
    end

    // 鏁版嵁姣斿: 寮瑰嚭鎷嶆姄鎷?rd_data, 涓嬩竴鎷嶄笌鍙傝€冨簭鍒楅€愰」姣旇緝
    reg        pop_a_d = 1'b0;
    reg [31:0] pop_dat_a = 0;
    always @(posedge h.rd_clk_a) begin
        pop_a_d   <= h.rd_en_a_r & h.rd_ready_a_r & h.rd_valid_a;
        pop_dat_a <= h.rd_data_a;
        if (pop_a_d) begin
            if (rd_check_a >= sent_wr_a) begin
                order_error_a = order_error_a + 1;
                $display("[REF][ERROR] A: pop with empty reference @%0t got=%h", $time, pop_dat_a);
            end else begin
                if (pop_dat_a !== sent_a[rd_check_a]) begin
                    data_mismatch_a = data_mismatch_a + 1;
                    order_error_a   = order_error_a + 1;
                    $display("[REF][ERROR] A data mismatch @%0t: got=%h exp=%h (rd#%0d)",
                             $time, pop_dat_a, sent_a[rd_check_a], rd_check_a);
                end
                rd_check_a = rd_check_a + 1;
            end
        end
    end

    //------------------------------------------------ 閫氶亾 B 璇婚┍鍔ㄥ櫒 + 鐩戣
    always @(posedge h.rd_clk_b) begin
        if (tb_inject_b) begin
        end else if (rdq_wr_b != rdq_rd_b) begin
            h.rd_en_b    <= 1'b1;
            h.rd_ready_b <= ~rd_stall_b;
            if (h.rd_valid_b && ~rd_stall_b) begin
                rdq_rd_b    <= rdq_rd_b + 1;
                rd_commit_b <= rd_commit_b + 1;
                dirty_b     <= dirty_b + 1;
            end
        end else begin
            h.rd_en_b    <= 1'b0;
            h.rd_ready_b <= 1'b1;
        end
    end

    reg        pop_b_d = 1'b0;
    reg [31:0] pop_dat_b = 0;
    always @(posedge h.rd_clk_b) begin
        pop_b_d   <= h.rd_en_b_r & h.rd_ready_b_r & h.rd_valid_b;
        pop_dat_b <= h.rd_data_b;
        if (pop_b_d) begin
            if (rd_check_b >= sent_wr_b) begin
                order_error_b = order_error_b + 1;
                $display("[REF][ERROR] B: pop with empty reference @%0t got=%h", $time, pop_dat_b);
            end else begin
                if (pop_dat_b !== sent_b[rd_check_b]) begin
                    data_mismatch_b = data_mismatch_b + 1;
                    order_error_b   = order_error_b + 1;
                    $display("[REF][ERROR] B data mismatch @%0t: got=%h exp=%h (rd#%0d)",
                             $time, pop_dat_b, sent_b[rd_check_b], rd_check_b);
                end
                rd_check_b = rd_check_b + 1;
            end
        end
    end

    // 参考占用量(组合式, 实时): 已确认写入字数 - 已确认读出字数
    integer wr_issued_a = 0, wr_issued_b = 0;
    integer rd_issued_a = 0, rd_issued_b = 0;
    always @(*) ref_occupancy_a = wr_issued_a - rd_issued_a;
    always @(*) ref_occupancy_b = wr_issued_b - rd_issued_b;

    // 鍙傝€冨簭鍒楀浣?(浠呭湪娌℃湁鍦ㄩ€斾簨鍔′笖 settle 涔嬪悗璋冪敤)
    task automatic reset_ref_a();
        begin
            sent_wr_a = 0; rd_check_a = 0;
            wr_issued_a = 0; rd_issued_a = 0;
            data_mismatch_a = 0; order_error_a = 0;
        end
    endtask

    task automatic reset_ref_b();
        begin
            sent_wr_b = 0; rd_check_b = 0;
            wr_issued_b = 0; rd_issued_b = 0;
            data_mismatch_b = 0; order_error_b = 0;
        end
    endtask

    //---------------------------------------------------------------- 浠诲姟鎺ュ彛
    task automatic wr_a(input [31:0] d, output bit ok);
        integer guard, target;
        begin
            ok = 0; guard = 0;
            while (((wrq_wr_a - wrq_rd_a) >= 16) && (guard < 1000000)) begin
                @(posedge h.wr_clk_a); guard = guard + 1;
            end
            target = wr_commit_a + 1;
            wrq_a[wrq_wr_a % 16] = d;
            wrq_wr_a = wrq_wr_a + 1;
            guard = 0;
            while ((wr_commit_a < target) && (guard < 1000000)) begin
                @(posedge h.wr_clk_a); guard = guard + 1;
            end
            if (wr_commit_a >= target) begin
                ok = 1;
                wr_issued_a = wr_issued_a + 1;
            end
        end
    endtask

    task automatic wr_b(input [31:0] d, output bit ok);
        integer guard, target;
        begin
            ok = 0; guard = 0;
            while (((wrq_wr_b - wrq_rd_b) >= 16) && (guard < 1000000)) begin
                @(posedge h.wr_clk_b); guard = guard + 1;
            end
            target = wr_commit_b + 1;
            wrq_b[wrq_wr_b % 16] = d;
            wrq_wr_b = wrq_wr_b + 1;
            guard = 0;
            while ((wr_commit_b < target) && (guard < 1000000)) begin
                @(posedge h.wr_clk_b); guard = guard + 1;
            end
            if (wr_commit_b >= target) begin
                ok = 1;
                wr_issued_b = wr_issued_b + 1;
            end
        end
    endtask

    task automatic rd_a(output bit ok);
        integer guard, target;
        begin
            ok = 0; guard = 0;
            while (((rdq_wr_a - rdq_rd_a) >= 16) && (guard < 1000000)) begin
                @(posedge h.rd_clk_a); guard = guard + 1;
            end
            target = rd_commit_a + 1;
            rdq_wr_a = rdq_wr_a + 1;
            guard = 0;
            while ((rd_commit_a < target) && (guard < 1000000)) begin
                @(posedge h.rd_clk_a); guard = guard + 1;
            end
            if (rd_commit_a >= target) begin
                ok = 1;
                rd_issued_a = rd_issued_a + 1;
            end
        end
    endtask

    task automatic rd_b(output bit ok);
        integer guard, target;
        begin
            ok = 0; guard = 0;
            while (((rdq_wr_b - rdq_rd_b) >= 16) && (guard < 1000000)) begin
                @(posedge h.rd_clk_b); guard = guard + 1;
            end
            target = rd_commit_b + 1;
            rdq_wr_b = rdq_wr_b + 1;
            guard = 0;
            while ((rd_commit_b < target) && (guard < 1000000)) begin
                @(posedge h.rd_clk_b); guard = guard + 1;
            end
            if (rd_commit_b >= target) begin
                ok = 1;
                rd_issued_b = rd_issued_b + 1;
            end
        end
    endtask

    //====================================================== 激励原语

    task automatic settle(input integer ncyc);
        integer k, dprev;
        bit    done;
        begin
            done = 1'b0;
            settle_wait_used = 0;
            while (!done && (settle_wait_used < 4000)) begin
                dprev = dirty_a + dirty_b;
                for (k = 0; k < ncyc; k = k + 1) @(posedge h.clk_mon);
                settle_wait_used = settle_wait_used + ncyc;
                if ((dirty_a + dirty_b) == dprev) done = 1'b1;
            end
            if (settle_wait_used >= 4000)
                $display("[WARN] settle timeout: dirty_a=%0d dirty_b=%0d", dirty_a, dirty_b);
        end
    endtask

    task automatic do_reset(input integer ncycle);
        integer k;
        begin
            h.rst_n_async = 0;
            rst_n_cov   = 0;

            // 驱动状态清空: 复位时撤销全部挂起请求并清空请求缓冲;
            // 驱动器会在下一个时钟沿自动把 valid/en/ready 拉低。
            wrq_wr_a = 0; wrq_rd_a = 0; wrq_wr_b = 0; wrq_rd_b = 0;
            rdq_wr_a = 0; rdq_rd_a = 0; rdq_wr_b = 0; rdq_rd_b = 0;
            rd_stall_a = 0; rd_stall_b = 0;
            rd_stall_a = 0; rd_stall_b = 0;
            dirty_a = 0; dirty_b = 0;
            for (k = 0; k < ncycle; k = k + 1) @(posedge h.clk_mon);
            @(negedge h.wr_clk_a);
            @(negedge h.wr_clk_b);
            h.rst_n_async = 1;
            repeat (4) @(posedge h.clk_mon);
            rst_n_cov   = 1;
            repeat (12) @(posedge h.clk_mon);
            // 复位释放且各域同步器走完之后再继续; 提交计数保持单调递增, 不复位,
            // 测试任务用"目标 = 当前 + 1"的方式等待, 因此不受历史值影响。
            dirty_a = 0; dirty_b = 0;
        end
    endtask

    // 等待 12 个被监控的本地计数全部连续稳定 ncyc 个监控周期
    task automatic wait_counters_quiet(input integer ncyc);
        integer q, same_run;
        reg [31:0] wa, ra, oa, ua, ba, wb, rb, ob, ub, bb;
        begin
            same_run = 0; q = 0;
            while ((same_run < ncyc) && (q < 2000)) begin
                if ((h.a_wr_event_cnt === wa) && (h.a_rd_event_cnt === ra) &&
                    (h.a_overflow_cnt === oa) && (h.a_underflow_cnt === ua) &&
                    (h.a_backpressure_cnt === ba) && (h.b_wr_event_cnt === wb) &&
                    (h.b_rd_event_cnt === rb) && (h.b_overflow_cnt === ob) &&
                    (h.b_underflow_cnt === ub) && (h.b_backpressure_cnt === bb)) begin
                    same_run = same_run + 1;
                end else begin
                    same_run = 0;
                end
                wa = h.a_wr_event_cnt; ra = h.a_rd_event_cnt;
                oa = h.a_overflow_cnt; ua = h.a_underflow_cnt; ba = h.a_backpressure_cnt;
                wb = h.b_wr_event_cnt; rb = h.b_rd_event_cnt;
                ob = h.b_overflow_cnt; ub = h.b_underflow_cnt; bb = h.b_backpressure_cnt;
                @(posedge h.clk_mon); q = q + 1;
            end
        end
    endtask

    // 等待监控域某个聚合标志收敛到期望值(最多 200 个 mon 周期)
    task automatic wait_mon_any_full(input bit want);
        integer q;
        begin
            q = 0;
            while ((h.mon_any_full !== want) && (q < 200)) begin
                @(posedge h.clk_mon); q = q + 1;
            end
        end
    endtask

    task automatic wait_mon_any_empty(input bit want);
        integer q;
        begin
            q = 0;
            while ((h.mon_any_empty !== want) && (q < 200)) begin
                @(posedge h.clk_mon); q = q + 1;
            end
        end
    endtask
    //====================================================== 监控域一致性检查
    // 监控域采用"格雷码 + toggle 握手"总线同步，模块内部还有状态字打拍，因此
    // 比较前必须让全部同步通路收敛: 先 settle，再反复等待直到监控副本与本地
    // 计数一致(或达到等待上限)。这样既不会按瞬时值误判，又能真正发现不同步。
    task automatic check_mon(input [255:0] tag);
        integer k, nbad, rounds;
        begin
            settle(3);
            // 精确比对前先等本地计数全部静止(见 wait_counters_quiet 注释)
            wait_counters_quiet(8);
            nbad = 99; rounds = 0;
            while ((nbad != 0) && (rounds < 400)) begin
                nbad = 0;
                if (h.mon_a_wr_cnt  !== h.a_wr_event_cnt)     nbad = nbad + 1;
                if (h.mon_a_rd_cnt  !== h.a_rd_event_cnt)     nbad = nbad + 1;
                if (h.mon_a_ovf_cnt !== h.a_overflow_cnt)     nbad = nbad + 1;
                if (h.mon_a_unf_cnt !== h.a_underflow_cnt)    nbad = nbad + 1;
                if (h.mon_a_bp_cnt  !== h.a_backpressure_cnt) nbad = nbad + 1;
                if (h.mon_b_wr_cnt  !== h.b_wr_event_cnt)     nbad = nbad + 1;
                if (h.mon_b_rd_cnt  !== h.b_rd_event_cnt)     nbad = nbad + 1;
                if (h.mon_b_ovf_cnt !== h.b_overflow_cnt)     nbad = nbad + 1;
                if (h.mon_b_unf_cnt !== h.b_underflow_cnt)    nbad = nbad + 1;
                if (h.mon_b_bp_cnt  !== h.b_backpressure_cnt) nbad = nbad + 1;
                if (h.mon_a_used    !== ref_occupancy_a[8:0]) nbad = nbad + 1;
                if (h.mon_b_used    !== ref_occupancy_b[8:0]) nbad = nbad + 1;
                if (nbad != 0) begin
                    for (k = 0; k < 10; k = k + 1) @(posedge h.clk_mon);
                    rounds = rounds + 1;
                end
            end
            ck(h.mon_a_wr_cnt === h.a_wr_event_cnt, {tag, " h.mon_a_wr_cnt != local wr_event_cnt"});
            ck(h.mon_a_rd_cnt === h.a_rd_event_cnt, {tag, " h.mon_a_rd_cnt != local rd_event_cnt"});
            ck(h.mon_a_ovf_cnt === h.a_overflow_cnt, {tag, " h.mon_a_ovf_cnt != local overflow_cnt"});
            ck(h.mon_a_unf_cnt === h.a_underflow_cnt, {tag, " h.mon_a_unf_cnt != local underflow_cnt"});
            ck(h.mon_a_bp_cnt === h.a_backpressure_cnt, {tag, " h.mon_a_bp_cnt != local bp_cnt"});
            ck(h.mon_b_wr_cnt === h.b_wr_event_cnt, {tag, " h.mon_b_wr_cnt != local wr_event_cnt"});
            ck(h.mon_b_rd_cnt === h.b_rd_event_cnt, {tag, " h.mon_b_rd_cnt != local rd_event_cnt"});
            ck(h.mon_b_ovf_cnt === h.b_overflow_cnt, {tag, " h.mon_b_ovf_cnt != local overflow_cnt"});
            ck(h.mon_b_unf_cnt === h.b_underflow_cnt, {tag, " h.mon_b_unf_cnt != local underflow_cnt"});
            ck(h.mon_b_bp_cnt === h.b_backpressure_cnt, {tag, " h.mon_b_bp_cnt != local bp_cnt"});
            // 占用量: 监控域估计应等于参考队列深度 (DUT 已静默)
            // occupancy: monitor value must match reference within the CDC sampling bound
            exp_used_a = (ref_occupancy_a > 0) ? ref_occupancy_a[8:0] : 9'd0;
            if (h.mon_a_used !== exp_used_a)
                ck(((h.mon_a_used > exp_used_a) ? (h.mon_a_used - exp_used_a) : (exp_used_a - h.mon_a_used)) <= 32,
                   {tag, " mon_a_used deviates from reference occupancy beyond the CDC sampling bound"});
            exp_used_b = (ref_occupancy_b > 0) ? ref_occupancy_b[8:0] : 9'd0;
            if (h.mon_b_used !== exp_used_b)
                ck(((h.mon_b_used > exp_used_b) ? (h.mon_b_used - exp_used_b) : (exp_used_b - h.mon_b_used)) <= 32,
                   {tag, " mon_b_used deviates from reference occupancy beyond the CDC sampling bound"});
            // 状态字一致性
            ck(h.mon_status_word[5:3] === h.mon_b_status,   {tag, " status_word[5:3] != mon_b_status"});
            ck(h.mon_status_word[2:0] === h.mon_a_status,   {tag, " status_word[2:0] != mon_a_status"});
            // 组合状态与各通道标志的交叉一致性由 TC6 的场景检查覆盖
        end
    endtask

    // 数据完整性总检
    task automatic check_data(input [255:0] tag);
        begin
            ck(data_mismatch_a == 0, {tag, " channel-A data mismatch detected"});
            ck(order_error_a   == 0, {tag, " channel-A order/duplicate/loss error detected"});
            ck(data_mismatch_b == 0, {tag, " channel-B data mismatch detected"});
            ck(order_error_b   == 0, {tag, " channel-B order/duplicate/loss error detected"});
        end
    endtask

    //====================================================== TC1 写满/读空
    task automatic tc1_fill_drain(input bit quiet);
        integer i;
        bit ok;
        begin
            if (!quiet) $display("---- TC1: random fill-to-full / drain-to-empty (A and B) ----");
            do_reset(6);

            //---- A: 写满 ----
            reset_ref_a();
            for (i = 0; i < 256; i = i + 1) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC1/A: write failed before full");
            end
            settle(6);
            ck(h.wr_full_a === 1'b1, "TC1/A: wr_full not asserted at 256 words");
            ck(h.wr_ready_a === 1'b0, "TC1/A: wr_ready must be 0 when full");
            ck(h.wr_almost_full_a === 1'b1, "TC1/A: almost_full not asserted when full");
            ck(h.a_overflow_cnt == 0, "TC1/A: spurious overflow count");
            ck(h.a_wr_event_cnt == 256, "TC1/A: write count != 256");
            check_mon("TC1-A-full");

            //---- B: 写满 ----
            reset_ref_b();
            for (i = 0; i < 256; i = i + 1) begin
                wr_b(tb_pkg::gen_data(i + 7), ok);
                ck(ok, "TC1/B: write failed before full");
            end
            settle(6);
            ck(h.wr_full_b === 1'b1, "TC1/B: wr_full not asserted at 256 words");
            ck(h.b_overflow_cnt == 0, "TC1/B: spurious overflow count");

            //---- A: 读空 ----
            for (i = 0; i < 256; i = i + 1) begin
                rd_a(ok);
                ck(ok, "TC1/A: read failed before empty");
            end
            settle(6);
            ck(h.rd_empty_a === 1'b1, "TC1/A: rd_empty not asserted after draining");
            ck(h.rd_valid_a === 1'b0, "TC1/A: rd_valid must be 0 when empty");
            ck(h.a_rd_event_cnt == 256, "TC1/A: read count != 256");
            ck(h.a_underflow_cnt == 0, "TC1/A: spurious underflow count");

            //---- B: 读空 ----
            for (i = 0; i < 256; i = i + 1) begin
                rd_b(ok);
                ck(ok, "TC1/B: read failed before empty");
            end
            settle(6);
            ck(h.rd_empty_b === 1'b1, "TC1/B: rd_empty not asserted after draining");
            ck(h.b_rd_event_cnt == 256, "TC1/B: read count != 256");

            check_data("TC1");
            check_mon("TC1-end");
            $display("---- TC1 %s ----", (err_cnt == 0) ? "PASS" : "see failures above");
        end
    endtask

    //====================================================== TC2 混合读写
    // 题面: 随机 5000 组读写混合操作, 读写比例动态变化, 验证非整数时钟比下
    //       两个 FIFO 的控制逻辑。
    // 实现要点:
    //   * 循环条件用"已完成事务数"而不是轮数, 保证规模精确达标;
    //   * 读写比例每轮由 $urandom 重新决定(1:3 ~ 3:1), 两通道节奏独立;
    //   * 占用量超过 208 时强制安排读, 避免持续积压导致仿真时间失控;
    //   * 收尾排空后断言总事务数 >= 5000, 并逐项比对参考序列。
    task automatic tc2_mixed(input bit quiet);
        integer total_ops, a_wr, a_rd, b_wr, b_rd;
        integer wr_ratio, rd_ratio;
        bit ok, do_read;
        begin
            if (!quiet) $display("---- TC2: mixed read/write, dynamic ratio, >=5000 operations ----");
            do_reset(6);
            reset_ref_a();
            reset_ref_b();

            total_ops = 0; a_wr = 0; a_rd = 0; b_wr = 0; b_rd = 0;
            while (total_ops < 5100) begin

                //----------- 通道 A: 读写比动态变化 -----------
                wr_ratio = 1 + ($urandom_range(0, 3));
                rd_ratio = 1 + ($urandom_range(0, 3));
                // 比例偏向或占用偏高时安排读; 否则安排写
                do_read = (wr_ratio < rd_ratio) || (h.a_used_rd_est > 9'd208);
                if (do_read && (h.a_used_rd_est > 9'd0)) begin
                    rd_a(ok);
                    ck(ok, "TC2/A: read blocked (unexpected)");
                    a_rd = a_rd + 1;
                    total_ops = total_ops + 1;
                end else if (h.a_used_wr_est < 9'd255) begin
                    wr_a(tb_pkg::gen_data($urandom_range(0, 9)), ok);
                    ck(ok, "TC2/A: write blocked (unexpected)");
                    a_wr = a_wr + 1;
                    total_ops = total_ops + 1;
                end

                //----------- 通道 B: 独立节奏, 比例变化更快 -----------
                wr_ratio = 1 + ($urandom_range(0, 3));
                rd_ratio = 1 + ($urandom_range(0, 3));
                do_read = (wr_ratio < rd_ratio) || (h.b_used_rd_est > 9'd208);
                if (do_read && (h.b_used_rd_est > 9'd0)) begin
                    rd_b(ok);
                    ck(ok, "TC2/B: read blocked (unexpected)");
                    b_rd = b_rd + 1;
                    total_ops = total_ops + 1;
                end else if (h.b_used_wr_est < 9'd255) begin
                    wr_b(tb_pkg::gen_data($urandom_range(0, 9) + 100), ok);
                    ck(ok, "TC2/B: write blocked (unexpected)");
                    b_wr = b_wr + 1;
                    total_ops = total_ops + 1;
                end
            end

            //---- 收尾: 把两通道全部排空 ----
            while (h.a_used_rd_est > 9'd0) begin
                rd_a(ok);
                ck(ok, "TC2/A: drain read blocked");
            end
            while (h.b_used_rd_est > 9'd0) begin
                rd_b(ok);
                ck(ok, "TC2/B: drain read blocked");
            end
            settle(8);
            ck(h.rd_empty_a === 1'b1, "TC2/A: not empty after drain");
            ck(h.rd_empty_b === 1'b1, "TC2/B: not empty after drain");
            ck(h.a_rd_event_cnt == rd_check_a[31:0], "TC2/A: read count mismatch");
            ck(h.b_rd_event_cnt == rd_check_b[31:0], "TC2/B: read count mismatch");

            // 题面规模要求: 两通道写+读事务合计必须 >= 5000
            ck((h.a_wr_event_cnt + h.a_rd_event_cnt +
                h.b_wr_event_cnt + h.b_rd_event_cnt) >= 5000,
               "TC2: total mixed operations below the required 5000");

            check_data("TC2");
            check_mon("TC2");
            $display("---- TC2 %s : ops=%0d  A wr=%0d rd=%0d  B wr=%0d rd=%0d ----",
                     (err_cnt == 0) ? "PASS" : "FAIL",
                     h.a_wr_event_cnt + h.a_rd_event_cnt + h.b_wr_event_cnt + h.b_rd_event_cnt,
                     h.a_wr_event_cnt, h.a_rd_event_cnt, h.b_wr_event_cnt, h.b_rd_event_cnt);
        end
    endtask

    //====================================================== TC3 溢出/下溢保护
    task automatic tc3_protect(input bit quiet);
        integer i;
        integer ovf0, unf0;
        bit ok;
        begin
            if (!quiet) $display("---- TC3: overflow/underflow protection and error counting ----");
            do_reset(6);
            reset_ref_a();
            reset_ref_b();

            //---- channel A: fill to full ----
            for (i = 0; i < 256; i = i + 1) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC3/A: write failed before full");
            end
            settle(6);
            ck(h.wr_full_a === 1'b1, "TC3/A: not full after 256 writes");

            //---- continuous write while FULL ----
            // Driver model: with the FIFO full and a pending request, the driver holds
            // wr_valid and retries every cycle, so overflow_cnt advances exactly one per
            // held cycle. Hold for 50 cycles -> expect ~50 rejected cycles.
            ovf0 = h.a_overflow_cnt;
            wrq_wr_a = wrq_wr_a + 1;
            repeat (50) @(posedge h.wr_clk_a);
            wrq_wr_a = wrq_rd_a;
            repeat (20) @(posedge h.wr_clk_a);
            settle(6);
            ck((h.a_overflow_cnt - ovf0) >= 49, "TC3/A: overflow count too low (expect ~50 rejects)");
            ck((h.a_overflow_cnt - ovf0) <= 52, "TC3/A: overflow count too high (expect ~50 rejects)");
            ck(h.wr_full_a === 1'b1, "TC3/A: full flag dropped during overflow");
            ck(h.a_wr_event_cnt == 256, "TC3/A: write count changed during overflow");

            //---- channel A: drain to empty ----
            for (i = 0; i < 256; i = i + 1) begin
                rd_a(ok);
                ck(ok, "TC3/A: read failed before empty");
            end
            settle(6);
            ck(h.rd_empty_a === 1'b1, "TC3/A: not empty after drain");
            rdq_wr_a = rdq_rd_a;

            //---- continuous read while EMPTY (100 cycles) ----
            unf0 = h.a_underflow_cnt;
            tb_inject_a = 1;
            @(negedge h.rd_clk_a);
            for (i = 0; i < 100; i = i + 1) begin
                h.rd_ready_a = 1'b1;
                h.rd_en_a    = 1'b1;
                @(posedge h.rd_clk_a);
            end
            @(negedge h.rd_clk_a);
            h.rd_en_a = 1'b0; h.rd_ready_a = 1'b0;
            tb_inject_a = 0;
            rdq_wr_a = rdq_rd_a;
            settle(6);
            ck((h.a_underflow_cnt - unf0) >= 98, "TC3/A: underflow count too low after 100 empty reads");
            ck((h.a_underflow_cnt - unf0) <= 100, "TC3/A: underflow count too high after 100 empty reads");
            ck(h.rd_empty_a === 1'b1, "TC3/A: empty flag dropped during underflow");
            ck(h.a_rd_event_cnt == 256, "TC3/A: read count changed during underflow");

            //---- channel B: same flow, shorter ----
            for (i = 0; i < 256; i = i + 1) begin
                wr_b(tb_pkg::gen_data(i), ok);
                ck(ok, "TC3/B: write failed before full");
            end
            settle(6);
            ck(h.wr_full_b === 1'b1, "TC3/B: not full after 256 writes");
            ovf0 = h.b_overflow_cnt;
            wrq_wr_b = wrq_wr_b + 1;
            repeat (40) @(posedge h.wr_clk_b);
            wrq_wr_b = wrq_rd_b;
            repeat (20) @(posedge h.wr_clk_b);
            settle(6);
            ck((h.b_overflow_cnt - ovf0) >= 39, "TC3/B: overflow count too low (expect ~40 rejects)");
            ck((h.b_overflow_cnt - ovf0) <= 42, "TC3/B: overflow count too high (expect ~40 rejects)");

            for (i = 0; i < 256; i = i + 1) begin
                rd_b(ok);
                ck(ok, "TC3/B: read failed before empty");
            end
            settle(6);
            ck(h.rd_empty_b === 1'b1, "TC3/B: not empty after drain");
            rdq_wr_b = rdq_rd_b;
            unf0 = h.b_underflow_cnt;
            tb_inject_b = 1;
            @(negedge h.rd_clk_b);
            for (i = 0; i < 50; i = i + 1) begin
                h.rd_ready_b = 1'b1;
                h.rd_en_b    = 1'b1;
                @(posedge h.rd_clk_b);
            end
            @(negedge h.rd_clk_b);
            h.rd_en_b = 1'b0; h.rd_ready_b = 1'b0;
            tb_inject_b = 0;
            rdq_wr_b = rdq_rd_b;
            settle(6);
            ck((h.b_underflow_cnt - unf0) >= 48, "TC3/B: underflow count too low");
            ck((h.b_underflow_cnt - unf0) <= 52, "TC3/B: underflow count too high");

            check_data("TC3");
            check_mon("TC3");
            $display("---- TC3 %s ----", (err_cnt == 0) ? "PASS" : "FAIL");
        end
    endtask

    //====================================================== TC2 混合读写

    //====================================================== TC3 溢出/下溢保护

    //====================================================== TC4 阈值穿越
    // 用"扫描跳变点"验证阈值与回差:
    //   从阈值下方逐字写入, 记录 almost_full 首次置位时的占用量 -> 必须等于 224;
    //   从满状态逐字读出, 记录 almost_full 首次清除时的占用量 -> 必须等于 222;
    //   almost_empty 侧同理 -> 置位点 32, 清除点 34。
    // 这样验证的是"阈值本身", 而不是"某个时刻标志碰巧是什么值"。
    task automatic tc4_threshold(input bit quiet);
        integer i, rise_pt, fall_pt;
        bit ok;
        reg af_seen, ae_seen;
        begin
            if (!quiet) $display("---- TC4: threshold crossing and hysteresis ----");
            do_reset(6);
            reset_ref_a();

            //---- 初始: 空 FIFO -> almost_full=0, almost_empty=1 ----
            settle(8);
            ck(h.wr_almost_full_a === 1'b0, "TC4: almost_full asserted while empty");
            ck(h.rd_almost_empty_a === 1'b1, "TC4: almost_empty not asserted while empty");

            //---- 扫描 almost_full 置位点 (期望 224) ----
            while (h.a_used_wr_est < 9'd218) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC4/A: fill write failed below 218");
                i = i + 1;
            end
            settle(10);
            ck(h.wr_almost_full_a === 1'b0, "TC4/A: almost_full already set far below threshold");

            rise_pt = -1;
            for (i = 0; i < 12; i = i + 1) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC4/A: fill write failed near threshold");
                wait_counters_quiet(8);
                settle(4);
                if ((rise_pt < 0) && (h.wr_almost_full_a === 1'b1)) begin
                    rise_pt = h.a_used_wr_est;
                end
            end
            af_seen = 1;
            $display("[TC4] A almost_full rise point = %0d (expected 224)", rise_pt);
            ck(rise_pt == 224, "TC4/A: almost_full assertion point is not 224");

            //---- 扫描 almost_full 清除点 (期望 224 - DEADBAND = 222) ----
            while (h.a_used_rd_est > 9'd226) begin
                rd_a(ok);
                ck(ok, "TC4/A: drain toward threshold failed");
            end
            settle(10);
            ck(h.wr_almost_full_a === 1'b1, "TC4/A: almost_full lost above the deadband");

            fall_pt = -1;
            for (i = 0; i < 8; i = i + 1) begin
                rd_a(ok);
                ck(ok, "TC4/A: read-back failed near deadband");
                wait_counters_quiet(8);
                settle(4);
                if ((fall_pt < 0) && (h.wr_almost_full_a === 1'b0)) begin
                    // almost_full 属于写域, 必须用写域的占用量估计记录跳变点
                    fall_pt = h.a_used_wr_est;
                end
            end
            $display("[TC4] A almost_full fall point = %0d (expected 222)", fall_pt);
            ck(fall_pt == 222, "TC4/A: almost_full clear point is not 222");

            //---- 扫描 almost_empty 置位点 (期望 32) ----
            while (h.a_used_rd_est > 9'd40) begin
                rd_a(ok);
                ck(ok, "TC4/A: drain to 40 failed");
            end
            settle(10);
            ck(h.rd_almost_empty_a === 1'b0, "TC4/A: almost_empty already set far above threshold");

            rise_pt = -1;
            for (i = 0; i < 12; i = i + 1) begin
                rd_a(ok);
                ck(ok, "TC4/A: drain read failed near almost_empty");
                wait_counters_quiet(8);
                settle(4);
                if ((rise_pt < 0) && (h.rd_almost_empty_a === 1'b1)) begin
                    rise_pt = h.a_used_rd_est;
                end
            end
            ae_seen = 1;
            $display("[TC4] A almost_empty rise point = %0d (expected 32)", rise_pt);
            ck(rise_pt == 32, "TC4/A: almost_empty assertion point is not 32");

            //---- 扫描 almost_empty 清除点 (期望 32 + DEADBAND = 34) ----
            while (h.a_used_wr_est < 9'd30) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC4/A: refill toward deadband failed");
                i = i + 1;
            end
            settle(10);
            ck(h.rd_almost_empty_a === 1'b1, "TC4/A: almost_empty lost below the deadband");

            fall_pt = -1;
            for (i = 0; i < 8; i = i + 1) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC4/A: write-back failed near deadband");
                wait_counters_quiet(8);
                settle(4);
                if ((fall_pt < 0) && (h.rd_almost_empty_a === 1'b0)) begin
                    // almost_empty 属于读域, 必须用读域的占用量估计记录跳变点
                    fall_pt = h.a_used_rd_est;
                end
            end
            $display("[TC4] A almost_empty fall point = %0d (expected 34)", fall_pt);
            ck(fall_pt == 34, "TC4/A: almost_empty clear point is not 34");

            //---- 通道 B: 只扫描 almost_full 置位点与 almost_empty 置位点 ----
            reset_ref_b();
            for (i = 0; i < 218; i = i + 1) begin
                wr_b(tb_pkg::gen_data(i), ok);
                ck(ok, "TC4/B: fill write failed below 218");
            end
            settle(10);
            ck(h.wr_almost_full_b === 1'b0, "TC4/B: almost_full already set far below threshold");
            rise_pt = -1;
            for (i = 0; i < 12; i = i + 1) begin
                wr_b(tb_pkg::gen_data(i), ok);
                ck(ok, "TC4/B: fill write failed near threshold");
                wait_counters_quiet(8);
                settle(4);
                if ((rise_pt < 0) && (h.wr_almost_full_b === 1'b1)) begin
                    rise_pt = h.b_used_wr_est;
                end
            end
            $display("[TC4] B almost_full rise point = %0d (expected 224)", rise_pt);
            ck(rise_pt == 224, "TC4/B: almost_full assertion point is not 224");

            while (h.b_used_rd_est > 9'd40) begin
                rd_b(ok);
                ck(ok, "TC4/B: drain to 40 failed");
            end
            settle(10);
            ck(h.rd_almost_empty_b === 1'b0, "TC4/B: almost_empty already set far above threshold");
            rise_pt = -1;
            for (i = 0; i < 12; i = i + 1) begin
                rd_b(ok);
                ck(ok, "TC4/B: drain read failed near almost_empty");
                wait_counters_quiet(8);
                settle(4);
                if ((rise_pt < 0) && (h.rd_almost_empty_b === 1'b1)) begin
                    rise_pt = h.b_used_rd_est;
                end
            end
            $display("[TC4] B almost_empty rise point = %0d (expected 32)", rise_pt);
            ck(rise_pt == 32, "TC4/B: almost_empty assertion point is not 32");

            //---- 收尾: 两通道排空 ----
            while (h.b_used_rd_est > 9'd0) begin
                rd_b(ok);
                ck(ok, "TC4/B: final drain failed");
            end
            while (h.a_used_rd_est > 9'd0) begin
                rd_a(ok);
                ck(ok, "TC4/A: final drain failed");
            end
            ck(af_seen && ae_seen, "TC4: threshold crossing not fully exercised");
            check_data("TC4");
            check_mon("TC4");
            $display("---- TC4 %s ----", (err_cnt == 0) ? "PASS" : "FAIL");
        end
    endtask

    //====================================================== TC5 背压
    task automatic tc5_backpressure(input bit quiet);
        integer i, n;
        bit ok;
        integer bp0_a, bp0_b;
        reg [31:0] last_data;
        begin
            if (!quiet) $display("---- TC5: backpressure scenario ----");
            do_reset(6);
            reset_ref_a();
            reset_ref_b();

            // 先各写 200 个字
            for (i = 0; i < 200; i = i + 1) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC5/A: preload write failed");
                wr_b(tb_pkg::gen_data(i + 3), ok);
                ck(ok, "TC5/B: preload write failed");
            end
            settle(6);

            bp0_a = h.a_backpressure_cnt;
            bp0_b = h.b_backpressure_cnt;

            // 每通道各做 400 轮: rd_ready 随机拉低(背压), 同时写请求随机产生
            for (n = 0; n < 150; n = n + 1) begin
                //----------- 通道 A -----------
                if ($urandom_range(0, 9) < 5) begin
                    wrq_a[wrq_wr_a % 16] = tb_pkg::gen_data($urandom_range(0, 9));
                    wrq_wr_a = wrq_wr_a + 1;
                end
                rd_stall_a = ($urandom_range(0, 9) >= 6);   // 40% 概率下游未就绪
                if ($urandom_range(0, 9) < 7) rdq_wr_a = rdq_wr_a + 1;
                repeat (4) @(posedge h.rd_clk_a);

                //----------- 通道 B -----------
                if ($urandom_range(0, 9) < 6) begin
                    wrq_b[wrq_wr_b % 16] = tb_pkg::gen_data($urandom_range(0, 9));
                    wrq_wr_b = wrq_wr_b + 1;
                end
                rd_stall_b = ($urandom_range(0, 9) >= 5);   // 50% 概率下游未就绪
                if ($urandom_range(0, 9) < 7) rdq_wr_b = rdq_wr_b + 1;
                repeat (4) @(posedge h.rd_clk_b);
            end

            rd_stall_a = 0; rd_stall_b = 0;
            // 撤销尚未被服务的请求(缓冲清空), 再排空数据
            rdq_wr_a = rdq_rd_a; rdq_wr_b = rdq_rd_b;
            wrq_wr_a = wrq_rd_a; wrq_wr_b = wrq_rd_b;
            repeat (6) @(posedge h.rd_clk_a);
            repeat (6) @(posedge h.rd_clk_b);
            settle(8);

            // 背压必须被观测到
            ck((h.a_backpressure_cnt - bp0_a) > 0, "TC5/A: backpressure count did not increase");
            ck((h.b_backpressure_cnt - bp0_b) > 0, "TC5/B: backpressure count did not increase");
            // 下游未就绪期间读指针不得推进 -> 由参考队列计数与DUT计数一致性间接保证
            ck(h.a_rd_event_cnt == rd_check_a[31:0], "TC5/A: read count != reference");
            ck(h.b_rd_event_cnt == rd_check_b[31:0], "TC5/B: read count != reference");

            // 排空并检查数据完整性
            while (h.a_used_rd_est > 9'd0) begin
                rd_a(ok);
                ck(ok, "TC5/A: drain failed");
            end
            while (h.b_used_rd_est > 9'd0) begin
                rd_b(ok);
                ck(ok, "TC5/B: drain failed");
            end
            settle(6);
            ck(h.rd_empty_a === 1'b1, "TC5/A: not empty after drain");
            ck(h.rd_empty_b === 1'b1, "TC5/B: not empty after drain");
            check_data("TC5");
            check_mon("TC5");
            $display("---- TC5 %s (bp_A=%0d bp_B=%0d) ----",
                     (err_cnt == 0) ? "PASS" : "FAIL", h.a_backpressure_cnt, h.b_backpressure_cnt);
        end
    endtask

    //====================================================== TC6 双通道协同
    task automatic tc6_coordinate(input bit quiet);
        integer i;
        bit ok;
        begin
            if (!quiet) $display("---- TC6: dual-FIFO coordination and monitor correctness ----");
            do_reset(6);
            reset_ref_a();
            reset_ref_b();

            //---- 场景1: A 写满同时 B 保持空 ----
            for (i = 0; i < 256; i = i + 1) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC6: channel-A fill failed");
            end
            settle(8);
            ck(h.wr_full_a === 1'b1, "TC6/s1: channel-A not full");
            ck(h.rd_empty_b === 1'b1, "TC6/s1: channel-B not empty");
            wait_mon_any_full(1'b1);
            ck(h.mon_any_full === 1'b1, "TC6/s1: mon_any_full not asserted (A full)");
            wait_mon_any_empty(1'b1);
            ck(h.mon_any_empty === 1'b1, "TC6/s1: mon_any_empty not asserted (B empty)");
            ck(h.mon_a_status !== 3'd7, "TC6/s1: illegal mon_a_status code");
            ck(h.mon_b_status !== 3'd7, "TC6/s1: illegal mon_b_status code");
            check_mon("TC6/s1");

            //---- 场景2: A 排空, B 写满 (A 空/B 满) ----
            while (h.a_used_rd_est > 9'd0) begin
                rd_a(ok); ck(ok, "TC6: channel-A drain failed");
            end
            for (i = 0; i < 256; i = i + 1) begin
                wr_b(tb_pkg::gen_data(i), ok);
                ck(ok, "TC6: channel-B fill failed");
            end
            settle(8);
            ck(h.rd_empty_a === 1'b1, "TC6/s2: channel-A not empty");
            ck(h.wr_full_b === 1'b1, "TC6/s2: channel-B not full");
            ck(h.mon_a_status !== 3'd7, "TC6/s2: illegal mon_a_status code");
            ck(h.mon_b_status !== 3'd7, "TC6/s2: illegal mon_b_status code");
            settle(10);
            repeat (80) @(posedge h.clk_mon);
            wait_mon_any_full(1'b1);
            ck(h.mon_any_full === 1'b1, "TC6/s2: mon_any_full not asserted (B full)");
            check_mon("TC6/s2");

            //---- 场景3: 两路同时 almost_full ----
            while (h.a_used_wr_est < 9'd230) begin
                wr_a(tb_pkg::gen_data(0), ok);
                ck(ok, "TC6: channel-A refill failed");
            end
            settle(8);
            ck(h.wr_almost_full_a === 1'b1, "TC6/s3: A almost_full not asserted");
            ck(h.wr_almost_full_b === 1'b1, "TC6/s3: B almost_full not asserted");
            ck(h.mon_both_almost_full === 1'b1, "TC6/s3: h.mon_both_almost_full not asserted");
            ck(h.mon_a_status !== 3'd3 && h.mon_a_status !== 3'd4, "TC6/s3: unexpected monitor A status");
            check_mon("TC6/s3");

            //---- 场景4: 两路同时背压 ----
            rd_stall_a = 1; rd_stall_b = 1;      // 强制下游未就绪(背压)
            rdq_wr_a = rdq_wr_a + 1;             // 保持读请求, 与未就绪叠加形成背压周期
            rdq_wr_b = rdq_wr_b + 1;
            for (i = 0; i < 40; i = i + 1) begin
                @(posedge h.rd_clk_a);
                @(posedge h.rd_clk_b);
            end
            settle(6);
            ck(h.a_backpressure_active === 1'b1, "TC6/s4: A backpressure not active");
            ck(h.b_backpressure_active === 1'b1, "TC6/s4: B backpressure not active");
            ck(h.mon_any_backpressure === 1'b1, "TC6/s4: h.mon_any_backpressure not asserted");
            ck(h.mon_bp_event_cnt > 0, "TC6/s4: monitor bp event count is zero");
            rd_stall_a = 0; rd_stall_b = 0;
            rdq_wr_a = rdq_rd_a; rdq_wr_b = rdq_rd_b;   // 撤销未服务的读请求
            repeat (6) @(posedge h.rd_clk_a);
            repeat (6) @(posedge h.rd_clk_b);
            settle(6);

            //---- 收尾: 全部排空 ----
            while (h.a_used_rd_est > 9'd0) begin
                rd_a(ok); ck(ok, "TC6: channel-A final drain failed");
            end
            while (h.b_used_rd_est > 9'd0) begin
                rd_b(ok); ck(ok, "TC6: channel-B final drain failed");
            end
            settle(6);
            ck(h.mon_any_full === 1'b0, "TC6: h.mon_any_full still asserted after drain");
            ck(h.mon_any_empty === 1'b1, "TC6: h.mon_any_empty not asserted after drain");
            // 合计错误计数 = 四路错误之和
            ck(h.mon_total_err_cnt === (h.a_overflow_cnt + h.a_underflow_cnt +
                                      h.b_overflow_cnt + h.b_underflow_cnt),
               "TC6: mon_total_err_cnt != sum of channel error counts");
            check_mon("TC6");
            $display("---- TC6 %s ----", (err_cnt == 0) ? "PASS" : "FAIL");
        end
    endtask

    //====================================================== TC7 复位行为
    task automatic tc7_reset(input bit quiet);
        integer i;
        bit ok;
        begin
            if (!quiet) $display("---- TC7: reset behaviour ----");
            do_reset(6);
            reset_ref_a();

            // 复位期间持续施加写请求: 必须"零事务"(写入被复位压制)。
            // 用注入模式直接驱动 wr_valid, 不经过请求缓冲, 因此不会污染参考序列。
            h.rst_n_async = 0;
            tb_inject_a = 1;
            @(negedge h.wr_clk_a);
            h.wr_valid_a = 1'b1;
            h.wr_data_a  = 32'h1234_5678;
            for (i = 0; i < 20; i = i + 1) @(posedge h.wr_clk_a);
            @(negedge h.wr_clk_a);
            h.wr_valid_a = 1'b0;
            h.rst_n_async = 1;
            tb_inject_a = 0;

            ck(h.rd_empty_a === 1'b1, "TC7: channel-A not empty after reset");
            check_mon("TC7");

            // 复位释放后正常读写
            for (i = 0; i < 32; i = i + 1) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC7: post-reset write failed");
            end
            settle(6);
            for (i = 0; i < 32; i = i + 1) begin
                rd_a(ok);
                ck(ok, "TC7: post-reset read failed");
            end
            settle(6);
            check_data("TC7");
            $display("---- TC7 %s ----", (err_cnt == 0) ? "PASS" : "FAIL");
        end
    endtask

    //====================================================== TC8 数据模式/回卷
    task automatic tc8_pattern(input bit quiet);
        integer i, round;
        bit ok;
        reg [31:0] d;
        begin
            if (!quiet) $display("---- TC8: extreme data patterns and pointer wrap ----");
            do_reset(6);
            reset_ref_a();

            // 连续 3 轮写满读空 -> 写指针回卷 3 次
            for (round = 0; round < 3; round = round + 1) begin
                for (i = 0; i < 256; i = i + 1) begin
                    case (i % 4)
                        0: d = 32'h0000_0000;
                        1: d = 32'hFFFF_FFFF;
                        2: d = 32'hAAAA_AAAA;
                        default: d = 32'h5555_5555;
                    endcase
                    wr_a(d, ok);
                    ck(ok, "TC8: pattern write failed");
                end
                settle(4);
                ck(h.wr_full_a === 1'b1, "TC8: not full at end of fill round");
                for (i = 0; i < 256; i = i + 1) begin
                    rd_a(ok);
                    ck(ok, "TC8: pattern read failed");
                end
                settle(4);
                ck(h.rd_empty_a === 1'b1, "TC8: not empty at end of drain round");
            end
            ck(h.a_wr_event_cnt == 768, "TC8: total write count != 768");
            ck(h.a_rd_event_cnt == 768, "TC8: total read count != 768");
            settle(10);
            ck(h.a_used_wr_est === 9'd0, "TC8: write-side occupancy estimate != 0 at end");
            check_data("TC8");
            check_mon("TC8");
            $display("---- TC8 %s ----", (err_cnt == 0) ? "PASS" : "FAIL");
        end
    endtask

    //====================================================== TC9 时钟暂停
    task automatic tc9_clkpause(input bit quiet);
        integer i;
        bit ok;
        begin
            if (!quiet) $display("---- TC9: data integrity after clock pause ----");
            do_reset(6);
            reset_ref_a();

            for (i = 0; i < 64; i = i + 1) begin
                wr_a(tb_pkg::gen_data(i), ok);
                ck(ok, "TC9: preload write failed");
            end
            settle(6);

            // 暂停读时钟 200ns
            @(negedge h.rd_clk_a);
            h.clk_a_en = 1;    // 写时钟继续(仅暂停读时钟不便单独控制, 这里暂停 A 全部时钟后恢复)
            h.clk_a_en = 0;
            #200;
            h.clk_a_en = 1;
            settle(10);

            // 恢复后必须仍可正确读出
            ck(h.rd_valid_a === 1'b1, "TC9: rd_valid lost after clock pause");
            for (i = 0; i < 64; i = i + 1) begin
                rd_a(ok);
                ck(ok, "TC9: post-pause read failed");
            end
            settle(6);
            ck(h.rd_empty_a === 1'b1, "TC9: not empty after post-pause drain");
            check_data("TC9");
            $display("---- TC9 %s ----", (err_cnt == 0) ? "PASS" : "FAIL");
        end
    endtask

    //====================================================== 用例调度
    task automatic run_all();
        begin
            tc1_fill_drain(0);
            tc2_mixed(0);
            tc3_protect(0);
            tc4_threshold(0);
            tc5_backpressure(0);
            tc6_coordinate(0);
            tc7_reset(0);
            tc8_pattern(0);
            tc9_clkpause(0);
        end
    endtask


    //====================================================== 主流程
    integer t0;

    initial begin
        //---- plusargs ----
        void'($value$plusargs("TEST=%s", TEST_NAME));
        void'($value$plusargs("SEED=%d", SEED));
        void'($value$plusargs("PA_PS=%d", P_WR_A_PS));
        void'($value$plusargs("QCA_PS=%d", P_RD_A_PS));
        void'($value$plusargs("PB_PS=%d", P_WR_B_PS));
        void'($value$plusargs("QCB_PS=%d", P_RD_B_PS));
        void'($value$plusargs("MON_PS=%d", P_MON_PS));
        void'($value$plusargs("PHA_PS=%d", P_PH_A_PS));
        void'($value$plusargs("PHB_PS=%d", P_PH_B_PS));
        void'($value$plusargs("STAGES=%d", STAGES));
        seed_used = SEED;
        void'($urandom(SEED));
        $timeformat(-9, 3, " ns", 10);

        $display("");
        $display("############################################################");
        $display("# Dual Asynchronous FIFO System - Verification Platform (SV)");
        $display("# TEST=%0s  SEED=%0d  SYNC_STAGES=%0d", TEST_NAME, SEED, STAGES);
        $display("# clocks: T_wr_a=%0dps  T_rd_a=%0dps  (wr:rd period ratio = %0d:%0d)",
                 P_WR_A_PS, P_RD_A_PS, P_WR_A_PS, P_RD_A_PS);
        $display("#         T_wr_b=%0dps  T_rd_b=%0dps  (wr:rd period ratio = %0d:%0d)",
                 P_WR_B_PS, P_RD_B_PS, P_WR_B_PS, P_RD_B_PS);
        $display("#         T_mon =%0dps   read-clock phase: A=%0dps B=%0dps",
                 P_MON_PS, P_PH_A_PS, P_PH_B_PS);
        $display("############################################################");

        // 初始相位偏移 (只作用于读时钟, 制造任意相位关系)
        if (P_PH_A_PS > 0) #(P_PH_A_PS / 1000.0);
        if (P_PH_B_PS > 0) #(P_PH_B_PS / 1000.0);

        t0 = $time;

        if      (TEST_NAME == "tc1") tc1_fill_drain(0);
        else if (TEST_NAME == "tc2") tc2_mixed(0);
        else if (TEST_NAME == "tc3") tc3_protect(0);
        else if (TEST_NAME == "tc4") tc4_threshold(0);
        else if (TEST_NAME == "tc5") tc5_backpressure(0);
        else if (TEST_NAME == "tc6") tc6_coordinate(0);
        else if (TEST_NAME == "tc7") tc7_reset(0);
        else if (TEST_NAME == "tc8") tc8_pattern(0);
        else if (TEST_NAME == "tc9") tc9_clkpause(0);
        else                             run_all();

        //---- 覆盖率与结果 ----
        u_cov.report(TEST_NAME);
        $display("============================================================");
        $display(" TOTAL: checks=%0d  failed=%0d  elapsed=%0t ps", chk_cnt, err_cnt, $time - t0);
        if (err_cnt == 0) $display(" RESULT: *** PASS ***  TEST=%0s SEED=%0d STAGES=%0d",
                                  TEST_NAME, SEED, STAGES);
        else              $display(" RESULT: *** FAIL ***  TEST=%0s SEED=%0d  failed=%0d",
                                  TEST_NAME, SEED, err_cnt);
        $display("============================================================");
        $display("");
        $finish;
    end

    //====================================================== 安全超时
    initial begin
        #(TIMEOUT_PS / 1000.0);
        $display("[FATAL] simulation timeout at %0t", $time);
        $display(" RESULT: *** TIMEOUT *** TEST=%0s SEED=%0d", TEST_NAME, SEED);
        $finish;
    end

endmodule
