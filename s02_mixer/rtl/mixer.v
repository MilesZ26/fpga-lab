`timescale 1ns/1ps
//=============================================================================
// mixer — 复数混频器（complex mixer / 复本振乘法）
//-----------------------------------------------------------------------------
// 功能：
//   把输入基带复数 (i_in + j*q_in) 乘上复本振 e^{j*phi} = cos_in + j*sin_in：
//
//     CONJ=0 —— 上变频（乘 e^{+j*phi}，DUC 用这一侧）：
//         i_out = i_in*cos_in - q_in*sin_in
//         q_out = i_in*sin_in + q_in*cos_in
//
//     CONJ=1 —— 下变频（乘 e^{-j*phi}，即本振取共轭，DDC 用这一侧）：
//         i_out = i_in*cos_in + q_in*sin_in
//         q_out = q_in*cos_in - i_in*sin_in
//
//   本模块**不含 NCO**：cos/sin 由外面（nco.v）给。这样混频器就是一个纯
//   算术单元，可以单独用穷举/向量回放验，不用连带验 NCO。
//
// 时钟域：clk
// 延迟：  1 拍（输入 -> 输出；组合乘法 + 输出寄存器）
// 复位值：i_out = 0，q_out = 0
//
//-----------------------------------------------------------------------------
// 参数（三个位宽 + 三个行为开关）
//-----------------------------------------------------------------------------
//   IW    输入 i_in / q_in 位宽（补码）
//   AW    本振 cos_in / sin_in 位宽（补码）
//   OW    输出 i_out / q_out 位宽（补码），要求 OW <= IW+AW+1
//   SHIFT 输出右移位数 —— **这就是"增益分配"**，见下面「为什么要有 SHIFT」
//   ROUND 1 = 四舍五入（加半个 LSB 再右移）；0 = 直接截断（向 -inf 取整）
//   CONJ  0 = 上变频（e^{+jphi}）；1 = 下变频（e^{-jphi}）
//
//-----------------------------------------------------------------------------
// 三条必须想清楚的事（这也是 Stage 2 的核心）
//-----------------------------------------------------------------------------
// ① 位宽增长：i_in*cos_in 是 IW+AW 位，两个这样的乘积相加减再多 1 位。
//    所以"全精度和"是 SUM_W = IW+AW+1 位。RTL 里**先按全精度算，最后才截**——
//    提前截中间结果会多丢精度，而且省不下多少资源（乘法器本来就是这么大）。
//    例：IW=AW=12 时 FULL_W=24、SUM_W=25（(-2048)*(-2048)*2 = 2^23，
//    24 位补码最大只到 2^23-1，所以确实需要第 25 位）。
//
// ② 为什么要有 SHIFT（增益）：如果 i/q 和本振都是"1.0 = 2^(W-1)-1"的定点，
//    那么乘积的"1.0"变成了 2^(2W-2)，尺度被平方了。SHIFT = AW-1 正好把它除回去：
//    幅度 1.0 的本振乘完信号尺度不变（单位增益）。
//      - SHIFT 取小了 → 输出整体放大，容易饱和削顶；
//      - SHIFT 取大了 → 输出整体变小，白白丢掉低位精度。
//    这个取舍在 s05 集成为 DUC 时还要按整条链路的增益预算重算一次。
//
// ③ 截位与舍入：右移天然是"向 -inf 取整"（补码算术右移），
//    会给输出带来一个约 -0.5 LSB 的**直流偏置**。ROUND=1 时先加半个 LSB 再移，
//    变成四舍五入（tie 一律向 +inf），偏置基本消掉。代价是一个加法器。
//    ⚠️ 加了半个 LSB 之后，最大正值可能刚好越过 OW 的正上界，
//       所以这里先把和**加宽 1 位**再做舍入，最后**饱和**到 OW（不是回绕）。
//       回绕会把"最大的正数"变成"最大的负数"，波形上就是削顶处突然翻符号 ——
//       这是定点设计里最经典的一类事故。
//
//-----------------------------------------------------------------------------
// 参数与数据文件的对应关系：本模块**不读任何表**，纯算术。
//   本振由 nco.v 给（它的表在 s01_nco/lut/*.mem，$readmemh 的路径坑见那里）。
//   验收向量在 s02_mixer/vec/*.txt，由 scripts/gen_mixer_vec.py 生成。
//=============================================================================

module mixer #(
    parameter integer IW    = 12,          // 输入 i_in / q_in 位宽（补码）
    parameter integer AW    = 12,          // 本振 cos_in / sin_in 位宽（补码）
    parameter integer OW    = 13,          // 输出 i_out / q_out 位宽（补码）
    parameter integer SHIFT = AW - 1,      // 输出右移位数（增益归一化）
    parameter integer ROUND = 1,           // 1 = 四舍五入；0 = 截断
    parameter integer CONJ  = 0            // 0 = 上变频；1 = 下变频
)(
    input  wire                 clk,       // 时钟
    input  wire                 rst_n,     // 异步复位，低有效
    input  wire signed [IW-1:0] i_in,      // 输入 I（补码）
    input  wire signed [IW-1:0] q_in,      // 输入 Q（补码）
    input  wire signed [AW-1:0] cos_in,    // 本振 cos（补码）
    input  wire signed [AW-1:0] sin_in,    // 本振 sin（补码）
    output reg  signed [OW-1:0] i_out,     // 混频后 I（补码）
    output reg  signed [OW-1:0] q_out      // 混频后 Q（补码）
);

    // ── 位宽（编译期）────────────────────────────────────────────
    localparam integer FULL_W = IW + AW;        // 单个乘积的位宽
    localparam integer SUM_W  = FULL_W + 1;     // 两个乘积相加/减后的位宽

    // ── ① 全精度乘法 ─────────────────────────────────────────────
    // 赋值目标的宽度就是表达式的宽度，这里 FULL_W = IW+AW，所以是**不丢位**的乘积。
    // （如果写成 wire [IW-1:0] p = i_in * cos_in; 就会只留低 IW 位 —— 静默截断。）
    wire signed [FULL_W-1:0] p_ic = i_in * cos_in;   // I * cos
    wire signed [FULL_W-1:0] p_qs = q_in * sin_in;   // Q * sin
    wire signed [FULL_W-1:0] p_is = i_in * sin_in;   // I * sin
    wire signed [FULL_W-1:0] p_qc = q_in * cos_in;   // Q * cos

    // 每个乘积先**符号扩展 1 位**，再加减 —— 否则极端值相加减会溢出变号。
    wire signed [SUM_W-1:0] ic_x = {p_ic[FULL_W-1], p_ic}; //扩展后的 I 路和 cos 乘积
    wire signed [SUM_W-1:0] qs_x = {p_qs[FULL_W-1], p_qs}; //扩展后的 Q 路和 sin 乘积
    wire signed [SUM_W-1:0] is_x = {p_is[FULL_W-1], p_is}; //扩展后的 I 路和 sin 乘积
    wire signed [SUM_W-1:0] qc_x = {p_qc[FULL_W-1], p_qc}; //扩展后的 Q 路和 cos 乘积

    // 乘 e^{+jphi} 还是 e^{-jphi}：**带 j 的那两项（q*sin 和 i*sin）符号要一起翻**。
    //   CONJ=0：乘 e^{+jphi} → i 路是 -q*sin，q 路是 +i*sin
    //   CONJ=1：乘 e^{-jphi} → **两路都要翻**：i 路是 +q*sin，q 路是 -i*sin
    //   （第一版只翻了 q 路，于是 CONJ=1 变成了"既不共轭也不上变频"的第三种东西。
    //     向量回放抓不到它 —— Python 参考模型犯了**同一个**理解错误，
    //     这正是"自己证明自己"的经典失败方式；最后是一条手算的性质断言
    //     （cos=0,sin=64,i=q=64 → i_out 应该是 +64）把它揪出来的。）

    wire signed [SUM_W-1:0] qs_term = (CONJ != 0) ?  qs_x : -qs_x; //给第二项加正确的符号，上变频 I 路是 ic-qs， 下变频 I 路是 ic+qs，判断语句CONJ != 0 时是下变频，qs_term = +qs_x；CONJ=0 时是上变频，qs_term = -qs_x
    wire signed [SUM_W-1:0] is_term = (CONJ != 0) ? -is_x :  is_x; //给第二项加正确的符号，上变频 Q 路是 qc+is， 下变频 Q 路是 qc-is

    wire signed [SUM_W-1:0] i_sum = ic_x + qs_term;   // i*cos ∓ q*sin
    wire signed [SUM_W-1:0] q_sum = qc_x + is_term;   // q*cos ± i*sin

    // ── ② 舍入 + ③ 归一化右移 ───────────────────────────────────
    // 先加宽 1 位：舍入加的"半个 LSB"可能把最大正值顶出 SUM_W 位。
    wire signed [SUM_W:0] i_ext = {i_sum[SUM_W-1], i_sum};
    wire signed [SUM_W:0] q_ext = {q_sum[SUM_W-1], q_sum};

    // 半个 LSB = 1 << (SHIFT-1)。SHIFT=0（不移位）或 ROUND=0 时是 0。
    localparam signed [SUM_W:0] RND_C =
        (ROUND != 0 && SHIFT > 0) ? ({{SUM_W{1'b0}}, 1'b1} <<< (SHIFT-1))
                                  : {(SUM_W+1){1'b0}};

    wire signed [SUM_W:0] i_rnd = i_ext + RND_C;
    wire signed [SUM_W:0] q_rnd = q_ext + RND_C;

    // >>> 是算术右移：补码右移 = 向 -inf 取整（不是"截成 0 附近"）
    wire signed [SUM_W:0] i_sh = i_rnd >>> SHIFT;
    wire signed [SUM_W:0] q_sh = q_rnd >>> SHIFT;

    // ── 饱和到 OW 位（不回绕）, 用函数实现───────────────────────────────────
    localparam signed [SUM_W:0] OW_MAX = (64'sd1 <<< (OW-1)) - 1;   // 2^(OW-1)-1
    localparam signed [SUM_W:0] OW_MIN = -(64'sd1 <<< (OW-1));      // -2^(OW-1)

    function signed [OW-1:0] sat_ow;
        input signed [SUM_W:0] v;
        begin
            if (v > OW_MAX)
                sat_ow = OW_MAX[OW-1:0];
            else if (v < OW_MIN)
                sat_ow = OW_MIN[OW-1:0];
            else
                sat_ow = v[OW-1:0];
        end
    endfunction

    // ── 输出寄存器（1 拍延迟）────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_out <= {OW{1'b0}};
            q_out <= {OW{1'b0}};
        end else begin
            i_out <= sat_ow(i_sh); //两路都用饱和函数的返回值
            q_out <= sat_ow(q_sh);
        end
    end

endmodule
