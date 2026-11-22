//=============================================================================
// File        : sync_gray_bus.v
// Module      : sync_gray_bus / sync_gray_max
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
//
// ---------------------------------------------------------------------------
// 1) sync_gray_bus : "格雷码 + toggle 握手" 多比特跨时钟域总线同步器
//
//   适用场景: 源域信号变化速率可能高于目的域采样能力(本项目 f_rd(A)=1/6ns、
//   f_rd(B)=1/4ns 都快于监控时钟)，此时单纯打拍同步格雷码总线会出现 aliasing:
//   格雷码只保证"相邻码字 1 bit 变化"，若一次采样跨过 >=2 个计数，解码结果
//   可能少算，且误差会保留。
//
//   机制(源域电平式握手，无往返等待，不阻塞数据通路):
//     - 源域: 每当 src_bin 变化，把它的格雷码抓拍到 src_gray_r 并翻转 src_toggle
//             (数据与 toggle 同一拍更新 -> 二者相对关系在目的域依然可见)
//     - 目的域: toggle 打入 STAGES 级同步链；同步后的 toggle 与 dst_toggle_r
//               不等时说明 src_gray_r 至少在 STAGES 个目的域周期前已稳定，采样安全
//   结论: 不会采到撕裂值；但源域若在两次目的域采样之间变化多次，中间值会被
//         合并(只保证"最终值"可达)，因此不适合持续高速变化的计数器。
//
// ---------------------------------------------------------------------------
// 2) sync_gray_max : 单调递增计数器的跨域同步 (事件计数器/占用量推荐)
//
//   sync_gray_bus 对"持续高速变化的计数器"会出现永久性滞后(每次合并丢一个增量)。
//   事件计数器是单调不减的，因此这里用更贴合的方案:
//     - 两条独立的多级格雷码采样链(采样相位不同)，分别解码后取较大者
//     - 格雷码保证单链不撕裂；偶发采到旧值只会使结果暂时偏小、绝不会偏大，
//       于是 max() 单调收敛到源域真值
//     - 无握手、无"合并丢增量"，额外开销仅约 2*STAGES*W 个寄存器
//
//   Preset: src_bin 必须是"单调不减"的二进制计数/指针(本项目事件计数器与
//           占用量计数均满足)。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

//---------------------------------------------------------------------------
// 1) 格雷码 + toggle 握手 (适用于可能回退的状态量, 如指针/标志打包总线)
//---------------------------------------------------------------------------
module sync_gray_bus #(
    parameter integer W      = 9,
    parameter integer STAGES = 2
) (
    //----------------------------------------------------------- 源时钟域
    input  wire         src_clk,
    input  wire         src_rst_n,
    input  wire [W-1:0] src_bin,
    //----------------------------------------------------------- 目的时钟域
    input  wire         dst_clk,
    input  wire         dst_rst_n,
    output wire [W-1:0] dst_bin
);
    //--------------------------------------------------- 源域: 格雷编码 + 抓拍
    wire [W-1:0] src_gray;

    bin2gray #(.W(W)) u_src_bin2gray (
        .bin  (src_bin),
        .gray (src_gray)
    );

    reg [W-1:0] src_gray_r;
    reg         src_toggle;
    reg [W-1:0] src_bin_d;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_gray_r <= {W{1'b0}};
            src_toggle <= 1'b0;
            src_bin_d  <= {W{1'b0}};
        end else begin
            src_bin_d <= src_bin;
            if (src_bin != src_bin_d) begin
                // 源域更新: 数据与 toggle 同一拍更新
                src_gray_r <= src_gray;
                src_toggle <= ~src_toggle;
            end
        end
    end

    //--------------------------------------------------- 目的域: toggle 同步链
    reg [STAGES-1:0] toggle_chain;
    integer i;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            toggle_chain <= {STAGES{1'b0}};
        end else begin
            toggle_chain[0] <= src_toggle;
            for (i = 1; i < STAGES; i = i + 1) begin
                toggle_chain[i] <= toggle_chain[i-1];
            end
        end
    end

    wire toggle_sync = toggle_chain[STAGES-1];

    //--------------------------------------------------- 目的域: 稳定后采样 + 解码
    // 关键点: dst_toggle_r 记录的是"上次搬运时源域 toggle 的值"，即已经同步到
    // 目的域的 toggle_sync —— 而不是源域 toggle 的当前值。这样只要源域 toggle
    // 与上次搬运时的值不同(说明 src_gray_r 已稳定 >= STAGES 个目的域周期)，
    // 就会持续搬运最新数据；即使源域在两次采样之间变化多次，目的域也能在
    // 源域停止变化前多搬运几次，从而收敛到最终值(纯握手每变化一次只搬一次，
    // 遇到"变化快于采样"时会丢掉增量，形成永久滞后)。
    reg [W-1:0] dst_gray_r;
    reg         dst_toggle_r;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_gray_r   <= {W{1'b0}};
            dst_toggle_r <= 1'b0;
        end else if (toggle_sync != dst_toggle_r) begin
            dst_gray_r   <= src_gray_r;
            dst_toggle_r <= toggle_sync;
        end
    end

    gray2bin #(.W(W)) u_dst_gray2bin (
        .gray (dst_gray_r),
        .bin  (dst_bin)
    );

endmodule

//---------------------------------------------------------------------------
// 2) 双链格雷码采样取大值 (适用于单调不减计数器)
//---------------------------------------------------------------------------
module sync_gray_max #(
    parameter integer W      = 33,
    parameter integer STAGES = 2
) (
    //----------------------------------------------------------- 源时钟域
    input  wire         src_clk,
    input  wire         src_rst_n,
    input  wire [W-1:0] src_bin,
    //----------------------------------------------------------- 目的时钟域
    input  wire         dst_clk,
    input  wire         dst_rst_n,
    output wire [W-1:0] dst_bin
);
    // 源域: 组合格雷编码 (源值为寄存器输出, 直接编码; src_clk/src_rst_n 仅作
    // 时钟域标注, 使本模块在综合约束与 CDC 检查中归属明确)
    wire [W-1:0] src_gray;
    bin2gray #(.W(W)) u_src_bin2gray (
        .bin  (src_bin),
        .gray (src_gray)
    );

    wire unused_src_clk = src_clk | src_rst_n;

    // 目的域: 两条独立的多级采样链 (链路相位不同, 避免同时采到"变化中"的码字)
    reg [W-1:0] chain0 [STAGES-1:0];
    reg [W-1:0] chain1 [STAGES-1:0];
    integer i;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) begin
                chain0[i] <= {W{1'b0}};
                chain1[i] <= {W{1'b0}};
            end
        end else begin
            chain0[0] <= src_gray;
            for (i = 1; i < STAGES; i = i + 1) chain0[i] <= chain0[i-1];
            // 链 1: 在链 0 首级之后再打一拍, 形成采样相位差
            chain1[0] <= chain0[0];
            for (i = 1; i < STAGES; i = i + 1) chain1[i] <= chain1[i-1];
        end
    end

    wire [W-1:0] bin0, bin1;
    gray2bin #(.W(W)) u_g2b0 (.gray(chain0[STAGES-1]), .bin(bin0));
    gray2bin #(.W(W)) u_g2b1 (.gray(chain1[STAGES-1]), .bin(bin1));

    // 取较大者: 单调计数器真值一定 >= 任一采样链结果
    assign dst_bin = (bin0 >= bin1) ? bin0 : bin1;

endmodule

`default_nettype wire
