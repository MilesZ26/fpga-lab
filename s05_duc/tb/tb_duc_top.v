`timescale 1ns/1ps
//=============================================================================
// tb_duc_top — s05 板级顶层的集成验收
//-----------------------------------------------------------------------------
// 只测"顶层接线"，不重复算术（算术在 tb_duc_core 里逐位对过）：
//   ① reset_sync：复位期间 DUC 输出 0；
//   ② 测试单音真的进了 DUC，输出是 0.06 Fs 的复单音（0.01 + 0.05）；
//   ③ 幅度 ≈ 1000（增益预算没被接线改坏）；
//   ④ 四颗 LED 同相位 1 Hz 心跳。
//
// 时钟参数按项目惯例调小：CLK_HZ=100、FREQ_SIG=1、FREQ_LO=5，
// 这样仿真几微秒就能跑完一个心跳周期。
//=============================================================================
module tb_duc_top;
    `include "tb_common.vh"

    localparam integer CLK_HZ   = 100;
    localparam integer HEART_HZ = 1;
    localparam integer FREQ_SIG = 1;       // 0.01 × Fs
    localparam integer FREQ_LO  = 5;       // 0.05 × Fs
    localparam integer OW_INT   = 15;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [3:0] led;

    duc_top #(
        .CLK_HZ(CLK_HZ), .HEART_HZ(HEART_HZ),
        .FREQ_SIG(FREQ_SIG), .FREQ_LO(FREQ_LO),
        .OW_INT(OW_INT), .LO_DLY(4)
    ) dut (
        .clk(clk), .rst_n(rst_n), .led(led)
    );

    // 顶层内部探针（层次引用；和 ILA 探的是同一批信号）
    wire signed [OW_INT-1:0] i_e = dut.i_e;
    wire signed [OW_INT-1:0] i_o = dut.i_o;
    wire signed [OW_INT-1:0] q_e = dut.q_e;
    wire signed [OW_INT-1:0] q_o = dut.q_o;

    integer t, nz, peak, mag, mag_min, mag_max;
    integer rises, prev, hb_edges, hb_prev;

    initial begin
        // ── 1. 复位 ─────────────────────────────────────────────────
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        `check_eq("复位期间 DUC i_e = 0", i_e, 0);
        `check_eq("复位期间 DUC q_e = 0", q_e, 0);
        `check_eq("复位期间 LED 全灭", led, 4'b0000);

        // ── 2. 释放复位，跑稳态 ─────────────────────────────────────
        rst_n = 1'b1;
        for (t = 0; t < 300; t = t + 1) @(posedge clk);
        @(negedge clk);

        `check(i_e !== 0 || q_e !== 0, "运行中 DUC 输出非零（测试单音进了链路）");

        // 幅度：取 200 个点，|i_e + j q_e| 的峰谷
        peak = 0;
        mag_min = 1 << 30;
        mag_max = 0;
        for (t = 0; t < 200; t = t + 1) begin
            @(negedge clk);
            if (i_e > peak) peak = i_e;
            mag = i_e*i_e + q_e*q_e;
            if (mag < mag_min) mag_min = mag;
            if (mag > mag_max) mag_max = mag;
        end
        `check(peak > 1800 && peak < 2150,
               "DUC 输出单音幅度 ≈ 2040（满幅测试单音 × 单位增益）");
        `check(mag_min > 1800*1800 && mag_max < 2150*2150,
               "DUC 输出复单音幅度在 1800..2150（I/Q 正交、没有单路缺失）");
        `check(mag_max - mag_min < (mag_max / 3),
               "DUC 输出复单音幅度基本恒定（max-min < max/3）");

        // ── 3. 频率：i_e 的上升过零次数 ≈ 0.06 × 1000 = 60 ──────────
        // 注意 i_e 是 2Fs 波形里的偶相，采样率仍是 Fs，所以直接按 Fs 数。
        rises = 0;
        prev = (i_e >= 0);
        for (t = 0; t < 1000; t = t + 1) begin
            @(negedge clk);
            nz = (i_e >= 0);
            if (!prev && nz) rises = rises + 1;
            prev = nz;
        end
        `check(rises >= 50 && rises <= 70,
               "i_e 上升过零 ≈ 60 次/1000 拍（0.06 Fs = 0.01 + 0.05）");

        // ── 4. 心跳：四颗灯同相位，1 Hz（仿真半周期 50 拍）─────────
        `check(led[3:0] == {4{led[0]}}, "四颗 LED 同相位（都接同一个 hb）");
        hb_edges = 0;
        hb_prev = led[0];
        for (t = 0; t < 120; t = t + 1) begin
            @(negedge clk);
            if (led[0] != hb_prev) hb_edges = hb_edges + 1;
            hb_prev = led[0];
        end
        `check(hb_edges >= 2, "120 拍内 LED 至少翻转 2 次（1 Hz 心跳在工作）");

        // ── 5. 异步复位立刻清零 ─────────────────────────────────────
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立刻把 i_e 清零（不等时钟沿）", i_e, 0);
        `check_eq("异步复位立刻把 q_e 清零", q_e, 0);
        `check_eq("异步复位立刻把 LED 清零", led, 4'b0000);

        tb_done;
    end

endmodule
