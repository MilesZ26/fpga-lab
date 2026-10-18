`timescale 1ns/1ps
//=============================================================================
// tb_fir_coef — 校验 s03_fir/lut/*.mem 这份系数表本身
//-----------------------------------------------------------------------------
// 为什么系数表也要 testbench：
//   tb_fir.v 能证明"RTL 正确地用了表里的数"，但证明不了"表本身对不对"。
//   表是 Python 离线设计 + 量化的（Vivado 综合不了浮点设计），一旦生成器改坏、
//   或者文件被手改过，卷积照样算得"很正确"，只是滤波器的频响错了。
//   所以把"表 = 生成器承诺的性质"也放进回归测试。
//
// 检查的性质：
//   1. 47 个系数没有 x（$readmemh 读不到文件时**不报错**，只会留 x）
//   2. 严格对称 c[k] == c[N-1-k]（线性相位；RTL 的预加结构依赖它）
//   3. 系数和 == 32768 == 2^(CW-1)（直流增益精确为 1.0）
//   4. 中心抽头是最大系数，且为正
//   5. 没有 -32768（量化的"满幅负值"，通常意味着归一化算错了）
//   6. coef5.mem 的 5 个值精确等于 [2048, 8192, 12288, 8192, 2048]
//
// 表路径：$readmemh 相对**仿真进程的工作目录**，所以 sim.sh 传 FIR_COEFDIR。
//=============================================================================
module tb_fir_coef;
    `include "tb_common.vh"

`ifndef FIR_COEFDIR
  `define FIR_COEFDIR "s03_fir/lut/"
`endif

    localparam integer N    = 47;
    localparam integer CW   = 16;
    localparam integer HALF = N / 2;

    reg signed [CW-1:0] coef  [0:N-1];
    reg signed [CW-1:0] coef5 [0:4];

    integer i;
    integer sum;
    integer sym_err;
    integer xerr;
    integer peak_err;

    initial begin
        $readmemh({`FIR_COEFDIR, "coef.mem"}, coef);
        $readmemh({`FIR_COEFDIR, "coef5.mem"}, coef5);
        $display("FIR_COEFDIR = %s", `FIR_COEFDIR);

        // ── 1. 没有 x ───────────────────────────────────────────────
        xerr = 0;
        for (i = 0; i < N; i = i + 1)
            if ((^coef[i]) === 1'bx)
                xerr = xerr + 1;
        `check_eq("coef.mem 的 47 个系数都不是 x（文件读满了）", xerr, 0);

        xerr = 0;
        for (i = 0; i < 5; i = i + 1)
            if ((^coef5[i]) === 1'bx)
                xerr = xerr + 1;
        `check_eq("coef5.mem 的 5 个系数都不是 x", xerr, 0);

        // ── 2. 对称（线性相位）──────────────────────────────────────
        sym_err = 0;
        for (i = 0; i < N; i = i + 1)
            if (coef[i] !== coef[N-1-i])
                sym_err = sym_err + 1;
        `check_eq("coef.mem 严格对称 c[k] == c[N-1-k]", sym_err, 0);

        sym_err = 0;
        for (i = 0; i < 5; i = i + 1)
            if (coef5[i] !== coef5[4-i])
                sym_err = sym_err + 1;
        `check_eq("coef5.mem 也严格对称", sym_err, 0);

        // ── 3. 直流增益 = 1（系数和 = 2^15）────────────────────────
        sum = 0;
        for (i = 0; i < N; i = i + 1)
            sum = sum + coef[i];
        `check_eq("coef.mem 系数和 = 32768（直流增益精确为 1.0）", sum, 32768);

        sum = 0;
        for (i = 0; i < 5; i = i + 1)
            sum = sum + coef5[i];
        `check_eq("coef5.mem 系数和 = 32768", sum, 32768);

        // ── 4. 中心抽头是最大系数且为正 ─────────────────────────────
        peak_err = 0;
        for (i = 0; i < N; i = i + 1)
            if (coef[HALF] < coef[i])
                peak_err = peak_err + 1;
        `check_eq("中心抽头是最大系数（低通的主瓣）", peak_err, 0);
        `check(coef[HALF] > 0, "中心抽头为正");
        `check_eq("默认设计的中心抽头 = 9810", coef[HALF], 9810);

        // ── 5. 不出现 -32768 ───────────────────────────────────────
        peak_err = 0;
        for (i = 0; i < N; i = i + 1)
            if (coef[i] === -32768)
                peak_err = peak_err + 1;
        `check_eq("coef.mem 没有 -32768（对称量化不会产生满幅负值）", peak_err, 0);

        // ── 6. coef5 的精确值（tb_fir.v 的手算用例依赖它）──────────
        `check_eq("coef5[0] = 2048",  coef5[0], 2048);
        `check_eq("coef5[1] = 8192",  coef5[1], 8192);
        `check_eq("coef5[2] = 12288", coef5[2], 12288);
        `check_eq("coef5[3] = 8192",  coef5[3], 8192);
        `check_eq("coef5[4] = 2048",  coef5[4], 2048);

        tb_done;
    end

endmodule
