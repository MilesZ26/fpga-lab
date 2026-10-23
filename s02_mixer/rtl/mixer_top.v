`timescale 1ns/1ps
//=============================================================================
// mixer_top — s02_mixer 的板级顶层（"混频验证台"）
//-----------------------------------------------------------------------------
// ⚠️ 先说明定位：**这块顶层不是 DUC 的一部分**。它是一块实验台，
//    目的是用板子上真实跑起来的信号证明"复数混频确实把频率搬走了"。
//    真正的 DUC 集成要到 s05 才做。
//
// 结构（两个 NCO + 一个混频器，全部单一时钟域）：
//
//     nco u_nco_sig  FREQ_IN ──► sig_cos / sig_sin ─┐  （"收到的复基带信号"）
//                                                   ├─► mixer ─► i_out / q_out
//     nco u_nco_lo   FREQ_LO ──► lo_cos  / lo_sin  ─┘  （本振）
//
//   注意输入那一侧的 (i, q) 是 (cos, sin) —— 这就是一个**正频率**的复单音
//   e^{j*w_in*t}。用两个 NCO 造"输入信号"只是为了在板子上有东西可混；
//   真实链路里这一侧接的是成型滤波之后的基带符号。
//
// 看什么（这是本 stage 的板级验收点）：
//   CONJ=1（下变频）：输出频率 = FREQ_IN - FREQ_LO = 250k - 200k = **50 kHz**
//   CONJ=0（上变频）：输出频率 = FREQ_IN + FREQ_LO = 250k + 200k = **450 kHz**
//   "混频"就是这一件事：频率被搬移，而且搬到了和 / 差上。
//   ILA 上量一下输出波形的周期（50 kHz → 20 µs），对得上就对。
//
// ILA 采样窗的算术（和 s01 同一个坑，上板前先算清楚）：
//   ILA 采样时钟 50 MHz、深度 8192 → 窗口 163.84 µs。
//   50 kHz 在窗口里放得下 8.19 个周期 → 形状看得清。
//   **如果为了看 LED 把频率调成 1 Hz，窗口里连 1/1000 个周期都没有，
//   ILA 上就是一条直线 —— 那是采样窗不够，不是 bug。**
//
// 时钟域：clk（单一时钟域，无 CDC）
// 延迟：  rst_n_sync 比按键晚 2 拍（异步复位、同步释放）；
//        i_out/q_out 比 (i_in, 本振) 晚 1 拍（mixer 的输出寄存器）。
// 复位值：led = 4'b0000
//
// ── 关于 ILA（和 s01 完全一样的做法）─────────────────────────────
//   六个关键信号上挂了 (* mark_debug = "true", keep = "true" *)：
//     sig_cos / sig_sin（输入信号）、lo_cos / lo_sin（本振）、i_out / q_out（输出）
//   mark_debug 让 Vivado 的 Set up Debug 能认出它们；keep 才真正阻止综合优化
//   （只有 mark_debug 时，没连到引脚的位会被整个优化掉，向导里就找不到这些网）。
//
//   **ILA 核本身绝对不要写进 RTL** —— 它是 Vivado IP，iverilog 没有行为模型，
//   写进来 make sim 立刻编译不过。核请在 Vivado 里用 Set up Debug 挂。
//
//   探针建议：6 个都探大约 74 位（12+12+12+12+13+13），深度 8192 时 BRAM 吃得不少。
//   只想证明"混频有效"的话，**探 i_out 和 q_out 就够了**（26 位），
//   输入频率是本设计的参数，不需要从波形上反推。
//
// 依赖：nco 来自 s01_nco/rtl/nco.v（见 s02_mixer/deps.txt），
//       它靠 `NCO_LUTDIR 宏找 s01_nco/lut/*.mem —— 综合前必须把 NCO_LUTDIR 指对，
//       否则 $readmemh 不报错、表里全 x（坑的细节见 s01_nco/constr/nco.xdc）。
//=============================================================================

module mixer_top #(
    parameter integer CLK_HZ  = 50_000_000,   // 板级时钟（和 XDC 的 create_clock 必须一致）
    parameter integer FREQ_IN = 250_000,      // "输入信号"频率（实验台上假冒的基带单音）
    parameter integer FREQ_LO = 200_000,      // local oscillator, 本振频率
    parameter integer PHASE_W = 32,           // NCO 相位累加器位宽
    parameter integer LUT_AW  = 12,           // NCO 查表地址位宽（必须和 lut/*.mem 一致）
    parameter integer AW      = 12,           // NCO 输出幅度位宽 = 本振位宽（必须和表一致）
    parameter integer IW      = 12,           // 混频器输入 i/q 位宽（这里直接接 sig NCO，等于 AW）
    parameter integer OW      = 13,           // 混频器输出位宽
    parameter integer SHIFT   = AW - 1,       // 增益归一化右移（AW-1 = 单位增益）
    parameter integer ROUND   = 1,            // 1 = 四舍五入
    parameter integer CONJ    = 1             // 1 = 下变频（看差频）；0 = 上变频（看和频）
)(
    input  wire       clk,     // 板级时钟 R4
    input  wire       rst_n,   // 板级按键，低有效（异步）
    output wire [3:0] led      // led[0]=V9，led[1..3]=Y8/Y7/W7
);

    // ── 复位：异步复位、同步释放 ──
    // 顶层端口仍叫 rst_n（和 XDC / 板上网络名对上），内部一律用 rst_n_sync。
    wire rst_n_sync;
    reset_sync u_reset_sync (
        .clk   (clk),
        .arst_n(rst_n),
        .rst_n (rst_n_sync)
    );

    // ── 输入信号源（实验台专用，不是 DUC 的一部分）──
    (* mark_debug = "true", keep = "true" *) wire signed [AW-1:0] sig_cos;
    (* mark_debug = "true", keep = "true" *) wire signed [AW-1:0] sig_sin;

    nco #(
        .CLK_HZ (CLK_HZ),
        .FREQ_HZ(FREQ_IN),
        .PHASE_W(PHASE_W),
        .LUT_AW (LUT_AW),
        .AW     (AW)
    ) u_nco_sig (
        .clk   (clk),
        .rst_n (rst_n_sync),
        .fsin_o(sig_sin),
        .fcos_o(sig_cos)
    );

    // ── 本振 ──
    (* mark_debug = "true", keep = "true" *) wire signed [AW-1:0] lo_cos;
    (* mark_debug = "true", keep = "true" *) wire signed [AW-1:0] lo_sin;

    nco #(
        .CLK_HZ (CLK_HZ),
        .FREQ_HZ(FREQ_LO),
        .PHASE_W(PHASE_W),
        .LUT_AW (LUT_AW),
        .AW     (AW)
    ) u_nco_lo (
        .clk   (clk),
        .rst_n (rst_n_sync),
        .fsin_o(lo_sin),
        .fcos_o(lo_cos)
    );

    // ── 复数混频 ──
    (* mark_debug = "true", keep = "true" *) wire signed [OW-1:0] i_out;
    (* mark_debug = "true", keep = "true" *) wire signed [OW-1:0] q_out;

    mixer #(
        .IW    (IW),
        .AW    (AW),
        .OW    (OW),
        .SHIFT (SHIFT),
        .ROUND (ROUND),
        .CONJ  (CONJ)
    ) u_mixer (
        .clk   (clk),
        .rst_n (rst_n_sync),
        .i_in  (sig_cos),
        .q_in  (sig_sin),
        .cos_in(lo_cos),
        .sin_in(lo_sin),
        .i_out (i_out),
        .q_out (q_out)
    );

    // ── LED ──
    // 位宽跟着 OW 走，换输出位宽时这里不用改。
    // led[0] 特意放符号位（V9 是 s00 反证过的那颗灯）。
    assign led[0]   = i_out[OW-1];        // 符号位：每半个输出周期翻转
    assign led[3:1] = i_out[OW-2 -: 3];   // 幅值高 3 位：二进制斜坡

endmodule
