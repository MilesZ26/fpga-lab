`timescale 1ns/1ps
//=============================================================================
// ddc_core — 数字下变频器（DDC）的算法本体
//-----------------------------------------------------------------------------
// 功能（DUC 的严格逆序，s06 定案）：
//
//   两相 I/Q ──► 2× 半带抽取 ──► 复数混频（下变频）──► FIR 信道滤波 ──► 符号
//   (2Fs, 15b)   (16b)           (NCO @ f_lo, 17b)      (18b)          (13b)
//
// 为什么是这个顺序
//-----------------------------------------------------------------------------
//   DUC 是 "成型 FIR → 上变频 → 插值"，所以 DDC 反过来：
//   "抽取 → 下变频 → 信道 FIR"。
//
//   · 先抽取：ADC 在 2Fs 上给两相，先降到 Fs，后面所有运算（混频、信道滤波）
//     都在低速率上做，省资源。半带滤波器本身就是抗混叠滤波器。
//   · 再下变频：把低 IF（f_lo = 0.05 Fs）搬回 0。
//   · 最后信道滤波：在基带上做低通，滤掉混频产生的高频分量和带外噪声。
//     这一步在**基带**做，滤波器响应才是设计时看到的那条低通曲线。
//
//   这和 s03 TASK 里"DDC 里顺序反过来"的旧说法一致（旧说法只说了"反过来"，
//   没写清反成什么样；s05/s06 把顺序钉死并写进文档）。
//
// 为什么 DDC 混频器的 LO 要延迟 14 拍
//-----------------------------------------------------------------------------
//   DUC 混频器在样本 n 上乘的是 lo[n]。这个样本经过 interp / decim 之后
//   到达 DDC 混频器；功能模型里，DDC 抽取输出 w[n] 携带的载波相位是 **lo[n-10]**。
//
//   ⚠️ 10 不是半带的群延迟 15，而是**相位延迟**：群延迟描述"包络晚多少"，
//   相位延迟描述"载波转了多少"。f_lo=0.05 Fs 的窄带上两者不是同一个数。
//   判别方法很直接（tb_ddc_core 的 step 场景）：DC 1000 混上去再混下来，
//   LO 下标取 10 → +1000/0；取 15 → 0/+1000（差 90°）；取 20 → -1000/0（差 180°）。
//
//   RTL 的 LO_DLY = 10 + 4 = 14。那个 +4 和 DUC 的 LO_DLY=4 是**同一个**
//   混频器 handoff 常数（DUC 模型下标 0 → RTL 4）—— 非阻塞赋值让"模块延迟"
//   和"链路上实际晚几拍"差一个沿前的采样。所以 DUC/DDC 两个核的 LO_DLY
//   标定规则是一致的：**RTL LO_DLY = 模型里需要的 LO 下标 + 4**。
//
//   **改 LO_DLY 只旋转相位，不改频率**；回环 TB 会直接抓出来。
//   详见 scripts/gen_duc_ddc_vec.py 的 LO_IDX_DDC / LO_DLY_DDC。
//
// 位宽链
//-----------------------------------------------------------------------------
//   输入 15（DUC 插值输出）→ decim 16 → mixer 17 → FIR 18 → 输出饱和 13。
//   DUC 的 12 位符号经过整条链后回到 13 位（多 1 位余量），单位增益。
//   如果中间任何一级截回 12 位，回环误差会明显变大 —— TB 的逐位比对会红。
//
// 时钟域：clk（Fs）。
// 延迟：  输入两相 n → 输出在 **n+10** 拍（decim 4 + mixer 1 + FIR 4 + 1 handoff）；
//         信道 FIR 还有 23 个样本群延迟，体现在输出波形的形状上，不在拍数里。
// 复位值：所有延迟线 / 流水寄存器 / 输出 = 0。
//=============================================================================

module ddc_core #(
    parameter integer IW          = 15,           // 输入位宽（DUC 插值输出）
    parameter integer CW          = 16,           // FIR / 半带系数位宽（Q1.15）
    parameter integer N_DEC       = 61,           // 半带总抽头数（4q+1）
    parameter integer N_FIR       = 47,           // 信道 FIR 抽头数
    parameter integer AW          = 12,           // NCO 幅度位宽
    parameter integer PHASE_W     = 32,           // NCO 相位累加器位宽
    parameter integer LUT_AW      = 12,           // NCO 查表地址位宽
    parameter integer CLK_HZ      = 50_000_000,   // 输入时钟频率（NCO 用）
    parameter integer FREQ_HZ     = 2_500_000,    // 本振频率（和 DUC 同一个 f_lo）
    parameter integer OW_DEC      = IW + 1,       // 抽取输出位宽（16）
    parameter integer OW_MIX      = OW_DEC + 1,   // 混频输出位宽（17）
    parameter integer OW_FIR      = OW_MIX + 1,   // FIR 输出位宽（18）
    parameter integer OW_OUT      = 13,           // 最终输出位宽（13）
    parameter integer SHIFT_DEC   = CW - 1,       // 抽取右移（15）
    parameter integer SHIFT_MIX   = AW - 1,       // 混频右移（11）
    parameter integer SHIFT_FIR   = CW - 1,       // 信道 FIR 右移（15）
    parameter integer ROUND       = 1,            // 1 = 四舍五入
    parameter integer LO_DLY      = 14,           // 本振延迟（= LO 下标 10 + handoff 4）
    parameter         COEF_FILE_DEC = "hb_odd.mem",// 半带奇数抽头
    parameter         COEF_FILE_FIR = "coef.mem"   // 信道 FIR 系数
)(
    input  wire                 clk,
    input  wire                 rst_n,            // 异步复位，低有效
    input  wire signed [IW-1:0] i_e,              // I 路偶相 u[2n]
    input  wire signed [IW-1:0] i_o,              // I 路奇相 u[2n+1]
    input  wire signed [IW-1:0] q_e,              // Q 路偶相
    input  wire signed [IW-1:0] q_o,              // Q 路奇相
    output reg  signed [OW_OUT-1:0] i_out,        // 恢复的 I 符号
    output reg  signed [OW_OUT-1:0] q_out         // 恢复的 Q 符号
);

    // ── ① 2× 半带抽取（I/Q 各一路）────────────────────────────────────
    // ⚠️ 这里的名字是 x_e/x_o，不是"偶相/奇相输出"——decim2 的接口就是
    //    "一对相邻采样进、一个低速率采样出"。
    wire signed [OW_DEC-1:0] dec_i, dec_q;

    decim2 #(
        .IW(IW), .CW(CW), .N(N_DEC), .OW(OW_DEC),
        .SHIFT(SHIFT_DEC), .ROUND(ROUND), .COEF_FILE(COEF_FILE_DEC)
    ) u_dec_i (
        .clk(clk), .rst_n(rst_n),
        .x_e(i_e), .x_o(i_o), .y_out(dec_i)
    );

    decim2 #(
        .IW(IW), .CW(CW), .N(N_DEC), .OW(OW_DEC),
        .SHIFT(SHIFT_DEC), .ROUND(ROUND), .COEF_FILE(COEF_FILE_DEC)
    ) u_dec_q (
        .clk(clk), .rst_n(rst_n),
        .x_e(q_e), .x_o(q_o), .y_out(dec_q)
    );

    // ── ② 本振（NCO）+ 相位延迟 ──────────────────────────────────────
    wire signed [AW-1:0] lo_sin, lo_cos;

    nco #(
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .PHASE_W(PHASE_W), .LUT_AW(LUT_AW), .AW(AW)
    ) u_nco (
        .clk(clk), .rst_n(rst_n), .fsin_o(lo_sin), .fcos_o(lo_cos)
    );

    wire signed [AW-1:0] lo_sin_d, lo_cos_d;

    generate
        if (LO_DLY == 0) begin : g_lo_bypass
            assign lo_sin_d = lo_sin;
            assign lo_cos_d = lo_cos;
        end else begin : g_lo_dly
            reg signed [AW-1:0] sin_dly [0:LO_DLY-1];
            reg signed [AW-1:0] cos_dly [0:LO_DLY-1];
            integer di;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (di = 0; di < LO_DLY; di = di + 1) begin
                        sin_dly[di] <= {AW{1'b0}};
                        cos_dly[di] <= {AW{1'b0}};
                    end
                end else begin
                    sin_dly[0] <= lo_sin;
                    cos_dly[0] <= lo_cos;
                    for (di = 1; di < LO_DLY; di = di + 1) begin
                        sin_dly[di] <= sin_dly[di-1];
                        cos_dly[di] <= cos_dly[di-1];
                    end
                end
            end

            assign lo_sin_d = sin_dly[LO_DLY-1];
            assign lo_cos_d = cos_dly[LO_DLY-1];
        end
    endgenerate

    // ── ③ 复数混频（下变频，CONJ=1）───────────────────────────────────
    // CONJ=1 就是乘 e^{-j phi}：i*cos + q*sin, q*cos - i*sin。
    // ⚠️ 是"两路都翻"，不是只翻 Q 路 —— s02 的第一版就栽在这里（见学习备忘 10）。
    wire signed [OW_MIX-1:0] mix_i, mix_q;

    mixer #(
        .IW(OW_DEC), .AW(AW), .OW(OW_MIX),
        .SHIFT(SHIFT_MIX), .ROUND(ROUND), .CONJ(1)
    ) u_mixer (
        .clk(clk), .rst_n(rst_n),
        .i_in(dec_i), .q_in(dec_q),
        .cos_in(lo_cos_d), .sin_in(lo_sin_d),
        .i_out(mix_i), .q_out(mix_q)
    );

    // ── ④ 基带信道 FIR（I/Q 各一路）───────────────────────────────────
    wire signed [OW_FIR-1:0] fir_i, fir_q;

    fir #(
        .IW(OW_MIX), .CW(CW), .N(N_FIR), .OW(OW_FIR),
        .SHIFT(SHIFT_FIR), .ROUND(ROUND), .COEF_FILE(COEF_FILE_FIR)
    ) u_fir_i (
        .clk(clk), .rst_n(rst_n), .x_in(mix_i), .y_out(fir_i)
    );

    fir #(
        .IW(OW_MIX), .CW(CW), .N(N_FIR), .OW(OW_FIR),
        .SHIFT(SHIFT_FIR), .ROUND(ROUND), .COEF_FILE(COEF_FILE_FIR)
    ) u_fir_q (
        .clk(clk), .rst_n(rst_n), .x_in(mix_q), .y_out(fir_q)
    );

    // ── ⑤ 输出饱和到 OW_OUT（不回绕）──────────────────────────────────
    // 单位增益下输出约 ±2047，13 位（±4095）绰绰有余。饱和是为了"万一"
    // （比如换一组增益 >1 的滤波器）：回绕会把最大正数变成最大负数，
    // 波形上突然翻符号 —— 这是定点设计里最经典的一类事故。
    localparam signed [OW_FIR-1:0] OUT_MAX = (64'sd1 <<< (OW_OUT-1)) - 1;
    localparam signed [OW_FIR-1:0] OUT_MIN = -(64'sd1 <<< (OW_OUT-1));

    function signed [OW_OUT-1:0] sat_out;
        input signed [OW_FIR-1:0] v;
        begin
            if (v > OUT_MAX)
                sat_out = OUT_MAX[OW_OUT-1:0];
            else if (v < OUT_MIN)
                sat_out = OUT_MIN[OW_OUT-1:0];
            else
                sat_out = v[OW_OUT-1:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_out <= {OW_OUT{1'b0}};
            q_out <= {OW_OUT{1'b0}};
        end else begin
            i_out <= sat_out(fir_i);
            q_out <= sat_out(fir_q);
        end
    end

endmodule
