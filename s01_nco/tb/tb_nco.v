`timescale 1ns/1ps
//=============================================================================
// tb_nco — NCO 验收测试
//-----------------------------------------------------------------------------
// 被测：s01_nco/rtl/nco.v（相位累加器 + $readmemh 查表，同步输出）
//
// 参数选取（照 TASK.md 的建议，让 FTW 整除、周期是整数拍，判据才干净）：
//   DUT A: CLK_HZ=1024, FREQ_HZ=16, PHASE_W=16
//          FTW = 16 * 2^16 / 1024 = 1024     → 周期 = 2^16/1024 = 64 拍
//   DUT B: CLK_HZ=1000, FREQ_HZ=13, PHASE_W=24
//          FTW 真值 = 13 * 2^24 / 1000 = 218103.808 → **截断**成 218103
//          故意选"除不尽"的：专门用来看 FTW 取整引起的频率偏差能不能被算出来
//   DUT C: CLK_HZ=1024, FREQ_HZ=16, PHASE_W=24（只换 PHASE_W）
//          FTW = 262144 → 周期仍是 64 拍：证明频率由 FTW 决定，与累加器位宽无关
//
// 时序约定：输出是"相位累加器 1 拍 + 输出寄存器 1 拍"，比当前相位晚 1 拍。
// 所以 TB 在每个 posedge 之后 #1 采样（这时 NBA 已经更新完），第 n 个样本对应
// 地址 addr(n) = (n * FTW) mod 2^PHASE_W 的高 12 位。
//
// 检查点分布（"改坏哪一行会变红"）：
//   复位行为      → phase_acc 复位值 / 输出的复位分支
//   PHI_INC 对账  → localparam 那条移位+除法（写错宽度会立刻红）
//   逐拍序列       → 地址取高位（移位量）/ 查表 / 1 拍延迟
//   周期           → 相位累加"加 FTW、自然溢出回绕"
//   幅度恒定       → 表本身 + sin/cos 用同一地址（错位一拍就会超容差）
//   参数换一组     → PHASE_W / 位宽切片是否真的参数化了
//=============================================================================
module tb_nco;
    `include "tb_common.vh"

