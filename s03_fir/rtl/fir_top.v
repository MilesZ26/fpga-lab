`timescale 1ns/1ps
//=============================================================================
// fir_top — s03_fir 的板级顶层（实验台：冲激发生器 + FIR + LED + ILA）
//-----------------------------------------------------------------------------
// 这个顶层**不是** DUC 的一部分，它是"实验台器材"，只负责在板子上造出一个
// 能一眼看懂 FIR 行为的信号：
//
//   · 每 IMP_PERIOD 个时钟产生一个**单点冲激**（幅度 2047，宽度 1 拍）
//   · 冲激送进 fir.v，输出就是滤波器的**冲激响应**（系数表本身，按 2047/2^15 缩放）
//   · ILA 抓到 fir_out，应该在触发点之后看到 47 个点的波形：
//         h[k] = round(2047 * coef[k] / 2^15)
//     峰值（中心抽头 9810）= 613，两边对称 —— 这就是"线性相位"的直接证据。
//
// 为什么不用 NCO 造正弦：
//   冲激响应能**逐点**和 coef.mem 对账，比"看正弦被滤小了"更硬。
//   而且不需要第二个 NCO，顶层简单，出问题的地方少。
//   想看"正弦被滤波"的效果可以以后再搭（s05 集成时自然会看到）。
//
// 时钟域：clk
// 延迟：  fir_out 相对 x_in 4 拍（fir.v 的流水线），本模块不再加延迟
// 复位：  外部按键 rst_n 先过 reset_sync（异步复位、同步释放）；
//         内部所有寄存器用同步释放后的 rst_sync_n。
//
// LED：
//   四颗灯都接同一个 1 Hz 心跳。**这是故意的**：
//   led[0]=V9 是 s00 上板反证过的引脚，led[1..3]=Y8/Y7/W7 只来自引脚表。
//   四颗一起闪，哪颗不闪就怀疑那颗灯的引脚，而不是 RTL。
//=============================================================================

module fir_top #(
    parameter integer CLK_HZ     = 50_000_000, // 输入时钟频率（和 XDC 的 20 ns 对应）
    parameter integer HEART_HZ   = 1,          // LED 心跳频率（Hz，必须 >0）
    parameter integer IMP_PERIOD = 1024,       // 每隔多少个时钟发一个冲激（2..65535）
    parameter integer IW         = 12,         // FIR 输入位宽
    parameter integer CW         = 16,         // FIR 系数位宽
    parameter integer N          = 47,         // FIR 抽头数
    parameter integer OW         = IW + 1,      // FIR 输出位宽
    parameter integer SHIFT      = CW - 1,     // FIR 输出右移位数
    parameter integer ROUND      = 1           // FIR 舍入开关
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
    // imp_cnt == 0 的那一拍 imp=1，x_in = 2047；其余拍 x_in = 0。
    // 复位释放后第一个冲激立刻出现（imp_cnt 从 0 开始），方便 ILA 抓到。
    reg [15:0] imp_cnt;
    wire       imp;
    // 用 rst_sync_n 门控：复位期间 imp 也是 0，避免"复位还没释放就发冲激"。
    assign imp = rst_sync_n && (imp_cnt == 16'd0);

    always @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n)
            imp_cnt <= 16'd0;
        else if (imp_cnt >= IMP_PERIOD - 1)
            imp_cnt <= 16'd0;
        else
            imp_cnt <= imp_cnt + 16'd1;
    end

    // 冲激幅度 = IW 位补码的最大正值（2^(IW-1)-1）。写成参数化形式，
    // 这样改 IW 时不用手改这个魔数（默认 IW=12 → 2047）。
    wire signed [IW-1:0] x_in = imp ? {1'b0, {(IW-1){1'b1}}} : {IW{1'b0}};

    // ── FIR ─────────────────────────────────────────────────────────
    wire signed [OW-1:0] fir_out;

    fir #(
        .IW(IW), .CW(CW), .N(N), .OW(OW), .SHIFT(SHIFT), .ROUND(ROUND)
    ) u_fir (
        .clk  (clk),
        .rst_n(rst_sync_n),
        .x_in (x_in),
        .y_out(fir_out)
    );

    // ── ILA 探针 ────────────────────────────────────────────────────
    // mark_debug 让 Vivado 的 Set up Debug 能列出这两个信号；
    // keep 防止综合把"看起来没人用"的 fir_out 优化掉（s01 踩过这个坑）。
    // 想再省资源可以只探 fir_out（13 位），imp 用触发条件代替。
    (* mark_debug = "true", keep = "true" *) wire imp_dbg  = imp;
    (* mark_debug = "true", keep = "true" *) wire signed [OW-1:0] fir_dbg = fir_out;

    // ── LED ─────────────────────────────────────────────────────────
    assign led = {4{hb}};

endmodule
