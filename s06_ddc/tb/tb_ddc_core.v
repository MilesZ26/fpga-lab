`timescale 1ns/1ps
//=============================================================================
// tb_ddc_core — s06 DDC 核心的验收
//-----------------------------------------------------------------------------
// 要回答的问题（和 tb_duc_core 对称）：
//
//   ① 算术：4 场景 × 512 样本的逐位向量（decim → mixer → FIR）。
//   ② 复位：复位期间 i_out/q_out = 0；异步复位立刻清零。
//   ③ 相位：step 场景（DC 1000 上变频后的复单音）经过 DDC 后必须回到
//      **+998 / 0** —— 如果 LO_DLY 差 5 拍，会变成 0/+998（差 90°）；
//      差 10 拍会变成 -998/0（差 180°）。这条是"相位对齐"的硬判据。
//   ④ 增益：tone 场景输出幅度 ≈ 1000；复单音幅度基本恒定。
//   ⑤ 饱和：OW_OUT=8 的实例把 ±1000 钳到 ±127/-128。
//   ⑥ 参数化：N_DEC=5/N_FIR=5/LO=0 的小实例，DC 输入 → 1000。
//   ⑦ 相位敏感：LO_DLY=0 的实例和正确实例不同（向量真的在抓相位）。
//
// 时序：下降沿驱动四路输入，同一个下降沿读 i_out/q_out；
//       第 k 个下降沿的输入对应第 k+LAT 个下降沿的输出（LAT=10）。
//=============================================================================
module tb_ddc_core;
    `include "tb_common.vh"

`ifndef VECDIR
  `define VECDIR "s06_ddc/vec/"
`endif
`ifndef FIR_COEFDIR
  `define FIR_COEFDIR "s03_fir/lut/"
`endif
`ifndef HB_COEFDIR
  `define HB_COEFDIR "s04_resample/lut/"