`ifndef NCO_LUTDIR
  `ifdef LUTDIR
    `define NCO_LUTDIR `LUTDIR
  `else
    `define NCO_LUTDIR "s01_nco/lut/"
  `endif
`endif

    // ── DUT A：主验收对象 ────────────────────────────────────
    localparam integer CLK_HZ  = 1024;
    localparam integer FREQ_HZ = 16;
    localparam integer PHASE_W = 16;
    localparam integer LUT_AW  = 12;      // 必须和 nco 的默认值、以及 lut/*.mem 一致
    localparam integer AW      = 12;
    localparam integer FTW     = (FREQ_HZ * (64'd1 << PHASE_W)) / CLK_HZ;     // 1024
    localparam integer PERIOD  = (1 << PHASE_W) / FTW;                        // 64 拍

    // ── DUT B：不整除的 FTW（看取整误差）────────────────────
    localparam integer CLK_B   = 1000;
    localparam integer FREQ_B  = 13;
    localparam integer PHASE_B = 24;
    localparam integer FTW_B   = (FREQ_B * (64'd1 << PHASE_B)) / CLK_B;       // 218103

    // ── DUT C：只换 PHASE_W ─────────────────────────────────
    localparam integer PHASE_C = 24;
    localparam integer FTW_C   = (FREQ_HZ * (64'd1 << PHASE_C)) / CLK_HZ;     // 262144

    localparam integer ADDR_SH = PHASE_W - LUT_AW;  // 地址取相位高 LUT_AW 位
    localparam integer DEPTH   = 1 << LUT_AW;
    localparam integer AMP     = (1 << (AW-1)) - 1; // 表满幅（生成器约定）

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    wire signed [AW-1:0] sin_a, cos_a;
    wire signed [AW-1:0] sin_b, cos_b;
    wire signed [AW-1:0] sin_c, cos_c;

    always #(`CLK_PERIOD/2) clk = ~clk;

    nco #(.CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ), .PHASE_W(PHASE_W),
          .LUT_AW(LUT_AW), .AW(AW)) dut_a (
        .clk(clk), .rst_n(rst_n), .fsin_o(sin_a), .fcos_o(cos_a));
    nco #(.CLK_HZ(CLK_B),  .FREQ_HZ(FREQ_B),  .PHASE_W(PHASE_B),
          .LUT_AW(LUT_AW), .AW(AW)) dut_b (
        .clk(clk), .rst_n(rst_n), .fsin_o(sin_b), .fcos_o(cos_b));
    nco #(.CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ), .PHASE_W(PHASE_C),
          .LUT_AW(LUT_AW), .AW(AW)) dut_c (
        .clk(clk), .rst_n(rst_n), .fsin_o(sin_c), .fcos_o(cos_c));

`ifdef DUMP_VCD
    // 只 dump 关心的信号：ROM 有 4096 项，全 dump 会让 VCD 变成几十 MB
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(1, tb_nco);
        $dumpvars(1, dut_a.phase_acc, dut_a.addr, dut_a.fsin_o, dut_a.fcos_o);
        $dumpvars(1, dut_b.phase_acc, dut_b.fsin_o);
        $dumpvars(1, dut_c.phase_acc, dut_c.fsin_o);
    end
`endif

    // ── 参考表：TB 自己把同一份 .mem 读进来做 golden model ──────
    // 表本身的正确性由 tb_lut.v 负责；这里用它来验"地址 + 延迟 + 查表"。
    reg signed [AW-1:0] exp_sin [0:DEPTH-1];
    reg signed [AW-1:0] exp_cos [0:DEPTH-1];

    integer n, i, j, found, found2;
    integer seq_err, amp, amp_min, amp_max, amp_dev;
    integer events, span, started;
    integer peak_a1, peak_c;
    reg signed [AW-1:0] prev_b;
    real    f_theory_b, f_meas_b, f_err_ppm;

    // 采一拍：posedge 之后 #1，等非阻塞赋值落定
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        $readmemh({`NCO_LUTDIR, "sin.mem"}, exp_sin);
        $readmemh({`NCO_LUTDIR, "cos.mem"}, exp_cos);

        // ══ 1. 复位行为 ═══════════════════════════════════════
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        `check_eq("复位期间 phase_acc = 0", dut_a.phase_acc, 0);
        `check(sin_a === 12'sd0 && cos_a === 12'sd0, "复位期间 sin/cos 输出都是 0（不是 x）");

        // ══ 2. PHI_INC（频率控制字）与 1 拍延迟 ═══════════════
        rst_n = 1'b1;
        `check_eq("FTW = 16 * 2^16 / 1024 = 1024", dut_a.PHI_INC, FTW);

        tick;
        `check_eq("复位释放后第 1 拍：fsin_o = table[0] = 0", sin_a, 0);
        `check_eq("复位释放后第 1 拍：fcos_o = table[0] = +2047", cos_a, AMP);

        // ══ 3. 逐拍序列（golden model）+ 幅度恒定 ═════════════
        seq_err = 0;
        amp_min = 2147483647;
        amp_max = 0;
        for (n = 0; n < 4 * PERIOD; n = n + 1) begin
            if (n < PERIOD) begin
                j = ((n * FTW) % (1 << PHASE_W)) >> ADDR_SH;
                if (sin_a !== exp_sin[j] || cos_a !== exp_cos[j]) begin
                    seq_err = seq_err + 1;
                    if (seq_err <= 3)
                        $display("    [参考] n=%0d addr=%0d 期望 sin=%0d cos=%0d，实测 sin=%0d cos=%0d",
                                 n, j, exp_sin[j], exp_cos[j], sin_a, cos_a);
                end
            end
            if (n == 16 && sin_a !== AMP)
                $display("    [参考] n=16 本应是幅值顶点 +2047，实测 %0d", sin_a);
            amp = $signed(sin_a) * $signed(sin_a) + $signed(cos_a) * $signed(cos_a);
            if (amp < amp_min) amp_min = amp;
            if (amp > amp_max) amp_max = amp;
            tick;
        end
        `check_eq("前 64 拍输出逐拍等于 table[(n*FTW) mod 2^PHASE_W 的高 12 位]", seq_err, 0);
        `check_eq("n=16 时是 sin 幅值顶点 +2047", exp_sin[((16 * FTW) % (1 << PHASE_W)) >> ADDR_SH], AMP);

        // 容差来源：每个采样点量化误差 |e| <= 0.5 LSB，A = 2047 时
        //   amp = A^2 + 2A(sin*e1 + cos*e2)，max|sin*e1+cos*e2| = 0.5*sqrt(2)
        //   → 单边偏差上界 ≈ 2*A*0.707 ≈ 2895。取 4096 做判据（有依据又不虚设）。
        amp_dev = (AMP*AMP - amp_min > amp_max - AMP*AMP)
                ? (AMP*AMP - amp_min) : (amp_max - AMP*AMP);
        $display("幅度：sin^2+cos^2 min=%0d max=%0d（中心 %0d），单边最大偏差 %0d，相对 %.4f%%",
                 amp_min, amp_max, AMP*AMP, amp_dev, (amp_max - amp_min) * 100.0 / (AMP*AMP));
        `check(amp_dev <= 4096, "幅度恒定：sin^2+cos^2 单边偏差 <= 4096（理论上界 2895）");

        // ══ 4. 周期：黑盒测两个相邻峰值的间隔 ═════════════════
        found = 0;
        for (i = 0; i < 2 * PERIOD && !found; i = i + 1) begin
            if (sin_a == AMP) found = 1;
            else tick;
        end
        `check(found, "能在有限拍内等到 sin 峰值（说明输出在动）");

        j = 0;
        found2 = 0;
        for (i = 0; i < 2 * PERIOD && !found2; i = i + 1) begin
            tick;
            j = j + 1;
            if (sin_a == AMP) found2 = 1;
        end
        peak_a1 = j;
        `check_eq("两个相邻 sin 峰值间隔 = 2^PHASE_W / FTW = 64 拍", peak_a1, PERIOD);

        j = 0;
        found2 = 0;
        for (i = 0; i < 2 * PERIOD && !found2; i = i + 1) begin
            tick;
            j = j + 1;
            if (sin_a == AMP) found2 = 1;
        end
        `check_eq("再测一个周期，间隔同样是 64 拍（周期性）", j, PERIOD);

        // ══ 5. 运行中途异步复位 ═══════════════════════════════
        // 故意停在时钟中间拉低 rst_n：异步复位不该等到下一个时钟沿才生效
        @(posedge clk);
        #3;
        rst_n = 1'b0;
        #1;
        `check(sin_a === 12'sd0 && cos_a === 12'sd0, "异步复位：不在时钟沿也能立刻把输出清零");
        `check_eq("异步复位：相位累加器立刻回 0", dut_a.phase_acc, 0);

        // ══ 6. DUT B：换一组 PHASE_W + 不整除的 FTW ═══════════
        repeat (2) @(posedge clk);
        #1;
        rst_n = 1'b1;
        `check_eq("DUT B 的 FTW = 截断(13 * 2^24 / 1000) = 218103", dut_b.PHI_INC, FTW_B);

        events = 0;
        span = 0;
        started = 0;
        prev_b = $signed(sin_b);
        for (i = 0; i < 20000 && events <= 100; i = i + 1) begin
            tick;
            if (started) span = span + 1;
            if ($signed(sin_b) >= 0 && prev_b < 0) begin
                events = events + 1;
                if (events == 1) started = 1;      // 从第 1 次上升过零开始数拍
            end
            prev_b = $signed(sin_b);
        end
        `check_eq("DUT B 数到 101 次上升过零（100 个周期）", events, 101);
        f_theory_b = FTW_B * (CLK_B * 1.0) / (1 << PHASE_B);
        f_meas_b   = 100.0 * CLK_B / span;
        f_err_ppm  = (f_meas_b - FREQ_B) * 1.0e6 / FREQ_B;
        $display("DUT B 频率对账：请求 %0d Hz，FTW=%0d（真值 %.3f，截断丢 %.3f）",
                 FREQ_B, FTW_B, FREQ_B * (1 << PHASE_B) * 1.0 / CLK_B,
                 FREQ_B * (1 << PHASE_B) * 1.0 / CLK_B - FTW_B);
        $display("              100 个周期实测 %0d 拍（预测 %.2f），实测频率 %.6f Hz，与请求差 %0.4f ppm",
                 span, 100.0 * (1 << PHASE_B) / FTW_B, f_meas_b, f_err_ppm);
        `check(span >= 100.0 * (1 << PHASE_B) / FTW_B - 1.0
            && span <= 100.0 * (1 << PHASE_B) / FTW_B + 1.0,
               "DUT B 的周期长度对得上 FTW（差 <= 1 拍）");
        // 判据 2：实测频率与"用截断后 FTW 反算的理论值"一致。
        // 容差必须用**测量分辨率**：数 100 个周期、量到 ±1 拍，
        // 分辨率 = 1 拍/span ≈ 1/(100*76.92) ≈ 1.3e-4（≈130 ppm）。
        // 别写比它还小的判据 —— 那样测的不是 RTL，是测量噪声。
        `check((f_meas_b - f_theory_b) <  CLK_B * 1.0 / span
            && (f_theory_b - f_meas_b) <  CLK_B * 1.0 / span,
               "DUT B 实测频率与理论值之差在 1 拍测量分辨率以内");
        // 判据 3：理论偏差本身 = FTW 只能取整带来的系统性偏低，
        // 且不超过 1 个 LSB：1/FTW = 1/218103 ≈ 4.6 ppm。
        // 这个量级**测不出来**（130 ppm 分辨率），所以这里判的是算术，不是波形。
        `check(f_theory_b <= FREQ_B
            && (FREQ_B - f_theory_b) / FREQ_B <= 1.0 / FTW_B,
               "理论频率偏低且不超过 1 个 FTW LSB（≈4.6 ppm）——取整误差可解释");

        // ══ 7. DUT C：只换 PHASE_W，频率应当不变 ═════════════
        repeat (2) @(posedge clk);
        #1;
        rst_n = 1'b1;
        `check_eq("DUT C 的 FTW = 16 * 2^24 / 1024 = 262144", dut_c.PHI_INC, FTW_C);
        found = 0;
        for (i = 0; i < 2 * PERIOD && !found; i = i + 1) begin
            if (sin_c == AMP) found = 1;
            else tick;
        end
        j = 0;
        found2 = 0;
        for (i = 0; i < 2 * PERIOD && !found2; i = i + 1) begin
            tick;
            j = j + 1;
            if (sin_c == AMP) found2 = 1;
        end
        peak_c = j;
        `check_eq("DUT C（PHASE_W=24）周期仍是 64 拍：换位宽不改频率", peak_c, PERIOD);

        // ══ 8. 频率误差可解释 ═════════════════════════════════
        $display("DUT A 频率对账：请求 %0d Hz，FTW=%0d（真值 %.3f，恰好整除无误差）",
                 FREQ_HZ, FTW, FREQ_HZ * (1 << PHASE_W) * 1.0 / CLK_HZ);
        $display("              实测周期 %0d 拍 → %.6f Hz，与请求差 %.4f ppm",
                 peak_a1, CLK_HZ * 1.0 / peak_a1,
                 (CLK_HZ * 1.0 / peak_a1 - FREQ_HZ) * 1.0e6 / FREQ_HZ);
        `check_eq("DUT A 实测频率 = CLK_HZ / 64 = 16 Hz（FTW 整除，误差为 0）",
                  CLK_HZ / peak_a1, FREQ_HZ);

        tb_done;
    end

endmodule
