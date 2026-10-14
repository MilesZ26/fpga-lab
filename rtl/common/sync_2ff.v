//=============================================================================
// sync_2ff — 两级同步器（跨时钟域）
//-----------------------------------------------------------------------------
// 功能：
//   把异步输入信号同步到 clk 时钟域。两级触发器串联，第一级可能出现
//   亚稳态，但它有一整个时钟周期去稳定，第二级采到的就是稳定值。
//
// 时钟域：clk（输入 async_in 属于另一个时钟域或异步）
// 延迟：  2 拍
//
// 适用范围（重要！）：
//   ✅ 适合：单比特、变化缓慢的控制信号（使能、标志、按键电平）
//   ❌ 不适合：多比特总线（各位到达时间不同，会采到中间态！）
//              多比特跨时钟域要用异步 FIFO 或握手协议
//   ❌ 不适合：需要"每个脉冲都被捕获"的快速脉冲
//              （如果脉冲比目标时钟还窄，会被整个漏掉）
//              这种要用脉冲同步器（翻转+边沿检测）
//
// ASYNC_REG 属性告诉 Vivado 这两个触发器是一组同步器，
// 摆放时会靠在一起，提高 MTBF。
//=============================================================================

`timescale 1ns/1ps

module sync_2ff #(
    parameter integer       WIDTH       = 1,
    parameter [WIDTH-1:0]   RESET_VALUE = {WIDTH{1'b0}}
)(
    input  wire             clk,
    input  wire             rst_n,     // 低有效
    input  wire [WIDTH-1:0] async_in,
    output wire [WIDTH-1:0] sync_out
);

    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] s1;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= RESET_VALUE;
            s2 <= RESET_VALUE;
        end else begin
            s1 <= async_in;
            s2 <= s1;
        end
    end

    assign sync_out = s2;

endmodule
