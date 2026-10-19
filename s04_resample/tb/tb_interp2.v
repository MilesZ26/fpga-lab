`timescale 1ns/1ps
//=============================================================================
// tb_interp2 — 2× 半带插值的验收
//-----------------------------------------------------------------------------
// 这个 testbench 要回答五个问题：
//
//   ① 算术对不对？
//      —— Python 参考模型（scripts/gen_resample_vec.py）生成的**逐位精确**向量回放。
//         4 个场景 × 512 个样本，(x, y_e, y_o) 三元一组逐拍比对。
//
//   ② 多相的"相位"对不对？
//      —— 冲激响应：
//           · 偶相 y_e 就是 15 个输入样本的群延迟（幅度原样 2047；
//             从驱动下降沿算，引脚上是第 19 个下降沿）
//           · 奇相 y_o 是 30 个点：round(2047*o[k]/2^14)，k = 0..29
//         并检查 y_o[k] == y_o[29-k]（线性相位）。
//         这一条专门抓"偶相少补一级寄存器"这类错 —— 数值全对但两相错开一拍。
//
//   ③ 直流增益对不对？
//      —— 常量输入时两相都必须逐位等于输入（±1000 / ±满幅）。
//         这是"半带偶相 0.5 + 奇相和 0.5 = 1"的直接证据。
//
//   ④ 舍入 / 饱和 / 参数对不对？
//      —— 5 抽头 hb5.mem（就是线性内插 (x[n]+x[n-1])/2）：
//           · x=1 → 和 = 8192 = 半个 LSB，ROUND=1 得 1、ROUND=0 得 0
//           · x=-1 → ROUND=1 得 0、ROUND=0 得 -1（算术右移向 -inf）
//         OW=8 实例验饱和（不回绕），IW=8 实例验输入位宽参数。
//
//   ⑤ 延迟是不是 4 拍？
//      —— 冲激后第 3 拍输出仍为 0，第 4 拍才出现 y_o[0]。
//
// 时序约定（和 s03 的 tb_fir.v 完全一致）：
//   TB 在**下降沿**驱动 x_in，在同一个下降沿读输出。
//   第 k 个下降沿驱动的输入，对应**第 k+4 个下降沿**的 y_e / y_o。
//   y_e 和 y_o 是**同一个输出时刻**的两相，所以都用 k+4 对齐，不能差一拍。
//=============================================================================
module tb_interp2;
    `include "tb_common.vh"

`ifndef VECDIR
  `define VECDIR "s04_resample/vec/"
