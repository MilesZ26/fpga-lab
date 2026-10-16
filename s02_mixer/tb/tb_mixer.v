`timescale 1ns/1ps
//=============================================================================
// tb_mixer — s02 复数混频器验收测试
//-----------------------------------------------------------------------------
// 被测：s02_mixer/rtl/mixer.v
//
// 验证方法（三种，故意用不同的手段，避免"自己证明自己"）：
//
//   ① **参考模型 + 向量回放**：scripts/gen_mixer_vec.py 用 Python 独立算好
//      (输入, 期望输出)，落在 s02_mixer/vec/mixer_{a,b,c,d}.txt。
//      这里只负责逐拍回放 + 逐位比对。Python 是第三种语言，位宽规则和 Verilog
//      无关，所以两边同时错的可能性很小。
//
//   ② **性质断言**：不看具体数值，只看"混频器应该满足的性质"——
//      单位幅度本振下幅度保持不变、旋转 90° 就是把 (i,q) 交换并改符号、
//      零输入出零。这类断言换了参数也成立，能抓住"整体尺度错 2 倍"这种错。
//
//   ③ **边界手算**：舍入的 tie（被丢掉的低位刚好是半个 LSB）、正负饱和、
//      CONJ 开关的方向 —— 每条都直接把期望值写在断言里，人能一眼核对。
//
// 四个 DUT 配置（与 scripts/gen_mixer_vec.py 的 PRESETS 一一对应）：
//   A  IW=12 AW=12 OW=13 SHIFT=11 ROUND=1 CONJ=0  主配置：单位增益 + 四舍五入 + 上变频
//   B  IW=12 AW=12 OW=8  SHIFT=6  ROUND=0 CONJ=1  故意让它饱和：验截断 + 饱和 + 下变频
//   C  IW=8  AW=10 OW=12 SHIFT=9  ROUND=1 CONJ=0  换一组位宽：验参数化真的生效
//   D  IW=12 AW=12 OW=13 SHIFT=11 ROUND=0 CONJ=0  与 A 输入完全相同，只有舍入方式不同
//
// 为什么 A 与 D 要成对：SHIFT=11 时"被丢掉的 11 位"刚好等于半个 LSB 的用例
// 是唯一能区分"四舍五入"和"截断"的地方。两个 DUT 吃同一串输入、结果不同，
// 才证明 ROUND 参数不是摆设（这叫"给测试本身做测试"）。
//
// 延迟约定：mixer 是"组合乘加 + 输出寄存器"，输入到输出**正好 1 拍**。
// 回放里每拍换一个输入、下一拍比对，所以**这条延迟也被一起验了**——
// 如果 RTL 变成 2 拍延迟，或者输出没寄存（组合直通），回放会全错。
//=============================================================================
module tb_mixer;
    `include "tb_common.vh"

`ifndef VECDIR
  `define VECDIR "s02_mixer/vec/"
