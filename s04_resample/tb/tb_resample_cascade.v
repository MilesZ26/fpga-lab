`timescale 1ns/1ps
//=============================================================================
// tb_resample_cascade — interp2 → decim2 串起来跑
//-----------------------------------------------------------------------------
// 为什么要有这个 TB：
//   前面两个 TB 各自证明"模块内部算对了"，但多相结构真正的坑在**模块之间**：
//   插值吐出的两相 (y_e, y_o) 直接喂给抽取的两相输入 (x_e, x_o) 时，
//   相位、位宽、延迟任何一处错位，输出都不会是"延迟 30 拍的原信号"。
//
// 三条证据：
//   ① 向量回放：Python 参考模型把"插值 13 位输出 → 抽取 13 位输入"整条链算一遍，
//      512 个样本逐位比对（**不是**容差比对）。
//   ② 冲激响应：43 个非零点、关于第 30 点对称、峰值 1991、两端回零 —— 
//      这是"插值 + 抽取 = 半带自相关"的形状，也是整条链线性相位的证据。
//   ③ 性质断言：
//        · 直流：1000 进 → 1000 出（逐位，延迟 30 拍）
//        · 通带单音：输出 ≈ 输入（延迟 30 拍，误差 ≤ 4 LSB）
//      ⚠️ **只对通带成立**。随机白噪声在临界频率（0.25·2Fs = 奈奎斯特）上
//         有能量，而"插值再抽取"整体是一个**半带的平方**（低通），
//         白噪声本来就会被它滤掉一部分 —— 所以随机场景只能靠向量逐位比对，
//         不能拿"≈ 延迟"当判据。这一点写进 TASK.md，别当成 bug 查。
//
// 位宽衔接（s05 集成时会再遇到一次）：
//   interp2 输出 13 位 → decim2 的 IW 必须是 **13**（不是 12），
//   否则中间结果被截一位，误差会翻倍。最终输出 OW = 14。
//
// 时序约定：下降沿驱动 x_in，同一个下降沿读 y_out；
//   第 k 个下降沿的输入对应**第 k+8 个下降沿**的输出（4 + 4 级流水）。
//=============================================================================
module tb_resample_cascade;
    `include "tb_common.vh"

`ifndef VECDIR
  `define VECDIR "s04_resample/vec/"
