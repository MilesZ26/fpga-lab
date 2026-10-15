`timescale 1ns/1ps
//=============================================================================
// tb_lut — 校验 s01_nco/lut/*.mem 这份"真值表"本身
//-----------------------------------------------------------------------------
// 为什么查表数据也要 testbench：
//   RTL 的 testbench 只能证明"RTL 读到了表里的东西"，证明不了"表本身对不对"。
//   表是脚本离线生成的（Vivado 综合不了 $sin，必须是常量），一旦生成器改了、
//   或者文件被手改过，仿真会照样"通过"，但上板输出的频率/幅度就是错的。
//   所以把"表 = 生成器"这条关系也放进回归测试。
//
// 表路径：
//   $readmemh 的路径是相对**仿真进程的工作目录**（sim.sh 在 build/ 里跑 vvp），
//   不是相对 RTL/testbench 文件所在目录。所以 sim.sh 会传进来一个绝对路径宏
//   `LUTDIR`；直接手工跑 iverilog 时用下面的默认值（相对仓库根）。
//
// 检查点（12 个）：
//   1. 四个象限的特征值（0 / ±2047 / 0）
//   2. 值域恰好 [-2047, +2047]，没有用到 -2048（保证正负严格对称）
//   3. cos[i] == sin[(i+N/4)%N]：两张表同源，只差 1/4 圈
//   4. 幅度恒定：sin^2+cos^2 是常数（NCO 最经典的判据）
//=============================================================================
module tb_lut;
    `include "tb_common.vh"

    localparam LUT_AW = 12;
    localparam AW     = 12;
    localparam DEPTH  = 1 << LUT_AW;
    localparam AMP    = (1 << (AW-1)) - 1;      // 2047

`ifndef LUTDIR
  `define LUTDIR "s01_nco/lut/"
`endif

    reg signed [AW-1:0] sin_rom [0:DEPTH-1];
    reg signed [AW-1:0] cos_rom [0:DEPTH-1];

    integer i;
    integer vmin, vmax;
    integer shift_err;
    integer amp, amp_min, amp_max, amp_dev;
    real    amp_pp;

    initial begin
        $readmemh({`LUTDIR, "sin.mem"}, sin_rom);
        $readmemh({`LUTDIR, "cos.mem"}, cos_rom);
        $display("LUTDIR = %s", `LUTDIR);
        $display("表深 = %0d，幅值位宽 = %0d，满幅 = %+0d", DEPTH, AW, AMP);

        // ── 1. 特征点 ────────────────────────────────────────────
        `check_eq("sin[0] = 0",        sin_rom[0],          0);
        `check_eq("sin[N/4] = +2047",  sin_rom[DEPTH/4],    AMP);
        `check_eq("sin[N/2] = 0",      sin_rom[DEPTH/2],    0);
        `check_eq("sin[3N/4] = -2047", sin_rom[3*DEPTH/4],  -AMP);
        `check_eq("cos[0] = +2047",    cos_rom[0],          AMP);
        `check_eq("cos[N/4] = 0",      cos_rom[DEPTH/4],    0);
        `check_eq("cos[N/2] = -2047",  cos_rom[DEPTH/2],    -AMP);

        // ── 2. 值域与对称性 ──────────────────────────────────────
        // 如果量化用了"就近取整"之类的非对称规则，sin 表会带上微小直流，
        // 后面做混频时就是本振泄漏。这里顺手把它钉死。
        vmin = 32767;
        vmax = -32768;
        for (i = 0; i < DEPTH; i = i + 1) begin
            if (sin_rom[i] < vmin) vmin = sin_rom[i];
            if (sin_rom[i] > vmax) vmax = sin_rom[i];
        end
        `check_eq("sin 表最小值 = -2047", vmin, -AMP);
        `check_eq("sin 表最大值 = +2047", vmax, AMP);
        `check_eq("奇对称：sin[N/2-1] == -sin[N/2+1]",
                  sin_rom[DEPTH/2 - 1], -sin_rom[DEPTH/2 + 1]);

        // ── 3. cos 表 = sin 表移 1/4 圈 ──────────────────────────
        shift_err = 0;
        for (i = 0; i < DEPTH; i = i + 1)
            if (cos_rom[i] !== sin_rom[(i + DEPTH/4) % DEPTH])
                shift_err = shift_err + 1;
        `check_eq("cos[i] == sin[(i+N/4)%N] 对全部 4096 点成立", shift_err, 0);

        // ── 4. 幅度恒定 ──────────────────────────────────────────
        // 容差推导：每个采样点量化误差 |e| <= 0.5 LSB，A = 2047
        //   amp = A^2 + 2A(sin*e1 + cos*e2) + O(e^2)
        //   max|sin*e1 + cos*e2| = 0.5*sqrt(2) ≈ 0.707
        //   => 单边偏差上界 ≈ 2*2047*0.707 ≈ 2895
        // 判据取 4096（= 2A）：有理论依据，又不至于宽到形同虚设
        // （故意改坏表里一个数会看到偏差涨到 4A 以上）。
        amp_min = 2147483647;
        amp_max = 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            amp = sin_rom[i] * sin_rom[i] + cos_rom[i] * cos_rom[i];
            if (amp < amp_min) amp_min = amp;
            if (amp > amp_max) amp_max = amp;
        end
        amp_pp  = (amp_max - amp_min) / (AMP * AMP * 1.0);
        amp_dev = (AMP*AMP - amp_min > amp_max - AMP*AMP)
                ? (AMP*AMP - amp_min) : (amp_max - AMP*AMP);
        $display("sin^2+cos^2：min=%0d max=%0d（理论中心 %0d）峰峰=%.4f%% 单边最大偏差=%0d",
                 amp_min, amp_max, AMP*AMP, amp_pp * 100.0, amp_dev);
        `check(amp_dev <= 4096, "幅度平方单边偏差 <= 4096（量化理论上界 2895）");

        tb_done;
    end
endmodule