`endif
`ifndef HB_COEFDIR
  `define HB_COEFDIR "s04_resample/lut/"
`endif

    // ── 主配置（和 scripts/gen_resample_vec.py 的默认值必须一致）────────
    localparam integer IW    = 12;
    localparam integer CW    = 16;
    localparam integer N     = 61;
    localparam integer OW    = 13;
    localparam integer SHIFT = 14;         // = CW-2：插值少移一位（×2）
    localparam integer LAT   = 4;
    localparam integer K     = (N-1)/2;    // 30 个奇数抽头
    localparam integer HALF  = K/2;        // 15：偶相延迟 / 奇相对称中心

    // ── 向量文件：10 个头字 + 4 个场景 × 512 样本 × 3 个字 ──────────────
    localparam integer NSCEN = 4;
    localparam integer NSAMP = 512;
    localparam integer VEC_HEAD = 10;
    localparam integer VEC_WORDS = VEC_HEAD + 3 * NSCEN * NSAMP;

    // ── 时钟 / 复位 / 输入 ──────────────────────────────────────────
    reg clk = 0;
    reg rst_n = 0;
    reg signed [IW-1:0] x_in = 0;

    always #5 clk = ~clk;

    // ── DUT 们 ─────────────────────────────────────────────────────
    wire signed [OW-1:0] y_e, y_o;          // 主配置 ROUND=1
    wire signed [OW-1:0] y_e_t, y_o_t;      // 主配置 ROUND=0
    wire signed [12:0] y_e5, y_o5;          // 5 抽头（线性内插）
    wire signed [12:0] y_e5_t, y_o5_t;      // 5 抽头 ROUND=0
    wire signed [7:0]  y_e_sat, y_o_sat;    // OW=8 → 故意饱和
    wire signed [8:0]  y_e_iw8, y_o_iw8;    // IW=8

    interp2 #(
        .IW(IW), .CW(CW), .N(N), .OW(OW), .SHIFT(SHIFT), .ROUND(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_e(y_e), .y_o(y_o)
    );

    interp2 #(
        .IW(IW), .CW(CW), .N(N), .OW(OW), .SHIFT(SHIFT), .ROUND(0)
    ) dut_t (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_e(y_e_t), .y_o(y_o_t)
    );

    // hb5.mem = [8192, 8192]：N=5 的半带，奇相就是 (x[n]+x[n-1])/2
    interp2 #(
        .IW(12), .CW(CW), .N(5), .OW(13), .SHIFT(SHIFT), .ROUND(1),
        .COEF_FILE("hb5.mem")
    ) dut5 (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_e(y_e5), .y_o(y_o5)
    );

    interp2 #(
        .IW(12), .CW(CW), .N(5), .OW(13), .SHIFT(SHIFT), .ROUND(0),
        .COEF_FILE("hb5.mem")
    ) dut5_t (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_e(y_e5_t), .y_o(y_o5_t)
    );

    interp2 #(
        .IW(12), .CW(CW), .N(5), .OW(8), .SHIFT(SHIFT), .ROUND(1),
        .COEF_FILE("hb5.mem")
    ) dut5_sat (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_e(y_e_sat), .y_o(y_o_sat)
    );

    interp2 #(
        .IW(8), .CW(CW), .N(5), .OW(9), .SHIFT(SHIFT), .ROUND(1),
        .COEF_FILE("hb5.mem")
    ) dut5_iw8 (
        .clk(clk), .rst_n(rst_n), .x_in(x_in[7:0]), .y_e(y_e_iw8), .y_o(y_o_iw8)
    );

    // ── 存储：参考向量 + 系数（TB 自己再读一遍，用来算冲激期望值）────
    reg [31:0] vec [0:VEC_WORDS-1];
    reg signed [CW-1:0] coef [0:K-1];

    // ── 变量 ───────────────────────────────────────────────────────
    integer s, t, k, z;
    integer err_e, err_o, sym_err, dc_err, tie_err;
    integer rnd_diff;
    integer first_nz;
    integer pre_out;
    reg signed [31:0] sval;
    reg signed [OW-1:0] imp_o [0:K-1];

    // ── 系数校验和（和 gen_resample_vec.py 同算法）────────────────────
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

    // ── 向量回放 ───────────────────────────────────────────────────
    task replay_case;
        input integer scen;
        integer bt, tt, ee_e, ee_o;
        reg signed [31:0] ev_e, ev_o;
        begin
            do_reset;
            bt = VEC_HEAD + scen * 3 * NSAMP;
            ee_e = 0;
            ee_o = 0;
            for (tt = 0; tt < NSAMP + LAT; tt = tt + 1) begin
                @(negedge clk);
                x_in = (tt < NSAMP) ? vec[bt + 3*tt][IW-1:0] : {IW{1'b0}};
                if (tt >= LAT) begin
                    ev_e = $signed(vec[bt + 3*(tt-LAT) + 1]);
                    ev_o = $signed(vec[bt + 3*(tt-LAT) + 2]);
                    if (y_e !== ev_e[OW-1:0]) begin
                        if (ee_e < 3)
                            $display("    [mismatch] 场景 %0d 的 n=%0d y_e：got=%0d exp=%0d",
                                     scen, tt-LAT, y_e, ev_e);
                        ee_e = ee_e + 1;
                    end
                    if (y_o !== ev_o[OW-1:0]) begin
                        if (ee_o < 3)
                            $display("    [mismatch] 场景 %0d 的 n=%0d y_o：got=%0d exp=%0d",
                                     scen, tt-LAT, y_o, ev_o);
                        ee_o = ee_o + 1;
                    end
                    if (scen == 3 && y_o !== y_o_t)
                        rnd_diff = rnd_diff + 1;
                end
            end
            `check_eq("向量回放：偶相 512 个样本逐位一致", ee_e, 0);
            `check_eq("向量回放：奇相 512 个样本逐位一致", ee_o, 0);
        end
    endtask

    // ── 主流程 ─────────────────────────────────────────────────────
    initial begin
        $readmemh({`VECDIR, "interp_vec.txt"}, vec);
        $readmemh({`HB_COEFDIR, "hb_odd.mem"}, coef);

        // ── 0. 向量文件 / 系数表自检（$readmemh 的失败方式是静默的）──
        `check(vec[0] === 32'hF04C0DE1, "向量文件哨兵正确（文件真的读进来了）");
        `check_eq("向量文件场景数 = 4", vec[1], NSCEN);
        `check_eq("每场景样本数 = 512", vec[2], NSAMP);
        `check_eq("数据行数 = 2048", vec[3], NSCEN * NSAMP);
        `check_eq("向量文件 IW = RTL 的 IW", vec[4], IW);
        `check_eq("向量文件 OW = RTL 的 OW", vec[5], OW);
        `check_eq("向量文件 SHIFT = 14（插值 = CW-2）", vec[6], SHIFT);
        `check_eq("向量文件 ROUND = 1", vec[7], 1);
        `check_eq("向量文件与 hb_odd.mem 的系数校验和一致", vec[8], coef_sum(0));
        `check_eq("向量文件 LAT = 4", vec[9], LAT);

        z = 0;
        for (k = 0; k < K; k = k + 1)
            if ((^coef[k]) === 1'bx)
                z = z + 1;
        `check_eq("系数表 30 个值全部读入（没有 x）", z, 0);

        // ── 1. 复位行为 ─────────────────────────────────────────────
        rst_n = 1'b0;
        x_in  = 12'sd2047;
        repeat (4) @(posedge clk);
        `check_eq("复位期间输入拉满，偶相输出仍为 0", y_e, 0);
        `check_eq("复位期间输入拉满，奇相输出仍为 0", y_o, 0);

        do_reset;
        for (t = 0; t < LAT + N; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd1000;
        end
        `check(y_o !== 0, "运行中奇相输出非零（下面才能测异步复位）");
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立即把奇相清零（不等时钟沿）", y_o, 0);
        rst_n = 1'b1;
        @(negedge clk);

        // ── 2. 延迟 + 冲激响应 + 两相相位关系 ───────────────────────
        do_reset;
        first_nz = -1;
        pre_out  = 0;
        for (t = 0; t < K + LAT + 4; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? 12'sd2047 : 12'sd0;
            if (t == LAT - 1)
                pre_out = y_o;                 // 第 3 拍：应该还是 0
            if (t >= LAT && t - LAT < K) begin
                imp_o[t-LAT] = y_o;
                if (first_nz < 0 && y_o != 0)
                    first_nz = t;
            end
        end
        `check_eq("延迟 4 拍：第 3 拍奇相输出仍为 0", pre_out, 0);
        `check_eq("冲激响应第一个非零值出现在第 4 拍", first_nz, LAT);

        err_o = 0;
        for (k = 0; k < K; k = k + 1) begin
            sval = 2047 * coef[k];
            sval = sval + (1 << (SHIFT-1));
            sval = sval >>> SHIFT;
            if (imp_o[k] !== sval[OW-1:0]) begin
                if (err_o < 3)
                    $display("    [mismatch] o[%0d]：got=%0d exp=%0d", k, imp_o[k], sval);
                err_o = err_o + 1;
            end
        end
        `check_eq("奇相冲激响应的 30 个抽头逐位相等", err_o, 0);

        sym_err = 0;
        for (k = 0; k < K/2; k = k + 1)
            if (imp_o[k] !== imp_o[K-1-k])
                sym_err = sym_err + 1;
        `check_eq("线性相位：o[k] == o[K-1-k] 对 30 个点全成立", sym_err, 0);
        `check_eq("奇相峰值 = 1298（2047*10387/2^14 四舍五入）", imp_o[HALF-1], 1298);

        // 偶相：冲激延迟 15 拍后原样出现
        do_reset;
        err_e = 0;
        for (t = 0; t < HALF + LAT + 2; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? 12'sd2047 : 12'sd0;
            if (t >= LAT && (t - LAT) != HALF && y_e !== 0)
                err_e = err_e + 1;
        end
        `check_eq("偶相冲激响应除输出下标 15 外全为 0", err_e, 0);

        do_reset;
        for (t = 0; t < HALF + LAT + 1; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? 12'sd2047 : 12'sd0;
        end
        `check_eq("偶相在输出下标 15 原样输出 2047（15 个输入样本群延迟，无乘法器）", y_e, 2047);

        // ── 3. 直流增益（两相都必须逐位等于输入）────────────────────
        dc_err = 0;
        do_reset;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd1000;
            if (t >= LAT + N && (y_e !== 13'sd1000 || y_o !== 13'sd1000))
                dc_err = dc_err + 1;
        end
        `check_eq("直流 +1000：两相稳态都 = +1000", dc_err, 0);

        dc_err = 0;
        do_reset;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = -12'sd1000;
            if (t >= LAT + N && (y_e !== -13'sd1000 || y_o !== -13'sd1000))
                dc_err = dc_err + 1;
        end
        `check_eq("直流 -1000：两相稳态都 = -1000", dc_err, 0);

        dc_err = 0;
        do_reset;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd2047;
            if (t >= LAT + N && (y_e !== 13'sd2047 || y_o !== 13'sd2047))
                dc_err = dc_err + 1;
        end
        `check_eq("满幅 +2047：两相稳态都 = +2047", dc_err, 0);

        dc_err = 0;
        do_reset;
        for (t = 0; t < 2*N + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = -12'sd2048;
            if (t >= LAT + N && (y_e !== -13'sd2048 || y_o !== -13'sd2048))
                dc_err = dc_err + 1;
        end
        `check_eq("满幅 -2048：两相稳态都 = -2048", dc_err, 0);

        // ── 4. 参考向量回放（4 个场景 × 512 样本）──────────────────
        rnd_diff = 0;
        for (s = 0; s < NSCEN; s = s + 1)
            replay_case(s);
        `check(rnd_diff > 50,
               "ROUND=1 和 ROUND=0 在奇相上真的不同（随机场景 >50 拍）");

        // ── 5. 舍入 tie（5 抽头 = 线性内插）────────────────────────
        // y_o = (8192*(x[n]+x[n-1])) >> 14。x=1、x[n-1]=0 → 8192 = 半个 LSB。
        do_reset;
        for (t = 0; t < LAT + 3; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? 12'sd1 : 12'sd0;
            if (t == LAT) begin
                `check_eq("舍入 tie 正：ROUND=1 得 1", y_o5, 1);
                `check_eq("舍入 tie 正：ROUND=0 得 0", y_o5_t, 0);
            end
        end

        // x=-1：-8192 是负半 LSB。ROUND=1 → 0；ROUND=0 → -1（向 -inf 取整）。
        do_reset;
        for (t = 0; t < LAT + 3; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? -12'sd1 : 12'sd0;
            if (t == LAT) begin
                `check_eq("舍入 tie 负：ROUND=1 得 0", y_o5, 0);
                `check_eq("舍入 tie 负：ROUND=0 得 -1", y_o5_t, -1);
            end
        end

        // ── 6. 饱和（OW=8，故意让它装不下）────────────────────────
        do_reset;
        for (t = 0; t < LAT + 40; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd2047;
            if (t == LAT + 30) begin
                `check_eq("饱和不回绕：+2047 在 OW=8 上钳到 +127（偶相）", y_e_sat, 127);
                `check_eq("饱和不回绕：+2047 在 OW=8 上钳到 +127（奇相）", y_o_sat, 127);
            end
        end

        do_reset;
        for (t = 0; t < LAT + 40; t = t + 1) begin
            @(negedge clk);
            x_in = -12'sd2048;
            if (t == LAT + 30) begin
                `check_eq("饱和不回绕：-2048 在 OW=8 上钳到 -128（偶相）", y_e_sat, -128);
                `check_eq("饱和不回绕：-2048 在 OW=8 上钳到 -128（奇相）", y_o_sat, -128);
            end
        end

        // ── 7. 参数化：IW=8 ────────────────────────────────────────
        do_reset;
        for (t = 0; t < LAT + 20; t = t + 1) begin
            @(negedge clk);
            x_in = 8'sd127;
            if (t == LAT + 10) begin
                `check_eq("IW=8 实例：偶相稳态 = +127", y_e_iw8, 127);
                `check_eq("IW=8 实例：奇相稳态 = +127", y_o_iw8, 127);
            end
        end

        tb_done;
    end

endmodule
