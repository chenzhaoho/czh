//=============================================================================
// File        : sync_2ff.v
// Module      : sync_2ff_p / sync_2ff_1 / sync_2ff_c
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 多级(默认 2 级，可参数化为 3 级) 打拍同步器，用于跨时钟域
//               采样已经格雷编码的指针/计数器，以及慢变化的电平类标志。
//               所有触发器使用目的时钟与同步复位 (clk 域内 rst_n 已同步释放)。
//               注意: 本模块不做任何"多数表决"或"握手"，只提供亚稳态衰减窗口，
//               因此只允许接格雷码总线或单比特电平信号。
// Parameters  : STAGES 同步级数 (>=2)，默认为 2。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

//---------------------------------------------------------------- 9 bit 指针
module sync_2ff_p #(
    parameter integer STAGES = 2,
    parameter integer W = 9
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [W-1:0] d_async,
    output wire [W-1:0] q_sync
);
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] sync_chain [STAGES-1:0];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) begin
                sync_chain[i] <= {W{1'b0}};
            end
        end else begin
            sync_chain[0] <= d_async;
            for (i = 1; i < STAGES; i = i + 1) begin
                sync_chain[i] <= sync_chain[i-1];
            end
        end
    end
    assign q_sync = sync_chain[STAGES-1];
endmodule

//---------------------------------------------------------- 1 bit 电平/标志
module sync_2ff_1 #(
    parameter integer STAGES = 2
) (
    input  wire clk,
    input  wire rst_n,
    input  wire d_async,
    output wire q_sync
);
    reg [STAGES-1:0] sync_chain;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_chain <= {STAGES{1'b0}};
        end else begin
            sync_chain[0] <= d_async;
            for (i = 1; i < STAGES; i = i + 1) begin
                sync_chain[i] <= sync_chain[i-1];
            end
        end
    end
    assign q_sync = sync_chain[STAGES-1];
endmodule

//---------------------------------------------------------- 6 bit 状态字
module sync_2ff_s #(
    parameter integer STAGES = 2
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [5:0] d_async,
    output wire [5:0] q_sync
);
    reg [5:0] sync_chain [STAGES-1:0];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) begin
                sync_chain[i] <= 6'd0;
            end
        end else begin
            sync_chain[0] <= d_async;
            for (i = 1; i < STAGES; i = i + 1) begin
                sync_chain[i] <= sync_chain[i-1];
            end
        end
    end
    assign q_sync = sync_chain[STAGES-1];
endmodule

//------------------------------------------------- W bit 格雷码事件计数器
module sync_2ff_c #(
    parameter integer W      = 33,
    parameter integer STAGES = 2
) (
    input  wire     clk,
    input  wire     rst_n,
    input  wire [W-1:0] d_async,
    output wire [W-1:0] q_sync
);
    reg [W-1:0] sync_chain [STAGES-1:0];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) begin
                sync_chain[i] <= {W{1'b0}};
            end
        end else begin
            sync_chain[0] <= d_async;
            for (i = 1; i < STAGES; i = i + 1) begin
                sync_chain[i] <= sync_chain[i-1];
            end
        end
    end
    assign q_sync = sync_chain[STAGES-1];
endmodule

`default_nettype wire
