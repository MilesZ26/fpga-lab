`timescale 1ns/1ps
//=============================================================================
// tb_fir — FIR 滤波器的算术级验收
//-----------------------------------------------------------------------------
// 这个 testbench 要回答四个问题：
//
//   ① 算术对不对？
//      —— 用 Python 参考模型（scripts/gen_fir_vec.py）生成的**逐位精确**向量回放。
//         参考模型用任意精度整数，和 Verilog 的位宽规则完全无关，所以它和 RTL
//         不可能"错得一样"（s02 混频器就是靠这一点之外的手算断言才抓到 bug 的）。
//
//   ② 结构对不对？
//      —— 冲激响应：输入一个幅度 2047 的单点冲激，输出应该依次是
//         round(2047 * c[k] / 2^15)，k = 0..N-1。这直接验证了
//         延迟线、对称预加、中心抽头下标、系数顺序。
//         同时检查**线性相位**：h[k] == h[N-1-k] 必须逐位相等。
//
//   ③ 位宽 / 舍入 / 饱和对不对？
//      —— 5 抽头 coef5.mem 的手算边界用例：
//         · x=2 打在系数 8192 上 → 乘积 16384 = 半个 LSB，正好是舍入 tie
//         · OW=8 的实例上，±满幅输入必须钳到 +127/-128（不是回绕）
//         · IW=8 的实例验证输入位宽参数
//
//   ④ 延迟是不是 4 拍？
//      —— 冲激响应第一个非零值必须出现在第 4 拍，前 3 拍必须为 0。
//
// 时序约定（很重要，不然会差一拍）：
//   TB 在**下降沿**驱动 x_in，在同一个下降沿读 y_out。
//   第 k 个下降沿驱动的输入，经过 4 个上升沿之后，在**第 k+4 个下降沿**
//   读到对应的输出。所以比较时用 y_out vs y_exp[k-4]。
//   这个约定和 RTL 的 4 级流水（x_r → p_reg → gsum → y_out）一一对应。
//=============================================================================
module tb_fir;
    `include "tb_common.vh"

`ifndef VECDIR
  `define VECDIR "s03_fir/vec/"