`endif

    // ── 向量数组 ─────────────────────────────────────────────────
    // 每个文件：第 0 个字是哨兵 C0FFEE01，第 1 个字是用例个数，
    // 之后每 6 个字一个用例（i q cos sin i_out q_out，32 位补码位模式）。
    // ⚠️ 数组必须**刚好**装得下：$readmemh 遇到文件比数组长会打
    // "Not enough words in the file" 告警（而且尾部会被截断）。
    // 用例数由生成器的 N_RANDOM 决定，改了生成器就要同步改这里 ——
    // 下面有 cases_* <= VEC_MAX_CASES 的断言兜住这件事。
    localparam integer VEC_MAX_CASES = 1620;              // 生成器的 N_PAD，四个文件都一样长
    localparam integer VEC_MAX = 2 + 6*VEC_MAX_CASES;     // 哨兵 + 个数 + 每个用例 6 个字

    reg [31:0] veca [0:VEC_MAX-1];
    reg [31:0] vecb [0:VEC_MAX-1];
    reg [31:0] vecc [0:VEC_MAX-1];
    reg [31:0] vecd [0:VEC_MAX-1];

    // ── 四个 DUT 的配置（必须和生成器 PRESETS 一致！）────────────
    localparam integer IW_A = 12, AW_A = 12, OW_A = 13, SH_A = 11;
    localparam integer IW_B = 12, AW_B = 12, OW_B = 8,  SH_B = 6;
    localparam integer IW_C = 8,  AW_C = 10, OW_C = 12, SH_C = 9;
    localparam integer IW_D = 12, AW_D = 12, OW_D = 13, SH_D = 11;

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;

    // A
    reg  signed [IW_A-1:0] a_i, a_q;
    reg  signed [AW_A-1:0] a_c, a_s;
    wire signed [OW_A-1:0] a_oi, a_oq;
    // B
    reg  signed [IW_B-1:0] b_i, b_q;
    reg  signed [AW_B-1:0] b_c, b_s;
    wire signed [OW_B-1:0] b_oi, b_oq;
    // C
    reg  signed [IW_C-1:0] c_i, c_q;
    reg  signed [AW_C-1:0] c_c, c_s;
    wire signed [OW_C-1:0] c_oi, c_oq;
    // D
    reg  signed [IW_D-1:0] d_i, d_q;
    reg  signed [AW_D-1:0] d_c, d_s;
    wire signed [OW_D-1:0] d_oi, d_oq;

    always #(`CLK_PERIOD/2) clk = ~clk;

    mixer #(.IW(IW_A), .AW(AW_A), .OW(OW_A), .SHIFT(SH_A), .ROUND(1), .CONJ(0))
    dut_a (.clk(clk), .rst_n(rst_n), .i_in(a_i), .q_in(a_q),
           .cos_in(a_c), .sin_in(a_s), .i_out(a_oi), .q_out(a_oq));

    mixer #(.IW(IW_B), .AW(AW_B), .OW(OW_B), .SHIFT(SH_B), .ROUND(0), .CONJ(1))
    dut_b (.clk(clk), .rst_n(rst_n), .i_in(b_i), .q_in(b_q),
           .cos_in(b_c), .sin_in(b_s), .i_out(b_oi), .q_out(b_oq));

    mixer #(.IW(IW_C), .AW(AW_C), .OW(OW_C), .SHIFT(SH_C), .ROUND(1), .CONJ(0))
    dut_c (.clk(clk), .rst_n(rst_n), .i_in(c_i), .q_in(c_q),
           .cos_in(c_c), .sin_in(c_s), .i_out(c_oi), .q_out(c_oq));

    mixer #(.IW(IW_D), .AW(AW_D), .OW(OW_D), .SHIFT(SH_D), .ROUND(0), .CONJ(0))
    dut_d (.clk(clk), .rst_n(rst_n), .i_in(d_i), .q_in(d_q),
           .cos_in(d_c), .sin_in(d_s), .i_out(d_oi), .q_out(d_oq));

