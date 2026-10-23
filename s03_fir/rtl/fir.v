`timescale 1ns/1ps
//=============================================================================
// fir — 对称抽头的线性相位 FIR 低通滤波器
//-----------------------------------------------------------------------------
// 功能：
//   直接型（direct form）卷积：
//
//       y[n] = ( sum_{k=0}^{N-1} c[k] * x[n-k] ) >>> SHIFT
//
//   系数 c[k] 从 .mem 文件读入（脚本离线设计 + 量化，见 s03_fir/lut/README.md）。
//
// 时钟域：clk
// 延迟：  4 拍（输入 x_in 被采样后，第 4 个时钟沿出 y_out）
// 复位值：所有延迟线 / 流水寄存器 / y_out = 0；系数数组不复位（它是常量）
//
//-----------------------------------------------------------------------------
// 为什么是"对称抽头"（本模块最重要的结构决定）
//-----------------------------------------------------------------------------
//   FIR 低通用窗函数法设计出来天然满足 c[k] = c[N-1-k]，这叫**线性相位**：
//   所有频率的群延迟都相同（(N-1)/2 个采样），波形不会被滤"歪"。
//   对称还有一个白送的好处：卷积可以改写成
//
//       y[n] = sum_{i=0}^{H-1} c[i] * ( x[n-i] + x[n-(N-1-i)] )   (+ 中心抽头)
//
//   也就是说**先做加法、再乘法** —— 加法器比乘法器便宜得多：
//   N=47 时乘法器从 47 个降到 24 个（DSP48 在 Artix-7 上是紧俏资源）。
//   这就是 generate 里 g_pair 做的事（预加 pre-adder）。
//
//-----------------------------------------------------------------------------
// 位宽（每一位都要能说清为什么）
//-----------------------------------------------------------------------------
//   IW      输入位宽（补码），默认 12
//   CW      系数位宽（补码，Q1.CW-1），默认 16
//   N       抽头数，默认 47（奇数 → 群延迟是整数 23 拍，测试好对账）
//   OW      输出位宽（补码），默认 IW+1
//   SHIFT   输出右移位数，默认 CW-1（把 Q1.(CW-1) 的尺度除回去）
//   ROUND   1 = 四舍五入；0 = 直接截断
//
//   预加和 PA_W   = IW + 1         两个 IW 位有符号数相加，多 1 位
//   乘积   PROD_W = PA_W + CW      有符号乘法的全精度位宽
//   求和   SUM_W  = PROD_W + ceil(log2(NP)) + 1
//                                  NP 个乘积相加，多 ceil(log2(NP)) 位；
//                                  再留 1 位给"舍入加的半个 LSB"
//   最终   FINAL_W = SUM_W + 1     舍入可能把最大正值顶出 SUM_W，所以再加 1 位
//
//   ⚠️ 和 mixer.v 一样：**先把全精度结果算完，最后才截**。提前截中间结果
//      省不下 DSP，只会白丢精度，而且会让"哪一位代表什么"变得很难查。
//
//   ⚠️ 默认 OW = IW+1 是**留余量**的：系数和 = 2^(CW-1)，单位直流增益，
//      理论上 OW=IW 就够（x=+2047 → y=+2047）。多 1 位是为了给"以后换
//      一组增益 > 1 的系数"留空间，也避免舍入在边界上多 1 LSB 就溢出。
//      要验证饱和逻辑，tb_fir.v 里用 OW=8 的实例把输出故意压小。
//
//-----------------------------------------------------------------------------
// 流水线（4 级，每级都在时钟沿打分号）
//-----------------------------------------------------------------------------
//   级 1：x_r / dly[]        —— 输入寄存 + 采样延迟线（窗口 x[n..n-N+1]）
//   级 2：p_reg[]            —— 预加 + 乘法（对称合并后的 NP 个乘积）
//   级 3：gsum[]             —— 4 组部分和（每组最多 ceil(NP/4) 个乘积）
//   级 4：y_out              —— 4 组相加 + 舍入 + 饱和
//
//   为什么加法树要分组流水：24 个 29 位乘积如果在一个周期里做 5 层加法，
//   50 MHz 下也许能过，但余量会被吃掉；分成"组内 3 层 + 组间 2 层"后，
//   每级只有 3 层左右的加法，时序余量大得多。代价是延迟从 2 拍变成 4 拍，
//   FIR 本来就在数据通路里，4 拍延迟完全可接受。
//
//-----------------------------------------------------------------------------
// 数据文件
//-----------------------------------------------------------------------------
//   系数文件默认 "coef.mem"，目录由宏 FIR_COEFDIR 给出：
//     `ifndef FIR_COEFDIR
//       `define FIR_COEFDIR "s03_fir/lut/"   // 手工跑 / Vivado 综合的兜底
//     `endif
//     initial $readmemh({`FIR_COEFDIR, COEF_FILE}, coef);
//
//   ⚠️ $readmemh 的路径相对**仿真/综合进程的工作目录**，不是 .v 所在目录。
//      make sim 会传绝对路径；Vivado 里要配 FIR_COEFDIR（见 constr/fir.xdc）。
//      COEF_FILE 做成参数，是为了让 testbench 能用同一套 RTL 换一张
//      coef5.mem（5 抽头）来做手算边界用例。
//=============================================================================

