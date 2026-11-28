//=============================================================================
// File        : async_fifo.v
// Module      : async_fifo
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 参数化双时钟异步 FIFO 单通道。
//
//   结构 (Clifford E. Cummings, SNUG 2002 经典结构 + 课设扩展):
//     - 双时钟存储阵列    : reg [DW-1:0] mem [0:DEPTH-1]，无 IP，由综合推断 RAM
//     - 指针              : (AW+1) bit 扩展二进制指针，自然回卷
//     - 跨时钟域          : 只把"格雷码指针"送过多级同步器
//     - 满/空             : 只在本地时钟域用同步后的对方格雷码指针产生
//     - 占用估计          : 9 bit 模运算减法，合法范围 0..DEPTH
//     - almost 标志       : 阈值参数化 + 迟滞(去抖动)
//     - 背压              : rd_valid && !rd_ready 期间读指针/输出保持
//     - 错误统计          : 溢出/下溢/背压/读写事务，32 bit 饱和计数
//     - 跨域计数          : 源域二进制 -> 格雷码 -> 目的域同步 -> 解码
//
//   接口语义 (与项目计划书 3.2 一致):
//     写侧: wr_ready = !full；仅 wr_valid && wr_ready 时写入并推进写指针；
//           wr_valid && full 记一次溢出写尝试。
//     读侧: 仅 rd_en && rd_ready && rd_valid 时弹出数据并
//           推进读指针；rd_en && empty 记一次下溢读尝试；
//           rd_valid && !rd_ready 记一个背压周期。
//     模式 0/2 中，rd_valid 有效而未成交时队首保持；模式 1 以 rd_data_valid 指示响应。
//
// Preset / 假设:
//     1) 深度 DEPTH = 2**AW；AW=8 -> 9 bit 指针 -> 深度 256，与题目一致。
//     2) 复位低有效、异步置位同步释放；模块内部为每个时钟域各生成一份复位。
//     3) 对方事件需经过同步链和解码流水才能在本地域可见，状态为保守估计。
//     4) 目的域允许跳过中间格雷码；按扩展指针的模差值累计全部事件。
//        物理 CDC 仍需约束 Gray 总线位间偏斜并核查同步器实现。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module async_fifo #(
    parameter integer AW              = 8,      // 地址位宽，深度 = 2**AW
    parameter integer DW              = 32,     // 数据位宽
    parameter integer SYNC_STAGES     = 2,      // 同步级数 2 或 3
    parameter integer ALMOST_FULL_TH  = 224,    // 默认 7/8 深度
    parameter integer ALMOST_EMPTY_TH = 32,     // 默认 1/8 深度
    parameter integer DEADBAND        = 2,      // 阈值迟滞(去抖动)
    parameter integer CNT_W           = 32,     // 事件计数器位宽(饱和计数)
    parameter integer READ_MODE       = 0       // 0=组合直通, 1=同步请求, 2=BRAM ready/valid
) (
    //----------------------------------------------------------- 全局异步复位
    input  wire              rst_n_async,
    //----------------------------------------------------------- 写时钟域
    input  wire              wr_clk,
    input  wire              wr_valid,
    input  wire [DW-1:0]     wr_data,
    output wire              wr_ready,              // = !full
    output wire              wr_full,
    output wire              full_check,            // 与同一采样进度的 Gray 判满交叉检查
    output wire              wr_almost_full,
    output reg  [DW-1:0]     wr_data_committed,     // 最近一次成功写入的数据
    output reg               wr_data_valid,         // 至少有一个字已写入且尚未读出
    output wire [CNT_W-1:0]  wr_event_cnt,          // 本地: 成功写入次数
    output wire [CNT_W-1:0]  overflow_cnt,          // 本地: 满时写尝试周期数
    output wire [CNT_W-1:0]  overflow_flag_cnt,     // 本地: 溢出标志置位次数
    output wire [AW:0]       wr_used_dbg,           // 本地: 占用量估计(同步指针)
    //----------------------------------------------------------- 读时钟域
    input  wire              rd_clk,
    input  wire              rd_en,
    input  wire              rd_ready,
    output wire [DW-1:0]     rd_data,               // FWFT 或同步读数据
    output wire              rd_data_valid,         // 与 rd_data 对应的有效指示
    output wire              rd_valid,              // 模式 2: 队首数据已就绪; 其他模式: FIFO 非空
    output wire              rd_empty,
    output wire              rd_almost_empty,
    output wire [CNT_W-1:0]  rd_event_cnt,          // 本地: 成功读出次数
    output wire [CNT_W-1:0]  underflow_cnt,         // 本地: 空时读尝试周期数
    output wire [CNT_W-1:0]  underflow_flag_cnt,    // 本地: 下溢标志置位次数
    output wire [CNT_W-1:0]  backpressure_cnt,      // 本地: 背压周期数
    output wire              backpressure_active,   // 本地: 当前周期正处于背压
    output wire [AW:0]       rd_used_dbg,           // 本地: 占用量估计(同步指针)
    //------------------------------------------------ 同步到 clk_mon 的监控量
    input  wire              clk_mon,
    input  wire              rst_n_mon,             // clk_mon 域同步释放后的复位
    output wire [CNT_W-1:0]  wr_event_cnt_sync,     // 写入次数 (mon 域)
    output wire [CNT_W-1:0]  rd_event_cnt_sync,     // 读出次数 (mon 域)
    output wire [CNT_W-1:0]  overflow_cnt_sync,     // 溢出计数 (mon 域)
    output wire [CNT_W-1:0]  underflow_cnt_sync,    // 下溢计数 (mon 域)
    output wire [CNT_W-1:0]  backpressure_cnt_sync, // 背压计数 (mon 域)
    output wire [AW:0]       used_sync,             // 占用量 (mon 域)
    output wire              full_sync,             // 满标志 (mon 域)
    output wire              almost_full_sync,      // 几乎满 (mon 域)
    output wire              empty_sync,            // 空标志 (mon 域)
    output wire              almost_empty_sync      // 几乎空 (mon 域)
);
    //=====================================================================
    // 本地参数
    //=====================================================================
    localparam integer DEPTH    = (1 << AW);
    localparam [AW:0]  PTR_MAX  = {AW+1{1'b1}};         // 2**(AW+1)-1
    localparam [CNT_W-1:0] CNT_MAX = {CNT_W{1'b1}};     // 饱和值

    //=====================================================================
    // 1. 复位同步释放 (每个时钟域各一份)
    //=====================================================================
    wire rst_n_wr;
    wire rst_n_rd;

    rst_sync #(.STAGES(SYNC_STAGES)) u_rst_sync_wr (
        .clk         (wr_clk),
        .rst_n_async (rst_n_async),
        .rst_n_sync  (rst_n_wr)
    );

    rst_sync #(.STAGES(SYNC_STAGES)) u_rst_sync_rd (
        .clk         (rd_clk),
        .rst_n_async (rst_n_async),
        .rst_n_sync  (rst_n_rd)
    );

    //=====================================================================
    // 2. 存储阵列 : 32 bit x 256，写端口在 wr_clk，读端口组合读出
    //    禁止使用 IP；综合工具推断为一块简单双端口 RAM
    //=====================================================================
    reg [DW-1:0] mem [0:DEPTH-1];
    reg [AW-1:0] wr_addr;
    reg [AW-1:0] rd_addr;
    reg [AW:0] wr_occupancy_r;      // 写域: 当前 FIFO 内字数 (0..DEPTH)
    reg [AW:0] rd_occupancy_r;      // 读域: 当前 FIFO 内字数 (0..DEPTH)


    //=====================================================================
    // 3. 二进制指针 (含回卷位) 与格雷码
    //=====================================================================
    reg  [AW:0] wr_bin;
    reg  [AW:0] rd_bin;

    wire [AW:0] wr_bin_next  = (wr_bin + {{AW{1'b0}}, 1'b1}) & PTR_MAX;
    wire [AW:0] rd_bin_next  = (rd_bin + {{AW{1'b0}}, 1'b1}) & PTR_MAX;

    // 注意: 读域必须同步写指针的【当前值】而不是"下一值"。
    // 早期版本同步 wr_bin_next 的格雷码(经典 Cummings 满判据的副产品)，在改为
    // "读域占用量计数"方案后，会让读域看到的写指针比真实值大 1(空 FIFO 被误算成
    // 已有 1 个字 -> rd_valid 误报)，因此这里统一同步 wr_bin 的格雷码。
    reg [AW:0] wr_gray;
    reg [AW:0] rd_gray;
    wire [AW:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    wire [AW:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // 读写"真正发生"的条件(与项目计划书 3.2 一致):
    //   wr_fire : wr_valid && wr_ready(即非满)   -> 写入并推进写指针
    //   rd_pop  : rd_en && rd_ready && rd_valid  -> 弹出并推进读指针
    //   ovf_try : wr_valid && full               -> 溢出写尝试(被拒绝)
    //   unf_try : rd_en && empty                 -> 下溢读尝试(被拒绝)
    //   bp_cyc  : rd_valid && !rd_ready          -> 背压周期(数据被压住)
    wire wr_fire;
    wire rd_pop;
    wire ovf_try;
    wire unf_try;
    wire bp_cyc;

    assign wr_fire = wr_valid & wr_ready;
    assign ovf_try = wr_valid & wr_full;
    assign rd_pop  = rd_en & rd_ready & rd_valid;
    assign unf_try = rd_en & rd_empty;
    assign bp_cyc  = rd_valid & (~rd_ready);

    //=====================================================================
    // 存储阵列读出由 READ_MODE 选择
    //   READ_MODE=0 (FWFT, 默认): 组合读出, rd_data 当拍即有效, 接口最直观,
    //                             但综合只能得到分布式 RAM(LUTRAM), 且在
    //                             rd_clk 极快时组合路径成为时序瓶颈。
    //   READ_MODE=1 (Standard)   : 读地址在时钟沿被采样, 可推断为块 RAM(BRAM);
    //                             代价是 rd_data 比 rd_pop 晚一拍, 由
    //                             rd_data_valid 指示何时有效。
    //                             调用方须在 rd_data_valid=1 时采样 rd_data。
    //   READ_MODE=2 (BRAM)       : 同步预取，端口仍按 ready/valid 交付。
    //                             本地看到首字后多一拍读时钟，连续读取可每拍成交。
    //=====================================================================
    generate
        if (READ_MODE == 0) begin : g_read_fwft
            reg [DW-1:0] last_popped;
            always @(posedge rd_clk or negedge rst_n_rd) begin
                if (!rst_n_rd) last_popped <= {DW{1'b0}};
                else if (rd_pop) last_popped <= mem[rd_addr];
            end
            assign rd_data       = rd_valid ? mem[rd_addr] : last_popped;
            assign rd_data_valid = rd_valid;
            assign rd_valid      = rst_n_rd & ~rd_empty;
        end else if (READ_MODE == 2) begin : g_read_bram
            reg [DW-1:0] head_data;
            reg          head_valid;

            // The enabled RAM output holds the head during a stall. On a
            // transfer, read the next address if one more word is visible.
            // Only the external transfer advances rd_bin and rd_gray.
            wire fetch = rst_n_rd && ((!head_valid && !rd_empty) ||
                                      (rd_pop && (|rd_occupancy_r[AW:1])));
            wire [AW-1:0] fetch_addr = rd_pop ? rd_bin_next[AW-1:0] : rd_addr;

            always @(posedge rd_clk) begin
                if (fetch) head_data <= mem[fetch_addr];
            end

            // Reset validity separately so the data read infers block RAM.
            always @(posedge rd_clk or negedge rst_n_rd) begin
                if (!rst_n_rd) head_valid <= 1'b0;
                else if (fetch || rd_pop) head_valid <= fetch;
            end

            assign rd_data       = head_data;
            assign rd_data_valid = head_valid;
            assign rd_valid      = head_valid;
        end else begin : g_read_std
            reg [DW-1:0] rd_data_r;
            reg          rd_data_valid_r;
            always @(posedge rd_clk or negedge rst_n_rd) begin
                if (!rst_n_rd) begin
                    rd_data_r       <= {DW{1'b0}};
                    rd_data_valid_r <= 1'b0;
                end else begin
                    // 地址与使能在同一时钟沿被采样 -> 同步读, 可映射到 BRAM
                    rd_data_valid_r <= rd_pop;
                    if (rd_pop) rd_data_r <= mem[rd_addr];
                end
            end
            assign rd_data       = rd_data_r;
            assign rd_data_valid = rd_data_valid_r;
            assign rd_valid      = rst_n_rd & ~rd_empty;
        end
    endgenerate


    // 写地址: 每次成功写入后随写指针推进(满时 wr_fire=0，地址保持不变，
    // 因此不会覆盖尚未读出的数据)
    always @(posedge wr_clk or negedge rst_n_wr) begin
        if (!rst_n_wr) begin
            wr_addr <= {AW{1'b0}};
            wr_bin  <= {(AW+1){1'b0}};
            wr_gray <= {(AW+1){1'b0}};
        end else if (wr_fire) begin
            wr_addr <= wr_bin_next[AW-1:0];
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
        end
    end

    // 读地址: 仅当真正弹出(rd_en && rd_ready && rd_valid)时推进；
    // 空时或被背压时地址保持 -> rd_data 保持
    always @(posedge rd_clk or negedge rst_n_rd) begin
        if (!rst_n_rd) begin
            rd_addr <= {AW{1'b0}};
            rd_bin  <= {(AW+1){1'b0}};
            rd_gray <= {(AW+1){1'b0}};
        end else if (rd_pop) begin
            rd_addr <= rd_bin_next[AW-1:0];
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
        end
    end

    // 存储阵列写端口: 双时钟 RAM 的写侧(读侧为上面的组合读出 assign)
    always @(posedge wr_clk) begin
        if (wr_fire) begin
            mem[wr_addr] <= wr_data;
        end
    end

    //=====================================================================
    // 4. 跨时钟域同步: 只同步格雷码指针
    //=====================================================================
    wire [AW:0] rd_gray_sync;       // 写域看到的读指针(格雷)
    wire [AW:0] wr_gray_sync;       // 读域看到的写指针(格雷)
    wire [AW:0] rd_bin_sync;        // 写域解码出的读指针(二进制)
    wire [AW:0] wr_bin_sync;        // 读域解码出的写指针(二进制)

    sync_2ff_p #(.STAGES(SYNC_STAGES), .W(AW+1)) u_sync_rd_ptr (
        .clk     (wr_clk),
        .rst_n   (rst_n_wr),
        .d_async (rd_gray),
        .q_sync  (rd_gray_sync)
    );

    sync_2ff_p #(.STAGES(SYNC_STAGES), .W(AW+1)) u_sync_wr_ptr (
        .clk     (rd_clk),
        .rst_n   (rst_n_rd),
        .d_async (wr_gray),
        .q_sync  (wr_gray_sync)
    );

    gray2bin #(.W(AW+1)) u_rd_gray2bin (.gray(rd_gray_sync), .bin(rd_bin_sync));
    gray2bin #(.W(AW+1)) u_wr_gray2bin (.gray(wr_gray_sync), .bin(wr_bin_sync));

    //=====================================================================
    // 5. 精确占用量计数 -> FULL / EMPTY 标志
    //
    //   写域占用 = 已写入字数 - 已同步到的读出字数；
    //   读域占用 = 已同步到的写入字数 - 已读出字数。
    //   同步指针可以一拍前进多字，必须累计完整模差值；握手阻止越界。
    //   正确实现的经典扩展 Gray 指针法也可保存 DEPTH 个字，
    //   提前一字判满属于实现错误，而非该方法的固有容量损耗。
    //   两个计数器都由"本地事件 + 对方格雷码指针的单调前进"驱动, 天然是
    //   CDC 安全的(从不比较两个域的瞬时值), 且 FULL/EMPTY 在本地域内精确成立:
    //       full  <-> 写域 cnt == DEPTH (占满 256 个字)
    //       empty <-> 读域 cnt == 0
    //   代价: 每个域多一个 AW+1 位计数器及其加减逻辑; 标志仍是本地域组合输出,
    //   写满/读空在对方域看来允许有同步器延迟(异步 FIFO 的固有特性)。
    //   格雷码指针仍然保留用于跨域传递(占用量估计、监控域状态量)。
    //=====================================================================
    reg  [AW:0] rd_ptr_seen;         // 写域: 上一次同步到的读指针
    reg  [AW:0] wr_ptr_seen;         // 读域: 上一次同步到的写指针

    // 上一轮改进: gray2bin 解码后的指针再打一拍, 把
    //   "同步器 -> 解码 -> 比较 -> 占用量±1"
    // 这条长组合链切成两段。实测该链在 rd_clk=4ns 时为 4.667ns(logic 2.513+route 2.154),
    // 是整个设计最紧的路径; 加一级流水后逻辑深度减半。
    // 代价: 占用量估计多 1 拍延迟(异步 FIFO 本身就有同步延迟, 方向仍然保守)。
    reg  [AW:0] rd_bin_sync_r;      // 写域: 解码后的读指针(再打一拍)
    reg  [AW:0] wr_bin_sync_r;      // 读域: 解码后的写指针(再打一拍)

    always @(posedge wr_clk or negedge rst_n_wr) begin
        if (!rst_n_wr) rd_bin_sync_r <= {(AW+1){1'b0}};
        else           rd_bin_sync_r <= rd_bin_sync;
    end

    always @(posedge rd_clk or negedge rst_n_rd) begin
        if (!rst_n_rd) wr_bin_sync_r <= {(AW+1){1'b0}};
        else           wr_bin_sync_r <= wr_bin_sync;
    end

    // Destination clocks may skip multiple Gray values: count the entire
    // modular pointer delta, not just whether the pointer changed.
    wire [AW:0] rd_delta = rd_bin_sync_r - rd_ptr_seen;
    wire [AW:0] wr_delta = wr_bin_sync_r - wr_ptr_seen;

    always @(posedge wr_clk or negedge rst_n_wr) begin
        if (!rst_n_wr) begin
            wr_occupancy_r <= {(AW+1){1'b0}};
            rd_ptr_seen    <= {(AW+1){1'b0}};
        end else begin
            rd_ptr_seen <= rd_bin_sync_r;
            wr_occupancy_r <= wr_occupancy_r + {{AW{1'b0}}, wr_fire} - rd_delta;
        end
    end

    always @(posedge rd_clk or negedge rst_n_rd) begin
        if (!rst_n_rd) begin
            rd_occupancy_r <= {(AW+1){1'b0}};
            wr_ptr_seen    <= {(AW+1){1'b0}};
        end else begin
            wr_ptr_seen <= wr_bin_sync_r;
            rd_occupancy_r <= rd_occupancy_r + wr_delta - {{AW{1'b0}}, rd_pop};
        end
    end

    wire [AW:0] wr_used_est;
    wire [AW:0] rd_used_est;

    assign wr_used_est = wr_occupancy_r;      // 写域精确占用量
    assign rd_used_est = rd_occupancy_r;      // 读域精确占用量

    assign wr_full  = (wr_occupancy_r == DEPTH[AW:0]);
    assign rd_empty = (rd_occupancy_r == {(AW+1){1'b0}});

    assign wr_ready   = rst_n_wr & ~wr_full;
    wire [AW:0] rd_gray_seen = (rd_ptr_seen >> 1) ^ rd_ptr_seen;
    wire gray_full = (wr_gray == {~rd_gray_seen[AW:AW-1], rd_gray_seen[AW-2:0]});
    assign full_check = (wr_full == gray_full);

    //=====================================================================
    // 6. almost_full / almost_empty 阈值标志 (带迟滞去抖动)
    //=====================================================================
    reg  wr_almost_full_r;
    reg  rd_almost_empty_r;

    // 写入侧: 占用 >= ALMOST_FULL_TH 置位; 占用 <= TH-DEADBAND 清除
    always @(posedge wr_clk or negedge rst_n_wr) begin
        if (!rst_n_wr) begin
            wr_almost_full_r <= 1'b0;
        end else if ({{(32-(AW+1)){1'b0}}, wr_occupancy_r} >= ALMOST_FULL_TH) begin
            wr_almost_full_r <= 1'b1;
        end else if ({{(32-(AW+1)){1'b0}}, wr_occupancy_r} <= (ALMOST_FULL_TH - DEADBAND)) begin
            wr_almost_full_r <= 1'b0;
        end
    end

    // 读出侧: 占用 <= ALMOST_EMPTY_TH 置位; 占用 >= TH+DEADBAND 清除
    always @(posedge rd_clk or negedge rst_n_rd) begin
        if (!rst_n_rd) begin
            rd_almost_empty_r <= 1'b0;
        end else if ({{(32-(AW+1)){1'b0}}, rd_occupancy_r} <= ALMOST_EMPTY_TH) begin
            rd_almost_empty_r <= 1'b1;
        end else if ({{(32-(AW+1)){1'b0}}, rd_occupancy_r} >= (ALMOST_EMPTY_TH + DEADBAND)) begin
            rd_almost_empty_r <= 1'b0;
        end
    end

    assign wr_almost_full  = wr_almost_full_r;
    assign rd_almost_empty = rd_almost_empty_r;

    //=====================================================================
    // 7. 写时钟域事件
    //=====================================================================
    reg  [CNT_W-1:0] wr_event_cnt_r;
    reg  [CNT_W-1:0] ovf_try_cnt_r;
    reg  [CNT_W-1:0] ovf_flag_cnt_r;
    reg              overflow_flag;

    always @(posedge wr_clk or negedge rst_n_wr) begin
        if (!rst_n_wr) begin
            wr_event_cnt_r  <= {CNT_W{1'b0}};
            ovf_try_cnt_r   <= {CNT_W{1'b0}};
            ovf_flag_cnt_r  <= {CNT_W{1'b0}};
            overflow_flag   <= 1'b0;
            wr_data_committed <= {DW{1'b0}};
            wr_data_valid     <= 1'b0;
        end else begin
            // 溢出周期计数 (被拒绝的写请求，每个周期计一次)
            if (ovf_try && (ovf_try_cnt_r != CNT_MAX)) begin
                ovf_try_cnt_r <= ovf_try_cnt_r + {{(CNT_W-1){1'b0}}, 1'b1};
            end

            // 溢出标志置位次数 (对"进入溢出状态"这一事件计数)
            overflow_flag <= ovf_try;
            if (ovf_try && !overflow_flag && (ovf_flag_cnt_r != CNT_MAX)) begin
                ovf_flag_cnt_r <= ovf_flag_cnt_r + {{(CNT_W-1){1'b0}}, 1'b1};
            end

            // 成功写入事务计数 + 最近写入数据 (指针/地址推进见第 3 节)
            if (wr_fire) begin
                if (wr_event_cnt_r != CNT_MAX) begin
                    wr_event_cnt_r <= wr_event_cnt_r + {{(CNT_W-1){1'b0}}, 1'b1};
                end
                wr_data_committed <= wr_data;
                wr_data_valid     <= 1'b1;
            end
        end
    end

    assign wr_event_cnt      = wr_event_cnt_r;

    assign overflow_cnt      = ovf_try_cnt_r;
    assign overflow_flag_cnt = ovf_flag_cnt_r;
    assign wr_used_dbg       = wr_used_est;

    //=====================================================================
    // 8. 读时钟域事件
    //=====================================================================
    reg  [CNT_W-1:0] rd_event_cnt_r;
    reg  [CNT_W-1:0] unf_try_cnt_r;
    reg  [CNT_W-1:0] unf_flag_cnt_r;
    reg  [CNT_W-1:0] bp_cnt_r;
    reg              underflow_flag;

    always @(posedge rd_clk or negedge rst_n_rd) begin
        if (!rst_n_rd) begin
            rd_event_cnt_r  <= {CNT_W{1'b0}};
            unf_try_cnt_r   <= {CNT_W{1'b0}};
            unf_flag_cnt_r  <= {CNT_W{1'b0}};
            bp_cnt_r        <= {CNT_W{1'b0}};
            underflow_flag  <= 1'b0;
        end else begin
            // 下溢周期计数
            if (unf_try && (unf_try_cnt_r != CNT_MAX)) begin
                unf_try_cnt_r <= unf_try_cnt_r + {{(CNT_W-1){1'b0}}, 1'b1};
            end
            // 下溢标志置位次数
            underflow_flag <= unf_try;
            if (unf_try && !underflow_flag && (unf_flag_cnt_r != CNT_MAX)) begin
                unf_flag_cnt_r <= unf_flag_cnt_r + {{(CNT_W-1){1'b0}}, 1'b1};
            end
            // 背压周期计数
            if (bp_cyc && (bp_cnt_r != CNT_MAX)) begin
                bp_cnt_r <= bp_cnt_r + {{(CNT_W-1){1'b0}}, 1'b1};
            end
            // 成功读出事务计数
            if (rd_pop && (rd_event_cnt_r != CNT_MAX)) begin
                rd_event_cnt_r <= rd_event_cnt_r + {{(CNT_W-1){1'b0}}, 1'b1};
            end
        end
    end

    assign rd_event_cnt       = rd_event_cnt_r;
    assign underflow_cnt      = unf_try_cnt_r;
    assign underflow_flag_cnt = unf_flag_cnt_r;
    assign backpressure_cnt   = bp_cnt_r;
    assign rd_used_dbg        = rd_used_est;
    assign backpressure_active = bp_cyc;

    //=====================================================================
    // 9. 事件计数器跨域: 源域二进制 -> 格雷码 -> (toggle 握手) -> 同步 -> 解码
    //
    //   为什么要握手: 格雷码只保证"相邻码字 1 bit 变化"，若目的域一次采样
    //   跨过 >=2 个计数(即源域计数周期 < SYNC_STAGES x 目的域周期)，解码结果
    //   可能少算(aliasing)。本项目 f_rd(A)=1/6ns、f_rd(B)=1/4ns 都高于监控
    //   时钟采样能力，因此计数器/状态一律用"格雷码 + toggle 握手"总线同步:
    //   源域每次更新时抓拍该格雷码，目的域仅在 toggle 打拍稳定后采样，
    //   保证被采样的格雷码在采样窗口内绝对静止 -> 每次更新恰好采样一次。
    //   代价是状态量比纯 2 级打拍多约 2 个目的域周期的延迟，属可接受折衷。
    //=====================================================================
    wire [CNT_W:0] wr_event_bin_sync, rd_event_bin_sync, ovf_cnt_bin_sync;
    wire [CNT_W:0] unf_cnt_bin_sync, bp_cnt_bin_sync;

    sync_gray_max #(.W(CNT_W+1), .STAGES(SYNC_STAGES)) u_s_wr_event (
        .src_clk(wr_clk), .src_rst_n(rst_n_wr), .src_bin({1'b0, wr_event_cnt_r}),
        .dst_clk(clk_mon), .dst_rst_n(rst_n_mon), .dst_bin(wr_event_bin_sync));

    sync_gray_max #(.W(CNT_W+1), .STAGES(SYNC_STAGES)) u_s_rd_event (
        .src_clk(rd_clk), .src_rst_n(rst_n_rd), .src_bin({1'b0, rd_event_cnt_r}),
        .dst_clk(clk_mon), .dst_rst_n(rst_n_mon), .dst_bin(rd_event_bin_sync));

    sync_gray_max #(.W(CNT_W+1), .STAGES(SYNC_STAGES)) u_s_ovf_cnt (
        .src_clk(wr_clk), .src_rst_n(rst_n_wr), .src_bin({1'b0, ovf_try_cnt_r}),
        .dst_clk(clk_mon), .dst_rst_n(rst_n_mon), .dst_bin(ovf_cnt_bin_sync));

    sync_gray_max #(.W(CNT_W+1), .STAGES(SYNC_STAGES)) u_s_unf_cnt (
        .src_clk(rd_clk), .src_rst_n(rst_n_rd), .src_bin({1'b0, unf_try_cnt_r}),
        .dst_clk(clk_mon), .dst_rst_n(rst_n_mon), .dst_bin(unf_cnt_bin_sync));

    sync_gray_max #(.W(CNT_W+1), .STAGES(SYNC_STAGES)) u_s_bp_cnt (
        .src_clk(rd_clk), .src_rst_n(rst_n_rd), .src_bin({1'b0, bp_cnt_r}),
        .dst_clk(clk_mon), .dst_rst_n(rst_n_mon), .dst_bin(bp_cnt_bin_sync));

    // 解码后再做一次 32 bit 饱和截断: 33 bit 通道可分辨"源域已到 2^32-1"
    // 与"回卷"，这里统一饱和到 0xFFFFFFFF，与源域饱和计数语义一致。
    localparam [CNT_W:0] SYNCCNT_MAX = {1'b0, {CNT_W{1'b1}}};

    assign wr_event_cnt_sync     = (wr_event_bin_sync > SYNCCNT_MAX) ? {CNT_W{1'b1}} : wr_event_bin_sync[CNT_W-1:0];
    assign rd_event_cnt_sync     = (rd_event_bin_sync > SYNCCNT_MAX) ? {CNT_W{1'b1}} : rd_event_bin_sync[CNT_W-1:0];
    assign overflow_cnt_sync     = (ovf_cnt_bin_sync  > SYNCCNT_MAX) ? {CNT_W{1'b1}} : ovf_cnt_bin_sync[CNT_W-1:0];
    assign underflow_cnt_sync    = (unf_cnt_bin_sync  > SYNCCNT_MAX) ? {CNT_W{1'b1}} : unf_cnt_bin_sync[CNT_W-1:0];
    assign backpressure_cnt_sync = (bp_cnt_bin_sync   > SYNCCNT_MAX) ? {CNT_W{1'b1}} : bp_cnt_bin_sync[CNT_W-1:0];

    //=====================================================================
    // 10. 状态量跨域到 mon 域 (指针 + 全部电平标志)
    //
    //   工程要点:
    //   (a) mon 域的 {wr_ptr, rd_ptr} 必须来自"同一快照", 否则会出现"读指针超过
    //       写指针"的瞬时组合, 使占用量出现巨大跳变(例如空 FIFO 被算成 511)。
    //       因此两侧指针与标志打包成一条总线一次搬运, 绝不能分两条总线各自同步。
    //   (b) 打包源以"写时钟域快照 + toggle"实现: 每次快照内容变化就更新快照寄存器
    //       并翻转 toggle。mon 域用 toggle 的多级同步链检测"快照已稳定", 从而保证
    //       采样到的总线在同一快照内, 不会出现多比特同时跳变的撕裂窗口。
    //   (c) 与纯握手不同: mon 域只要发现 toggle 与上次采样值不同就再次采样, 因此
    //       即使源域快照变化比 mon 采样更快, 也能持续追赶并最终收敛到最后一个快照
    //       (纯握手每次变化只搬一次, 变化快时会丢掉增量形成永久滞后)。
    //
    //   打包内容: {wr_bin, rd_bin_sync, wr_full, wr_almost_full,
    //              rd_empty_sync, rd_almost_empty_sync} = 22 bit
    //   监控域占用量: (wr_bin_mon - rd_bin_mon) 模 2^(AW+1), 合法范围 0..DEPTH
    //=====================================================================
    localparam integer ST_W = 2*(AW+1) + 4;     // 9 + 9 + 2 + 2 = 22 bit

    // 读域标志 -> 写域 (单比特电平信号, 多级打拍即可)
    wire rd_empty_wr, rd_almost_empty_wr;
    sync_2ff_1 #(.STAGES(SYNC_STAGES)) u_s_rd_empty_wr (
        .clk(wr_clk), .rst_n(rst_n_wr), .d_async(rd_empty), .q_sync(rd_empty_wr));
    sync_2ff_1 #(.STAGES(SYNC_STAGES)) u_s_rd_ae_wr (
        .clk(wr_clk), .rst_n(rst_n_wr), .d_async(rd_almost_empty), .q_sync(rd_almost_empty_wr));

    //-------------------------------------------- 写域: 一致性快照 + toggle
    wire [ST_W-1:0] st_now = {wr_bin, rd_bin_sync, wr_full, wr_almost_full,
                             rd_empty_wr, rd_almost_empty_wr};

    reg  [ST_W-1:0] st_snap;
    reg             st_snap_tog;
    reg  [ST_W-1:0] st_now_d;

    always @(posedge wr_clk or negedge rst_n_wr) begin
        if (!rst_n_wr) begin
            st_snap     <= {ST_W{1'b0}};
            st_snap_tog <= 1'b0;
            st_now_d    <= {ST_W{1'b0}};
        end else begin
            st_now_d <= st_now;
            if (st_now != st_now_d) begin
                st_snap     <= st_now;      // 数据与 toggle 同一拍更新
                st_snap_tog <= ~st_snap_tog;
            end
        end
    end

    //-------------------------------------------- mon 域: toggle 同步 + 持续追赶
    reg [SYNC_STAGES-1:0] st_tog_chain;
    integer j;
    always @(posedge clk_mon or negedge rst_n_mon) begin
        if (!rst_n_mon) begin
            st_tog_chain <= {SYNC_STAGES{1'b0}};
        end else begin
            st_tog_chain[0] <= st_snap_tog;
            for (j = 1; j < SYNC_STAGES; j = j + 1) st_tog_chain[j] <= st_tog_chain[j-1];
        end
    end

    wire st_tog_sync = st_tog_chain[SYNC_STAGES-1];

    reg [ST_W-1:0] st_sync;
    reg            st_tog_seen;
    always @(posedge clk_mon or negedge rst_n_mon) begin
        if (!rst_n_mon) begin
            st_sync     <= {ST_W{1'b0}};
            st_tog_seen <= 1'b0;
        end else if (st_tog_sync != st_tog_seen) begin
            st_sync     <= st_snap;         // 快照已稳定 >= SYNC_STAGES 个 mon 周期
            st_tog_seen <= st_tog_sync;
        end
    end

    wire [AW:0] wr_bin_mon = st_sync[ST_W-1 -: (AW+1)];
    wire [AW:0] rd_bin_mon = st_sync[ST_W-(AW+1)-1 -: (AW+1)];

    // 监控域占用量估计 (模运算减法, 合法范围 0..DEPTH)
    wire [AW:0] used_mon = (wr_bin_mon - rd_bin_mon) & PTR_MAX;

    assign used_sync         = used_mon;
    assign full_sync         = st_sync[3];
    assign almost_full_sync  = st_sync[2];
    assign empty_sync        = st_sync[1];
    assign almost_empty_sync = st_sync[0];

endmodule