`ifdef DUMP_VCD
    // 只 dump 关心的信号。**千万不要** $dumpvars(0, tb_mixer)：
    // 那会把 4 个 12000 字的向量数组全写进 VCD，文件几百 MB。
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(1, tb_mixer.clk, tb_mixer.rst_n);
        $dumpvars(1, tb_mixer.a_i, tb_mixer.a_q, tb_mixer.a_c, tb_mixer.a_s,
                     tb_mixer.a_oi, tb_mixer.a_oq);
        $dumpvars(1, tb_mixer.b_i, tb_mixer.b_q, tb_mixer.b_c, tb_mixer.b_s,
                     tb_mixer.b_oi, tb_mixer.b_oq);
        $dumpvars(1, tb_mixer.c_i, tb_mixer.c_q, tb_mixer.c_c, tb_mixer.c_s,
                     tb_mixer.c_oi, tb_mixer.c_oq);
        $dumpvars(1, tb_mixer.d_oi, tb_mixer.d_oq);
    end
`endif

    // ── 工具 ─────────────────────────────────────────────────────
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            repeat (2) @(posedge clk);
            #1;
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    // 量化一个本振样本：x 是 [-1,1] 的实数，返回四舍五入到 AW_A 位补码的值。
    // 只在 TB 里用（$cos/$sin/$rtoi 不可综合，RTL 里绝对看不到）。
    function signed [AW_A-1:0] quant_lo;
        input real x;
        begin
            if (x >= 0.0)
                quant_lo = $rtoi(x * 2047.0 + 0.5);
            else
                quant_lo = -$rtoi(-x * 2047.0 + 0.5);
        end
    endfunction

    // 向量文件自查：这个 32 位字能不能装进 w 位补码。
    // 装不进说明"生成器给了超出端口的输入" —— RTL 会静默截位，测试却可能照样绿。
    function integer fits_w;
        input [31:0] word;
        input integer w;
        reg signed [31:0] sv;
        begin
            sv = word;
            fits_w = (sv >= -(1 << (w-1))) && (sv <= (1 << (w-1)) - 1);
        end
    endfunction

    // ── 回放：单 DUT ─────────────────────────────────────────────
    integer mismatch_a, mismatch_b, mismatch_c, mismatch_d;
    integer cases_a, cases_b, cases_c, cases_d;
    integer diff_ad, in_mismatch_ad, range_bad;

    task replay_a;
        input integer n;
        integer k, bad;
        reg [31:0] w;
        reg signed [IW_A-1:0] ii, qq;
        reg signed [AW_A-1:0] cc, ss;
        reg signed [OW_A-1:0] ei, eq;
        begin
            bad = 0;
            for (k = 0; k < n; k = k + 1) begin
                w = veca[2 + 6*k + 0]; ii = w[IW_A-1:0];
                w = veca[2 + 6*k + 1]; qq = w[IW_A-1:0];
                w = veca[2 + 6*k + 2]; cc = w[AW_A-1:0];
                w = veca[2 + 6*k + 3]; ss = w[AW_A-1:0];
                w = veca[2 + 6*k + 4]; ei = w[OW_A-1:0];
                w = veca[2 + 6*k + 5]; eq = w[OW_A-1:0];
                a_i = ii; a_q = qq; a_c = cc; a_s = ss;
                tick;                       // 这一拍采样 = 上一拍输入的响应
                if (a_oi !== ei || a_oq !== eq) begin
                    bad = bad + 1;
                    if (bad <= 3)
                        $display("    [A] 用例 %0d：i=%0d q=%0d c=%0d s=%0d → 期望 (%0d,%0d)，实测 (%0d,%0d)",
                                 k, $signed(ii), $signed(qq), $signed(cc), $signed(ss),
                                 $signed(ei), $signed(eq), $signed(a_oi), $signed(a_oq));
                end
            end
            mismatch_a = bad;
        end
    endtask

    task replay_b;
        input integer n;
        integer k, bad;
        reg [31:0] w;
        reg signed [IW_B-1:0] ii, qq;
        reg signed [AW_B-1:0] cc, ss;
        reg signed [OW_B-1:0] ei, eq;
        begin
            bad = 0;
            for (k = 0; k < n; k = k + 1) begin
                w = vecb[2 + 6*k + 0]; ii = w[IW_B-1:0];
                w = vecb[2 + 6*k + 1]; qq = w[IW_B-1:0];
                w = vecb[2 + 6*k + 2]; cc = w[AW_B-1:0];
                w = vecb[2 + 6*k + 3]; ss = w[AW_B-1:0];
                w = vecb[2 + 6*k + 4]; ei = w[OW_B-1:0];
                w = vecb[2 + 6*k + 5]; eq = w[OW_B-1:0];
                b_i = ii; b_q = qq; b_c = cc; b_s = ss;
                tick;
                if (b_oi !== ei || b_oq !== eq) begin
                    bad = bad + 1;
                    if (bad <= 3)
                        $display("    [B] 用例 %0d：i=%0d q=%0d c=%0d s=%0d → 期望 (%0d,%0d)，实测 (%0d,%0d)",
                                 k, $signed(ii), $signed(qq), $signed(cc), $signed(ss),
                                 $signed(ei), $signed(eq), $signed(b_oi), $signed(b_oq));
                end
            end
            mismatch_b = bad;
        end
    endtask

    task replay_c;
        input integer n;
        integer k, bad;
        reg [31:0] w;
        reg signed [IW_C-1:0] ii, qq;
        reg signed [AW_C-1:0] cc, ss;
        reg signed [OW_C-1:0] ei, eq;
        begin
            bad = 0;
            for (k = 0; k < n; k = k + 1) begin
                w = vecc[2 + 6*k + 0]; ii = w[IW_C-1:0];
                w = vecc[2 + 6*k + 1]; qq = w[IW_C-1:0];
                w = vecc[2 + 6*k + 2]; cc = w[AW_C-1:0];
                w = vecc[2 + 6*k + 3]; ss = w[AW_C-1:0];
                w = vecc[2 + 6*k + 4]; ei = w[OW_C-1:0];
                w = vecc[2 + 6*k + 5]; eq = w[OW_C-1:0];
                c_i = ii; c_q = qq; c_c = cc; c_s = ss;
                tick;
                if (c_oi !== ei || c_oq !== eq) begin
                    bad = bad + 1;
                    if (bad <= 3)
                        $display("    [C] 用例 %0d：i=%0d q=%0d c=%0d s=%0d → 期望 (%0d,%0d)，实测 (%0d,%0d)",
                                 k, $signed(ii), $signed(qq), $signed(cc), $signed(ss),
                                 $signed(ei), $signed(eq), $signed(c_oi), $signed(c_oq));
                end
            end
            mismatch_c = bad;
        end
    endtask

    // A 与 D 同时回放：输入字段必须逐字相同（生成器保证），输出各自比对，
    // 顺带统计两者输出不同的用例数 —— 用它证明 ROUND 参数真的在起作用。
    task replay_ad_lockstep;
        input integer n;
        integer k;
        reg [31:0] w;
        reg signed [IW_A-1:0] ii, qq;
        reg signed [AW_A-1:0] cc, ss;
        reg signed [OW_A-1:0] eai, eaq, edi, edq;
        begin
            mismatch_a = 0;
            mismatch_d = 0;
            in_mismatch_ad = 0;
            diff_ad = 0;
            for (k = 0; k < n; k = k + 1) begin
                if (veca[2+6*k+0] !== vecd[2+6*k+0] ||
                    veca[2+6*k+1] !== vecd[2+6*k+1] ||
                    veca[2+6*k+2] !== vecd[2+6*k+2] ||
                    veca[2+6*k+3] !== vecd[2+6*k+3])
                    in_mismatch_ad = in_mismatch_ad + 1;

                w = veca[2 + 6*k + 0]; ii = w[IW_A-1:0];
                w = veca[2 + 6*k + 1]; qq = w[IW_A-1:0];
                w = veca[2 + 6*k + 2]; cc = w[AW_A-1:0];
                w = veca[2 + 6*k + 3]; ss = w[AW_A-1:0];
                w = veca[2 + 6*k + 4]; eai = w[OW_A-1:0];
                w = veca[2 + 6*k + 5]; eaq = w[OW_A-1:0];
                w = vecd[2 + 6*k + 4]; edi = w[OW_D-1:0];
                w = vecd[2 + 6*k + 5]; edq = w[OW_D-1:0];

                a_i = ii; a_q = qq; a_c = cc; a_s = ss;
                d_i = ii; d_q = qq; d_c = cc; d_s = ss;
                tick;
                if (a_oi !== eai || a_oq !== eaq) mismatch_a = mismatch_a + 1;
                if (d_oi !== edi || d_oq !== edq) mismatch_d = mismatch_d + 1;
                if (a_oi !== d_oi || a_oq !== d_oq) diff_ad = diff_ad + 1;
            end
        end
    endtask

    // ── 主流程 ───────────────────────────────────────────────────
    integer k, lat1, lat2, lat_ok;
    integer mag_in, mag_out, dev, dev_max, dev_max_n;
    real th;
    reg signed [OW_A-1:0] hold_i;

    initial begin
        // 先给一个确定的初值，避免第 1 拍比对时输入是 x
        a_i = 0; a_q = 0; a_c = 0; a_s = 0;
        b_i = 0; b_q = 0; b_c = 0; b_s = 0;
        c_i = 0; c_q = 0; c_c = 0; c_s = 0;
        d_i = 0; d_q = 0; d_c = 0; d_s = 0;

        // ══ 1. 读向量文件（哨兵字是防"读不到文件不报错"的）══════
        $readmemh({`VECDIR, "mixer_a.txt"}, veca);
        $readmemh({`VECDIR, "mixer_b.txt"}, vecb);
        $readmemh({`VECDIR, "mixer_c.txt"}, vecc);
        $readmemh({`VECDIR, "mixer_d.txt"}, vecd);

        `check_eq("mixer_a.txt 读到了（第 1 个字 = 哨兵 C0FFEE01）", veca[0], 32'hC0FFEE01);
        `check_eq("mixer_b.txt 读到了（第 1 个字 = 哨兵 C0FFEE01）", vecb[0], 32'hC0FFEE01);
        `check_eq("mixer_c.txt 读到了（第 1 个字 = 哨兵 C0FFEE01）", vecc[0], 32'hC0FFEE01);
        `check_eq("mixer_d.txt 读到了（第 1 个字 = 哨兵 C0FFEE01）", vecd[0], 32'hC0FFEE01);

        cases_a = veca[1];
        cases_b = vecb[1];
        cases_c = vecc[1];
        cases_d = vecd[1];
        $display("向量用例数：A=%0d B=%0d C=%0d D=%0d",
                 cases_a, cases_b, cases_c, cases_d);
        `check(cases_a > 1000 && cases_b > 1000 && cases_c > 1000 && cases_d > 1000,
               "四组向量的用例数都 > 1000（文件被截断/换行符搞坏会在这里现形）");
        // 必须**恰好等于**：$readmemh 的文件字数少于数组长度会打告警，
        // 多于数组长度会静默截断。相等是唯一干净的状态。
        `check_eq("A 用例数 = 数组容量（$readmemh 不告警、不截断）", cases_a, VEC_MAX_CASES);
        `check_eq("B 用例数 = 数组容量", cases_b, VEC_MAX_CASES);
        `check_eq("C 用例数 = 数组容量", cases_c, VEC_MAX_CASES);
        `check_eq("D 用例数 = 数组容量", cases_d, VEC_MAX_CASES);

        // ══ 1b. 向量文件自查：输入必须装得进对应端口 ═════════════
        // 这叫"给测试做测试"。生成器要是给了超出位宽的输入（比如 IW=8 却给 511），
        // RTL 会**静默截位**，回放仍然可能全绿 —— 那测的就不是设计，是巧合。
        // 所以先证明喂进去的每一个数本身合法。
        range_bad = 0;
        for (k = 0; k < cases_a; k = k + 1) begin
            if (!fits_w(veca[2+6*k+0], IW_A)) range_bad = range_bad + 1;
            if (!fits_w(veca[2+6*k+1], IW_A)) range_bad = range_bad + 1;
            if (!fits_w(veca[2+6*k+2], AW_A)) range_bad = range_bad + 1;
            if (!fits_w(veca[2+6*k+3], AW_A)) range_bad = range_bad + 1;
        end
        for (k = 0; k < cases_b; k = k + 1) begin
            if (!fits_w(vecb[2+6*k+0], IW_B)) range_bad = range_bad + 1;
            if (!fits_w(vecb[2+6*k+1], IW_B)) range_bad = range_bad + 1;
            if (!fits_w(vecb[2+6*k+2], AW_B)) range_bad = range_bad + 1;
            if (!fits_w(vecb[2+6*k+3], AW_B)) range_bad = range_bad + 1;
        end
        for (k = 0; k < cases_c; k = k + 1) begin
            if (!fits_w(vecc[2+6*k+0], IW_C)) range_bad = range_bad + 1;
            if (!fits_w(vecc[2+6*k+1], IW_C)) range_bad = range_bad + 1;
            if (!fits_w(vecc[2+6*k+2], AW_C)) range_bad = range_bad + 1;
            if (!fits_w(vecc[2+6*k+3], AW_C)) range_bad = range_bad + 1;
        end
        for (k = 0; k < cases_d; k = k + 1) begin
            if (!fits_w(vecd[2+6*k+0], IW_D)) range_bad = range_bad + 1;
            if (!fits_w(vecd[2+6*k+1], IW_D)) range_bad = range_bad + 1;
            if (!fits_w(vecd[2+6*k+2], AW_D)) range_bad = range_bad + 1;
            if (!fits_w(vecd[2+6*k+3], AW_D)) range_bad = range_bad + 1;
        end
        `check_eq("四组向量里的输入都在各自端口的位宽范围内（生成器给错位宽会在这里现形）",
                  range_bad, 0);

        // ══ 2. 复位行为 ═════════════════════════════════════════
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        `check(a_oi === 13'sd0 && a_oq === 13'sd0, "复位期间 A 输出 = 0（不是 x）");
        `check(b_oi === 8'sd0  && b_oq === 8'sd0,  "复位期间 B 输出 = 0（不是 x）");
        `check(c_oi === 12'sd0 && c_oq === 12'sd0, "复位期间 C 输出 = 0（不是 x）");

        // 复位期间把输入拉满：输出必须仍然是 0 —— 复位优先级高于数据
        a_i = 12'sd2047; a_q = 12'sd2047; a_c = 12'sd2047; a_s = -12'sd2048;
        tick;
        `check(a_oi === 13'sd0 && a_oq === 13'sd0,
               "复位期间输入拉满，输出仍是 0（复位优先）");

        // 异步复位：不等时钟沿就清零
        rst_n = 1'b1;
        a_i = 12'sd100; a_q = 12'sd100; a_c = 12'sd2047; a_s = 12'sd0;
        repeat (3) @(posedge clk);
        @(posedge clk);
        #3;
        rst_n = 1'b0;                 // 故意停在时钟中间
        #1;
        `check(a_oi === 13'sd0 && a_oq === 13'sd0,
               "异步复位：时钟沿中间拉低 rst_n，输出立刻清零");
        rst_n = 1'b1;

        // ══ 3. 显式验 1 拍延迟 ══════════════════════════════════
        do_reset;
        a_c = 12'sd2047; a_s = 12'sd0;      // 本振 = 单位实轴
        a_i = 12'sd100;  a_q = 12'sd0;      // 期望 round(100*2047/2048) = 100
        tick;
        lat1 = a_oi;
        hold_i = a_oi;                      // 记住这一拍的输出
        a_i = 12'sd200;                     // 立刻改输入，时钟沿还没来
        #1;
        lat_ok = (a_oi === hold_i);         // 输出应该还没动
        tick;
        lat2 = a_oi;
        `check_eq("延迟 1 拍：输入 100 时输出 100", lat1, 100);
        `check(lat_ok, "延迟 1 拍：输入变了但时钟沿没来，输出保持上一拍的值（没有组合直通）");
        `check_eq("延迟 1 拍：下一个时钟沿才更新成 200", lat2, 200);

        // ══ 4. 向量回放 ═════════════════════════════════════════
        do_reset;
        replay_a(cases_a);
        `check_eq("A：1620 个用例逐位精确（ROUND=1 / SHIFT=11 / CONJ=0）", mismatch_a, 0);

        do_reset;
        replay_b(cases_b);
        `check_eq("B：1620 个用例逐位精确（ROUND=0 / SHIFT=6 / CONJ=1 / 会饱和）", mismatch_b, 0);

        do_reset;
        replay_c(cases_c);
        `check_eq("C：1620 个用例逐位精确（IW=8 AW=10 OW=12，换位宽仍然对）", mismatch_c, 0);

        do_reset;
        replay_ad_lockstep(cases_a);
        `check_eq("A 与 D 两组向量的输入字段逐字相同（可比性前提）", in_mismatch_ad, 0);
        `check_eq("A：回放仍然全对", mismatch_a, 0);
        `check_eq("D：1620 个用例逐位精确（ROUND=0，其余同 A）", mismatch_d, 0);
        $display("A(四舍五入) 与 D(截断) 输出不同的用例数：%0d / %0d", diff_ad, cases_a);
        `check(diff_ad > 0, "ROUND 参数真的起作用：A 与 D 的输出确有不同（否则这个开关是摆设）");

        // ══ 5. 舍入边界手算（人能一眼核对的数值）════════════════
        // SHIFT=11 时"半个 LSB"是 1024。取本振 cos=1024、sin=0、q=0，
        // 于是 i_sum = i*1024，正好落在 tie 上。
        do_reset;
        a_c = 12'sd1024; a_s = 12'sd0;
        d_c = 12'sd1024; d_s = 12'sd0;
        a_q = 12'sd0;    d_q = 12'sd0;

        a_i = 12'sd1;  d_i = 12'sd1;        // i_sum = 1024 = 0.5 LSB
        tick;
        `check_eq("四舍五入：1024 >> 11 = 1（tie 向上）", a_oi, 13'sd1);
        `check_eq("直接截断：1024 >> 11 = 0（向 -inf 取整）", d_oi, 13'sd0);

        a_i = 12'sd1;  d_i = 12'sd1;
        a_c = 12'sd1023; d_c = 12'sd1023;   // i_sum = 1023，比半个 LSB 小一点
        tick;
        `check_eq("四舍五入：1023 >> 11 = 0（不足半个 LSB 不能进位）", a_oi, 13'sd0);
        `check_eq("直接截断：1023 >> 11 = 0", d_oi, 13'sd0);

        a_c = 12'sd1024; d_c = 12'sd1024;
        a_i = -12'sd1;  d_i = -12'sd1;      // i_sum = -1024（负的 tie）
        tick;
        `check_eq("四舍五入（负 tie）：(-1024 + 1024) >> 11 = 0", a_oi, 13'sd0);
        `check_eq("直接截断（负 tie）：-1024 >> 11 = -1（向 -inf）", d_oi, -13'sd1);

        a_i = 12'sd3;  d_i = 12'sd3;        // i_sum = 3072 = 1.5 LSB
        tick;
        `check_eq("四舍五入：3072 >> 11 = 2", a_oi, 13'sd2);
        `check_eq("直接截断：3072 >> 11 = 1", d_oi, 13'sd1);

        // ══ 6. 饱和（B：OW=8 / SHIFT=6）═════════════════════════
        // 不饱和时是 65472，远超 8 位补码的 +127；必须**钳住**而不是回绕。
        do_reset;
        b_i = 12'sd2047; b_q = 12'sd0; b_c = 12'sd2047; b_s = 12'sd0;
        tick;
        `check_eq("饱和：正溢出钳到 +127（回绕的话会变成 -128/别的负数）", b_oi, 8'sd127);

        b_i = -12'sd2048; b_q = 12'sd0; b_c = 12'sd2047; b_s = 12'sd0;
        tick;
        `check_eq("饱和：负溢出钳到 -128", b_oi, -8'sd128);

        b_i = 12'sd1; b_q = 12'sd0; b_c = 12'sd64; b_s = 12'sd0;
        tick;                                // 64 >> 6 = 1，不需要饱和
        `check_eq("没越界时不饱和：64 >> 6 = 1", b_oi, 8'sd1);

        // ══ 7. CONJ（上/下变频方向）═════════════════════════════
        // B 是 CONJ=1（下变频）：
        //   i_out = i*cos + q*sin,  q_out = q*cos - i*sin
        // 取 cos=0、sin=64，i=q=64：i_sum = 64*64 = 4096 → 4096>>6 = 64
        //                            q_sum = -64*64 = -4096 → -4096>>6 = -64
        b_i = 12'sd64; b_q = 12'sd64; b_c = 12'sd0; b_s = 12'sd64;
        tick;
        `check_eq("下变频（CONJ=1）：cos=0,sin=64,i=q=64 → i_out = +64（i*cos + q*sin 这一项）",
                  b_oi, 8'sd64);
        `check_eq("下变频（CONJ=1）：同一组输入 → q_out = -64（-i*sin 这一项）",
                  b_oq, -8'sd64);

        // A 是 CONJ=0（上变频）；本振 (cos=0, sin=2047) 约等于 +90°：
        //   输入 (2047, 0) 应该转到 (0, +2047) 附近
        do_reset;
        a_i = 12'sd2047; a_q = 12'sd0; a_c = 12'sd0; a_s = 12'sd2047;
        tick;
        `check_eq("上变频（CONJ=0）：本振 +90°，输入 (2047,0) → i_out ≈ 0", a_oi, 13'sd0);
        `check_eq("上变频（CONJ=0）：本振 +90°，输入 (2047,0) → q_out ≈ +2046（2047²/2048 取整）",
                  a_oq, 13'sd2046);

        // ══ 8. 零输入 / 单位本振 ════════════════════════════════
        a_i = 12'sd0; a_q = 12'sd0; a_c = 12'sd2047; a_s = 12'sd0;
        tick;
        `check(a_oi === 13'sd0 && a_oq === 13'sd0, "零输入 + 满幅本振 → 输出仍是 0");

        // 单位实轴本振 (2047, 0)：输出 ≈ 输入，允许 2 LSB 误差。
        // 误差来源：本振的"1.0"是 2047/2048（不是 1），所以有个 -0.05% 的系统性缩小；
        // 2047 * 0.05% ≈ 1 LSB，再加输出本身的 0.5 LSB 舍入，判 2 LSB 是够的。
        a_i = 12'sd2047; a_q = -12'sd100; a_c = 12'sd2047; a_s = 12'sd0;
        tick;
        dev = (a_oi > 13'sd2047) ? (a_oi - 13'sd2047) : (13'sd2047 - a_oi);
        `check(dev <= 2, "单位本振 (2047,0)：i_out ≈ i_in（差 <= 2 LSB，见注释里的误差来源）");
        dev = (a_oq > -13'sd100) ? (a_oq + 13'sd100) : (-13'sd100 - a_oq);
        `check(dev <= 2, "单位本振 (2047,0)：q_out ≈ q_in（差 <= 2 LSB）");

        // ══ 9. 性质断言：单位幅度本振不改变幅度 ═════════════════
        // 混频只是"旋转 + 单位增益"，所以 sqrt(i²+q²) 应该保持不变。
        // 本振量化到 ±0.5 LSB，输入幅度 2047 时相对误差 < 0.05%，
        // 输出再叠 0.5 LSB 舍入 → |out| 的误差约 1.5 LSB；判据取 8 LSB。
        // 注意：这条判据对"SHIFT 少了一半/多了一半"这种尺度错误极其敏感
        //（那种错会让输出直接差 2 倍，≈1024 LSB），所以它是有牙齿的。
        do_reset;
        a_i = 12'sd2047; a_q = 12'sd0;
        dev_max = 0;
        dev_max_n = 0;
        for (k = 0; k < 32; k = k + 1) begin
            th = 2.0 * 3.141592653589793 * k / 32.0;
            a_c = quant_lo($cos(th));
            a_s = quant_lo($sin(th));
            tick;
            mag_in  = 2047*2047;
            mag_out = $signed(a_oi) * $signed(a_oi) + $signed(a_oq) * $signed(a_oq);
            dev = (mag_out > mag_in) ? (mag_out - mag_in) : (mag_in - mag_out);
            if (dev > dev_max) begin
                dev_max = dev;
                dev_max_n = k;
            end
        end
        $display("幅度保持：32 个本振相位点里最大偏差 %0d（在第 %0d 个点），判据 %0d",
                 dev_max, dev_max_n, 2*2047*8);
        `check(dev_max <= 2*2047*8,
               "单位幅度本振旋转 32 个相位点，|i²+q²| 的偏差都在 8 LSB 以内（尺度没搞错）");

        // ══ 10. 全零向量：i=q=cos=sin=0 ═════════════════════════
        a_i = 0; a_q = 0; a_c = 0; a_s = 0;
        tick;
        `check(a_oi === 13'sd0 && a_oq === 13'sd0, "全零输入 → 全零输出（没有多余的直流偏置）");

        tb_done;
    end

endmodule