module fir #(
    parameter integer IW        = 12,          // 输入位宽（补码）
    parameter integer CW        = 16,          // 系数位宽（补码，Q1.CW-1）
    parameter integer N         = 47,          // 抽头数（>=2；奇数时群延迟为整数）
    parameter integer OW        = IW + 1,      // 输出位宽（补码）
    parameter integer SHIFT     = CW - 1,      // 输出右移位数（增益归一化）
    parameter integer ROUND     = 1,           // 1 = 四舍五入；0 = 截断
    parameter         COEF_FILE = "coef.mem"   // 系数文件名（目录由 FIR_COEFDIR 给）
)(
    input  wire                 clk,          // 时钟
    input  wire                 rst_n,        // 异步复位，低有效
    input  wire signed [IW-1:0] x_in,         // 输入样本（补码）
    output reg  signed [OW-1:0] y_out         // 滤波输出（补码）
);

`ifndef FIR_COEFDIR
  `define FIR_COEFDIR "s03_fir/lut/"
`endif

    // ── 编译期位宽 / 结构参数 ──────────────────────────────────────────
    localparam integer HALF   = N / 2;              // 对称"对数"，默认23个
    localparam integer NP     = (N + 1) / 2;        // number of products 乘法器个数（奇数 N 含中心抽头），默认24个
    localparam integer PA_W   = IW + 1;             // 预加和位宽
    localparam integer PROD_W = PA_W + CW;          // 乘积全精度位宽
    localparam integer SUM_W  = PROD_W + $clog2(NP) + 1; //  求和全精度位宽（多 1 位给舍入加的半个 LSB），第二项是 ceil(log2(NP))，因为 NP 个乘积相加可能多出这么多位
    localparam integer FINAL_W = SUM_W + 1;         // 舍入前的额外 1 位
    localparam integer GROUPS = 4;                  // 部分和组数（流水级 3）
    localparam integer GSUM_N = (NP + GROUPS - 1) / GROUPS;  // 每组最多几个乘积，默认6个
    localparam integer LATENCY = 4;                 // 输入 -> 输出延迟（拍）

    // ── 系数（常量表，脚本生成）──────────────────────────────────────
    // 数组长度必须和 .mem 的行数**恰好相等**：$readmemh 文件短了不会报错，
    // 只会留下 x（见 docs/进度.md 已知坑 9）。tb_fir_coef.v 会检查没有 x。
    reg signed [CW-1:0] coef [0:N-1];
    initial begin
        $readmemh({`FIR_COEFDIR, COEF_FILE}, coef);
    end

    // ── 级 1：输入寄存 + 采样延迟线 ──────────────────────────────────
    // 时钟沿之后：
    //   x_r    = x[n]        （当前样本）
    //   dly[0] = x[n-1]
    //   dly[i] = x[n-1-i]
    // 所以"窗口" win[i] = x[n-i] 在 RTL 里写成：
    //   i == 0 → x_r
    //   i >= 1 → dly[i-1]
    reg signed [IW-1:0] x_r;
    reg signed [IW-1:0] dly [0:N-2];     // N-1 个历史样本（N>=2）

    integer di;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r <= {IW{1'b0}};
            for (di = 0; di < N-1; di = di + 1)
                dly[di] <= {IW{1'b0}}; // 复位时延迟线清零
        end else begin
            x_r <= x_in; // 当前样本寄存
            dly[0] <= x_r;               // 注意：这里用的是**旧的** x_r
            for (di = 1; di < N-1; di = di + 1) //编译时 for 语句变成 N-2 个独立的赋值语句
                dly[di] <= dly[di-1]; //一个个往前延迟线深处推
        end
    end

    // ── 级 2 的组合部分：对称预加 + 乘法 ────────────────────────────
    // 奇数 N：HALF 对 + 1 个中心抽头，共 NP = HALF+1 个乘积
    // 偶数 N：HALF 对，共 NP = HALF 个乘积
    //
    // 每一对 (i, N-1-i) 的窗口值是 x[n-i] 和 x[n-(N-1-i)]：
    //   xa = win[i]       = (i==0) ? x_r : dly[i-1]
    //   xb = win[N-1-i]   = dly[N-2-i]
    // 预加先符号扩展 1 位再相加（两个 IW 位有符号数相加可能到 IW+1 位）。
    wire signed [PROD_W-1:0] prod [0:NP-1];

    genvar gi; //generate index
    generate //用 generate 是因为要生成若干独立的 assign 语句，不能用 for 循环（for 循环会生成一个数组赋值）。
        for (gi = 0; gi < HALF; gi = gi + 1) begin : g_pair // generate 块的名字
            if (gi == 0) begin : g_first //这个条件分支的名字
                // 第一对：窗口的"新端"是当前样本 x_r，不是延迟线。
                // 单独写一个分支，是为了**不让 dly[-1] 出现在任何表达式里** ——
                // 即使三元运算符没选中它，iverilog 展开时也会对 dly[-1] 报越界警告。
                // 下面的 pa 是 pre-adder 的意思，PA_W 位宽。是把成对的两个样本先加起来再乘系数。
                wire signed [PA_W-1:0] pa = {{1{x_r[IW-1]}}, x_r} //符号扩展一位
                                          + {{1{dly[N-2][IW-1]}}, dly[N-2]}; //最新的采样和最旧的采样，延迟线的头和尾
                assign prod[0] = pa * coef[0]; // 加完了再乘系数
            end else begin : g_rest
                wire signed [IW-1:0] xa = dly[gi-1];
                wire signed [IW-1:0] xb = dly[N-2-gi];
                wire signed [PA_W-1:0] pa = {{1{xa[IW-1]}}, xa} //相加之前先符号扩展一位
                                          + {{1{xb[IW-1]}}, xb};
                assign prod[gi] = pa * coef[gi];
            end
        end

        if (N % 2 != 0) begin : g_center
            // 奇数 N 的中心抽头：窗口下标是 (N-1)/2 = HALF，
            // 也就是 dly[HALF-1]（不是 x_r！中心样本已经是 23 拍之前的事了）。（对于47抽头，HALF=23，中心抽头是 x[n-23]，在 dly[22] 里）
            wire signed [IW-1:0] xc = dly[HALF-1]; //找到延迟线里对应中心抽头的样本
            wire signed [PA_W-1:0] pa = {{1{xc[IW-1]}}, xc};
            assign prod[NP-1] = pa * coef[HALF];
        end
    endgenerate

    // ── 级 2：乘积寄存器 ─────────────────────────────────────────────
    // 一个 always 块写整个数组，避免"多个 always 块驱动同一个数组"的综合歧义。
    reg signed [PROD_W-1:0] p_reg [0:NP-1];
    integer pi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pi = 0; pi < NP; pi = pi + 1)
                p_reg[pi] <= {PROD_W{1'b0}};
        end else begin
            for (pi = 0; pi < NP; pi = pi + 1)
                p_reg[pi] <= prod[pi]; //之前的 prod 数组是纯逻辑的，把样本和系数用线网连接起来，这一部分才给寄存器p_reg
        end
    end

    // ── 级 3：分成 4 组做部分和 ──────────────────────────────────────
    // 组内相加是组合逻辑（最多 GSUM_N 个乘积，GSUM_N=6 时是 3 层加法），
    // 结果在时钟沿打一拍。组间相加留到级 4。
    //
    // 这里用 function 而不是 always @*：function 只在时钟沿被调用，
    // 不会有"@* 对数组敏感"的告警；综合时 for 循环会展开、base 变成常量。
    // 如果用 always @* 读 p_reg 数组，iverilog 会打印
    //   "@* is sensitive to all N words in array 'p_reg'"
    // 虽然结果是对的，但 lint 日志会变脏。
    reg signed [SUM_W-1:0] gsum [0:GROUPS-1];
    integer g;
    //这段比较无聊，就是先做部分和的组合逻辑再做寄存器，避免 24 个乘积在一个 always 块里做 5 层加法，时序余量被吃掉。
    function signed [SUM_W-1:0] group_sum;
        input integer base;
        integer t;
        begin
            group_sum = {SUM_W{1'b0}};
            for (t = 0; t < GSUM_N; t = t + 1) begin
                if (base + t < NP)
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
    // 4 组的和不会超出 SUM_W：SUM_W 已经按"NP 个乘积"留够了位。
    wire signed [SUM_W-1:0] sum_all = gsum[0] + gsum[1] + gsum[2] + gsum[3];

    // 舍入常数 = 半个 LSB = 1 << (SHIFT-1)。
    // 先加宽 1 位，因为加完半个 LSB 之后最大正值可能刚好越过 SUM_W 的上界。
    // 先算一个安全的移位量：SHIFT=0 时下面三元表达式的假分支虽然不会被选中，
    // 但常量表达式里的 <<< -1 是未定义行为，干脆把移位量单独限制到 >=0。
    localparam integer RND_SH = (SHIFT > 0) ? (SHIFT - 1) : 0;
    localparam signed [FINAL_W-1:0] RND_C =
        (ROUND != 0 && SHIFT > 0) ? ({{FINAL_W-1{1'b0}}, 1'b1} <<< RND_SH)
                                  : {FINAL_W{1'b0}};
    //上面是做舍入的标准步骤，把数字1左移 RND_SH 位，得到半个 LSB 的值，然后加到 sum_all 上。后面再右移，就变成了四舍五入的效果。ROUND=0 时不加，直接截断。
    wire signed [FINAL_W-1:0] sum_ext = {sum_all[SUM_W-1], sum_all}; //符号扩展一位，防止加上半个 LSB 后溢出
    wire signed [FINAL_W-1:0] sum_rnd = sum_ext + RND_C;
    wire signed [FINAL_W-1:0] sum_sh  = sum_rnd >>> SHIFT;   // 算术右移 = 向 -inf 取整

    // 饱和（不是回绕）：回绕会把最大正数变成最大负数，波形上突然翻符号。
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
