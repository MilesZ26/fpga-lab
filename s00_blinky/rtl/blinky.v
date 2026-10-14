//=============================================================================
// blinky — LED 心跳（Stage 0）
//-----------------------------------------------------------------------------
// 功能：
//   产生一个方波去驱动 LED，频率由参数决定。
//   这是最小可用的"时钟 + 复位 + 分频 + 输出"完整例子，
//   目的是跑通"仿真 → 综合 → 上板"这条链路，而不是实现什么功能。
//
// 时钟域：clk
// 延迟：  复位后 led 为 0；经过 DIV 拍翻转一次
// 复位值：led = 0
//
// 分频原理：
//   计数器数到 DIV-1 翻转一次 led，所以 led 的一个完整周期
//   = 2 * DIV 个时钟。要得到 BLINK_HZ，就令
//       DIV = CLK_HZ / (2 * BLINK_HZ)
//
// 参数化为什么重要：
//   仿真时把 CLK_HZ 调成 100 而不是 50_000_000，
//   仿真从几秒钟变成几微秒。**同样的 RTL，改参数就能仿真。**
//=============================================================================

`timescale 1ns/1ps

module blinky #(
    parameter integer CLK_HZ   = 50_000_000,   // 输入时钟频率
    parameter integer BLINK_HZ = 1             // 期望的闪烁频率
)(
    input  wire clk,
    input  wire rst_n,   // 低有效
    output wire led
);

    localparam integer DIV   = CLK_HZ / (2 * BLINK_HZ);
    localparam integer CNT_W = (DIV <= 1) ? 1 : $clog2(DIV); //计算存储计数器所需的位宽，用判断语句防止返回0的错误

    reg [CNT_W-1:0] cnt;
    reg             led_r;

    // ── 分频计数器 ──
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= {CNT_W{1'b0}};
        else if (cnt == DIV - 1)
            cnt <= {CNT_W{1'b0}};
        else
            cnt <= cnt + 1'b1;
    end

    // ── LED 翻转 ──
    // 用 "cnt == DIV-1" 而不是 "cnt == DIV"，因为 cnt 到 DIV-1 就归零了。
    // 这样翻转时刻和归零时刻是同一拍，不会差一拍。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            led_r <= 1'b0;
        else if (cnt == DIV - 1)
            led_r <= ~led_r;
    end

    assign led = led_r;

endmodule
