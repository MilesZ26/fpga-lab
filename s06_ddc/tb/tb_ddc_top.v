`timescale 1ns/1ps
//=============================================================================
// tb_ddc_top — s06 板级顶层（DUC → DDC 回环）的集成验收
//-----------------------------------------------------------------------------
// 只测顶层接线 + 板上能观察到的现象：
//   ① reset_sync：复位期间 DUC/DDC 输出 0、LED 全灭；
//   ② DUC 输出是 0.06 Fs 的复单音（0.01 + 0.05）；
//   ③ DDC 输出回到 0.01 Fs 的复单音，幅度 ≈ 1000（回环通了）；
//   ④ led[0]（DDC 活动）和 led[1]（DUC 活动）点亮；
//   ⑤ led[3:2] 1 Hz 心跳；
//   ⑥ 异步复位立刻清零。
//
// ACT_W 调成 8：板上是 16（约 0.8 ms 才点亮），仿真里 256 拍就到顶了。
//=============================================================================
module tb_ddc_top;
    `include "tb_common.vh"

    localparam integer CLK_HZ   = 100;
    localparam integer HEART_HZ = 1;
    localparam integer FREQ_SIG = 1;
    localparam integer FREQ_LO  = 5;
    localparam integer OW_DUC   = 15;
    localparam integer OW_DDC   = 13;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [3:0] led;

    ddc_top #(
        .CLK_HZ(CLK_HZ), .HEART_HZ(HEART_HZ),
        .FREQ_SIG(FREQ_SIG), .FREQ_LO(FREQ_LO),
        .OW_DUC(OW_DUC), .OW_DDC(OW_DDC),
        .LO_DLY_DUC(4), .LO_DLY_DDC(23),
        .ACT_W(8), .ACT_THRESH(16)
    ) dut (
        .clk(clk), .rst_n(rst_n), .led(led)
    );

    wire signed [OW_DUC-1:0] ie = dut.ie;
    wire signed [OW_DUC-1:0] qe = dut.qe;
    wire signed [OW_DDC-1:0] di = dut.ddc_i;
    wire signed [OW_DDC-1:0] dq = dut.ddc_q;

    integer t, nz, peak, mag, mag_min, mag_max;
    integer rises_duc, rises_ddc, prev, hb_edges, hb_prev;

    initial begin
        // ── 1. 复位 ─────────────────────────────────────────────────
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        `check_eq("复位期间 DUC i_e = 0", ie, 0);
        `check_eq("复位期间 DDC i_out = 0", di, 0);
        `check_eq("复位期间 LED 全灭", led, 4'b0000);

        // ── 2. 释放复位，跑回环稳态 ─────────────────────────────────
        rst_n = 1'b1;
        for (t = 0; t < 2000; t = t + 1) @(posedge clk);
        @(negedge clk);

        `check(ie !== 0 || qe !== 0, "运行中 DUC 输出非零");
        `check(di !== 0 || dq !== 0, "运行中 DDC 回环输出非零（整条链通了）");

        // ── 3. DDC 输出幅度 ≈ 1000 ──────────────────────────────────
        peak = 0;
        mag_min = 1 << 30;
        mag_max = 0;
        for (t = 0; t < 400; t = t + 1) begin
            @(negedge clk);
            if (di > peak) peak = di;
            mag = di*di + dq*dq;
            if (mag < mag_min) mag_min = mag;
            if (mag > mag_max) mag_max = mag;
        end
        `check(peak > 1800 && peak < 2150,
               "DDC 回环输出幅度 ≈ 2040（满幅测试单音 × 单位增益）");
        `check(mag_min > 1800*1800 && mag_max < 2150*2150,
               "DDC 回环复单音幅度在 1800..2150（I/Q 都在）");
        `check(mag_max - mag_min < (mag_max / 3),
               "DDC 回环复单音幅度基本恒定");

        // ── 4. 频率：DUC ≈ 0.06 Fs、DDC ≈ 0.01 Fs ──────────────────
        rises_duc = 0;
        prev = (ie >= 0);
        for (t = 0; t < 1000; t = t + 1) begin
            @(negedge clk);
            nz = (ie >= 0);
            if (!prev && nz) rises_duc = rises_duc + 1;
            prev = nz;
        end
        `check(rises_duc >= 50 && rises_duc <= 70,
               "DUC 输出上升过零 ≈ 60 次/1000 拍（0.06 Fs）");

        rises_ddc = 0;
        prev = (di >= 0);
        for (t = 0; t < 1000; t = t + 1) begin
            @(negedge clk);
            nz = (di >= 0);
            if (!prev && nz) rises_ddc = rises_ddc + 1;
            prev = nz;
        end
        `check(rises_ddc >= 8 && rises_ddc <= 12,
               "DDC 输出上升过零 ≈ 10 次/1000 拍（回到 0.01 Fs）");

        // ── 5. 活动 LED + 心跳 ──────────────────────────────────────
        `check(led[0] == 1'b1, "led[0] 点亮：DDC 输出有持续活动");
        `check(led[1] == 1'b1, "led[1] 点亮：DUC 输出有持续活动");
        `check(led[3:2] == {2{led[2]}}, "led[3:2] 同相位（都接 hb）");
        hb_edges = 0;
        hb_prev = led[2];
        for (t = 0; t < 120; t = t + 1) begin
            @(negedge clk);
            if (led[2] != hb_prev) hb_edges = hb_edges + 1;
            hb_prev = led[2];
        end
        `check(hb_edges >= 2, "120 拍内心跳至少翻转 2 次");

        // ── 6. 异步复位立刻清零 ─────────────────────────────────────
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立刻把 DDC i_out 清零", di, 0);
        `check_eq("异步复位立刻把 DUC i_e 清零", ie, 0);
        `check_eq("异步复位立刻把 LED 清零", led, 4'b0000);

        tb_done;
    end

endmodule
