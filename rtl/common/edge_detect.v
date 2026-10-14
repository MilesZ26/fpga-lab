//=============================================================================
// edge_detect — 边沿检测
//-----------------------------------------------------------------------------
// 功能：
//   输入 level 发生变化时，输出一个只持续 1 个时钟周期的脉冲。
//
// 时钟域：clk（level 必须已经在这个时钟域里！
//         如果是异步信号，先过 sync_2ff 再用这个模块）
// 延迟：  组合输出，level 变化的同一时刻就有效
//
// 重要提醒：
//   rise / fall / both 是"电平变化"的指示，它在 level 改变的瞬间就拉高，
//   在下一次时钟上升沿被清除。所以它跟 level 的变化是同时的，不是延迟一拍。
//
// 复位行为：
//   rst_n = 0 期间 rise / fall / both 被强制为 0，不会向下游放脉冲。
//   复位释放那一刻，如果 level 已经是 1，因为 level_d 的复位值是 0，
//   还是会输出一个 rise / both 脉冲 —— 这是"复位后第一次采样"的必然结果，
//   不是 bug。真实的输入在复位期间通常是低电平，所以一般不出现。
//
// 典型用法：
//   按键消抖后的信号 → edge_detect → 得到"按下"脉冲
//=============================================================================

`timescale 1ns/1ps

module edge_detect (
    input  wire clk,
    input  wire rst_n,   // 低有效
    input  wire level,   // 被检测的信号（已在本时钟域）
    output wire rise,    // level 由 0 变 1 时输出 1 拍
    output wire fall,    // level 由 1 变 0 时输出 1 拍
    output wire both     // 只要变化就输出 1 拍
);

    reg level_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            level_d <= 1'b0;
        else
            level_d <= level;
    end

    // rst_n 门控：复位期间把三个脉冲输出都压到 0。
    // 少了这个与门，复位瞬间会被误判成一个边沿：
    //   level 还是 1，level_d 被异步复位成 0，both = 1 ^ 0 = 1。
    assign rise = rst_n &  level & ~level_d; //时钟上升沿是0，现在变1
    assign fall = rst_n & ~level &  level_d; //时钟上升沿是1，现在变0
    assign both = rst_n & (level ^  level_d);

endmodule
