//=============================================================================
// File        : rst_sync.v
// Module      : rst_sync
// Project     : 双异步 FIFO 系统 (课程设计 题目27 / 题目一)
// Description : 复位同步释放电路。复位"异步置位、同步释放"，用于把外部异步
//               复位 rst_n_async 转换成某个时钟域内干净、无亚稳态风险的
//               rst_n_sync，供该域内所有触发器使用。
//               首级触发器直接用 rst_n_async 作异步复位，使复位路径不经过
//               组合逻辑，避免复位树上的毛刺。
// Parameters  : STAGES 同步释放级数，默认 2 (可参数化 3)。
// Preset      : rst_n_async 低有效；外部必须保证其宽度 >= STAGES 个目标时钟周期。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module rst_sync #(
    parameter integer STAGES = 2
) (
    input  wire clk,
    input  wire rst_n_async,
    output wire rst_n_sync
);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [STAGES-1:0] sync_chain;
    integer i;

    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) begin
            sync_chain <= {STAGES{1'b0}};
        end else begin
            sync_chain[0] <= 1'b1;
            for (i = 1; i < STAGES; i = i + 1) begin
                sync_chain[i] <= sync_chain[i-1];
            end
        end
    end

    assign rst_n_sync = sync_chain[STAGES-1];
endmodule
`default_nettype wire
