`timescale 1ns/1ps
//=============================================================================
// tb_decim2 — 2× 半带抽取的验收
//-----------------------------------------------------------------------------
// 和 tb_interp2 一一对应，但输入是"两相并行"的：
//   输入 x_e / x_o 是 2Fs 上的相邻采样（x_e[n] = u[2n]，x_o[n] = u[2n+1]），
//   输出 y 在 Fs 上。
//
// 要回答的问题：
//   ① 算术对不对？—— Python 参考向量（x_e, x_o, y）逐拍回放。
//   ② 相位对不对？—— 两路冲激分别打：
//        · 只打 x_e：y[15] = 1024（= 0.5·2047 的四舍五入），**其余全 0**
//        · 只打 x_o：y[1..30] 是 30 个点，关于 k=15.5 对称
//      这一对是"半带把 61 抽头拆成 1 + 30"的最直接证据。
//      也顺带证明 x_o 的窗口确实整体挪了一拍（少挪会整体错半个采样）。
//   ③ 增益对不对？—— 直流 x_e = x_o = 1000 → y = 1000（逐位）。
//   ④ 抗混叠对不对？—— 喂 0.40（相对 2Fs）的正弦：落在半带阻带里，
//      抽取后应该几乎消失（实测幅度 ≤ 几个 LSB）；对照组 0.10 的正弦必须原样通过。
//      **这是"抽取之前必须低通"的板级前证据**（上板时 ILA 也看这个）。
//   ⑤ 舍入 / 饱和 / 参数？—— hb5 的 tie、OW=8 的饱和、IW=8 的位宽。
//
// 时序约定（和 s03/s04 其它 TB 一致）：
//   下降沿驱动 x_e / x_o，同一个下降沿读 y。
//   第 k 个下降沿的一对输入，对应**第 k+4 个下降沿**的 y。
//=============================================================================
module tb_decim2;
    `include "tb_common.vh"

`ifndef VECDIR
  `define VECDIR "s04_resample/vec/"
