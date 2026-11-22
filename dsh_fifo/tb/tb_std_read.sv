//=====================================================================
// tb_std_read.sv -- READ_MODE=1（同步读 / Standard 模式）专项验证
//
// 为什么需要它:
//   READ_MODE=0 是原有的组合读(FWFT)模式, 由 tb_top.sv 的 9 个用例覆盖。
//   READ_MODE=1 把存储阵列改成"时钟沿采样读地址", 目的是让综合工具能把它
//   推断为块 RAM(BRAM), 从而缩短 rd_data 的组合路径、让 rd_clk 跑得更快。
//   代价是接口语义变化:
//       rd_pop  那一拍: rd_data 仍是"将要弹出"的数据(尚未更新)
//       rd_pop  后一拍: rd_data_valid=1, rd_data 才是本次弹出的数据
//   因此原有 FWFT 的用例不能直接套用, 需要按新语义写验证。
//
// 验证内容:
//   T1  写入 128 个字后读回, 数据与顺序完全一致
//   T2  rd_data_valid 必须严格滞后 rd_pop 一拍(不能提前、不能漏)
//   T3  空时发读请求: rd_pop=0, rd_data_valid 保持 0
//   T4  写满 256 字后读出全部, 数据一致(覆盖指针回卷)
//   T5  背压下(rd_ready=0)不弹出, rd_data_valid 不误拉高
//=====================================================================
`timescale 1ns / 1ps

module tb_std_read;

    localparam integer DW    = 32;
    localparam integer AW    = 8;
    localparam integer DEPTH = (1 << AW);
    localparam integer CNT_W = 32;

    //--------------------------------------------- 时钟与复位
    reg rst_n_async = 1'b0;
    reg wr_clk  = 1'b0;
    reg rd_clk  = 1'b0;
    reg clk_mon = 1'b0;

    always #5.0 wr_clk  = ~wr_clk;     // 10 ns  -> 100 MHz
    always #3.0 rd_clk  = ~rd_clk;     // 6  ns  -> 166.7 MHz  (5:3)
    always #2.5 clk_mon = ~clk_mon;    // 5  ns  -> 200 MHz

    //--------------------------------------------- DUT 端口
    reg  [DW-1:0] wr_data  = {DW{1'b0}};
    reg           wr_valid = 1'b0;
    wire          wr_ready, wr_full, full_check, wr_almost_full;
    wire [DW-1:0] wr_data_committed;
    wire          wr_data_valid;
    wire [CNT_W-1:0] wr_event_cnt, overflow_cnt, overflow_flag_cnt;
    wire [AW:0]   wr_used_dbg;

    reg           rd_en    = 1'b0;
    reg           rd_ready = 1'b0;
    wire [DW-1:0] rd_data;
    wire          rd_data_valid, rd_valid, rd_empty, rd_almost_empty;
    wire [CNT_W-1:0] rd_event_cnt, underflow_cnt, underflow_flag_cnt, backpressure_cnt;
    wire          backpressure_active;
    wire [AW:0]   rd_used_dbg;

    wire [CNT_W-1:0] wr_event_cnt_sync, rd_event_cnt_sync;
    wire [CNT_W-1:0] overflow_cnt_sync, underflow_cnt_sync, backpressure_cnt_sync;
    wire [AW:0]   used_sync;
    wire          full_sync, almost_full_sync, empty_sync, almost_empty_sync;

    //--------------------------------------------- 计分板
    integer err_cnt = 0;
    integer chk_cnt = 0;
    integer i;
    integer rd_base = 0;
    reg [DW-1:0] rd_before;

    task automatic ck(input bit cond, input [511:0] msg);
        begin
            chk_cnt = chk_cnt + 1;
            if (!cond) begin
                err_cnt = err_cnt + 1;
                $display("[FAIL] %0t ns : %0s", $time, msg);
            end
        end
    endtask

    //--------------------------------------------- DUT: READ_MODE=1
    async_fifo #(
        .AW              (AW),
        .DW              (DW),
        .SYNC_STAGES     (2),
        .ALMOST_FULL_TH  (224),
        .ALMOST_EMPTY_TH (32),
        .DEADBAND        (2),
        .CNT_W           (CNT_W),
        .READ_MODE       (1)              // <<< 同步读模式
    ) u_fifo (
        .rst_n_async           (rst_n_async),
        .wr_clk                (wr_clk),
        .wr_valid              (wr_valid),
        .wr_data               (wr_data),
        .wr_ready              (wr_ready),
        .wr_full               (wr_full),
        .full_check            (full_check),
        .wr_almost_full        (wr_almost_full),
        .wr_data_committed     (wr_data_committed),
        .wr_data_valid         (wr_data_valid),
        .wr_event_cnt          (wr_event_cnt),
        .overflow_cnt          (overflow_cnt),
        .overflow_flag_cnt     (overflow_flag_cnt),
        .wr_used_dbg           (wr_used_dbg),
        .rd_clk                (rd_clk),
        .rd_en                 (rd_en),
        .rd_ready              (rd_ready),
        .rd_data               (rd_data),
        .rd_data_valid         (rd_data_valid),
        .rd_valid              (rd_valid),
        .rd_empty              (rd_empty),
        .rd_almost_empty       (rd_almost_empty),
        .rd_event_cnt          (rd_event_cnt),
        .underflow_cnt         (underflow_cnt),
        .underflow_flag_cnt    (underflow_flag_cnt),
        .backpressure_cnt      (backpressure_cnt),
        .backpressure_active   (backpressure_active),
        .rd_used_dbg           (rd_used_dbg),
        .clk_mon               (clk_mon),
        .rst_n_mon             (rst_n_async),
        .wr_event_cnt_sync     (wr_event_cnt_sync),
        .rd_event_cnt_sync     (rd_event_cnt_sync),
        .overflow_cnt_sync     (overflow_cnt_sync),
        .underflow_cnt_sync    (underflow_cnt_sync),
        .backpressure_cnt_sync (backpressure_cnt_sync),
        .used_sync             (used_sync),
        .full_sync             (full_sync),
        .almost_full_sync      (almost_full_sync),
        .empty_sync            (empty_sync),
        .almost_empty_sync     (almost_empty_sync)
    );

    //--------------------------------------------- 写一个字
    task automatic write_word(input [DW-1:0] d);
        begin
            @(negedge wr_clk);
            wr_valid = 1'b1;
            wr_data  = d;
            @(posedge wr_clk);
            while (!wr_ready) @(posedge wr_clk);
            @(negedge wr_clk);
            wr_valid = 1'b0;
        end
    endtask

    //--------------------------------------------- 读一个字(Standard 语义)
    // 返回队列方式: 先发 rd_en, 再等 rd_data_valid, 然后采样 rd_data
    reg [DW-1:0] got;
    task automatic read_word(output [DW-1:0] d, output bit ok);
        integer guard;
        begin
            ok = 1'b0; guard = 0;
            @(negedge rd_clk);
            // 空时 rd_pop 不会发生 -> rd_data_valid 也不会拉高
            if (rd_empty) begin
                rd_en    = 1'b1;
                rd_ready = 1'b1;
                @(posedge rd_clk);
                repeat (3) @(posedge rd_clk);
                if (!rd_data_valid) ok = 0;
                @(negedge rd_clk);
                rd_en = 1'b0; rd_ready = 1'b0;
                d = rd_data;
                return;
            end
            rd_en    = 1'b1;
            rd_ready = 1'b1;
            @(posedge rd_clk);                 // 这一拍 rd_pop 生效
            @(negedge rd_clk);
            rd_en    = 1'b0;
            rd_ready = 1'b0;
            // 下一拍起 rd_data_valid 应拉高
            guard = 0;
            while (!rd_data_valid && guard < 8) begin
                @(posedge rd_clk); guard = guard + 1;
            end
            d = rd_data;
            ok = rd_data_valid;
        end
    endtask

    //--------------------------------------------- 主流程
    initial begin
        $timeformat(-9, 1, " ns", 10);
        $display("");
        $display("############################################################");
        $display("# tb_std_read : READ_MODE=1 (synchronous read / Standard)");
        $display("# clocks: wr=10ns  rd=6ns  mon=5ns");
        $display("############################################################");

        // 复位
        rst_n_async = 1'b0;
        repeat (8) @(posedge clk_mon);
        rst_n_async = 1'b1;
        repeat (8) @(posedge clk_mon);

        // ---- T1: 写 128 个递增数据, 读回并比对顺序 ----
        $display("---- T1: write 128 then read back in order ----");
        for (i = 0; i < 128; i = i + 1) write_word(32'h1000_0000 + i);
        ck(wr_event_cnt == 32'd128, "T1: wr_event_cnt != 128 after 128 writes");
        ck(overflow_cnt == 32'd0,   "T1: unexpected overflow");

        for (i = 0; i < 128; i = i + 1) begin
            read_word(got, ok_dummy);
            ck(ok_dummy, "T1: rd_data_valid did not assert");
            ck(got === (32'h1000_0000 + i), "T1: data mismatch / wrong order");
        end
        ck(rd_event_cnt == 32'd128, "T1: rd_event_cnt != 128 after 128 reads");
        ck(underflow_cnt == 32'd0,  "T1: unexpected underflow");
        repeat (6) @(posedge rd_clk);
        ck(rd_empty === 1'b1,       "T1: not empty after draining");

        // ---- T2: Standard 语义 —— rd_data 只在 rd_pop 之后更新 ----
        $display("---- T2: Standard semantics: rd_data updates only after rd_pop ----");
        write_word(32'hCAFE_0001);
        write_word(32'hCAFE_0002);
        // 等 FIFO 里有数据(rd_valid 有效)
        begin : wait_data
            integer g;
            g = 0;
            while (!rd_valid && g < 16) begin
                @(posedge rd_clk); g = g + 1;
            end
        end
        @(negedge rd_clk);
        ck(rd_valid === 1'b1, "T2: rd_valid should be 1 with two words inside");
        rd_before = rd_data;                 // 记录"请求前"的读数据
        rd_en    = 1'b1;
        rd_ready = 1'b1;
        @(posedge rd_clk);                   // T: rd_pop 生效, NBA 区更新输出
        @(negedge rd_clk);                   // T 拍后半拍: 输出已稳定
        ck(rd_data_valid === 1'b1, "T2: rd_data_valid should be 1 in the pop cycle");
        ck(rd_data === 32'hCAFE_0001, "T2: first popped word wrong");
        ck(rd_data !== rd_before,
           "T2: Standard mode must not show the next word before rd_pop");
        rd_en = 1'b0; rd_ready = 1'b0;
        @(posedge rd_clk);
        @(negedge rd_clk);
        ck(rd_data_valid === 1'b0, "T2: rd_data_valid should drop with no new pop");

        // ---- T3: 空时读请求不应产生 rd_data_valid ----
        $display("---- T3: read request on empty FIFO ----");
        // T2 只弹出了 1 个字, 先把剩下的读空, 才能测"空时读"
        while (!rd_empty) begin
            read_word(got, ok_dummy);
        end
        repeat (6) @(posedge rd_clk);
        ck(rd_empty === 1'b1, "T3: FIFO should be empty here");
        rd_base = rd_event_cnt;                  // 采样基线, 避免硬编码
        @(negedge rd_clk);
        rd_en = 1'b1; rd_ready = 1'b1;
        repeat (4) @(posedge rd_clk);
        ck(rd_data_valid === 1'b0, "T3: rd_data_valid asserted on empty read");
        ck(rd_event_cnt == rd_base, "T3: rd_event_cnt changed on empty read");
        @(negedge rd_clk);
        rd_en = 1'b0; rd_ready = 1'b0;

        // ---- T4: 写满 256 字再全读, 覆盖指针回卷 ----
        $display("---- T4: fill 256 (pointer wrap) then drain ----");
        for (i = 0; i < 256; i = i + 1) write_word(32'h2000_0000 + i);
        ck(wr_full === 1'b1, "T4: not full after 256 writes");
        for (i = 0; i < 256; i = i + 1) begin
            read_word(got, ok_dummy);
            ck(ok_dummy, "T4: rd_data_valid did not assert");
            ck(got === (32'h2000_0000 + i), "T4: data mismatch after wrap");
        end
        repeat (6) @(posedge rd_clk);
        ck(rd_empty === 1'b1, "T4: not empty after second drain");

        // ---- T5: 背压期间不应产生新的 rd_data_valid ----
        $display("---- T5: no pop while rd_ready is low ----");
        write_word(32'hDEAD_0001);
        @(negedge rd_clk);
        rd_en    = 1'b1;
        rd_ready = 1'b0;                     // 下游未就绪
        repeat (4) @(posedge rd_clk);
        ck(rd_data_valid === 1'b0, "T5: rd_data_valid asserted during backpressure");
        ck(backpressure_active === 1'b1, "T5: backpressure_active should be 1");
        ck(backpressure_cnt > 0, "T5: backpressure_cnt should count");
        @(negedge rd_clk);
        rd_en = 1'b0; rd_ready = 1'b0;

        // ---- 汇总 ----
        $display("");
        $display("============================================================");
        $display(" TOTAL: checks=%0d  failed=%0d", chk_cnt, err_cnt);
        if (err_cnt == 0) $display(" RESULT: *** PASS ***  tb_std_read (READ_MODE=1)");
        else              $display(" RESULT: *** FAIL ***  tb_std_read  failed=%0d", err_cnt);
        $display("============================================================");
        $finish;
    end

    // ok_dummy 声明(在 initial 里使用)
    bit ok_dummy;

    // 超时保护
    initial begin
        #500_000;
        $display("[FATAL] timeout");
        $display(" RESULT: *** TIMEOUT *** tb_std_read");
        $finish;
    end

endmodule
