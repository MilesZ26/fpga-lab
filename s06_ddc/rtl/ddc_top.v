`timescale 1ns/1ps
//=============================================================================
// ddc_top — s06 的板级顶层（DUC → DDC 数字回环 + ILA + 活动指示）
//-----------------------------------------------------------------------------
// 这个顶层是 s06 的"合龙"实验台：
//
//   tone_nco (0.01 Fs) ──► DUC ──► 四相 I/Q (2Fs) ──► DDC ──► 恢复的 I/Q
//                                                      ▲
//                                            LO_DLY=23（回环值）
//
//   板上没有 ADC/DAC，所以回环是**数字**的：DUC 的并行四相直接接 DDC 的
//   四相输入。这正好把 s05/s06 的接口、位宽、相位、延迟全部串起来；
//   ILA 同时看 DUC 输出和 DDC 输出，能一眼看出"搬上去再搬下来"是否回到
//   原来的 0.01 Fs 单音。
//
// 为什么 DDC 的 LO_DLY 是 23，不是独立 DDC 的 14：
//   LO 延迟是"相对数据到达时刻"的。独立 DDC 的输入在 t 拍就到，所以 14 拍；
//   回环里 DUC 的输出比输入晚 9 拍才到 DDC，所以 DDC 的本振要再多等 9 拍：
//   14 + 9 = 23。**同一个 DDC 核，接在不同位置就要用不同的 LO_DLY** ——
//   这是集成阶段最容易被忽略的一课。tb_duc_ddc_loopback 会抓这个错。
//
// LED：
//   led[0] = DDC 输出有活动（回环通了）
//   led[1] = DUC 输出有活动（插值有数据）
//   led[3:2] = 1 Hz 心跳
//   活动指示用"泄漏计数器"：有信号就 +1，没信号就 -1，计数到一半以上点亮。
//   这样单音过零时不会闪，只有真的持续有数据才亮。
//
// 时钟域：clk（Fs=50 MHz）。复位：reset_sync。
//=============================================================================

module ddc_top #(
    parameter integer CLK_HZ     = 50_000_000,
    parameter integer HEART_HZ   = 1,
    parameter integer FREQ_SIG   = 500_000,    // 测试单音 = 0.01 Fs
    parameter integer FREQ_LO    = 2_500_000,  // 本振 = 0.05 Fs
    parameter integer PHASE_W    = 32,
    parameter integer LUT_AW     = 12,
    parameter integer AW         = 12,
    parameter integer IW         = 12,
    parameter integer CW         = 16,
    parameter integer N_FIR      = 47,
    parameter integer N_HB       = 61,
    parameter integer OW_DUC     = 15,
    parameter integer OW_DDC     = 13,
    parameter integer LO_DLY_DUC = 4,
    parameter integer LO_DLY_DDC = 23,          // 回环值 = 独立 14 + DUC 9
    parameter integer ACT_W      = 16,          // 活动计数器位宽（板上 16；仿真可调小）
    parameter integer ACT_THRESH = 16           // 活动判定阈值（LSB）
)(
    input  wire       clk,
    input  wire       rst_n,
    output wire [3:0] led
);

    // ── 复位同步 ────────────────────────────────────────────────────
    wire rst_sync_n;
    reset_sync u_reset_sync (
        .clk   (clk),
        .arst_n(rst_n),
        .rst_n (rst_sync_n)
    );

    // ── 心跳 ────────────────────────────────────────────────────────
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

    // ── 测试单音 ────────────────────────────────────────────────────
    wire signed [AW-1:0] tone_i, tone_q;

    nco #(
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_SIG),
        .PHASE_W(PHASE_W), .LUT_AW(LUT_AW), .AW(AW)
    ) u_tone_nco (
        .clk(clk), .rst_n(rst_sync_n),
        .fsin_o(tone_q), .fcos_o(tone_i)
    );

    // ── DUC ─────────────────────────────────────────────────────────
    wire signed [OW_DUC-1:0] ie, io, qe, qo;

    duc_core #(
        .IW(IW), .CW(CW), .N_FIR(N_FIR), .N_HB(N_HB),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_LO),
        .OW_FIR(IW+1), .OW_MIX(IW+2), .OW_INT(OW_DUC),
        .SHIFT_FIR(CW-1), .SHIFT_MIX(AW-1), .SHIFT_INT(CW-2),
        .ROUND(1), .LO_DLY(LO_DLY_DUC)
    ) u_duc (
        .clk(clk), .rst_n(rst_sync_n),
        .i_in(tone_i), .q_in(tone_q),
        .i_e(ie), .i_o(io), .q_e(qe), .q_o(qo)
    );

    // ── DDC（回环：DUC 的四相直接喂进去）────────────────────────────
    wire signed [OW_DDC-1:0] ddc_i, ddc_q;

    ddc_core #(
        .IW(OW_DUC), .CW(CW), .N_DEC(N_HB), .N_FIR(N_FIR),
        .AW(AW), .PHASE_W(PHASE_W), .LUT_AW(LUT_AW),
        .CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_LO),
        .OW_DEC(OW_DUC+1), .OW_MIX(OW_DUC+2), .OW_FIR(OW_DUC+3),
        .OW_OUT(OW_DDC),
        .SHIFT_DEC(CW-1), .SHIFT_MIX(AW-1), .SHIFT_FIR(CW-1),
        .ROUND(1), .LO_DLY(LO_DLY_DDC)
    ) u_ddc (
        .clk(clk), .rst_n(rst_sync_n),
        .i_e(ie), .i_o(io), .q_e(qe), .q_o(qo),
        .i_out(ddc_i), .q_out(ddc_q)
    );

    // ── 活动指示（泄漏计数器）───────────────────────────────────────
    // |v| 用补码取反加一；阈值 16 LSB 很小，单音的大部分时间都在阈值以上。
    wire [OW_DUC-1:0] abs_ie = ie[OW_DUC-1] ? (~ie + 1'b1) : ie;
    wire [OW_DUC-1:0] abs_qe = qe[OW_DUC-1] ? (~qe + 1'b1) : qe;
    wire [OW_DDC-1:0] abs_di = ddc_i[OW_DDC-1] ? (~ddc_i + 1'b1) : ddc_i;
    wire [OW_DDC-1:0] abs_dq = ddc_q[OW_DDC-1] ? (~ddc_q + 1'b1) : ddc_q;

    wire duc_act = (abs_ie > ACT_THRESH) || (abs_qe > ACT_THRESH);
    wire ddc_act = (abs_di > ACT_THRESH) || (abs_dq > ACT_THRESH);

    reg [ACT_W-1:0] duc_cnt, ddc_cnt;

    always @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n)
            duc_cnt <= {ACT_W{1'b0}};
        else if (duc_act) begin
            if (duc_cnt != {ACT_W{1'b1}})
                duc_cnt <= duc_cnt + 1'b1;
        end else if (duc_cnt != {ACT_W{1'b0}})
            duc_cnt <= duc_cnt - 1'b1;
    end

    always @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n)
            ddc_cnt <= {ACT_W{1'b0}};
        else if (ddc_act) begin
            if (ddc_cnt != {ACT_W{1'b1}})
                ddc_cnt <= ddc_cnt + 1'b1;
        end else if (ddc_cnt != {ACT_W{1'b0}})
            ddc_cnt <= ddc_cnt - 1'b1;
    end

    assign led[0] = ddc_cnt[ACT_W-1];
    assign led[1] = duc_cnt[ACT_W-1];
    assign led[3:2] = {2{hb}};

    // ── ILA 探针 ────────────────────────────────────────────────────
    // DUC 四相 60 位 + DDC 两路 26 位 = 86 位；深度 4096 约 9 块 RAMB36。
    (* mark_debug = "true", keep = "true" *) wire signed [OW_DUC-1:0] ie_dbg  = ie;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_DUC-1:0] io_dbg  = io;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_DUC-1:0] qe_dbg  = qe;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_DUC-1:0] qo_dbg  = qo;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_DDC-1:0] di_dbg  = ddc_i;
    (* mark_debug = "true", keep = "true" *) wire signed [OW_DDC-1:0] dq_dbg  = ddc_q;

endmodule
