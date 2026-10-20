`timescale 1ns/1ps
//=============================================================================
// tb_duc_ddc_loopback — DUC → DDC 整条链的验收（s06 的"合龙"测试）
//-----------------------------------------------------------------------------
// 为什么要有这个 TB：
//   tb_duc_core / tb_ddc_core 各自证明"半条链"对，但集成时真正的坑在
//   **两条链之间**：
//     · NCO 相位：DDC 的 LO 要晚多少拍才能把 DUC 的载波相位抵消掉？
//     · 位宽：DUC 出 15 位，DDC 的 IW 必须是 15（不是 12/13）；
//     · 多相：DUC 的两相 (i_e,i_o)/(q_e,q_o) 直接喂 DDC 的四路输入；
//     · 延迟：整条链 LAT = DUC 9 + DDC 10 = 19 拍。
//   任何一处错，输出频率可能还是对的，但相位/幅度/星座会歪 ——
//   所以这里用**整条链的 Python 逐位向量**（4 场景 × 512 样本）比对。
//
// 三条性质断言（向量之外）：
//   ① step：DC 1000 进 → DDC 输出 +998/0（相位对；差 90°/180° 会掉出窗口）。
//   ② tone：0.01 Fs 的复单音进 → 输出复单音幅度 ≈ 1000 且基本恒定。
//   ③ 相位敏感：把 DDC 的 LO_DLY 改成 0，输出必须和正确实例不同。
//
// 时序：下降沿驱动 DUC 输入，同一个下降沿读 DDC 输出；
//       第 k 个下降沿的输入对应第 k+19 个下降沿的输出。
//=============================================================================
module tb_duc_ddc_loopback;
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

    localparam integer IW      = 12;
    localparam integer CW      = 16;
    localparam integer N_FIR   = 47;
    localparam integer N_HB    = 61;
    localparam integer AW      = 12;
    localparam integer PHASE_W = 32;
    localparam integer LUT_AW  = 12;
    localparam integer CLK_HZ  = 100;
    localparam integer FREQ_HZ = 5;
    localparam integer OW_INT  = 15;
    localparam integer OW_OUT  = 13;
    localparam integer LAT_DUC = 9;
    localparam integer LAT_DDC = 10;
    localparam integer LAT     = LAT_DUC + LAT_DDC;   // 19
    localparam integer LO_DLY_DUC = 4;
    localparam integer LO_DLY_DDC = 23;   // 回环值 = 独立 DDC 的 14 + DUC 延迟 9

    localparam integer NSCEN   = 4;
    localparam integer NSAMP   = 512;
    localparam integer VEC_HEAD = 16;
    localparam integer VEC_WORDS = VEC_HEAD + 4 * NSCEN * NSAMP;

    reg clk = 0;
    reg rst_n = 0;
    reg signed [IW-1:0] i_in = 0, q_in = 0;

    always #5 clk = ~clk;

    // ── DUC ────────────────────────────────────────────────────────
    wire signed [OW_INT-1:0] i_e, i_o, q_e, q_o;

    duc_core #(
        .IW(IW), .CW(CW), .N_FIR(N_FIR), .N_HB(N_HB),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_FIR(13), .OW_MIX(14), .OW_INT(OW_INT),
        .SHIFT_FIR(15), .SHIFT_MIX(11), .SHIFT_INT(14),
        .ROUND(1), .LO_DLY(LO_DLY_DUC)
    ) u_duc (
        .clk(clk), .rst_n(rst_n),
        .i_in(i_in), .q_in(q_in),
        .i_e(i_e), .i_o(i_o), .q_e(q_e), .q_o(q_o)
    );

    // ── DDC（正确相位）────────────────────────────────────────────
    wire signed [OW_OUT-1:0] i_out, q_out;

    ddc_core #(
        .IW(OW_INT), .CW(CW), .N_DEC(N_HB), .N_FIR(N_FIR),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_DEC(16), .OW_MIX(17), .OW_FIR(18), .OW_OUT(OW_OUT),
        .SHIFT_DEC(15), .SHIFT_MIX(11), .SHIFT_FIR(15),
        .ROUND(1), .LO_DLY(LO_DLY_DDC)
    ) u_ddc (
        .clk(clk), .rst_n(rst_n),
        .i_e(i_e), .i_o(i_o), .q_e(q_e), .q_o(q_o),
        .i_out(i_out), .q_out(q_out)
    );

    // ── DDC（故意错相位，LO_DLY=0）────────────────────────────────
    wire signed [OW_OUT-1:0] bad_i, bad_q;

    ddc_core #(
        .IW(OW_INT), .CW(CW), .N_DEC(N_HB), .N_FIR(N_FIR),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .OW_DEC(16), .OW_MIX(17), .OW_FIR(18), .OW_OUT(OW_OUT),
        .SHIFT_DEC(15), .SHIFT_MIX(11), .SHIFT_FIR(15),
        .ROUND(1), .LO_DLY(0)
    ) u_ddc_bad (
        .clk(clk), .rst_n(rst_n),
        .i_e(i_e), .i_o(i_o), .q_e(q_e), .q_o(q_o),
        .i_out(bad_i), .q_out(bad_q)
    );

    reg [31:0] vec [0:VEC_WORDS-1];

    integer s, t, k, z, err, diffs;
    reg signed [31:0] ev, v0, v1;
    reg signed [OW_OUT-1:0] imp [0:80];
    integer first_nz, peak, peak_min;
    integer mag_min, mag_max, mag;
    integer sat_i, sat_q;

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
        reg signed [31:0] vi, vq, vo, vv;
        begin
            do_reset;
            bt = VEC_HEAD + scen * NSAMP * 4;
            ee = 0;
            for (tt = 0; tt < NSAMP + LAT; tt = tt + 1) begin
                @(negedge clk);
                if (tt < NSAMP) begin
                    vi = $signed(vec[bt + 4*tt + 0]);
                    vq = $signed(vec[bt + 4*tt + 1]);
                    i_in = vi[IW-1:0];
                    q_in = vq[IW-1:0];
                end else begin
                    i_in = {IW{1'b0}};
                    q_in = {IW{1'b0}};
                end
                if (tt >= LAT) begin
                    vo = $signed(vec[bt + 4*(tt-LAT) + 2]);
                    vv = $signed(vec[bt + 4*(tt-LAT) + 3]);
                    if (i_out !== vo[OW_OUT-1:0]) begin
                        if (ee < 3)
                            $display("    [mismatch] 场景 %0d n=%0d i_out got=%0d exp=%0d",
                                     scen, tt-LAT, i_out, vo);
                        ee = ee + 1;
                    end
                    if (q_out !== vv[OW_OUT-1:0]) ee = ee + 1;
                end
            end
            `check_eq("回环向量：本场景 512 个样本 × I/Q 逐位一致", ee, 0);
        end
    endtask

    initial begin
        $readmemh({`VECDIR, "loopback_vec.txt"}, vec);

        // ── 0. 自检 ─────────────────────────────────────────────────
        `check(vec[0] === 32'hD0C6D0C6, "向量文件哨兵正确（loopback_vec.txt 真的读进来了）");
        `check_eq("场景数 = 4", vec[1], NSCEN);
        `check_eq("每场景 512 样本", vec[2], NSAMP);
        `check_eq("数据行数 = 2048", vec[3], NSCEN*NSAMP);
        `check_eq("向量 IW = 12", vec[4], IW);
        `check_eq("向量 OW = 13", vec[5], OW_OUT);
        `check_eq("向量 LAT = 19（DUC 9 + DDC 10）", vec[14], LAT);
        `check_eq("向量 LO_DLY = 23（回环 DDC 侧 = 14 + DUC 9）", vec[15], LO_DLY_DDC);

        // ── 1. 复位 ─────────────────────────────────────────────────
        rst_n = 1'b0;
        i_in = 12'sd2047;
        q_in = -12'sd2048;
        repeat (5) @(posedge clk);
        `check_eq("复位期间 DDC i_out = 0", i_out, 0);
        `check_eq("复位期间 DDC q_out = 0", q_out, 0);

        do_reset;
        for (t = 0; t < 120; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
        end
        `check(i_out !== 0 || q_out !== 0, "运行中回环输出非零（下面才能测异步复位）");
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立即把回环 i_out 清零", i_out, 0);
        `check_eq("异步复位立即把回环 q_out 清零", q_out, 0);
        rst_n = 1'b1;
        @(negedge clk);

        // ── 2. 向量回放（4 个场景）──────────────────────────────────
        for (s = 0; s < NSCEN; s = s + 1)
            replay_case(s);

        // ── 3. step：DC 1000 进 → +998 / 0（相位对齐的硬判据）──────
        do_reset;
        for (t = 0; t < 400; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
        end
        `check(i_out >= 990 && i_out <= 1005,
               "回环 step：i_out = +998 附近（DC 增益 ≈ 1）");
        `check(q_out >= -3 && q_out <= 3,
               "回环 step：q_out ≈ 0（DDC 本振相位和 DUC 对齐）");

        // ── 4. tone：0.01 Fs 复单音 → 输出复单音幅度 ≈ 1000 ─────────
        mag_min = 1 << 30;
        mag_max = 0;
        do_reset;
        for (t = 0; t < 512 + LAT; t = t + 1) begin
            @(negedge clk);
            if (t < NSAMP) begin
                v0 = $signed(vec[VEC_HEAD + 2*NSAMP*4 + 4*t + 0]);
                v1 = $signed(vec[VEC_HEAD + 2*NSAMP*4 + 4*t + 1]);
                i_in = v0[IW-1:0];
                q_in = v1[IW-1:0];
            end else begin
                i_in = {IW{1'b0}};
                q_in = {IW{1'b0}};
            end
            if (t > 200 && t < 500) begin
                mag = i_out*i_out + q_out*q_out;
                if (mag < mag_min) mag_min = mag;
                if (mag > mag_max) mag_max = mag;
            end
        end
        `check(mag_min > 900*900 && mag_max < 1150*1150,
               "回环 tone：输出复单音幅度在 900..1150（整条链增益 ≈ 1）");
        `check(mag_max - mag_min < (mag_max / 3),
               "回环 tone：幅度基本恒定（max-min < max/3）");

        // ── 5. 冲激：回环冲激响应（形状 + 峰值 + 对称性）─────────────
        do_reset;
        for (t = 0; t < 120; t = t + 1) begin
            @(negedge clk);
            i_in = (t == 0) ? 12'sd2047 : 12'sd0;
            q_in = 12'sd0;
            if (t >= LAT && (t - LAT) <= 80)
                imp[t-LAT] = i_out;
        end
        first_nz = -1;
        for (k = 0; k <= 80; k = k + 1)
            if (first_nz < 0 && imp[k] != 0) first_nz = k;
        `check(first_nz > 40 && first_nz < 60,
               "回环冲激：第一个非零点在 40..60（FIR+半带的群延迟）");
        peak = 0;
        for (k = 0; k <= 80; k = k + 1)
            if (imp[k] > peak) peak = imp[k];
        peak_min = 0;
        for (k = 0; k <= 80; k = k + 1)
            if (imp[k] < peak_min) peak_min = imp[k];
        `check(peak > 300 && peak < 800,
               "回环冲激：正峰值在 300..800（两级 FIR + 半带的形状）");
        `check(peak_min < -100 && peak_min > -500,
               "回环冲激：负半边存在（不是只剩正峰）");

        // ── 6. 相位敏感：DDC 的 LO_DLY=0 必须和正确实例不同 ─────────
        diffs = 0;
        do_reset;
        for (t = 0; t < 400; t = t + 1) begin
            @(negedge clk);
            i_in = 12'sd1000;
            q_in = 12'sd0;
            if (t > 200 && i_out !== bad_i) diffs = diffs + 1;
        end
        `check(diffs > 50, "DDC LO_DLY=0 的实例和正确相位不同（回环向量能抓相位错）");

        // ── 7. 满幅随机不饱和：回环输出必须落在 13 位范围内 ─────────
        // 随机场景的向量回放已经逐位比过；这里再确认一下没有撞到 ±4095。
        sat_i = 0;
        sat_q = 0;
        do_reset;
        for (t = 0; t < NSAMP + LAT; t = t + 1) begin
            @(negedge clk);
            if (t < NSAMP) begin
                v0 = $signed(vec[VEC_HEAD + 3*NSAMP*4 + 4*t + 0]);
                v1 = $signed(vec[VEC_HEAD + 3*NSAMP*4 + 4*t + 1]);
                i_in = v0[IW-1:0];
                q_in = v1[IW-1:0];
            end else begin
                i_in = {IW{1'b0}};
                q_in = {IW{1'b0}};
            end
            if (i_out == 13'sd4095 || i_out == -13'sd4096) sat_i = sat_i + 1;
            if (q_out == 13'sd4095 || q_out == -13'sd4096) sat_q = sat_q + 1;
        end
        `check_eq("满幅随机：回环输出没有撞到 I 路饱和边界", sat_i, 0);
        `check_eq("满幅随机：回环输出没有撞到 Q 路饱和边界", sat_q, 0);

        tb_done;
    end

endmodule
