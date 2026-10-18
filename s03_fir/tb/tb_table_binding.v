`timescale 1ns/1ps
//=============================================================================
// tb_table_binding — 回归"一个表一个宏"的修复
//-----------------------------------------------------------------------------
// 2026-10-18 之前，全仓库只有一个 `LUTDIR` 宏：sim.sh 按"本 stage 优先，
// 否则沿 deps 找"选一个目录。s03 有了自己的 coef.mem 之后，如果同一轮仿真
// 里既例化 nco（要 s01_nco/lut/）又例化 fir（要 s03_fir/lut/），一个宏
// 只能指一个目录，必然有一个读错 —— 而且 $readmemh 读不到时**不报错**，
// 只会留下 x，很难查。
//
// 这个 TB 就是那个"同一轮仿真里两张表"的最小场景：
//   · s01 的 nco  → 两张 4096×12 的正弦/余弦表（NCO_LUTDIR）
//   · s03 的 fir  → 5 抽头 coef5.mem（FIR_COEFDIR）
//
// 它检查四件事：
//   1. NCO 的 ROM 特征值真的读进了 s01 的表（不是 x、不是 FIR 的系数）
//   2. FIR 的 coef[0]/coef[2] 真的读进了 s03 的系数表
//   3. 跑几拍后 NCO 输出不是 x
//   4. FIR 的冲激响应 h[0] = 128，证明它用的是 coef5.mem 而不是 s01 的表
//
// 如果哪天又把宏改回"全仓库一个 LUTDIR"，这个 TB 会立刻变红。
//=============================================================================
module tb_table_binding;
    `include "tb_common.vh"

`ifndef NCO_LUTDIR
  `ifdef LUTDIR
    `define NCO_LUTDIR `LUTDIR
  `else
    `define NCO_LUTDIR "s01_nco/lut/"
  `endif
`endif
`ifndef FIR_COEFDIR
  `define FIR_COEFDIR "s03_fir/lut/"
`endif

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ── s01 的 NCO（用默认 4096 深的表，LUT_AW=12/AW=12）──────────────
    wire signed [11:0] sin_o;
    wire signed [11:0] cos_o;
    nco #(
        .CLK_HZ(1024), .FREQ_HZ(16), .PHASE_W(16), .LUT_AW(12), .AW(12)
    ) u_nco (
        .clk(clk), .rst_n(rst_n), .fsin_o(sin_o), .fcos_o(cos_o)
    );

    // ── s03 的 FIR（5 抽头小车，coef5.mem = [2048,8192,12288,8192,2048]）
    reg signed [11:0] x_in = 0;
    wire signed [12:0] y_out;
    fir #(
        .IW(12), .CW(16), .N(5), .OW(13), .SHIFT(15), .ROUND(1),
        .COEF_FILE("coef5.mem")
    ) u_fir (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_out(y_out)
    );

    integer i;

    initial begin
        // ── 1. NCO 的表（直接看 ROM 内容，不依赖输出波形）───────────
        `check_eq("NCO sin_rom[0] = 0", u_nco.sin_rom[0], 0);
        `check_eq("NCO sin_rom[1024] = +2047", u_nco.sin_rom[1024], 2047);
        `check_eq("NCO cos_rom[0] = +2047", u_nco.cos_rom[0], 2047);
        `check_eq("NCO cos_rom[1024] = 0", u_nco.cos_rom[1024], 0);

        // ── 2. FIR 的系数表 ────────────────────────────────────────
        `check_eq("FIR coef[0] = 2048（来自 s03_fir/lut/coef5.mem）",
                  u_fir.coef[0], 2048);
        `check_eq("FIR coef[2] = 12288", u_fir.coef[2], 12288);

        // ── 3. 复位释放后 NCO 输出不是 x ──────────────────────────
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        #1;
        `check((^sin_o) !== 1'bx, "NCO sin 输出不是 x（表真的进了设计）");
        `check((^cos_o) !== 1'bx, "NCO cos 输出不是 x");
        `check(sin_o !== 12'sd0 || cos_o !== 12'sd0, "NCO 输出不是恒 0");

        // ── 4. FIR 冲激响应 h[0] = 128 ─────────────────────────────
        // 5 个下降沿的约定：驱动冲激后第 4 个下降沿看到 h[0]。
        @(negedge clk);
        x_in = 12'sd2047;                 // k=0：冲激
        @(negedge clk);
        x_in = 12'sd0;                    // k=1：立刻回 0（单点冲激）
        for (i = 0; i < 3; i = i + 1)     // k=2,3,4
            @(negedge clk);
        `check_eq("FIR h[0] = 128（2047*2048/2^15）", y_out, 128);

        tb_done;
    end

endmodule