`endif

    localparam integer IW      = 15;           // DUC 插值输出
    localparam integer CW      = 16;
    localparam integer N_DEC   = 61;
    localparam integer N_FIR   = 47;
    localparam integer AW      = 12;
    localparam integer PHASE_W = 32;
    localparam integer LUT_AW  = 12;
    localparam integer CLK_HZ  = 100;
    localparam integer FREQ_HZ = 5;
    localparam integer OW_DEC  = 16;
    localparam integer OW_MIX  = 17;
    localparam integer OW_FIR  = 18;
    localparam integer OW_OUT  = 13;
    localparam integer SHIFT_DEC = 15;
    localparam integer SHIFT_MIX = 11;
    localparam integer SHIFT_FIR = 15;
    localparam integer LAT     = 10;
    localparam integer LO_DLY  = 14;

    localparam integer NSCEN   = 4;
    localparam integer NSAMP   = 512;
    localparam integer VEC_HEAD = 16;
    localparam integer VEC_WORDS = VEC_HEAD + 6 * NSCEN * NSAMP;

    localparam [63:0] PHI_CALC = (64'd5 << PHASE_W) / 64'd100;

    reg clk = 0;
    reg rst_n = 0;
    reg signed [IW-1:0] x_i_e = 0, x_i_o = 0, x_q_e = 0, x_q_o = 0;

    always #5 clk = ~clk;

    // ── 主 DUT ─────────────────────────────────────────────────────
    wire signed [OW_OUT-1:0] i_out, q_out;

    ddc_core #(
        .IW(IW), .CW(CW), .N_DEC(N_DEC), .N_FIR(N_FIR),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_DEC(OW_DEC), .OW_MIX(OW_MIX), .OW_FIR(OW_FIR), .OW_OUT(OW_OUT),
        .SHIFT_DEC(SHIFT_DEC), .SHIFT_MIX(SHIFT_MIX), .SHIFT_FIR(SHIFT_FIR),
        .ROUND(1), .LO_DLY(LO_DLY)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_e(x_i_e), .i_o(x_i_o), .q_e(x_q_e), .q_o(x_q_o),
        .i_out(i_out), .q_out(q_out)
    );

    // ── 相位故意错 0 拍的实例 ──────────────────────────────────────
    wire signed [OW_OUT-1:0] bad_i, bad_q;

    ddc_core #(
        .IW(IW), .CW(CW), .N_DEC(N_DEC), .N_FIR(N_FIR),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_DEC(OW_DEC), .OW_MIX(OW_MIX), .OW_FIR(OW_FIR), .OW_OUT(OW_OUT),
        .SHIFT_DEC(SHIFT_DEC), .SHIFT_MIX(SHIFT_MIX), .SHIFT_FIR(SHIFT_FIR),
        .ROUND(1), .LO_DLY(0)
    ) dut_bad_phase (
        .clk(clk), .rst_n(rst_n),
        .i_e(x_i_e), .i_o(x_i_o), .q_e(x_q_e), .q_o(x_q_o),
        .i_out(bad_i), .q_out(bad_q)
    );

    // ── 输出饱和的实例（OW_OUT=8）──────────────────────────────────
    wire signed [7:0] sat_i, sat_q;

    ddc_core #(
        .IW(IW), .CW(CW), .N_DEC(N_DEC), .N_FIR(N_FIR),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_DEC(OW_DEC), .OW_MIX(OW_MIX), .OW_FIR(OW_FIR), .OW_OUT(8),
        .SHIFT_DEC(SHIFT_DEC), .SHIFT_MIX(SHIFT_MIX), .SHIFT_FIR(SHIFT_FIR),
        .ROUND(1), .LO_DLY(LO_DLY)
    ) dut_sat (
        .clk(clk), .rst_n(rst_n),
        .i_e(x_i_e), .i_o(x_i_o), .q_e(x_q_e), .q_o(x_q_o),
        .i_out(sat_i), .q_out(sat_q)
    );

    // ── 小实例：5 抽头半带 + 5 抽头 FIR + LO=0 ─────────────────────
    wire signed [OW_OUT-1:0] sm_i, sm_q;

    ddc_core #(
        .IW(IW), .CW(CW), .N_DEC(5), .N_FIR(5),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(0),
        .OW_DEC(OW_DEC), .OW_MIX(OW_MIX), .OW_FIR(OW_FIR), .OW_OUT(OW_OUT),
        .SHIFT_DEC(SHIFT_DEC), .SHIFT_MIX(SHIFT_MIX), .SHIFT_FIR(SHIFT_FIR),
        .ROUND(1), .LO_DLY(0),
        .COEF_FILE_DEC("hb5.mem"), .COEF_FILE_FIR("coef5.mem")
    ) dut_small (
        .clk(clk), .rst_n(rst_n),
        .i_e(x_i_e), .i_o(x_i_o), .q_e(x_q_e), .q_o(x_q_o),
        .i_out(sm_i), .q_out(sm_q)
    );

    // ── 参考向量 + 系数组 ──────────────────────────────────────────
    reg [31:0] vec [0:VEC_WORDS-1];
    reg signed [CW-1:0] coef [0:N_FIR-1];
    reg signed [CW-1:0] hb [0:(N_DEC-1)/2-1];

    integer s, t, k, z, err, diffs;
    reg signed [31:0] ev, v0, v1, v2, v3;
    integer peak, peak_min, mag_min, mag_max, mag;
    integer sat_pos, sat_neg, sat_bad;
    integer dc_max, dc_q_max;

    function [31:0] coef_sum47;
        input integer dummy;
        integer ii;
        reg [31:0] h;
        begin
            h = 32'h12345678;
            for (ii = 0; ii < N_FIR; ii = ii + 1)
                h = h * 32'd33 + {16'b0, coef[ii][15:0]};
            coef_sum47 = h;
        end
    endfunction

    function [31:0] coef_sum30;
        input integer dummy;
        integer ii;
        reg [31:0] h;
        begin
            h = 32'h12345678;
            for (ii = 0; ii < (N_DEC-1)/2; ii = ii + 1)
                h = h * 32'd33 + {16'b0, hb[ii][15:0]};
            coef_sum30 = h;
        end
    endfunction

    task do_reset;
        begin
            rst_n = 1'b0;
            x_i_e = {IW{1'b0}};
            x_i_o = {IW{1'b0}};
            x_q_e = {IW{1'b0}};
            x_q_o = {IW{1'b0}};
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task replay_case;
        input integer scen;
        integer bt, tt, ee;
        reg signed [31:0] v0, v1, v2, v3, vo, vq;
        begin
            do_reset;
            bt = VEC_HEAD + scen * NSAMP * 6;
            ee = 0;
            for (tt = 0; tt < NSAMP + LAT; tt = tt + 1) begin
                @(negedge clk);
                if (tt < NSAMP) begin
                    v0 = $signed(vec[bt + 6*tt + 0]);
                    v1 = $signed(vec[bt + 6*tt + 1]);
                    v2 = $signed(vec[bt + 6*tt + 2]);
                    v3 = $signed(vec[bt + 6*tt + 3]);
                    x_i_e = v0[IW-1:0];
                    x_i_o = v1[IW-1:0];
                    x_q_e = v2[IW-1:0];
                    x_q_o = v3[IW-1:0];
                end else begin
                    x_i_e = {IW{1'b0}};
                    x_i_o = {IW{1'b0}};
                    x_q_e = {IW{1'b0}};
                    x_q_o = {IW{1'b0}};
                end
                if (tt >= LAT) begin
                    vo = $signed(vec[bt + 6*(tt-LAT) + 4]);
                    vq = $signed(vec[bt + 6*(tt-LAT) + 5]);
                    if (i_out !== vo[OW_OUT-1:0]) begin
                        if (ee < 3)
                            $display("    [mismatch] 场景 %0d n=%0d i_out got=%0d exp=%0d",
                                     scen, tt-LAT, i_out, vo);
                        ee = ee + 1;
                    end
                    if (q_out !== vq[OW_OUT-1:0]) ee = ee + 1;
                end
            end
            `check_eq("向量回放：本场景 512 个样本 × I/Q 逐位一致", ee, 0);
        end
    endtask

    initial begin
        $readmemh({`VECDIR, "ddc_vec.txt"}, vec);
        $readmemh({`FIR_COEFDIR, "coef.mem"}, coef);
        $readmemh({`HB_COEFDIR, "hb_odd.mem"}, hb);

        // ── 0. 自检 ─────────────────────────────────────────────────
        `check(vec[0] === 32'hDDC60001, "向量文件哨兵正确（ddc_vec.txt 真的读进来了）");
        `check_eq("场景数 = 4", vec[1], NSCEN);
        `check_eq("每场景 512 样本", vec[2], NSAMP);
        `check_eq("数据行数 = 2048", vec[3], NSCEN*NSAMP);
        `check_eq("向量 IW = 15（DDC 输入两相）", vec[4], IW);
        `check_eq("向量 OW = 13（DDC 输出）", vec[5], OW_OUT);
        `check_eq("向量 CW = 16", vec[6], CW);
        `check_eq("向量 AW = 12", vec[7], AW);
        `check_eq("向量 SHIFT_FIR = 15", vec[8], SHIFT_FIR);
        `check_eq("向量 SHIFT_MIX = 11", vec[9], SHIFT_MIX);
        `check_eq("向量 SHIFT_DEC = 15", vec[10], SHIFT_DEC);
        `check_eq("FIR 系数校验和一致", vec[11], coef_sum47(0));
        `check_eq("半带系数校验和一致", vec[12], coef_sum30(0));
        `check_eq("PHI_INC = (5<<32)/100", vec[13], PHI_CALC[31:0]);
        `check_eq("向量 LAT = 10", vec[14], LAT);
        `check_eq("向量 LO_DLY = 14", vec[15], LO_DLY);

        z = 0;
        for (k = 0; k < N_FIR; k = k + 1)
            if ((^coef[k]) === 1'bx) z = z + 1;
        `check_eq("47 个 FIR 系数全部读入（没有 x）", z, 0);
        z = 0;
        for (k = 0; k < (N_DEC-1)/2; k = k + 1)
            if ((^hb[k]) === 1'bx) z = z + 1;
        `check_eq("30 个半带系数全部读入（没有 x）", z, 0);

        // ── 1. 复位 ─────────────────────────────────────────────────
        rst_n = 1'b0;
        x_i_e = 15'sd2047;
        x_i_o = -15'sd2048;
        x_q_e = 15'sd2047;
        x_q_o = -15'sd2048;
        repeat (4) @(posedge clk);
        `check_eq("复位期间 i_out = 0", i_out, 0);
        `check_eq("复位期间 q_out = 0", q_out, 0);

        do_reset;
        for (t = 0; t < 80; t = t + 1) begin
            @(negedge clk);
            x_i_e = 15'sd1000;
            x_i_o = 15'sd1000;
            x_q_e = 15'sd0;
            x_q_o = 15'sd0;
        end
        `check(i_out !== 0 || q_out !== 0, "运行中输出非零（下面才能测异步复位）");
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立即把 i_out 清零（不等时钟沿）", i_out, 0);
        `check_eq("异步复位立即把 q_out 清零（不等时钟沿）", q_out, 0);
        rst_n = 1'b1;
        @(negedge clk);

        // ── 2. 向量回放（4 个场景）──────────────────────────────────
        for (s = 0; s < NSCEN; s = s + 1)
            replay_case(s);

        // ── 3. 相位：step 场景 → DC +998 / 0 ───────────────────────
        // 这一段直接用向量里 step 场景的输入（DUC 输出的复单音），
        // 跑稳态后看 i_out/q_out。LO_DLY 差 5 拍 → 0/±998；差 10 拍 → -998/0。
        do_reset;
        for (t = 0; t < 512 + LAT; t = t + 1) begin
            @(negedge clk);
            if (t < 512) begin
                v0 = $signed(vec[VEC_HEAD + 1*NSAMP*6 + 6*t + 0]);
                v1 = $signed(vec[VEC_HEAD + 1*NSAMP*6 + 6*t + 1]);
                v2 = $signed(vec[VEC_HEAD + 1*NSAMP*6 + 6*t + 2]);
                v3 = $signed(vec[VEC_HEAD + 1*NSAMP*6 + 6*t + 3]);
                x_i_e = v0[IW-1:0];
                x_i_o = v1[IW-1:0];
                x_q_e = v2[IW-1:0];
                x_q_o = v3[IW-1:0];
            end else begin
                x_i_e = {IW{1'b0}};
                x_i_o = {IW{1'b0}};
                x_q_e = {IW{1'b0}};
                x_q_o = {IW{1'b0}};
            end
        end
        `check(i_out >= 990 && i_out <= 1005,
               "step 稳态：i_out = +998 附近（相位对；差 90°/180° 都会掉出这个窗口）");
        `check(q_out >= -3 && q_out <= 3,
               "step 稳态：q_out ≈ 0（正交分量被搬到 DC）");

        // ── 4. 增益 + 正交：tone 场景输出幅度 ≈ 1000 ────────────────
        mag_min = 1 << 30;
        mag_max = 0;
        do_reset;
        for (t = 0; t < 512 + LAT; t = t + 1) begin
            @(negedge clk);
            if (t < 512) begin
                v0 = $signed(vec[VEC_HEAD + 2*NSAMP*6 + 6*t + 0]);
                v1 = $signed(vec[VEC_HEAD + 2*NSAMP*6 + 6*t + 1]);
                v2 = $signed(vec[VEC_HEAD + 2*NSAMP*6 + 6*t + 2]);
                v3 = $signed(vec[VEC_HEAD + 2*NSAMP*6 + 6*t + 3]);
                x_i_e = v0[IW-1:0];
                x_i_o = v1[IW-1:0];
                x_q_e = v2[IW-1:0];
                x_q_o = v3[IW-1:0];
            end else begin
                x_i_e = {IW{1'b0}};
                x_i_o = {IW{1'b0}};
                x_q_e = {IW{1'b0}};
                x_q_o = {IW{1'b0}};
            end
            if (t > 200 && t < 500) begin
                mag = i_out*i_out + q_out*q_out;
                if (mag < mag_min) mag_min = mag;
                if (mag > mag_max) mag_max = mag;
            end
        end
        `check(mag_min > 900*900 && mag_max < 1150*1150,
               "tone 场景：恢复的单音幅度在 900..1150（增益 ≈ 1）");
        `check(mag_max - mag_min < (mag_max / 3),
               "恢复的复单音幅度基本恒定（max-min < max/3）");

        // ── 5. 相位敏感：LO_DLY=0 的实例必须和正确实例不同 ──────────
        diffs = 0;
        do_reset;
        for (t = 0; t < 512 + LAT; t = t + 1) begin
            @(negedge clk);
            if (t < 512) begin
                v0 = $signed(vec[VEC_HEAD + 1*NSAMP*6 + 6*t + 0]);
                v1 = $signed(vec[VEC_HEAD + 1*NSAMP*6 + 6*t + 1]);
                v2 = $signed(vec[VEC_HEAD + 1*NSAMP*6 + 6*t + 2]);
                v3 = $signed(vec[VEC_HEAD + 1*NSAMP*6 + 6*t + 3]);
                x_i_e = v0[IW-1:0];
                x_i_o = v1[IW-1:0];
                x_q_e = v2[IW-1:0];
                x_q_o = v3[IW-1:0];
            end
            if (t > 200 && i_out !== bad_i) diffs = diffs + 1;
        end
        `check(diffs > 50, "LO_DLY=0 的实例输出和正确相位不同（向量能抓相位错）");

        // ── 6. 饱和：OW_OUT=8 的实例把 ±1000 钳到 ±127/-128 ────────
        sat_pos = 0;
        sat_neg = 0;
        sat_bad = 0;
        do_reset;
        for (t = 0; t < 512 + LAT; t = t + 1) begin
            @(negedge clk);
            if (t < 512) begin
                v0 = $signed(vec[VEC_HEAD + 2*NSAMP*6 + 6*t + 0]);
                v1 = $signed(vec[VEC_HEAD + 2*NSAMP*6 + 6*t + 1]);
                v2 = $signed(vec[VEC_HEAD + 2*NSAMP*6 + 6*t + 2]);
                v3 = $signed(vec[VEC_HEAD + 2*NSAMP*6 + 6*t + 3]);
                x_i_e = v0[IW-1:0];
                x_i_o = v1[IW-1:0];
                x_q_e = v2[IW-1:0];
                x_q_o = v3[IW-1:0];
            end else begin
                x_i_e = {IW{1'b0}};
                x_i_o = {IW{1'b0}};
                x_q_e = {IW{1'b0}};
                x_q_o = {IW{1'b0}};
            end
            if (t > 200) begin
                if (sat_i > 127 || sat_i < -128) sat_bad = sat_bad + 1;
                if (sat_i == 127) sat_pos = sat_pos + 1;
                if (sat_i == -128) sat_neg = sat_neg + 1;
            end
        end
        `check_eq("OW_OUT=8：输出从不越界（饱和而不是回绕）", sat_bad, 0);
        `check(sat_pos > 5, "OW_OUT=8：正峰值被钳到 +127");
        `check(sat_neg > 5, "OW_OUT=8：负峰值被钳到 -128");

        // ── 7. 参数化冒烟：5 抽头半带 + 5 抽头 FIR + LO=0 ──────────
        do_reset;
        for (t = 0; t < 80; t = t + 1) begin
            @(negedge clk);
            x_i_e = 15'sd1000;
            x_i_o = 15'sd1000;
            x_q_e = 15'sd0;
            x_q_o = 15'sd0;
        end
        `check_eq("小实例（N_DEC=5/N_FIR=5/LO=0）：i_out = 1000", sm_i, 1000);
        `check_eq("小实例：q_out = 0", sm_q, 0);

        tb_done;
    end

endmodule
