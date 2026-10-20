`timescale 1ns/1ps
//=============================================================================
// duc_core — 数字上变频器（DUC）的算法本体
//-----------------------------------------------------------------------------
// 功能（s05 定案的顺序）：
//
//   符号 I/Q ──► FIR 成型 ──► 复数混频（上变频）──► 2× 半带插值 ──► 两相并行
//   (Fs, 12b)    (13b)        (NCO @ f_lo, 14b)      (2Fs, 15b)      i_e/i_o
//                                                                     q_e/q_o
//
// 为什么 FIR 在混频之前（这一段是 s05 集成时改正的旧猜测）
//-----------------------------------------------------------------------------
//   s03 的 TASK 里写过"DUC 里 FIR 在混频之后、插值之前"。那是**没集成时的猜测**：
//   当时只想着"混频把频谱搬到 IF，再用低通把带外切掉"。真接起来会发现两件事：
//
//   ① 成型滤波必须在**基带**做。混频之后再低通，滤波器响应是 H(f) 而不是
//      H(f-f_lo) —— 它会在 f_lo 附近按低通的过渡带去削信号，而不是按设计时
//      看到的那条平坦通带。f_lo 取得很低（0.05 Fs）时"看起来还行"，
//      但那不是 DUC 的通用做法，换一个 IF 就露馅。
//   ② 标准 DUC 的顺序是：**成型（基带）→ 上变频 → 插值**。插值滤波器
//      （半带）是低通，正好把混频后的镜像/高频分量挡在 DAC 之前。
//      本设计 f_lo = 0.05 Fs、信号 0.01 Fs，混频后落在 0.06 Fs，
//      远在半带通带 [0, 0.4 Fs] 之内，所以"先混频再插值"是安全的。
//
//   代价：混频器工作在 Fs（不是 2Fs），所以只要一个复数混频器（4 个乘法器），
//   不需要在 2Fs 上再做一次混频。这是有意的取舍，也把"低 IF"这个约束
//   明确写在参数里：**f_lo 必须落在 FIR 通带内，且 f_lo + 信号带宽 < 0.10 Fs**。
//
// 位宽链（详见 TASK_s05_duc.md 的增益预算表）
//-----------------------------------------------------------------------------
//   符号 IW=12（±2047）
//   FIR  OW_FIR=13：单位直流增益，输出仍是 ±2047（13 位留 1 位余量）
//   mixer OW_MIX=14：本振 AW=12、SHIFT=11 → 增益 2047/2048 ≈ 1.0；
//                    I/Q 同时满幅时单路最大约 4092，14 位刚好够（±8191）
//   interp OW_INT=15：半带插值补 ×2、偶相 0.5，整体单位增益；
//                    输出 ±2047，15 位留了很大余量（给以后换增益 >1 的成型滤波器）
//
// NCO 相位对齐（最容易错的一步）
//-----------------------------------------------------------------------------
//   FIR 有 4 拍流水，NCO 自己也有 1 拍输出寄存器，所以 LO 不能直接接过来：
//   直接接会让 y[n] 乘上 lo[n+3] 附近的值 —— 频率完全正确，但整条链的相位
//   整体旋转一个常数。**"频率对"和"相位对"是两件事**，这是集成时最值得
//   亲手改坏一次的地方（把 LO_DLY 改成 0，tb_duc_core 的向量回放会红一大片，
//   但用 ILA 看频率/幅度几乎看不出来）。
//
//   ⚠️ 精确的拍数不要在这里手推：Verilog 的 always 块读的是**时钟沿之前**的
//   值（非阻塞赋值），"模块延迟 4 拍"和"链路上实际晚几拍"差一个 handoff。
//   本文件的 LO_DLY 默认值 4 是用 tb_duc_core 的逐位向量标定出来的
//   （见 scripts/gen_duc_ddc_vec.py 的 LAT_DUC / LO_DLY_DUC）。
//   换 FIR 抽头数 / 流水级数时，这个值要跟着重标 —— 向量 TB 会直接告诉你。
//
// 时钟域：clk（Fs）。
// 延迟：  输入样本 n → y_o 在 **n+9** 拍出现（FIR 4 + mixer 1 + interp 4）；
//         y_e 的源是插值延迟线 dly[15]，所以是同一输出下标 n 的偶相，
//         端到端从输入样本算还要再加 15 个输入样本（半带群延迟）。
// 复位值：所有延迟线 / 流水寄存器 / 输出 = 0。
//=============================================================================

module duc_core #(
    parameter integer IW          = 12,           // 输入符号位宽（补码）
    parameter integer CW          = 16,           // FIR / 半带系数位宽（Q1.15）
    parameter integer N_FIR       = 47,           // 成型 FIR 抽头数
    parameter integer N_HB        = 61,           // 半带总抽头数（4q+1）
    parameter integer AW          = 12,           // NCO 幅度位宽
    parameter integer PHASE_W     = 32,           // NCO 相位累加器位宽
    parameter integer LUT_AW      = 12,           // NCO 查表地址位宽
    parameter integer CLK_HZ      = 50_000_000,   // 输入时钟频率（NCO 用）
    parameter integer FREQ_HZ     = 2_500_000,    // 本振频率（低 IF，0.05 Fs）
    parameter integer OW_FIR      = IW + 1,       // FIR 输出位宽（13）
    parameter integer OW_MIX      = OW_FIR + 1,   // 混频输出位宽（14）
    parameter integer OW_INT      = OW_MIX + 1,   // 插值输出位宽（15）
    parameter integer SHIFT_FIR   = CW - 1,       // FIR 右移（15）
    parameter integer SHIFT_MIX   = AW - 1,       // 混频右移（11，单位增益）
    parameter integer SHIFT_INT   = CW - 2,       // 插值右移（14：零插值补 ×2）
    parameter integer ROUND       = 1,            // 1 = 四舍五入
    parameter integer LO_DLY      = 4,            // 本振相对 FIR 输出的延迟（拍）
    parameter         COEF_FILE_FIR = "coef.mem", // 成型 FIR 系数
    parameter         COEF_FILE_HB  = "hb_odd.mem"// 半带奇数抽头
)(
    input  wire                 clk,
    input  wire                 rst_n,            // 异步复位，低有效
    input  wire signed [IW-1:0] i_in,             // 同相符号
    input  wire signed [IW-1:0] q_in,             // 正交符号
    output wire signed [OW_INT-1:0] i_e,          // I 路偶相 y[2n]（2Fs）
    output wire signed [OW_INT-1:0] i_o,          // I 路奇相 y[2n+1]
    output wire signed [OW_INT-1:0] q_e,          // Q 路偶相
    output wire signed [OW_INT-1:0] q_o           // Q 路奇相
);

    // ── ① 成型滤波（基带）────────────────────────────────────────────
    // 两个 FIR 共用一张 coef.mem，但各自有独立的延迟线和流水线。
    wire signed [OW_FIR-1:0] fir_i, fir_q;

    fir #(
        .IW(IW), .CW(CW), .N(N_FIR), .OW(OW_FIR),
        .SHIFT(SHIFT_FIR), .ROUND(ROUND), .COEF_FILE(COEF_FILE_FIR)
    ) u_fir_i (
        .clk(clk), .rst_n(rst_n), .x_in(i_in), .y_out(fir_i)
    );

    fir #(
        .IW(IW), .CW(CW), .N(N_FIR), .OW(OW_FIR),
        .SHIFT(SHIFT_FIR), .ROUND(ROUND), .COEF_FILE(COEF_FILE_FIR)
    ) u_fir_q (
        .clk(clk), .rst_n(rst_n), .x_in(q_in), .y_out(fir_q)
    );

    // ── ② 本振（NCO）+ 相位延迟 ──────────────────────────────────────
    // NCO 输出的是**连续**的 cos/sin；每拍一个相位点，和符号率 Fs 同步。
    wire signed [AW-1:0] lo_sin, lo_cos;

    nco #(
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ),
        .PHASE_W(PHASE_W), .LUT_AW(LUT_AW), .AW(AW)
    ) u_nco (
        .clk(clk), .rst_n(rst_n), .fsin_o(lo_sin), .fcos_o(lo_cos)
    );

    // LO_DLY 级延迟线：把"当前拍的本振"延迟到"FIR 输出样本所在的那一拍"。
    // 复位值 0 —— 所以复位后最初几拍的混频输出是 0，这是**故意**的：
    // 它让"复位期间输出必须为 0"这条验收在整条链上仍然成立。
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

    // ── ③ 复数混频（上变频，CONJ=0）───────────────────────────────────
    wire signed [OW_MIX-1:0] mix_i, mix_q;

    mixer #(
        .IW(OW_FIR), .AW(AW), .OW(OW_MIX),
        .SHIFT(SHIFT_MIX), .ROUND(ROUND), .CONJ(0)
    ) u_mixer (
        .clk(clk), .rst_n(rst_n),
        .i_in(fir_i), .q_in(fir_q),
        .cos_in(lo_cos_d), .sin_in(lo_sin_d),
        .i_out(mix_i), .q_out(mix_q)
    );

    // ── ④ 2× 半带插值（I/Q 各一路，两相输出）──────────────────────────
    // ⚠️ 这里 interp2 的 IW 必须是 OW_MIX=14，不能沿用 12/13 ——
    //    s04 的 TASK 里已经踩过一次"级联时中间结果截回 12 位"。
    //    多相接口的位宽衔接是 s05 增益预算的第一道题。
    interp2 #(
        .IW(OW_MIX), .CW(CW), .N(N_HB), .OW(OW_INT),
        .SHIFT(SHIFT_INT), .ROUND(ROUND), .COEF_FILE(COEF_FILE_HB)
    ) u_int_i (
        .clk(clk), .rst_n(rst_n), .x_in(mix_i),
        .y_e(i_e), .y_o(i_o)
    );

    interp2 #(
        .IW(OW_MIX), .CW(CW), .N(N_HB), .OW(OW_INT),
        .SHIFT(SHIFT_INT), .ROUND(ROUND), .COEF_FILE(COEF_FILE_HB)
    ) u_int_q (
        .clk(clk), .rst_n(rst_n), .x_in(mix_q),
        .y_e(q_e), .y_o(q_o)
    );

endmodule
