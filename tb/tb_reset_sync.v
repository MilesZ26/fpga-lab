//=============================================================================
// tb_reset_sync — reset_sync 的自测
//-----------------------------------------------------------------------------
// 这个模块的全部价值就一句话：**异步复位、同步释放**。
// 所以测试也必须把这两半分开验：
//
//   同步释放：arst_n 拉高之后，rst_n 要**等 2 个时钟沿**才变高
//             （这样所有触发器在同一时刻退出复位，不会有人先有人后）
//   异步复位：arst_n 拉低之后，rst_n **不用等时钟沿**立刻变低
//             （这样系统没时钟时也能被复位按住）
//
// 时钟周期：10ns（`CLK_PERIOD），时钟沿在 5, 15, 25, ... ns
//=============================================================================

`timescale 1ns/1ps

module tb_reset_sync;

    `include "tb_common.vh"

    reg  clk    = 1'b0;
    reg  arst_n = 1'b0;
    wire rst_n;

    always #(`CLK_PERIOD/2) clk = ~clk;

    reset_sync dut (
        .clk    (clk),
        .arst_n (arst_n),
        .rst_n  (rst_n)
    );

`ifdef DUMP_VCD
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_reset_sync);
    end
`endif

    initial begin
        // ── 复位按住期间 ──
        arst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        `check(rst_n === 1'b0, "arst_n = 0 期间 rst_n = 0");

        // ── 释放必须是同步的：数 2 拍 ──
        arst_n = 1'b1;
        #1;
        `check(rst_n === 1'b0, "释放后第 0 拍：rst_n 还是 0");

        @(posedge clk);
        #1;
        `check(rst_n === 1'b0, "释放后第 1 拍：rst_n 还是 0");

        @(posedge clk);
        #1;
        `check(rst_n === 1'b1,
               "释放后第 2 拍：rst_n 才变 1 —— 释放被同步对齐到了时钟");

        // ── 之后必须稳定保持，不能自己抖回去 ──
        repeat (2) @(posedge clk);
        #1;
        `check(rst_n === 1'b1, "释放之后一直保持 1，不会自己掉回去");

        // ── 拉低必须是异步的：不等时钟沿 ──
        // 此刻在两次时钟沿正中间，离下一个时钟沿还有 5ns。
        #4;
        arst_n = 1'b0;
        #1;
        `check(rst_n === 1'b0,
               "arst_n 拉低后 1ns 就生效，不用等时钟沿（这就是异步）");

        // ── 按住期间持续为 0 ──
        repeat (2) @(posedge clk);
        #1;
        `check(rst_n === 1'b0, "复位按住期间 rst_n 保持 0");

        tb_done;
    end

endmodule