`endif
`ifndef HB_COEFDIR
  `define HB_COEFDIR "s04_resample/lut/"
`endif

    localparam integer IW       = 12;
    localparam integer CW       = 16;
    localparam integer N        = 61;
    localparam integer OW_INT   = IW + 1;      // 13：插值输出
    localparam integer OW       = OW_INT + 1;  // 14：级联输出
    localparam integer SHIFT_I  = 14;          // 插值 CW-2
    localparam integer SHIFT_D  = 15;          // 抽取 CW-1
    localparam integer LAT      = 8;           // 4 + 4
    localparam integer K        = (N-1)/2;     // 30

    localparam integer NSCEN = 4;
    localparam integer NSAMP = 512;
    localparam integer VEC_HEAD = 10;
    localparam integer VEC_WORDS = VEC_HEAD + 2 * NSCEN * NSAMP;

    reg clk = 0;
    reg rst_n = 0;
    reg signed [IW-1:0] x_in = 0;

    always #5 clk = ~clk;

    wire signed [OW_INT-1:0] y_e, y_o;
    wire signed [OW-1:0] y_out;

    interp2 #(
        .IW(IW), .CW(CW), .N(N), .OW(OW_INT), .SHIFT(SHIFT_I), .ROUND(1)
    ) u_interp (
        .clk(clk), .rst_n(rst_n), .x_in(x_in), .y_e(y_e), .y_o(y_o)
    );

    decim2 #(
        .IW(OW_INT), .CW(CW), .N(N), .OW(OW), .SHIFT(SHIFT_D), .ROUND(1)
    ) u_decim (
        .clk(clk), .rst_n(rst_n), .x_e(y_e), .x_o(y_o), .y_out(y_out)
    );

    reg [31:0] vec [0:VEC_WORDS-1];
    reg signed [CW-1:0] coef [0:K-1];

    integer s, t, k, z, err;
    integer dc_err, band_err, sym_err, first_nz;
    reg signed [OW-1:0] imp [0:60];

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
            x_in  = {IW{1'b0}};
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
                end
            end
            `check_eq("向量回放：本场景 512 个样本逐位一致", ee, 0);
        end
    endtask

    initial begin
        $readmemh({`VECDIR, "cascade_vec.txt"}, vec);
        $readmemh({`HB_COEFDIR, "hb_odd.mem"}, coef);

        // ── 0. 自检 ─────────────────────────────────────────────────
        `check(vec[0] === 32'hF04C0DE1, "向量文件哨兵正确（文件真的读进来了）");
        `check_eq("向量文件场景数 = 4", vec[1], NSCEN);
        `check_eq("每场景样本数 = 512", vec[2], NSAMP);
        `check_eq("数据行数 = 2048", vec[3], NSCEN * NSAMP);
        `check_eq("向量文件 IW = 12", vec[4], IW);
        `check_eq("向量文件 OW = 14（级联输出）", vec[5], OW);
        `check_eq("向量文件 SHIFT = 15（抽取那级）", vec[6], SHIFT_D);
        `check_eq("向量文件 ROUND = 1", vec[7], 1);
        `check_eq("向量文件与 hb_odd.mem 的系数校验和一致", vec[8], coef_sum(0));
        `check_eq("向量文件 LAT = 8（4 + 4 级流水）", vec[9], LAT);

        z = 0;
        for (k = 0; k < K; k = k + 1)
            if ((^coef[k]) === 1'bx)
                z = z + 1;
        `check_eq("系数表 30 个值全部读入（没有 x）", z, 0);

        // ── 1. 复位 ─────────────────────────────────────────────────
        rst_n = 1'b0;
        x_in = 12'sd2047;
        repeat (4) @(posedge clk);
        `check_eq("复位期间输出为 0", y_out, 0);

        do_reset;
        for (t = 0; t < 60; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd1000;
        end
        `check(y_out !== 0, "运行中输出非零（下面才能测异步复位）");
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立即把输出清零（不等时钟沿）", y_out, 0);
        rst_n = 1'b1;
        @(negedge clk);

        // ── 2. 冲激响应（整条链的形状）──────────────────────────────
        do_reset;
        first_nz = -1;
        for (t = 0; t < 70; t = t + 1) begin
            @(negedge clk);
            x_in = (t == 0) ? 12'sd2047 : 12'sd0;
            if (t >= LAT && (t - LAT) <= 60) begin
                imp[t-LAT] = y_out;
                if (first_nz < 0 && y_out != 0)
                    first_nz = t - LAT;
            end
        end
        `check_eq("冲激响应第一个非零点在第 9 拍", first_nz, 9);
        `check_eq("峰值 = 1991，出现在第 30 拍（延迟 30 = 15 + 15）", imp[30], 1991);

        sym_err = 0;
        for (k = 9; k < 30; k = k + 1)
            if (imp[k] !== imp[60-k])
                sym_err = sym_err + 1;
        `check_eq("冲激响应关于第 30 点对称（21 对全相等）", sym_err, 0);

        err = 0;
        for (k = 0; k <= 60; k = k + 1)
            if ((k < 9 || k > 51) && imp[k] !== 0)
                err = err + 1;
        `check_eq("冲激响应在 9..51 之外全为 0（长度 43 点）", err, 0);

        // ── 3. 直流：1000 进 → 1000 出（延迟 30 拍，逐位）────────────
        do_reset;
        dc_err = 0;
        for (t = 0; t < 200; t = t + 1) begin
            @(negedge clk);
            x_in = 12'sd1000;
            if (t >= 64 && y_out !== 14'sd1000)
                dc_err = dc_err + 1;
        end
        `check_eq("直流 1000 进 → 1000 出（64 拍后逐位相等）", dc_err, 0);

        // ── 4. 通带单音：输出 ≈ 延迟 30 拍的输入 ───────────────────
        // 用向量里的 tones 场景（0.05 + 0.20，都在通带内），
        // 逐拍和 x[n-30] 比，误差应当只有几个 LSB（两个半带的通带纹波）。
        band_err = 0;
        do_reset;
        for (t = 0; t < NSAMP + LAT; t = t + 1) begin
            @(negedge clk);
            x_in = (t < NSAMP) ? vec[VEC_HEAD + 2*NSAMP + 2*t][IW-1:0] : {IW{1'b0}};
            if (t >= 64 && (t - LAT) >= 30) begin
                k = $signed(vec[VEC_HEAD + 2*NSAMP + 2*(t-LAT-30)]) ;
                if (y_out - k > 4 || k - y_out > 4)
                    band_err = band_err + 1;
            end
        end
        `check_eq("通带单音：输出与 x[n-30] 的偏差 ≤ 4 LSB", band_err, 0);

        // ── 5. 参考向量回放（4 个场景 × 512 样本）──────────────────
        for (s = 0; s < NSCEN; s = s + 1)
            replay_case(s);

        tb_done;
    end

endmodule
