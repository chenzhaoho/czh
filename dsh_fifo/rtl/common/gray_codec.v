//=============================================================================
// File        : gray_codec.v
// Module      : bin2gray / gray2bin
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 参数化格雷码编码/解码组合逻辑 (W 位)。
//               bin2gray : gray = (bin >> 1) ^ bin
//               gray2bin : bin[i] = ^gray[W-1:i] (逐位异或前缀)
//               跨时钟域只允许传递格雷码指针/计数器，禁止裸同步多位二进制。
//   工程说明: 顶层 function 形式在 Verilator 中会被当作模块例化处理，
//   因此改用参数化模块实现，同时更利于综合工具识别与面积统计。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

//--------------------------------------------------------------- 二进制->格雷
module bin2gray #(
    parameter integer W = 9
) (
    input  wire [W-1:0] bin,
    output wire [W-1:0] gray
);
    assign gray = (bin >> 1) ^ bin;
endmodule

//--------------------------------------------------------------- 格雷->二进制
module gray2bin #(
    parameter integer W = 9
) (
    input  wire [W-1:0] gray,
    output wire [W-1:0] bin
);
    genvar i;
    generate
        for (i = 0; i < W; i = i + 1) begin : g_prefix
            assign bin[i] = ^(gray >> i);
        end
    endgenerate
endmodule

`default_nettype wire
