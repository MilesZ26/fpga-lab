//=============================================================================
// tb_blinky — blinky 的自测
//-----------------------------------------------------------------------------
// 注意 CLK_HZ 用的是 100 而不是 50_000_000：
//   参数化之后仿真可以随便调小，几微秒就跑完。
//   DIV = 100 / (2*10) = 5，也就是每 5 个时钟翻转一次。
//=============================================================================

`timescale 1ns/1ps

module tb_blinky;

    `include "tb_common.vh"

    localparam integer CLK_HZ   = 100;
    localparam integer BLINK_HZ = 10;
    localparam integer DIV      = CLK_HZ / (2 * BLINK_HZ);   // = 5

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    wire led;

    always #(`CLK_PERIOD/2) clk = ~clk;

    blinky #(
        .CLK_HZ   (CLK_HZ),
        .BLINK_HZ (BLINK_HZ)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .led   (led)
    );

`ifdef DUMP_VCD
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_blinky);
    end
`endif

    time t_rise, t_fall;

    initial begin
        // ── 复位期间 ──
        rst_n = 1'b0;
        repeat (3) @(posedge clk);//重复三次
        #1;
        `check(led === 1'b0, "复位期间 LED 保持熄灭");

        rst_n = 1'b1;

        // ── 第一段高电平 ──
        @(posedge led);
        t_rise = $time;
        @(negedge led);
        t_fall = $time;
        `check_eq("LED 高电平时长 = DIV 个时钟周期",
                 t_fall - t_rise, DIV * `CLK_PERIOD);

        // ── 第一段低电平 ──
        @(posedge led);
        `check_eq("LED 低电平时长 = DIV 个时钟周期",
                 $time - t_fall, DIV * `CLK_PERIOD);

        // ── 再测一次高电平，确认周期性 ──
        t_rise = $time;
        @(negedge led);
        `check_eq("第二个周期的高电平时长相同（周期性）",
                 $time - t_rise, DIV * `CLK_PERIOD);

        tb_done;
    end

endmodule
