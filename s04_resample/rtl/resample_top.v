`timescale 1ns/1ps
//=============================================================================
// resample_top — s04_resample 的板级顶层（实验台：冲激 → 插值 → 抽取 → LED/ILA）
//-----------------------------------------------------------------------------
// 和 s03 的 fir_top 一样，这个顶层**不是** DUC 的一部分，是"实验台器材"：
//
//   · 每 IMP_PERIOD 个时钟发一个单点冲激（幅度 2047，宽度 1 拍）
//   · 冲激先进 interp2，看两相输出：
//         y_e：输出下标 15 处原样出现（半带偶相 = 纯延迟，0 个乘法器）；
//              从冲激采样沿算 +18（ILA 第 19 个采样点）
//         y_o：30 个点的奇相冲激响应，峰值 1298，关于 k=14.5 对称
//   · 再把 (y_e, y_o) 串进 decim2，还原成 Fs：整条链的冲激响应 43 个点、
//     峰值 1991、关于第 30 点对称（ILA 上峰值在 +37，即第 38 个采样点）—— 这一条
//     同时证明了相位对齐和位宽衔接。
//
// 为什么用冲激而不是正弦：
//   冲激响应能**逐点**和 lut/hb_odd.mem 对账，比"看正弦被滤小了"硬得多。
//   想看在板子上"插值出两倍采样"的效果，可以喂正弦后看两相波形，
//   但判据会变成"看起来像"，不如逐点对账。
//
// 时钟域：clk
// 延迟：  流水延迟 4 拍（y_e/y_o）和 8 拍（y_rt），**不含半带群延迟**。
//         端到端（从冲激采样沿算）：y_o **+3**、y_e **+18**；y_rt 峰值 **+37**
//         （ILA 第 38 个采样点）。别把"输出下标 k"直接当触发后点数。
// 复位：  外部 rst_n 先过 reset_sync（异步拉低、同步释放 2 拍）
// LED：   四颗灯接同一个 1 Hz 心跳（四颗都已被硬件反证过，见 XDC）
//=============================================================================

module resample_top #(
    parameter integer CLK_HZ     = 50_000_000, // 输入时钟频率（和 XDC 的 20 ns 对应）
    parameter integer HEART_HZ   = 1,          // LED 心跳频率（Hz，必须 >0）
    parameter integer IMP_PERIOD = 1024,       // 每隔多少个时钟发一个冲激（2..65535）
    parameter integer IW         = 12,         // 输入位宽
    parameter integer CW         = 16,         // 系数位宽
    parameter integer N          = 61,         // 半带抽头数（4q+1）
    parameter integer OW_INT     = IW + 1,     // 插值输出位宽
    parameter integer OW_RT      = IW + 2,     // 级联输出位宽
    parameter integer SHIFT_I    = CW - 2,     // 插值右移（CW-2）
    parameter integer SHIFT_D    = CW - 1,     // 抽取右移（CW-1）
    parameter integer ROUND      = 1
)(
    input  wire       clk,
    input  wire       rst_n,                   // 外部按键，低有效
    output wire [3:0] led
);

    // ── 复位同步（异步复位、同步释放）────────────────────────────────
    wire rst_sync_n;
    reset_sync u_reset_sync (
        .clk   (clk),
        .arst_n(rst_n),
        .rst_n (rst_sync_n)
    );

    // ── 心跳分频 ────────────────────────────────────────────────────
    // 半周期 = CLK_HZ / (2*HEART_HZ)。用 64 位算，避免参数大时溢出。
    localparam [63:0] HB_HALF_64 = (64'd1 * CLK_HZ) / (2 * HEART_HZ);
    localparam integer HB_HALF   = (HB_HALF_64 < 1) ? 1 : HB_HALF_64[31:0];

    reg [31:0] hb_cnt;
    reg        hb;
    always @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n) begin
            hb_cnt <= 32'd0;
            hb     <= 1'b0;
        end else if (hb_cnt >= HB_HALF - 1) begin
            hb_cnt <= 32'd0;
            hb     <= ~hb;
        end else begin
            hb_cnt <= hb_cnt + 32'd1;
        end
    end

    // ── 冲激发生器 ──────────────────────────────────────────────────
    reg [15:0] imp_cnt;
    wire       imp;
    assign imp = rst_sync_n && (imp_cnt == 16'd0);

    always @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n)
            imp_cnt <= 16'd0;
        else if (imp_cnt >= IMP_PERIOD - 1)
            imp_cnt <= 16'd0;
        else
            imp_cnt <= imp_cnt + 16'd1;
    end

    // 幅度 = IW 位补码最大正值（默认 IW=12 → 2047）
    wire signed [IW-1:0] x_in = imp ? {1'b0, {(IW-1){1'b1}}} : {IW{1'b0}};

    // ── 插值（1 进 2 出）────────────────────────────────────────────
    wire signed [OW_INT-1:0] y_e, y_o;

    interp2 #(
        .IW(IW), .CW(CW), .N(N), .OW(OW_INT),
        .SHIFT(SHIFT_I), .ROUND(ROUND)
    ) u_interp (
        .clk  (clk),
        .rst_n(rst_sync_n),
        .x_in (x_in),
        .y_e  (y_e),
        .y_o  (y_o)
    );

    // ── 抽取（2 进 1 出）────────────────────────────────────────────
    // ⚠️ IW 必须是插值的 OW_INT（默认 13），不能沿用 12。
    wire signed [OW_RT-1:0] y_rt;

    decim2 #(
        .IW(OW_INT), .CW(CW), .N(N), .OW(OW_RT),
        .SHIFT(SHIFT_D), .ROUND(ROUND)
    ) u_decim (
        .clk  (clk),
        .rst_n(rst_sync_n),
        .x_e  (y_e),
        .x_o  (y_o),
        .y_out(y_rt)
    );

    // ── ILA 探针 ────────────────────────────────────────────────────
    // mark_debug 让 Set up Debug 能列出这四个信号；keep 防止综合优化掉。
    // 总位宽 1 + 13 + 13 + 14 = 41 位；深度 8192 时约 9~10 块 RAMB36，
    // 比 s03（8192×14 位 ≈ 3.5 块）大不少 —— 位宽涨了 3 倍。
    (* mark_debug = "true", keep = "true" *) wire imp_dbg = imp;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_INT-1:0] ye_dbg  = y_e;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_INT-1:0] yo_dbg  = y_o;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_RT-1:0]  yrt_dbg = y_rt;

    // ── LED ─────────────────────────────────────────────────────────
    assign led = {4{hb}};

endmodule
