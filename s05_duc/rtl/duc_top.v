`timescale 1ns/1ps
//=============================================================================
// duc_top — s05 的板级顶层（实验台：复单音 → DUC → 四相 I/Q + ILA）
//-----------------------------------------------------------------------------
// 这个顶层**不是** DUC 算法的一部分，是"实验台器材"：
//
//   · tone_nco 产生一个 0.01 Fs 的复单音 (I=cos, Q=sin)，当 DUC 的输入符号；
//   · DUC 把它搬到 f_lo = 0.05 Fs（低 IF），再 2× 插值成两相 I/Q；
//   · ILA 看 6 组探针：输入单音、输出四相（i_e/i_o/q_e/q_o）。
//
// 为什么用单音而不是冲激：
//   单音能直接看"频率搬移"和"两相正交"，人眼/ILA 都容易判；冲激响应
//   已经在 tb_duc_core 里逐位对过，板上不必重复。想看向量逐位，用仿真。
//
// 为什么板上不做 2:1 并串：
//   真正的 1 路 DAC 需要 2Fs 的时钟（或 DDR），而达芬奇 Pro 的板载晶振是
//   50 MHz，没有现成的 100 MHz 时钟；要做得先例化 MMCM，属于"接 DAC"那一步。
//   本 stage 的判据是**并行的四相数据**（ILA 只能采 clk 上升沿，看不到 DDR
//   的下降沿数据），所以这里只把四相引到 ILA；serializer2 的 2:1 并串
//   在 tb_serializer2.v 里逐拍验过，等有 DAC/2 倍时钟时再接。
//
// 时钟域：clk（Fs=50 MHz）。
// 复位：  外部 rst_n 先过 reset_sync（异步拉低、同步释放 2 拍）。
// LED：   四颗灯接同一个 1 Hz 心跳（四颗都已被硬件反证过，见 XDC）。
//=============================================================================

module duc_top #(
    parameter integer CLK_HZ    = 50_000_000, // 输入时钟频率（和 XDC 的 20 ns 对应）
    parameter integer HEART_HZ  = 1,          // LED 心跳频率（Hz，必须 >0）
    parameter integer FREQ_SIG  = 500_000,    // 测试单音 = 0.01 Fs
    parameter integer FREQ_LO   = 2_500_000,  // 本振 = 0.05 Fs（低 IF）
    parameter integer PHASE_W   = 32,
    parameter integer LUT_AW    = 12,
    parameter integer AW        = 12,
    parameter integer IW        = 12,
    parameter integer CW        = 16,
    parameter integer N_FIR     = 47,
    parameter integer N_HB      = 61,
    parameter integer OW_INT    = 15,
    parameter integer LO_DLY    = 4
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
    localparam [63:0] HB_HALF_64 = (64'd1 * CLK_HZ) / (64'd2 * HEART_HZ);
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

    // ── 测试单音（复指数）──────────────────────────────────────────
    // 0.01 Fs 的正/余弦，12 位补码。tone_i = cos, tone_q = sin。
    wire signed [AW-1:0] tone_i, tone_q;

    nco #(
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_SIG),
        .PHASE_W(PHASE_W), .LUT_AW(LUT_AW), .AW(AW)
    ) u_tone_nco (
        .clk(clk), .rst_n(rst_sync_n),
        .fsin_o(tone_q), .fcos_o(tone_i)
    );

    // ── DUC 本体 ────────────────────────────────────────────────────
    wire signed [OW_INT-1:0] i_e, i_o, q_e, q_o;

    duc_core #(
        .IW(IW), .CW(CW), .N_FIR(N_FIR), .N_HB(N_HB),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_LO),
        .OW_FIR(IW+1), .OW_MIX(IW+2), .OW_INT(OW_INT),
        .SHIFT_FIR(CW-1), .SHIFT_MIX(AW-1), .SHIFT_INT(CW-2),
        .ROUND(1), .LO_DLY(LO_DLY)
    ) u_duc (
        .clk(clk), .rst_n(rst_sync_n),
        .i_in(tone_i), .q_in(tone_q),
        .i_e(i_e), .i_o(i_o), .q_e(q_e), .q_o(q_o)
    );

    // ── ILA 探针 ────────────────────────────────────────────────────
    // 6 组 × 12/15 位 = 84 位；深度 4096 时约 8~9 块 RAMB36。
    // 触发建议：tone_i[11]（单音的符号位）上升沿，或 i_e[14] 的某个沿。
    (* mark_debug = "true", keep = "true" *) wire signed [AW-1:0]     tone_i_dbg = tone_i;
    (* mark_debug = "true", keep = "true" *) wire signed [AW-1:0]     tone_q_dbg = tone_q;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_INT-1:0] ie_dbg     = i_e;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_INT-1:0] io_dbg     = i_o;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_INT-1:0] qe_dbg     = q_e;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_INT-1:0] qo_dbg     = q_o;

    // ── LED ─────────────────────────────────────────────────────────
    assign led = {4{hb}};

endmodule
