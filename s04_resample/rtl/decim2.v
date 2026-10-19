`timescale 1ns/1ps
//=============================================================================
// decim2 — 2× 半带抽取（多相结构，相位并行输入）
//-----------------------------------------------------------------------------
// 功能：输入两路 x_e / x_o 是 2Fs 上的**相邻采样**（x_e[n] = u[2n]，
//       x_o[n] = u[2n+1]），输出 y 在 Fs 上：
//
//     y[n] = ( 2^(CW-2)·x_e[n-K/2]
//              + Σ_{i=0}^{K-1} o[i]·x_o[n-1-i] ) >>> (CW-1)
//
//   K = (N-1)/2 = 30，o[i] = h[2i+1]（和 interp2 共用 lut/hb_odd.mem）。
//
// 为什么 x_o 要多延迟一拍
//-----------------------------------------------------------------------------
//   交错信号 u 里 x_o[n] = u[2n+1] 比 x_e[n] = u[2n] **晚半个采样**。
//   卷积窗口对齐到同一个输出时刻 y[n] 时，x_o 的窗口整体往回挪一个下标：
//       y[n] = Σ h[2i]·x_e[n-i] + Σ h[2i+1]·x_o[n-i-1]
//   所以 o_dly 的第一级是 x_o[n]，真正参与乘法的从 x_o[n-1] 开始。
//   **这个 -1 不是时序 bug，是抽取的相位关系**；少写它输出就会整体错半个采样。
//
// 为什么是"两个源相加"，而不是把 61 个抽头都算一遍
//-----------------------------------------------------------------------------
//   半带的偶相只有中心抽头 0.5，所以偶相的全部贡献就是
//       0.5·x_e[n-15]  —— 一个常数乘（就是移位），0 个 DSP。
//   真正要算的是奇相 30 个抽头 → 对称折叠成 15 个乘法器。
//   注意：这个 0.5 项必须在**移位之前**加到和里，不能先各自移位再相加
//   （那样会丢两次精度，而且舍入点变成两个）。所以这里把它当成第 16 个乘积。
//
// 位宽（和 interp2 / fir.v 同一套推导）
//-----------------------------------------------------------------------------
//   预加和 PA_W   = IW + 1
//   乘积   PROD_W = PA_W + CW（直通项只有 IW+CW-1 位，符号扩展进同一宽度）
//   求和   SUM_W  = PROD_W + ceil(log2(PAIRS+1)) + 1     ← 16 项
//   最终   FINAL_W = SUM_W + 1
//
// 时钟域：clk。延迟：**4 拍**（第 k 个下降沿的 x_e/x_o，对应第 k+4 个下降沿的 y）。
// 复位值：所有延迟线 / 流水寄存器 / 输出 = 0。
//=============================================================================

module decim2 #(
    parameter integer IW        = 12,             // 输入位宽（补码）
    parameter integer CW        = 16,             // 系数位宽（补码，Q1.CW-1）
    parameter integer N         = 61,             // 半带总抽头数，必须 = 4q+1
    parameter integer OW        = IW + 1,         // 输出位宽（补码）
    parameter integer SHIFT     = CW - 1,         // 输出右移位数（抽取：CW-1）
    parameter integer ROUND     = 1,              // 1 = 四舍五入；0 = 截断
    parameter         COEF_FILE = "hb_odd.mem"    // 系数文件名（目录由 HB_COEFDIR 给）
)(
    input  wire                 clk,
    input  wire                 rst_n,            // 异步复位，低有效
    input  wire signed [IW-1:0] x_e,              // 2Fs 上的偶相采样 u[2n]
    input  wire signed [IW-1:0] x_o,              // 2Fs 上的奇相采样 u[2n+1]
    output reg  signed [OW-1:0] y_out             // Fs 上的输出
);

`ifndef HB_COEFDIR
  `define HB_COEFDIR "s04_resample/lut/"   // 兜底：手工跑 iverilog / Vivado 综合
`endif

    // ── 编译期参数 ────────────────────────────────────────────────────
    localparam integer K      = (N - 1) / 2;      // 奇数抽头个数 = 中心下标 = 30
    localparam integer PAIRS  = K / 2;            // 乘法器个数 = 15
    localparam integer TERMS  = PAIRS + 1;        // 再加一个 0.5·x_e 直通项
    localparam integer PA_W   = IW + 1;
    localparam integer PROD_W = PA_W + CW;
    localparam integer SUM_W  = PROD_W + $clog2(TERMS) + 1;
    localparam integer FINAL_W = SUM_W + 1;
    localparam integer GROUPS = 4;
    localparam integer GSUM_N = (TERMS + GROUPS - 1) / GROUPS;
    localparam integer LATENCY = 4;

    // ── 系数表（30 行）──────────────────────────────────────────────
    reg signed [CW-1:0] coef [0:K-1];
    initial begin
        $readmemh({`HB_COEFDIR, COEF_FILE}, coef);
    end

    // ── 级 1：两路延迟线 ─────────────────────────────────────────────
    // e_dly[j] = x_e[n-j]（16 个，只用 [15] = x_e[n-15]，中间那些是移位链）
    // o_dly[j] = x_o[n-j]（31 个，用 [1..30] = x_o[n-1] .. x_o[n-30]）
    reg signed [IW-1:0] e_dly [0:K/2];
    reg signed [IW-1:0] o_dly [0:K];
    integer di;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (di = 0; di <= K/2; di = di + 1)
                e_dly[di] <= {IW{1'b0}};
            for (di = 0; di <= K; di = di + 1)
                o_dly[di] <= {IW{1'b0}};
        end else begin
            e_dly[0] <= x_e;
            for (di = 1; di <= K/2; di = di + 1)
                e_dly[di] <= e_dly[di-1];
            o_dly[0] <= x_o;
            for (di = 1; di <= K; di = di + 1)
                o_dly[di] <= o_dly[di-1];
        end
    end

    // ── 级 2 的组合部分：对称预加 + 乘法 + 直通项 ────────────────────
    // 第 i 对：抽头 i 用 o_dly[i+1]，抽头 K-1-i 用 o_dly[K-i]（K=30 → 30-i）。
    // 直通项：0.5 的偶相中心抽头。HALF_COEF = 2^(CW-2) 是常数，
    //         乘一个 2 的幂在综合里就是移位连线，**不占 DSP**。
    localparam signed [CW-1:0] HALF_COEF = (64'sd1 <<< (CW-2));

    wire signed [PROD_W-1:0] prod [0:TERMS-1];
    genvar gi;
    generate
        for (gi = 0; gi < PAIRS; gi = gi + 1) begin : g_pair
            wire signed [IW-1:0] xa = o_dly[gi+1];
            wire signed [IW-1:0] xb = o_dly[K-gi];
            wire signed [PA_W-1:0] pa = {{1{xa[IW-1]}}, xa}
                                      + {{1{xb[IW-1]}}, xb};
            assign prod[gi] = pa * coef[gi];
        end
    endgenerate

    // ⚠️ 这里必须先过一根 **signed** 线：`{{1{sign}}, x}` 是个拼接表达式，
    //    Verilog 里拼接**永远是无符号的**。直接写
    //        {{1{sign}}, x} * HALF_COEF
    //    乘法会按无符号算 —— 负数输入全变成大正数（这个 bug 在第一次跑
    //    tb_decim2 时被"直流 -1000"和"x_e 为负的向量场景"抓到了）。
    wire signed [IW-1:0] e_tap = e_dly[K/2];
    wire signed [PROD_W-1:0] prod_pas = e_tap * HALF_COEF;
    assign prod[PAIRS] = prod_pas;

    // ── 级 2：乘积寄存器 ─────────────────────────────────────────────
    reg signed [PROD_W-1:0] p_reg [0:TERMS-1];
    integer pi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pi = 0; pi < TERMS; pi = pi + 1)
                p_reg[pi] <= {PROD_W{1'b0}};
        end else begin
            for (pi = 0; pi < TERMS; pi = pi + 1)
                p_reg[pi] <= prod[pi];
        end
    end

    // ── 级 3：4 组部分和 ─────────────────────────────────────────────
    reg signed [SUM_W-1:0] gsum [0:GROUPS-1];
    integer g;

    function signed [SUM_W-1:0] group_sum;
        input integer base;
        integer t;
        begin
            group_sum = {SUM_W{1'b0}};
            for (t = 0; t < GSUM_N; t = t + 1) begin
                if (base + t < TERMS)
                    group_sum = group_sum + p_reg[base + t];
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (g = 0; g < GROUPS; g = g + 1)
                gsum[g] <= {SUM_W{1'b0}};
        end else begin
            for (g = 0; g < GROUPS; g = g + 1)
                gsum[g] <= group_sum(g * GSUM_N);
        end
    end

    // ── 级 4：组间相加 + 舍入 + 右移 + 饱和 ─────────────────────────
    wire signed [SUM_W-1:0] sum_all = gsum[0] + gsum[1] + gsum[2] + gsum[3];

    localparam integer RND_SH = (SHIFT > 0) ? (SHIFT - 1) : 0;
    localparam signed [FINAL_W-1:0] RND_C =
        (ROUND != 0 && SHIFT > 0) ? ({{FINAL_W-1{1'b0}}, 1'b1} <<< RND_SH)
                                  : {FINAL_W{1'b0}};

    wire signed [FINAL_W-1:0] sum_ext = {sum_all[SUM_W-1], sum_all};
    wire signed [FINAL_W-1:0] sum_rnd = sum_ext + RND_C;
    wire signed [FINAL_W-1:0] sum_sh  = sum_rnd >>> SHIFT;

    localparam signed [FINAL_W-1:0] OW_MAX = (64'sd1 <<< (OW-1)) - 1;
    localparam signed [FINAL_W-1:0] OW_MIN = -(64'sd1 <<< (OW-1));

    function signed [OW-1:0] sat_ow;
        input signed [FINAL_W-1:0] v;
        begin
            if (v > OW_MAX)
                sat_ow = OW_MAX[OW-1:0];
            else if (v < OW_MIN)
                sat_ow = OW_MIN[OW-1:0];
            else
                sat_ow = v[OW-1:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            y_out <= {OW{1'b0}};
        else
            y_out <= sat_ow(sum_sh);
    end

endmodule