`endif
`ifndef HB_COEFDIR
  `define HB_COEFDIR "s04_resample/lut/"
`endif

    localparam integer IW    = 12;
    localparam integer CW    = 16;
    localparam integer N     = 61;
    localparam integer OW    = 13;
    localparam integer SHIFT = 15;          // = CW-1：抽取不移位补偿（见 TASK.md）
    localparam integer LAT   = 4;
    localparam integer K     = (N-1)/2;     // 30
    localparam integer HALF  = K/2;         // 15

    localparam integer NSCEN = 4;
    localparam integer NSAMP = 512;
    localparam integer VEC_HEAD = 10;
    localparam integer VEC_WORDS = VEC_HEAD + 3 * NSCEN * NSAMP;

    reg clk = 0;
    reg rst_n = 0;
    reg signed [IW-1:0] x_e = 0;
    reg signed [IW-1:0] x_o = 0;

    always #5 clk = ~clk;

    // ── DUT 们 ─────────────────────────────────────────────────────
    wire signed [OW-1:0] y_out, y_trunc;
    wire signed [12:0] y5, y5_t;
    wire signed [7:0]  y_sat;
    wire signed [8:0]  y_iw8;

    decim2 #(
        .IW(IW), .CW(CW), .N(N), .OW(OW), .SHIFT(SHIFT), .ROUND(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .x_e(x_e), .x_o(x_o), .y_out(y_out)
    );

    decim2 #(
        .IW(IW), .CW(CW), .N(N), .OW(OW), .SHIFT(SHIFT), .ROUND(0)
    ) dut_t (
        .clk(clk), .rst_n(rst_n), .x_e(x_e), .x_o(x_o), .y_out(y_trunc)
    );

    decim2 #(
        .IW(12), .CW(CW), .N(5), .OW(13), .SHIFT(SHIFT), .ROUND(1),
        .COEF_FILE("hb5.mem")
    ) dut5 (
        .clk(clk), .rst_n(rst_n), .x_e(x_e), .x_o(x_o), .y_out(y5)
    );

    decim2 #(
        .IW(12), .CW(CW), .N(5), .OW(13), .SHIFT(SHIFT), .ROUND(0),
        .COEF_FILE("hb5.mem")
    ) dut5_t (
        .clk(clk), .rst_n(rst_n), .x_e(x_e), .x_o(x_o), .y_out(y5_t)
    );

    decim2 #(
        .IW(12), .CW(CW), .N(5), .OW(8), .SHIFT(SHIFT), .ROUND(1),
        .COEF_FILE("hb5.mem")
    ) dut5_sat (
        .clk(clk), .rst_n(rst_n), .x_e(x_e), .x_o(x_o), .y_out(y_sat)
    );

    decim2 #(
        .IW(8), .CW(CW), .N(5), .OW(9), .SHIFT(SHIFT), .ROUND(1),
        .COEF_FILE("hb5.mem")
    ) dut5_iw8 (
        .clk(clk), .rst_n(rst_n), .x_e(x_e[7:0]), .x_o(x_o[7:0]), .y_out(y_iw8)
    );

    reg [31:0] vec [0:VEC_WORDS-1];
    reg signed [CW-1:0] coef [0:K-1];

    integer s, t, k, z;
    integer err, sym_err, dc_err, rnd_diff;
    integer peak;
    reg signed [31:0] sval;
    reg signed [OW-1:0] imp_o [0:K];      // 下标 1..K 有值
    real tone;

    function [31:0] coef_sum;
        input integer dummy;
        integer ii;
        reg [31:0] h;
        begin
            h = 32'h12345678;
            for (ii = 0; ii < K; ii = ii + 1)
                h = h * 32'd33 + {16'b0, coef[ii][15:0]};
            coef_sum = h;
        end
    endfunction

    task do_reset;
        begin
            rst_n = 1'b0;
            x_e = {IW{1'b0}};
            x_o = {IW{1'b0}};
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task replay_case;
        input integer scen;
        integer bt, tt, ee;
        reg signed [31:0] ev;
        begin
            do_reset;
            bt = VEC_HEAD + scen * 3 * NSAMP;
            ee = 0;
            for (tt = 0; tt < NSAMP + LAT; tt = tt + 1) begin
                @(negedge clk);
                x_e = (tt < NSAMP) ? vec[bt + 3*tt][IW-1:0] : {IW{1'b0}};
                x_o = (tt < NSAMP) ? vec[bt + 3*tt + 1][IW-1:0] : {IW{1'b0}};
                if (tt >= LAT) begin
                    ev = $signed(vec[bt + 3*(tt-LAT) + 2]);
                    if (y_out !== ev[OW-1:0]) begin
                        if (ee < 3)
                            $display("    [mismatch] 场景 %0d 的 n=%0d：got=%0d exp=%0d",
                                     scen, tt-LAT, y_out, ev);
                        ee = ee + 1;
                    end
                    if (scen == 3 && y_out !== y_trunc)
                        rnd_diff = rnd_diff + 1;
                end
            end
            `check_eq("向量回放：本场景 512 个样本逐位一致", ee, 0);
        end
    endtask

    initial begin
        $readmemh({`VECDIR, "decim_vec.txt"}, vec);
        $readmemh({`HB_COEFDIR, "hb_odd.mem"}, coef);

        // ── 0. 自检 ─────────────────────────────────────────────────
        `check(vec[0] === 32'hF04C0DE1, "向量文件哨兵正确（文件真的读进来了）");
        `check_eq("向量文件场景数 = 4", vec[1], NSCEN);
        `check_eq("每场景样本数 = 512", vec[2], NSAMP);
        `check_eq("数据行数 = 2048", vec[3], NSCEN * NSAMP);
        `check_eq("向量文件 IW = RTL 的 IW", vec[4], IW);
        `check_eq("向量文件 OW = RTL 的 OW", vec[5], OW);
        `check_eq("向量文件 SHIFT = 15（抽取 = CW-1）", vec[6], SHIFT);
        `check_eq("向量文件 ROUND = 1", vec[7], 1);
        `check_eq("向量文件与 hb_odd.mem 的系数校验和一致", vec[8], coef_sum(0));
        `check_eq("向量文件 LAT = 4", vec[9], LAT);

        z = 0;
        for (k = 0; k < K; k = k + 1)
            if ((^coef[k]) === 1'bx)
                z = z + 1;
        `check_eq("系数表 30 个值全部读入（没有 x）", z, 0);

        // ── 1. 复位 ─────────────────────────────────────────────────
        rst_n = 1'b0;
        x_e = 12'sd2047;
        x_o = -12'sd2048;
        repeat (4) @(posedge clk);
        `check_eq("复位期间输入拉满，输出仍为 0", y_out, 0);

        do_reset;
        for (t = 0; t < LAT + N; t = t + 1) begin
            @(negedge clk);
            x_e = 12'sd1000;
            x_o = 12'sd1000;
        end
        `check(y_out !== 0, "运行中输出非零（下面才能测异步复位）");
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立即把输出清零（不等时钟沿）", y_out, 0);
        rst_n = 1'b1;
        @(negedge clk);

        // ── 2. 只打 x_e：半带偶相 = 一个 0.5 的中心抽头 ─────────────
        do_reset;
        for (t = 0; t < K + LAT + 2; t = t + 1) begin
            @(negedge clk);
            x_e = (t == 0) ? 12'sd2047 : 12'sd0;
            x_o = 12'sd0;
            if (t == LAT + HALF) begin
                `check_eq("x_e 冲激：y[15] = 1024（0.5·2047 的四舍五入）", y_out, 1024);
                `check_eq("x_e 冲激：ROUND=1 得 1024、ROUND=0 得 1023（tie）",
                          y_trunc, 1023);
            end
        end

        do_reset;
        err = 0;
        for (t = 0; t < K + LAT + 2; t = t + 1) begin
            @(negedge clk);
            x_e = (t == 0) ? 12'sd2047 : 12'sd0;
            x_o = 12'sd0;
            if (t >= LAT && (t - LAT) != HALF && y_out !== 0)
                err = err + 1;
        end
        `check_eq("x_e 冲激：除第 15 拍外输出全为 0", err, 0);

        // ── 3. 只打 x_o：30 个奇数抽头逐点对账 ─────────────────────
        do_reset;
        for (t = 0; t < K + LAT + 2; t = t + 1) begin
            @(negedge clk);
            x_e = 12'sd0;
            x_o = (t == 0) ? 12'sd2047 : 12'sd0;
            if (t >= LAT + 1 && (t - LAT) <= K)
                imp_o[t-LAT] = y_out;
        end

        err = 0;
        for (k = 1; k <= K; k = k + 1) begin
            sval = 2047 * coef[k-1];
            sval = sval + (1 << (SHIFT-1));
            sval = sval >>> SHIFT;
            if (imp_o[k] !== sval[OW-1:0]) begin
                if (err < 3)
                    $display("    [mismatch] o[%0d]：got=%0d exp=%0d", k, imp_o[k], sval);
                err = err + 1;
            end
        end
        `check_eq("x_o 冲激响应的 30 个抽头逐位相等", err, 0);

        sym_err = 0;
        for (k = 1; k <= K/2; k = k + 1)
            if (imp_o[k] !== imp_o[K+1-k])
                sym_err = sym_err + 1;
        `check_eq("线性相位：o[k] == o[K+1-k] 对 30 个点全成立", sym_err, 0);
        `check_eq("奇相峰值 = 649（2047*10387/2^15 四舍五入）",
                  imp_o[HALF], 649);

        // ── 4. 直流增益 ─────────────────────────────────────────────
        dc_err = 0;
        do_reset;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_e = 12'sd1000;
            x_o = 12'sd1000;
            if (t >= LAT + N && y_out !== 13'sd1000)
                dc_err = dc_err + 1;
        end
        `check_eq("直流 +1000：稳态输出 = +1000", dc_err, 0);

        dc_err = 0;
        do_reset;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_e = -12'sd1000;
            x_o = -12'sd1000;
            if (t >= LAT + N && y_out !== -13'sd1000)
                dc_err = dc_err + 1;
        end
        `check_eq("直流 -1000：稳态输出 = -1000", dc_err, 0);

        dc_err = 0;
        do_reset;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_e = 12'sd2047;
            x_o = 12'sd2047;
            if (t >= LAT + N && y_out !== 13'sd2047)
                dc_err = dc_err + 1;
        end
        `check_eq("满幅 +2047：稳态输出 = +2047", dc_err, 0);

        dc_err = 0;
        do_reset;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_e = -12'sd2048;
            x_o = -12'sd2048;
            if (t >= LAT + N && y_out !== -13'sd2048)
                dc_err = dc_err + 1;
        end
        `check_eq("满幅 -2048：稳态输出 = -2048", dc_err, 0);

        // ── 5. 抗混叠：0.40 的输入音必须被压下去 ────────────────────
        // u[m] = A·sin(2π·0.40·m)（m 在 2Fs 上）；x_e[n] = u[2n]，x_o[n] = u[2n+1]。
        do_reset;
        peak = 0;
        for (t = 0; t < 400; t = t + 1) begin
            @(negedge clk);
            tone = 2000.0 * $sin(2.0 * 3.141592653589793 * 0.40 * (2*t));
            x_e = $rtoi(tone);
            tone = 2000.0 * $sin(2.0 * 3.141592653589793 * 0.40 * (2*t+1));
            x_o = $rtoi(tone);
            if (t > 200 && y_out > peak)
                peak = y_out;
            if (t > 200 && -y_out > peak)
                peak = -y_out;
        end
        `check(peak <= 8,
               "抗混叠：0.40 的输入音（阻带）抽取后幅度 <= 8 LSB");

        // 对照组：0.10 的输入音在通带里，必须原样通过
        do_reset;
        peak = 0;
        for (t = 0; t < 400; t = t + 1) begin
            @(negedge clk);
            tone = 2000.0 * $sin(2.0 * 3.141592653589793 * 0.10 * (2*t));
            x_e = $rtoi(tone);
            tone = 2000.0 * $sin(2.0 * 3.141592653589793 * 0.10 * (2*t+1));
            x_o = $rtoi(tone);
            if (t > 200 && y_out > peak)
                peak = y_out;
            if (t > 200 && -y_out > peak)
                peak = -y_out;
        end
        `check(peak >= 1900 && peak <= 2100,
               "通带：0.10 的输入音抽取后幅度仍在 2000 附近（1900..2100）");

        // ── 6. 参考向量回放 ─────────────────────────────────────────
        rnd_diff = 0;
        for (s = 0; s < NSCEN; s = s + 1)
            replay_case(s);
        `check(rnd_diff > 50,
               "ROUND=1 和 ROUND=0 在抽取输出上真的不同（随机场景 >50 拍）");

        // ── 7. 舍入 tie（5 抽头）──────────────────────────────────
        // x_e[0]=1、x_o=0 → y[1] = (16384·1)>>15 = 0.5，正好是 tie。
        do_reset;
        for (t = 0; t < LAT + 4; t = t + 1) begin
            @(negedge clk);
            x_e = (t == 0) ? 12'sd1 : 12'sd0;
            x_o = 12'sd0;
            if (t == LAT + 1) begin
                `check_eq("抽取 tie 正：ROUND=1 得 1", y5, 1);
                `check_eq("抽取 tie 正：ROUND=0 得 0", y5_t, 0);
            end
        end

        // ── 8. 饱和（OW=8）─────────────────────────────────────────
        do_reset;
        for (t = 0; t < LAT + 40; t = t + 1) begin
            @(negedge clk);
            x_e = 12'sd2047;
            x_o = 12'sd2047;
            if (t == LAT + 30)
                `check_eq("饱和不回绕：+2047 在 OW=8 上钳到 +127", y_sat, 127);
        end

        do_reset;
        for (t = 0; t < LAT + 40; t = t + 1) begin
            @(negedge clk);
            x_e = -12'sd2048;
            x_o = -12'sd2048;
            if (t == LAT + 30)
                `check_eq("饱和不回绕：-2048 在 OW=8 上钳到 -128", y_sat, -128);
        end

        // ── 9. 参数化：IW=8 ────────────────────────────────────────
        do_reset;
        for (t = 0; t < LAT + 20; t = t + 1) begin
            @(negedge clk);
            x_e = 8'sd127;
            x_o = 8'sd127;
            if (t == LAT + 10)
                `check_eq("IW=8 实例：稳态输出 = +127", y_iw8, 127);
        end

        tb_done;
    end

endmodule
