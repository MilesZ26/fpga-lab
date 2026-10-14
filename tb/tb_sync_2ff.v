//=============================================================================
// tb_sync_2ff — sync_2ff 的自测
//-----------------------------------------------------------------------------
// 验证三件事：
//   1. 复位行为：rst_n = 0 期间输出立刻等于 RESET_VALUE（异步复位）
//   2. 延迟：输入变化后，输出**正好**晚 2 个时钟沿
//   3. 参数：WIDTH / RESET_VALUE 真的起作用
//
// 注意：仿真是**证不出**亚稳态的（iverilog 没有模拟建立/保持时间），
// 所以这里验的是"2 拍延迟"这个可以确定的部分 —— 它同时是别人
// 依赖这个模块时唯一能依赖的承诺。
//
// 时钟周期：10ns（`CLK_PERIOD），时钟沿在 5, 15, 25, ... ns
//=============================================================================

`timescale 1ns/1ps

module tb_sync_2ff;

    `include "tb_common.vh"

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;

    // 1 位（默认参数）
    reg        async_in = 1'b0;
    wire       sync_out;

    // 4 位（显式参数 + 非零复位值）
    reg  [3:0] async_in4 = 4'h0;
    wire [3:0] sync_out4;

    always #(`CLK_PERIOD/2) clk = ~clk; //创建时钟

    sync_2ff u_1bit (
        .clk      (clk),
        .rst_n    (rst_n),
        .async_in (async_in),
        .sync_out (sync_out)
    );

    sync_2ff #(
        .WIDTH       (4),
        .RESET_VALUE (4'b1010)
    ) u_4bit (
        .clk      (clk),
        .rst_n    (rst_n),
        .async_in (async_in4),
        .sync_out (sync_out4)
    );

`ifdef DUMP_VCD
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_sync_2ff);
    end
`endif

    initial begin
        // ── 复位 ──
        // 故意让输入在复位期间就已经是 1：复位必须压住它
        rst_n     = 1'b0;
        async_in  = 1'b1;
        async_in4 = 4'hF;

        repeat (3) @(posedge clk);
        #1;
        `check(sync_out === 1'b0,
               "复位期间 sync_out = 0（异步复位立刻生效，不等时钟）");
        `check(sync_out4 === 4'b1010,
               "4 位版本复位值是参数 RESET_VALUE 指定的 4'b1010，不是 0");

        // ── 释放复位，数延迟 ──
        rst_n = 1'b1;
        #1;
        `check(sync_out === 1'b0,
               "释放复位后第 0 拍：sync_out 还是 0");

        @(posedge clk);
        #1;
        `check(sync_out === 1'b0,
               "第 1 拍：sync_out 还是 0（只有第一级采到了 1）");

        @(posedge clk);
        #1;
        `check(sync_out === 1'b1,
               "第 2 拍：sync_out 跟随为 1 —— 正好延迟 2 拍");

        // ── 下降沿也必须是 2 拍（不能只测一个方向）──
        async_in = 1'b0; //波形里看这里没对齐时钟，下降是异步的
        #1;
        `check(sync_out === 1'b1,
               "输入刚变 0：sync_out 还没动");

        @(posedge clk);
        #1;
        `check(sync_out === 1'b1,
               "下降沿第 1 拍：sync_out 还是 1");

        @(posedge clk);
        #1;
        `check(sync_out === 1'b0,
               "下降沿第 2 拍：sync_out 跟随为 0");

        // ── WIDTH 参数：4 位版本也延迟 2 拍 ──
        // 复位释放后 async_in4 一直是 4'hF，所以此时 sync_out4 应该已经跟到 4'hF
        `check(sync_out4 === 4'hF,
               "4 位版本：复位释放后跟随输入变成 4'hF");

        async_in4 = 4'h5;
        #1;
        `check(sync_out4 === 4'hF,
               "4 位版本：输入刚变，输出未变");

        repeat (2) @(posedge clk);
        #1;
        `check(sync_out4 === 4'h5,
               "4 位版本：2 拍后输出跟随（它只是把每一位分别打两拍）");

        // ── 异步复位：在时钟沿之间拉低，不用等时钟 ──
        async_in = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        `check(sync_out === 1'b1,
               "先让输出稳定在 1（准备验证复位随时能拉低它）");

        #4;                     // 此刻在两次时钟沿正中间
        rst_n = 1'b0;           // 离下一个时钟沿还有 5ns
        #1;
        `check(sync_out === 1'b0,
               "复位拉低后 1ns 就变 0（离下一个时钟沿还有 5ns）");
        `check(sync_out4 === 4'b1010,
               "4 位版本同样立刻回到 RESET_VALUE");

        tb_done;
    end

endmodule
