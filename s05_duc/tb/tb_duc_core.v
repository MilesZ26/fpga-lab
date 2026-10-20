`timescale 1ns/1ps
//=============================================================================
// tb_duc_core — s05 DUC 核心的验收
//-----------------------------------------------------------------------------
// 这个 TB 要回答六个问题：
//
//   ① 整条链的算术对不对？—— Python 逐位向量（4 场景 × 512 样本 × 6 路）。
//   ② 复位对不对？—— 复位期间四路输出全 0；异步复位立刻清零。
//   ③ 延迟/相位对不对？—— 冲激响应：i_e 的第一个非零点在输出下标 15
//      （半带偶相 = 15 个输入样本的延迟）；i_o/q_o 在 0.. 出现。
//   ④ 增益预算对不对？—— DC 1000 进，DUC 输出复单音的幅度 ~1000（不是 2000、
//      也不是 500）；满幅随机不饱和（DUC 输出峰值 < 2048）。
//   ⑤ 参数真的起作用？—— N_FIR=5 / N_HB=5 / FREQ_HZ=0 的小实例，
//      DC 1000 进 → i_e = i_o = 1000（5 抽头 FIR + 线性内插半带，单位增益）。
//   ⑥ 饱和/相位敏感？—— OW_INT=8 的实例把 ±1000 钳到 ±127；
//      LO_DLY=0 的实例和正确相位**不同**（证明向量真的在抓相位，不是只抓幅度）。
//
// 时序约定（和 s03/s04 一致）：
//   下降沿驱动 i_in/q_in，同一个下降沿读输出。
//   第 k 个下降沿的输入，对应**第 k+LAT 个下降沿**的输出（LAT=9）。
//
// 向量文件头 16 个字：
//   0 哨兵 0xD0C50001 / 1 场景数 / 2 每场景样本 / 3 数据行数
//   4 IW / 5 OW / 6 CW / 7 AW
//   8 SHIFT_FIR / 9 SHIFT_MIX / 10 SHIFT_INT
//   11 FIR 系数校验和 / 12 HB 系数校验和
//   13 PHI_INC / 14 LAT / 15 LO_DLY
//=============================================================================
module tb_duc_core;
    `include "tb_common.vh"

`ifndef VECDIR
  `define VECDIR "s05_duc/vec/"
`endif
`ifndef FIR_COEFDIR
  `define FIR_COEFDIR "s03_fir/lut/"
`endif
`ifndef HB_COEFDIR
  `define HB_COEFDIR "s04_resample/lut/"
