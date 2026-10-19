`timescale 1ns/1ps
//=============================================================================
// interp2 — 2× 半带插值（多相结构，相位并行输出）
//-----------------------------------------------------------------------------
// 功能：输入 x 在速率 Fs 上，输出 y 在速率 2Fs 上，一对输出对应一个输入：
//
//     y_e[n] = y[2n]   = x[n-M/2]                        （偶相：恒等，0 个乘法器）
//     y_o[n] = y[2n+1] = ( Σ_{i=0}^{K-1} o[i]·x[n-i] ) >>> (CW-2)
//
//   M = (N-1)/2 = 30 是半带的中心抽头下标，K = (N-1)/2 = 30 是非零奇数抽头个数。
//   o[i] = h[2i+1]，就是 lut/hb_odd.mem 里的那张表。
//
// 为什么偶相是恒等（这个模块最重要的结构）
//-----------------------------------------------------------------------------
//   2× 插值 = 先零插值（x[2n]=x[n], x[2n+1]=0）再低通。半带的偶相系数只有
//   中心抽头 0.5，所以 y[2n] = 2 · 0.5 · x[n-M/2] = x[n-M/2] —— **连乘法器都不用**，
//   就是一条 15 拍的延迟线。插值真正要算的只有奇相那 15 个乘法器。
//   这就是"半带白送一半乘法器"：61 抽头，实际只有 15 个乘法器。
//
// 为什么 SHIFT = CW-2（比别的模块少移一位）
//-----------------------------------------------------------------------------
//   零插值之后信号平均功率掉一半，插值滤波器必须补一个 2 倍增益。
//   半带系数本身按 Q1.15 设计（和 = 32768 = 1.0），多出来的 ×2 就体现在
//   "少移一位"：2·S/2^15 = S/2^14。
//   ⚠️ 所以 interp2 的 SHIFT 默认是 CW-2，decim2 的默认是 CW-1。这不是笔误，
//      两个模块共用同一张系数表，区别就是这一位移位。
//
// 位宽（和 s03 的 fir.v 同一套推导）
//-----------------------------------------------------------------------------
//   预加和 PA_W   = IW + 1
//   乘积   PROD_W = PA_W + CW
//   求和   SUM_W  = PROD_W + ceil(log2(PAIRS)) + 1
//   最终   FINAL_W = SUM_W + 1
//   输出   OW     = IW + 1（单位增益，留 1 位余量）
//
// 流水线（4 级，和 fir.v 一致）
//-----------------------------------------------------------------------------
//   级 1：dly[]        —— 输入寄存 + 30 拍采样延迟线
//   级 2：p_reg[]      —— 15 对对称预加 + 乘法
//   级 3：gsum[]       —— 4 组部分和
//   级 4：y_o / y_e    —— 组间相加 + 舍入 + 移位 + 饱和
//
//   y_e 走的是"延迟线中间那一拍"，比 y_o 少三级加法；必须**自己补 3 级寄存器**
//   才能和 y_o 对齐。这是多相结构最容易漏的一步：两相错开一个采样点，
//   波形看起来只是"有点毛刺"，听感/频谱上是彻底的失真。
//
// 时钟域：clk。
// 延迟： 4 级流水（输入采样级 + p_reg + gsum + 输出），y_o 的第一个抽头在
//        采样沿后 **+3**。y_e 的源是 dly[15]：延迟线贡献 15 个输入样本，
//        再加 e1/e2/y_e **3 级**，共 **+18**（采样沿）。
//        ⚠️ ILA 触发行（imp_dbg=1）比采样沿早一拍，所以 ILA 偏移是
//        y_o **+4**、y_e **+19**（触发行 = 0）。别把这两套数混了。
// 复位值：所有延迟线 / 流水寄存器 / 输出 = 0。
//=============================================================================

module interp2 #(
    parameter integer IW        = 12,             // 输入位宽（补码）
    parameter integer CW        = 16,             // 系数位宽（补码，Q1.CW-1）
    parameter integer N         = 61,             // 半带总抽头数，必须 = 4q+1
    parameter integer OW        = IW + 1,         // 输出位宽（补码）
    parameter integer SHIFT     = CW - 2,         // 输出右移位数（插值：CW-2，见上）
    parameter integer ROUND     = 1,              // 1 = 四舍五入；0 = 截断
    parameter         COEF_FILE = "hb_odd.mem"    // 系数文件名（目录由 HB_COEFDIR 给）
)(
    input  wire                 clk,
    input  wire                 rst_n,            // 异步复位，低有效
    input  wire signed [IW-1:0] x_in,             // 低速率输入样本
    output reg  signed [OW-1:0] y_e,              // 偶相输出 y[2n]
    output reg  signed [OW-1:0] y_o               // 奇相输出 y[2n+1]
);

`ifndef HB_COEFDIR
  `define HB_COEFDIR "s04_resample/lut/"   // 兜底：手工跑 iverilog / Vivado 综合
`endif

    // ── 编译期参数 ────────────────────────────────────────────────────
    // K = 奇数下标的个数 = 中心抽头下标 M。N=4q+1 时 K=2q 是偶数，
    // 所以 30 个奇数抽头正好两两配对，没有"落单的中心奇数抽头"。
    localparam integer K      = (N - 1) / 2;
    localparam integer PAIRS  = K / 2;                    // 乘法器个数 = 15
    localparam integer PA_W   = IW + 1;
    localparam integer PROD_W = PA_W + CW;
    localparam integer SUM_W  = PROD_W + $clog2(PAIRS) + 1;
    localparam integer FINAL_W = SUM_W + 1;
    localparam integer GROUPS = 4;
    localparam integer GSUM_N = (PAIRS + GROUPS - 1) / GROUPS;
    localparam integer LATENCY = 4;

    // ── 系数表（30 行，K 个非零奇数抽头）────────────────────────────
    // 数组长度必须和 .mem 行数**恰好相等**（$readmemh 少了不报错，见已知坑 9）。
    // 只用前 PAIRS 个：表是对称的，后半是镜像，留给 tb_hb_coef.v 校验。
    reg signed [CW-1:0] coef [0:K-1];
    initial begin
        $readmemh({`HB_COEFDIR, COEF_FILE}, coef);
    end

    // ── 级 1：输入寄存 + 30 拍延迟线 ─────────────────────────────────
    // dly[j] = x[n-j]（j = 0..K-1）。窗口是新端在前、旧端在后。
    reg signed [IW-1:0] dly [0:K-1];
    integer di;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (di = 0; di < K; di = di + 1)
                dly[di] <= {IW{1'b0}};
        end else begin
            dly[0] <= x_in;
            for (di = 1; di < K; di = di + 1)
                dly[di] <= dly[di-1];
        end
    end

    // ── 级 2 的组合部分：对称预加 + 乘法 ─────────────────────────────
    // 第 i 对是 (h[2i+1], h[2(K-1-i)+1])，对应窗口 dly[i] 和 dly[K-1-i]。
    // h 对称 ⇒ 两个抽头相等 ⇒ 先加后乘：(a+b)·h。
    wire signed [PROD_W-1:0] prod [0:PAIRS-1];
    genvar gi;
    generate
        for (gi = 0; gi < PAIRS; gi = gi + 1) begin : g_pair
            wire signed [IW-1:0] xa = dly[gi];
            wire signed [IW-1:0] xb = dly[K-1-gi];
            wire signed [PA_W-1:0] pa = {{1{xa[IW-1]}}, xa}
                                      + {{1{xb[IW-1]}}, xb};
            assign prod[gi] = pa * coef[gi];
        end
    endgenerate

    // ── 级 2：乘积寄存器 ─────────────────────────────────────────────
    reg signed [PROD_W-1:0] p_reg [0:PAIRS-1];
    integer pi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pi = 0; pi < PAIRS; pi = pi + 1)
                p_reg[pi] <= {PROD_W{1'b0}};
        end else begin
            for (pi = 0; pi < PAIRS; pi = pi + 1)
                p_reg[pi] <= prod[pi];
        end
    end

    // ── 级 3：4 组部分和 ─────────────────────────────────────────────
    // function 只在时钟沿调用，避免 always @* 对数组敏感导致的日志噪音（同 fir.v）。
    reg signed [SUM_W-1:0] gsum [0:GROUPS-1];
    integer g;

    function signed [SUM_W-1:0] group_sum;
        input integer base;
        integer t;
        begin
            group_sum = {SUM_W{1'b0}};
            for (t = 0; t < GSUM_N; t = t + 1) begin
                if (base + t < PAIRS)
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

    // ── 级 4：偶相的"对齐延迟" ───────────────────────────────────────
    // 偶相源 = dly[K/2] = x[n-15]，本来就在级 1。要走到级 4 还差 2 级寄存器
    // （e1 是级 2、e2 是级 3，最后和 y_o 一起在级 4 打出去）。
    // K/2 = 15 就是半带的群延迟（以输入速率计）：输出 y[2n] 比输入晚 15 个输入样本。
    reg signed [IW-1:0] e1, e2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e1 <= {IW{1'b0}};
            e2 <= {IW{1'b0}};
        end else begin
            e1 <= dly[K/2];
            e2 <= e1;
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

    // 偶相：不经过乘法/移位，只做符号扩展。**但也要饱和**：
    // OW < IW 时（测试里故意用 OW=8 撞边界）直接截位会回绕，
    // 和奇相"饱和不回绕"就不一致了。
    wire signed [FINAL_W-1:0] e_ext = {{(FINAL_W-IW){e2[IW-1]}}, e2};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_o <= {OW{1'b0}};
            y_e <= {OW{1'b0}};
        end else begin
            y_o <= sat_ow(sum_sh);
            y_e <= sat_ow(e_ext);
        end
    end

endmodule