`endif
`ifndef FIR_COEFDIR
  `define FIR_COEFDIR "s03_fir/lut/"
`endif

    // ── 主配置（和 scripts/gen_fir_vec.py 的默认值必须一致）────────────
    localparam integer IW    = 12;
    localparam integer CW    = 16;
    localparam integer N     = 47;
    localparam integer OW    = 13;
    localparam integer SHIFT = 15;
    localparam integer LAT   = 4;
    localparam integer HALF  = N / 2;

    // ── 向量文件：9 个头字 + 4 个场景 × 512 样本 × 2 个字 ──────────────
    // 头字：哨兵 / 场景数 / 样本数 / 数据行数 / IW / OW / SHIFT / ROUND / 系数校验和
    localparam integer NSCEN = 4;
    localparam integer NSAMP = 512;
    localparam integer VEC_HEAD = 9;
    localparam integer VEC_WORDS = VEC_HEAD + 2 * NSCEN * NSAMP;

    // ── 时钟 / 复位 / 输入 ──────────────────────────────────────────
    reg clk = 0;
    reg rst_n = 0;
    reg signed [IW-1:0] x_in = 0;

    always #5 clk = ~clk;

    // ── DUT 们 ─────────────────────────────────────────────────────
    wire signed [OW-1:0] y_out;       // 主配置：ROUND=1
    wire signed [OW-1:0] y_trunc;     // 主配置：ROUND=0（和上面吃同一串输入）

    fir #(
        .IW(IW), .CW(CW), .N(N), .OW(OW), .SHIFT(SHIFT), .ROUND(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_out(y_out)
    );

    fir #(
        .IW(IW), .CW(CW), .N(N), .OW(OW), .SHIFT(SHIFT), .ROUND(0)
    ) dut_trunc (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_out(y_trunc)
    );

    // 5 抽头：coef5.mem = [2048, 8192, 12288, 8192, 2048]，和 = 32768
    wire signed [12:0] y5_rnd;        // OW=13, ROUND=1
    wire signed [12:0] y5_trunc;      // OW=13, ROUND=0
    wire signed [7:0]  y5_sat;        // OW=8  → 故意让它饱和
    wire signed [8:0]  y5_iw8;        // IW=8, OW=9 → 验输入位宽参数

    fir #(
        .IW(12), .CW(16), .N(5), .OW(13), .SHIFT(15), .ROUND(1),
        .COEF_FILE("coef5.mem")
    ) dut5_rnd (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_out(y5_rnd)
    );

    fir #(
        .IW(12), .CW(16), .N(5), .OW(13), .SHIFT(15), .ROUND(0),
        .COEF_FILE("coef5.mem")
    ) dut5_trunc (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_out(y5_trunc)
    );

    fir #(
        .IW(12), .CW(16), .N(5), .OW(8), .SHIFT(15), .ROUND(1),
        .COEF_FILE("coef5.mem")
    ) dut5_sat (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_out(y5_sat)
    );

    fir #(
        .IW(8), .CW(16), .N(5), .OW(9), .SHIFT(15), .ROUND(1),
        .COEF_FILE("coef5.mem")
    ) dut5_iw8 (
        .clk(clk), .rst_n(rst_n), .x_in(x_in[7:0]), .y_out(y5_iw8)
    );

    // ── 存储：参考向量 + 系数（TB 自己再读一遍系数，用来算冲激期望值）
    reg [31:0] vec [0:VEC_WORDS-1];
    reg signed [CW-1:0] coef [0:N-1];

    // ── 变量（Verilog-2001 要求模块级 / task 内先声明后使用）──────────
    integer s, t, k, b;
    integer err;
    integer sym_err;
    integer dc_err;
    integer first_nz;
    integer rnd_diff;
    integer pre_out;
    reg signed [31:0] expv;
    reg signed [31:0] sval;
    reg signed [OW-1:0] imp_resp [0:N-1];

    // ── 系数校验和（和 scripts/gen_fir_vec.py 的 coef_checksum 同算法）──
    // 用来确认"向量文件就是拿这份 coef.mem 生成的"，避免改了系数却忘了重生成向量。
    function [31:0] coef_sum;
        input integer dummy;
        integer ii;
        reg [31:0] h;
        begin
            h = 32'h12345678;
            for (ii = 0; ii < N; ii = ii + 1)
                h = h * 32'd33 + {16'b0, coef[ii][15:0]};
            coef_sum = h;
        end
    endfunction

    // ── 复位任务 ───────────────────────────────────────────────────
    task do_reset;
        begin
            rst_n = 1'b0;
            x_in  = {IW{1'b0}};
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    // ── 向量回放：场景 scen 的 512 个样本逐位比对 ───────────────────
    task replay_case;
        input integer scen;
        integer bt, tt, ee;
        reg signed [31:0] ev;
        begin
            do_reset;
            bt = VEC_HEAD + scen * 2 * NSAMP;
            ee = 0;
            for (tt = 0; tt < NSAMP + LAT; tt = tt + 1) begin
                @(negedge clk);
                x_in = (tt < NSAMP) ? vec[bt + 2*tt][IW-1:0] : {IW{1'b0}};
                if (tt >= LAT) begin
                    ev = $signed(vec[bt + 2*(tt-LAT) + 1]);
                    if (y_out !== ev[OW-1:0]) begin
                        if (ee < 3)
                            $display("    [mismatch] 场景 %0d 的 n=%0d：got=%0d exp=%0d",
                                     scen, tt-LAT, y_out, ev);
                        ee = ee + 1;
                    end
                    // 随机场景顺便统计 ROUND=1 和 ROUND=0 有多少拍不同
                    if (scen == 3 && y_out !== y_trunc)
                        rnd_diff = rnd_diff + 1;
                end
            end
            `check_eq("向量回放：本场景 512 个样本逐位一致", ee, 0);
        end
    endtask

    // ── 主流程 ─────────────────────────────────────────────────────
    initial begin
        $readmemh({`VECDIR, "fir_vec.txt"}, vec);
        $readmemh({`FIR_COEFDIR, "coef.mem"}, coef);

        // ── 0. 向量文件自检（防止 $readmemh 静默失败 / 参数对不上）──
        `check(vec[0] === 32'hF12C0DE1, "向量文件哨兵正确（文件真的读进来了）");
        `check_eq("向量文件场景数 = 4", vec[1], NSCEN);
        `check_eq("每场景样本数 = 512", vec[2], NSAMP);
        `check_eq("数据行数 = 2048", vec[3], NSCEN * NSAMP);
        `check_eq("向量文件 IW = RTL 的 IW", vec[4], IW);
        `check_eq("向量文件 OW = RTL 的 OW", vec[5], OW);
        `check_eq("向量文件 SHIFT = RTL 的 SHIFT", vec[6], SHIFT);
        `check_eq("向量文件 ROUND = 1", vec[7], 1);
        `check_eq("向量文件与 coef.mem 的系数校验和一致", vec[8], coef_sum(0));

        // ── 1. 复位行为 ─────────────────────────────────────────────
        rst_n = 1'b0;
        x_in  = 12'sd2047;                     // 复位期间把输入拉满
        repeat (4) @(posedge clk);
        `check_eq("复位期间输入拉满，输出仍为 0", y_out, 0);
        `check_eq("复位期间 5 抽头实例输出也为 0", y5_rnd, 0);

        // 运行中途异步复位：不等时钟沿，立刻清零
        do_reset;
        for (t = 0; t < LAT + N; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd1000;
        end
        `check(y_out !== 0, "运行中输出非零（下面才能测异步复位）");
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立即把输出清零（不等时钟沿）", y_out, 0);
        rst_n = 1'b1;
        @(negedge clk);

        // ── 2. 延迟 + 冲激响应 + 线性相位 ───────────────────────────
        do_reset;
        first_nz = -1;
        pre_out  = 0;
        for (t = 0; t < N + LAT + 2; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? 12'sd2047 : 12'sd0;
            if (t == LAT - 1)
                pre_out = y_out;               // 第 3 拍：应该还是 0
            if (t >= LAT && t - LAT < N) begin
                imp_resp[t-LAT] = y_out;
                if (first_nz < 0 && y_out != 0)
                    first_nz = t;              // 第一个非零输出出现在哪一拍
            end
        end
        `check_eq("延迟 4 拍：第 3 拍输出仍为 0", pre_out, 0);
        `check_eq("冲激响应第一个非零值出现在第 4 拍", first_nz, LAT);

        err = 0;
        for (k = 0; k < N; k = k + 1) begin
            sval = 2047 * coef[k];             // 全精度乘积
            sval = sval + (1 << (SHIFT-1));    // 四舍五入
            sval = sval >>> SHIFT;             // 算术右移
            if (imp_resp[k] !== sval[OW-1:0]) begin
                if (err < 3)
                    $display("    [mismatch] h[%0d]：got=%0d exp=%0d",
                             k, imp_resp[k], sval);
                err = err + 1;
            end
        end
        `check_eq("冲激响应的 47 个抽头逐位相等", err, 0);

        sym_err = 0;
        for (k = 0; k < N; k = k + 1)
            if (imp_resp[k] !== imp_resp[N-1-k])
                sym_err = sym_err + 1;
        `check_eq("线性相位：h[k] == h[N-1-k] 对 47 个点全成立", sym_err, 0);
        `check_eq("中心抽头的冲激响应 = 613（2047*9810/2^15 四舍五入）",
                  imp_resp[HALF], 613);

        // ── 3. 直流增益（系数和 = 2^15 → 增益精确为 1）──────────────
        do_reset;
        dc_err = 0;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd1000;
            if (t >= LAT + N && y_out !== 13'sd1000)
                dc_err = dc_err + 1;
        end
        `check_eq("直流输入 +1000 的稳态输出 = +1000", dc_err, 0);

        do_reset;
        dc_err = 0;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = -12'sd1000;
            if (t >= LAT + N && y_out !== -13'sd1000)
                dc_err = dc_err + 1;
        end
        `check_eq("直流输入 -1000 的稳态输出 = -1000", dc_err, 0);

        do_reset;
        dc_err = 0;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd2047;                  // 满幅正
            if (t >= LAT + N && y_out !== 13'sd2047)
                dc_err = dc_err + 1;
        end
        `check_eq("满幅 +2047 的稳态输出 = +2047", dc_err, 0);

        do_reset;
        dc_err = 0;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = -12'sd2048;                 // 满幅负
            if (t >= LAT + N && y_out !== -13'sd2048)
                dc_err = dc_err + 1;
        end
        `check_eq("满幅 -2048 的稳态输出 = -2048", dc_err, 0);

        // ── 4. 参考向量回放（4 个场景 × 512 样本）──────────────────
        rnd_diff = 0;
        for (s = 0; s < NSCEN; s = s + 1)
            replay_case(s);
        `check(rnd_diff > 50,
               "ROUND 在 47 抽头主滤波器上真的生效（随机场景 >50 拍结果不同）");

        // ── 5. 舍入 tie（5 抽头手算）───────────────────────────────
        // x=2 打在系数 8192 上：2*8192 = 16384 = 恰好半个 LSB。
        // ROUND=1：(16384+16384)>>15 = 1；ROUND=0：16384>>15 = 0。
        do_reset;
        for (t = 0; t < LAT + 3; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? 12'sd2 : 12'sd0;
            if (t == LAT + 1) begin
                `check_eq("舍入 tie 正：ROUND=1 得 1", y5_rnd, 1);
                `check_eq("舍入 tie 正：ROUND=0 得 0", y5_trunc, 0);
            end
        end

        // x=-2：-16384 是负半 LSB。ROUND=1 后 (-16384+16384)=0 → 0；
        // ROUND=0 时 -16384>>15 = -1（算术右移向 -inf 取整）。
        do_reset;
        for (t = 0; t < LAT + 3; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? -12'sd2 : 12'sd0;
            if (t == LAT + 1) begin
                `check_eq("舍入 tie 负：ROUND=1 得 0", y5_rnd, 0);
                `check_eq("舍入 tie 负：ROUND=0 得 -1", y5_trunc, -1);
            end
        end

        // ── 6. 饱和（5 抽头 + OW=8）────────────────────────────────
        do_reset;
        for (t = 0; t < LAT + 8; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd2047;
            if (t == LAT + 5)
                `check_eq("OW=8 正溢出钳到 +127", y5_sat, 127);
        end

        do_reset;
        for (t = 0; t < LAT + 8; t = t + 1) begin
            @(negedge clk);
            x_in = -12'sd2048;
            if (t == LAT + 5)
                `check_eq("OW=8 负溢出钳到 -128", y5_sat, -128);
        end

        do_reset;
        for (t = 0; t < LAT + 8; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd100;                   // 远没到 OW=8 的上界
            if (t == LAT + 5)
                `check_eq("OW=8 小幅值不饱和：100 → 100", y5_sat, 100);
        end

        // ── 7. IW=8 参数（5 抽头，冲激 64）────────────────────────
        // 64*8192 = 524288；+16384 后 >>15 = 16
        do_reset;
        for (t = 0; t < LAT + 3; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? 12'sd64 : 12'sd0;
            if (t == LAT + 1)
                `check_eq("IW=8：冲激 64 经系数 8192 得 16", y5_iw8, 16);
        end

        tb_done;
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_fir);
    end
`endif

endmodule