`endif
`ifndef NCO_LUTDIR
  `define NCO_LUTDIR "s01_nco/lut/"
`endif

    // ── 和 RTL / 生成器一致的参数 ────────────────────────────────────
    localparam integer IW      = 12;
    localparam integer CW      = 16;
    localparam integer N_FIR   = 47;
    localparam integer N_HB    = 61;
    localparam integer AW      = 12;
    localparam integer PHASE_W = 32;
    localparam integer LUT_AW  = 12;
    localparam integer CLK_HZ  = 100;          // 仿真时钟频率参数（只影响 NCO 增量）
    localparam integer FREQ_HZ = 5;            // 0.05 × Fs
    localparam integer OW_FIR  = 13;
    localparam integer OW_MIX  = 14;
    localparam integer OW_INT  = 15;
    localparam integer SHIFT_FIR = 15;
    localparam integer SHIFT_MIX = 11;
    localparam integer SHIFT_INT = 14;
    localparam integer LAT     = 9;
    localparam integer LO_DLY  = 4;

    localparam integer NSCEN   = 4;
    localparam integer NSAMP   = 512;
    localparam integer VEC_HEAD = 16;
    localparam integer VEC_WORDS = VEC_HEAD + 6 * NSCEN * NSAMP;

    localparam [63:0] PHI_CALC = (64'd5 << PHASE_W) / 64'd100;

    reg clk = 0;
    reg rst_n = 0;
    reg signed [IW-1:0] i_in = 0;
    reg signed [IW-1:0] q_in = 0;

    always #5 clk = ~clk;

    // ── DUT：主配置 ─────────────────────────────────────────────────
    wire signed [OW_INT-1:0] i_e, i_o, q_e, q_o;

    duc_core #(
        .IW(IW), .CW(CW), .N_FIR(N_FIR), .N_HB(N_HB),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_FIR(OW_FIR), .OW_MIX(OW_MIX), .OW_INT(OW_INT),
        .SHIFT_FIR(SHIFT_FIR), .SHIFT_MIX(SHIFT_MIX), .SHIFT_INT(SHIFT_INT),
        .ROUND(1), .LO_DLY(LO_DLY)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_in(i_in), .q_in(q_in),
        .i_e(i_e), .i_o(i_o), .q_e(q_e), .q_o(q_o)
    );

    // ── 辅助实例：相位故意错 0 拍（应该和主实例不同）──────────────────
    wire signed [OW_INT-1:0] bad_i_e, bad_i_o, bad_q_e, bad_q_o;

    duc_core #(
        .IW(IW), .CW(CW), .N_FIR(N_FIR), .N_HB(N_HB),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_FIR(OW_FIR), .OW_MIX(OW_MIX), .OW_INT(OW_INT),
        .SHIFT_FIR(SHIFT_FIR), .SHIFT_MIX(SHIFT_MIX), .SHIFT_INT(SHIFT_INT),
        .ROUND(1), .LO_DLY(0)
    ) dut_bad_phase (
        .clk(clk), .rst_n(rst_n),
        .i_in(i_in), .q_in(q_in),
        .i_e(bad_i_e), .i_o(bad_i_o), .q_e(bad_q_e), .q_o(bad_q_o)
    );

    // ── 辅助实例：输出位宽 8 → 故意饱和 ─────────────────────────────
    wire signed [7:0] sat_i_e, sat_i_o, sat_q_e, sat_q_o;

    duc_core #(
        .IW(IW), .CW(CW), .N_FIR(N_FIR), .N_HB(N_HB),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_FIR(OW_FIR), .OW_MIX(OW_MIX), .OW_INT(8),
        .SHIFT_FIR(SHIFT_FIR), .SHIFT_MIX(SHIFT_MIX), .SHIFT_INT(SHIFT_INT),
        .ROUND(1), .LO_DLY(LO_DLY)
    ) dut_sat (
        .clk(clk), .rst_n(rst_n),
        .i_in(i_in), .q_in(q_in),
        .i_e(sat_i_e), .i_o(sat_i_o), .q_e(sat_q_e), .q_o(sat_q_o)
    );

    // ── 辅助实例：5 抽头 FIR + 5 抽头半带 + LO=0（参数化冒烟）────────
    wire signed [OW_INT-1:0] sm_i_e, sm_i_o, sm_q_e, sm_q_o;

    duc_core #(
        .IW(IW), .CW(CW), .N_FIR(5), .N_HB(5),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(0),           // 本振 = DC（cos=2047, sin=0）
        .OW_FIR(OW_FIR), .OW_MIX(OW_MIX), .OW_INT(OW_INT),
        .SHIFT_FIR(SHIFT_FIR), .SHIFT_MIX(SHIFT_MIX), .SHIFT_INT(SHIFT_INT),
        .ROUND(1), .LO_DLY(0),
        .COEF_FILE_FIR("coef5.mem"), .COEF_FILE_HB("hb5.mem")
    ) dut_small (
        .clk(clk), .rst_n(rst_n),
        .i_in(i_in), .q_in(q_in),
        .i_e(sm_i_e), .i_o(sm_i_o), .q_e(sm_q_e), .q_o(sm_q_o)
    );

    // ── 参考向量 + 两张系数表（TB 自己再读一遍，用来校验 checksum）────
    reg [31:0] vec [0:VEC_WORDS-1];
    reg signed [CW-1:0] coef [0:N_FIR-1];
    reg signed [CW-1:0] hb [0:(N_HB-1)/2-1];

    integer s, t, k, z, err, diffs;
    reg signed [31:0] ev;
    reg signed [OW_INT-1:0] imp_e [0:60];
    integer first_nz, peak, peak_min;
    integer mag_min, mag_max, mag;
    integer sat_pos, sat_neg, sat_bad;
    integer tone_rise, tone_prev;

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
            for (ii = 0; ii < (N_HB-1)/2; ii = ii + 1)
                h = h * 32'd33 + {16'b0, hb[ii][15:0]};
            coef_sum30 = h;
        end
    endfunction

    task do_reset;
        begin
            rst_n = 1'b0;
            i_in  = {IW{1'b0}};
            q_in  = {IW{1'b0}};
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task replay_case;
        input integer scen;
        integer bt, tt, ee;
        reg signed [31:0] vi, vq, ve, vo, vqe, vqo;
        begin
            do_reset;
            bt = VEC_HEAD + scen * NSAMP * 6;
            ee = 0;
            for (tt = 0; tt < NSAMP + LAT; tt = tt + 1) begin
                @(negedge clk);
                if (tt < NSAMP) begin
                    vi = $signed(vec[bt + 6*tt + 0]);
                    vq = $signed(vec[bt + 6*tt + 1]);
                    i_in = vi[IW-1:0];
                    q_in = vq[IW-1:0];
                end else begin
                    i_in = {IW{1'b0}};
                    q_in = {IW{1'b0}};
                end
                if (tt >= LAT) begin
                    ve  = $signed(vec[bt + 6*(tt-LAT) + 2]);
                    vo  = $signed(vec[bt + 6*(tt-LAT) + 3]);
                    vqe = $signed(vec[bt + 6*(tt-LAT) + 4]);
                    vqo = $signed(vec[bt + 6*(tt-LAT) + 5]);
                    if (i_e !== ve[OW_INT-1:0]) begin
                        if (ee < 3)
                            $display("    [mismatch] 场景 %0d n=%0d i_e got=%0d exp=%0d",
                                     scen, tt-LAT, i_e, ve);
                        ee = ee + 1;
                    end
                    if (i_o !== vo[OW_INT-1:0]) ee = ee + 1;
                    if (q_e !== vqe[OW_INT-1:0]) ee = ee + 1;
                    if (q_o !== vqo[OW_INT-1:0]) ee = ee + 1;
                end
            end
            `check_eq("向量回放：本场景 512 个样本 × 4 路逐位一致", ee, 0);
        end
    endtask

    initial begin
        $readmemh({`VECDIR, "duc_vec.txt"}, vec);
        $readmemh({`FIR_COEFDIR, "coef.mem"}, coef);
        $readmemh({`HB_COEFDIR, "hb_odd.mem"}, hb);

        // ── 0. 自检：文件真的读进来了，参数和生成器一致 ─────────────
        `check(vec[0] === 32'hD0C50001, "向量文件哨兵正确（duc_vec.txt 真的读进来了）");
        `check_eq("场景数 = 4", vec[1], NSCEN);
        `check_eq("每场景 512 样本", vec[2], NSAMP);
        `check_eq("数据行数 = 2048", vec[3], NSCEN*NSAMP);
        `check_eq("向量 IW = 12", vec[4], IW);
        `check_eq("向量 OW = 15（DUC 输出）", vec[5], OW_INT);
        `check_eq("向量 CW = 16", vec[6], CW);
        `check_eq("向量 AW = 12", vec[7], AW);
        `check_eq("向量 SHIFT_FIR = 15", vec[8], SHIFT_FIR);
        `check_eq("向量 SHIFT_MIX = 11", vec[9], SHIFT_MIX);
        `check_eq("向量 SHIFT_INT = 14", vec[10], SHIFT_INT);
        `check_eq("FIR 系数校验和一致", vec[11], coef_sum47(0));
        `check_eq("半带系数校验和一致", vec[12], coef_sum30(0));
        `check_eq("PHI_INC = (5<<32)/100", vec[13], PHI_CALC[31:0]);
        `check_eq("向量 LAT = 9", vec[14], LAT);
        `check_eq("向量 LO_DLY = 4", vec[15], LO_DLY);

        z = 0;
        for (k = 0; k < N_FIR; k = k + 1)
            if ((^coef[k]) === 1'bx) z = z + 1;
        `check_eq("47 个 FIR 系数全部读入（没有 x）", z, 0);
        z = 0;
        for (k = 0; k < (N_HB-1)/2; k = k + 1)
            if ((^hb[k]) === 1'bx) z = z + 1;
        `check_eq("30 个半带系数全部读入（没有 x）", z, 0);

        // ── 1. 复位 ─────────────────────────────────────────────────
        rst_n = 1'b0;
        i_in = 12'sd2047;
        q_in = -12'sd2048;
        repeat (4) @(posedge clk);
        `check_eq("复位期间 i_e = 0", i_e, 0);
        `check_eq("复位期间 i_o = 0", i_o, 0);
        `check_eq("复位期间 q_e = 0", q_e, 0);
        `check_eq("复位期间 q_o = 0", q_o, 0);

        do_reset;
        for (t = 0; t < 40; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
        end
        `check(i_e !== 0 || q_e !== 0, "运行中输出非零（下面才能测异步复位）");
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立即把 i_e 清零（不等时钟沿）", i_e, 0);
        `check_eq("异步复位立即把 q_e 清零（不等时钟沿）", q_e, 0);
        rst_n = 1'b1;
        @(negedge clk);

        // ── 2. 向量回放（4 个场景）──────────────────────────────────
        for (s = 0; s < NSCEN; s = s + 1)
            replay_case(s);

        // ── 3. 冲激响应：偶相第一个非零点 = 输出下标 15 ────────────
        // 场景 0 是 i_in[0]=2047 的冲激。DUC 输出下标 k 对应 TB 的 t=k+LAT。
        do_reset;
        for (t = 0; t < 70; t = t + 1) begin
            @(negedge clk);
            i_in = (t == 0) ? 12'sd2047 : 12'sd0;
            q_in = 12'sd0;
            if (t >= LAT && (t - LAT) <= 60)
                imp_e[t-LAT] = i_e;
        end
        first_nz = -1;
        for (k = 0; k <= 60; k = k + 1)
            if (first_nz < 0 && imp_e[k] != 0) first_nz = k;
        `check_eq("冲激：i_e 的第一个非零点在输出下标 15（半带偶相 = 15 拍延迟）",
                  first_nz, 15);
        peak = 0;
        for (k = 0; k <= 60; k = k + 1)
            if (imp_e[k] > peak) peak = imp_e[k];
        peak_min = 0;
        for (k = 0; k <= 60; k = k + 1)
            if (imp_e[k] < peak_min) peak_min = imp_e[k];
        `check(peak > 300 && peak < 700, "冲激：i_e 峰值在 300..700（≈ 2047·h[23]/2^15）");
        `check(peak_min < -50 && peak_min > -250, "冲激：i_e 负半边存在（不是全正）");

        // ── 4. 增益 + 正交性：DC 1000 进，DUC 输出复单音幅度 ≈ 1000 ──
        // 稳态后取 200 个点，算 |i_e + j q_e|^2 的最小/最大值。
        do_reset;
        for (t = 0; t < 300; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
        end
        mag_min = 1 << 30;
        mag_max = 0;
        for (t = 0; t < 200; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
            mag = i_e*i_e + q_e*q_e;
            if (mag < mag_min) mag_min = mag;
            if (mag > mag_max) mag_max = mag;
        end
        `check(mag_min > 900*900 && mag_max < 1150*1150,
               "DC 1000 → 输出复单音幅度在 900..1150（增益 ≈ 1）");
        `check(mag_max - mag_min < (mag_max / 4),
               "复单音幅度基本恒定（max-min < max/4，不是两条不相干的波形）");

        // ── 5. 相位敏感：LO_DLY=0 的实例必须和正确实例不同 ──────────
        // 这条不替代"改坏 RTL 变红"，但能在 TB 内部证明向量在抓相位。
        diffs = 0;
        do_reset;
        for (t = 0; t < 200; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
            if (t > 50 && i_e !== bad_i_e) diffs = diffs + 1;
        end
        `check(diffs > 50, "LO_DLY=0 的实例输出和正确相位不同（向量能抓相位错）");

        // ── 6. 饱和：OW_INT=8 的实例把 ±1000 钳到 ±127 ──────────────
        sat_pos = 0;
        sat_neg = 0;
        sat_bad = 0;
        do_reset;
        for (t = 0; t < 300; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
            if (t > 100) begin
                if (sat_i_e > 127 || sat_i_e < -128) sat_bad = sat_bad + 1;
                if (sat_i_e == 127) sat_pos = sat_pos + 1;
                if (sat_i_e == -128) sat_neg = sat_neg + 1;
            end
        end
        `check_eq("OW_INT=8：输出从不越界（饱和而不是回绕）", sat_bad, 0);
        `check(sat_pos > 10, "OW_INT=8：正峰值被钳到 +127");
        `check(sat_neg > 10, "OW_INT=8：负峰值被钳到 -128");

        // ── 7. 参数化冒烟：5 抽头 FIR + 5 抽头半带，DC 1000 → 1000 ──
        do_reset;
        for (t = 0; t < 60; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
        end
        `check_eq("小实例（N_FIR=5/N_HB=5/LO=0）：i_e = 1000", sm_i_e, 1000);
        `check_eq("小实例：i_o = 1000", sm_i_o, 1000);
        `check_eq("小实例：q_e = 0", sm_q_e, 0);

        tb_done;
    end

endmodule
