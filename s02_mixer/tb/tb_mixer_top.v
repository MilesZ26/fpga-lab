`timescale 1ns/1ps
//=============================================================================
// tb_mixer_top — 顶层 mixer_top 的验收测试
//-----------------------------------------------------------------------------
// 被测：s02_mixer/rtl/mixer_top.v（reset_sync + 两个 nco + mixer + LED）
//
// mixer 的算术（位宽 / 舍入 / 饱和 / CONJ / 参数化）已经由 tb_mixer.v 用
// 45 个检查点、四组 Python 参考向量验得比较死。**本 TB 不重复那些**，
// 只验"顶层独有的、以及只有把 NCO 和混频器接起来才看得见"的事：
//
//   ① 复位同步：拉低异步立即生效；释放同步等 2 拍（reset_sync 的行为）
//   ② LED 映射：每拍 led[0]==i_out[OW-1] 且 led[3:1]==i_out[OW-2 -: 3]
//   ③ 复位期间 i_out/q_out/led 恒 0
//   ④ **混频真的发生了**：输出周期 = 2^PHASE_W / (FTW_IN ± FTW_LO)
//      —— 这是本 stage 的核心证据。输入单音周期是 65536/1536 ≈ 42.67 拍，
//         输出却是正好 64 拍（下变频）或 32 拍（上变频），频率被搬走了。
//   ⑤ 幅度：单位增益下输出幅度仍 ≈ 2047，且没到 OW=13 的饱和边界
//   ⑥ 正交性：i_out 的峰值处 q_out ≈ 0（I/Q 相位差 90° 没接反）
//
// 参数（都选成能整除的，周期是整数拍，判据才干净）：
//   CLK_HZ=1024, PHASE_W=16
//   FREQ_IN=24 → FTW_IN = 24*2^16/1024 = 1536（周期 42.67 拍，故意不是整数）
//   FREQ_LO=8  → FTW_LO = 512
//   下变频差频 FTW = 1536-512 = 1024 → 周期 65536/1024 = **64 拍**
//   上变频和频 FTW = 1536+512 = 2048 → 周期 65536/2048 = **32 拍**
//
// 两个 DUT 吃完全相同的输入，只有 CONJ 不同 —— 这样"和频/差频"的差别
// 只能来自 CONJ，排除了参数不一致导致的假绿。
//
// ⚠️ 相位对齐：两个 NCO 的相位都从 0 开始、延迟相同，所以输出
//    i_out ≈ 2047*cos(2*pi*k*n/64)，q_out ≈ 2047*sin(...)。
//    过零点会正好落在采样格上（n=16 时 cos=0），所以判过零必须写
//    "上一拍 < 0 且这一拍 >= 0"（只数**上升**过零），否则一个周期里
//    会数到两次。这和 tb_nco_top 里"别用 == 峰值当判据"是同一类坑。
//=============================================================================
module tb_mixer_top;
    `include "tb_common.vh"

`ifndef NCO_LUTDIR
  `ifdef LUTDIR
    `define NCO_LUTDIR `LUTDIR
  `else
    `define NCO_LUTDIR "s01_nco/lut/"
  `endif
`endif

    localparam integer CLK_HZ  = 1024;
    localparam integer PHASE_W = 16;
    localparam integer FREQ_IN = 24;
    localparam integer FREQ_LO = 8;
    localparam integer AW      = 12;
    localparam integer OW      = 13;

    localparam integer FTW_IN   = (FREQ_IN * (64'd1 << PHASE_W)) / CLK_HZ;  // 1536
    localparam integer FTW_LO   = (FREQ_LO * (64'd1 << PHASE_W)) / CLK_HZ;  // 512
    localparam integer PER_DOWN = (1 << PHASE_W) / (FTW_IN - FTW_LO);       // 64 拍
    localparam integer PER_UP   = (1 << PHASE_W) / (FTW_IN + FTW_LO);       // 32 拍

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;

    wire [3:0] led_down, led_up;

    always #(`CLK_PERIOD/2) clk = ~clk;

    // CONJ=1：下变频，输出差频 16 Hz（周期 64 拍）
    mixer_top #(
        .CLK_HZ(CLK_HZ), .FREQ_IN(FREQ_IN), .FREQ_LO(FREQ_LO), .PHASE_W(PHASE_W),
        .AW(AW), .IW(AW), .OW(OW), .SHIFT(AW-1), .ROUND(1), .CONJ(1)
    ) dut_down (
        .clk(clk), .rst_n(rst_n), .led(led_down)
    );

    // CONJ=0：上变频，输出和频 32 Hz（周期 32 拍）
    mixer_top #(
        .CLK_HZ(CLK_HZ), .FREQ_IN(FREQ_IN), .FREQ_LO(FREQ_LO), .PHASE_W(PHASE_W),
        .AW(AW), .IW(AW), .OW(OW), .SHIFT(AW-1), .ROUND(1), .CONJ(0)
    ) dut_up (
        .clk(clk), .rst_n(rst_n), .led(led_up)
    );

    // 用层次引用把顶层内部信号取出来看
    wire signed [OW-1:0] dn_i = dut_down.i_out;
    wire signed [OW-1:0] dn_q = dut_down.q_out;
    wire signed [OW-1:0] up_i = dut_up.i_out;
    wire signed [OW-1:0] up_q = dut_up.q_out;

`ifdef DUMP_VCD
    // 两个 NCO 各带两张 4096 项的表，全 dump 会让 VCD 巨大 —— 只 dump 关心的
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(1, tb_mixer_top.clk, tb_mixer_top.rst_n);
        $dumpvars(1, dn_i, dn_q, up_i, up_q, led_down, led_up);
        $dumpvars(1, dut_down.sig_cos, dut_down.sig_sin,
                     dut_down.lo_cos, dut_down.lo_sin);
    end
`endif

    integer dn_led_err, dn_max_abs, dn_q_at_peak, dn_cross, dn_span;
    integer up_led_err, up_max_abs, up_q_at_peak, up_cross, up_span;
    integer dn_min_mag, dn_max_mag, up_min_mag, up_max_mag;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // 跑 ncyc 拍，统计下变频这一路的 LED 映射 / 幅度 / 正交性 / 输出周期
    task measure_down;
        input integer ncyc;
        integer n, a, first_neg;
        reg signed [OW-1:0] v, q;
        begin
            dn_led_err = 0;
            dn_max_abs = 0;
            dn_q_at_peak = 0;
            dn_cross = 0;
            dn_span = 0;
            first_neg = 0;
            for (n = 0; n < ncyc; n = n + 1) begin
                v = dn_i;
                q = dn_q;
                if (led_down[0] !== v[OW-1]) dn_led_err = dn_led_err + 1;
                if (led_down[3:1] !== v[OW-2 -: 3]) dn_led_err = dn_led_err + 1;
                a = (v < 0) ? -v : v;
                if (a > dn_max_abs) begin
                    dn_max_abs = a;
                    dn_q_at_peak = q;
                end
                if (first_neg && v >= 0) begin
                    dn_cross = dn_cross + 1;
                    if (dn_cross == 1) dn_span = n;
                    if (dn_cross == 2) dn_span = n - dn_span;
                end
                first_neg = (v < 0);
                tick;
            end
        end
    endtask

    task measure_up;
        input integer ncyc;
        integer n, a, first_neg;
        reg signed [OW-1:0] v, q;
        begin
            up_led_err = 0;
            up_max_abs = 0;
            up_q_at_peak = 0;
            up_cross = 0;
            up_span = 0;
            first_neg = 0;
            for (n = 0; n < ncyc; n = n + 1) begin
                v = up_i;
                q = up_q;
                if (led_up[0] !== v[OW-1]) up_led_err = up_led_err + 1;
                if (led_up[3:1] !== v[OW-2 -: 3]) up_led_err = up_led_err + 1;
                a = (v < 0) ? -v : v;
                if (a > up_max_abs) begin
                    up_max_abs = a;
                    up_q_at_peak = q;
                end
                if (first_neg && v >= 0) begin
                    up_cross = up_cross + 1;
                    if (up_cross == 1) up_span = n;
                    if (up_cross == 2) up_span = n - up_span;
                end
                first_neg = (v < 0);
                tick;
            end
        end
    endtask

    initial begin
        // ══ 1. 复位同步（reset_sync：异步拉低、同步释放 2 拍）══════
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        `check(dut_down.rst_n_sync === 1'b0 && dut_up.rst_n_sync === 1'b0,
               "复位期间 rst_n_sync = 0");
        `check(dn_i === 13'sd0 && dn_q === 13'sd0, "复位期间下变频输出 i_out = q_out = 0（不是 x）");
        `check(led_down === 4'b0000 && led_up === 4'b0000, "复位期间 led 恒 0");

        rst_n = 1'b1;
        @(posedge clk);
        #1;
        `check(dut_down.rst_n_sync === 1'b0,
               "rst_n 拉高后第 1 拍：rst_n_sync 还是 0（释放是同步的，要等 2 拍）");
        @(posedge clk);
        #1;
        `check(dut_down.rst_n_sync === 1'b1, "第 2 拍 rst_n_sync 才变 1（异步复位、同步释放）");

        // ══ 2. 频率控制字（顶层参数真的传下去了吗）══════════════
        `check_eq("输入信号 NCO 的 FTW = 24 * 2^16 / 1024 = 1536",
                  dut_down.u_nco_sig.PHI_INC, FTW_IN);
        `check_eq("本振 NCO 的 FTW = 8 * 2^16 / 1024 = 512",
                  dut_down.u_nco_lo.PHI_INC, FTW_LO);
        `check_eq("预设的差频周期 = 2^16 / (1536-512) = 64 拍", PER_DOWN, 64);
        `check_eq("预设的和频周期 = 2^16 / (1536+512) = 32 拍", PER_UP, 32);

        // ══ 3. 运行中途异步复位 ═════════════════════════════════
        repeat (20) @(posedge clk);
        @(posedge clk);
        #3;
        rst_n = 1'b0;                    // 故意停在时钟中间
        #1;
        `check(dn_i === 13'sd0 && dn_q === 13'sd0,
               "异步复位：时钟沿中间拉低 rst_n，输出立刻清零（不等时钟沿）");
        `check(dut_down.rst_n_sync === 1'b0, "异步复位：rst_n_sync 立刻变 0");
        `check(led_down === 4'b0000, "异步复位：led 立刻清零");
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;

        // ══ 4. 下变频：混频真的把频率搬走了吗 ═══════════════════
        measure_down(256);
        `check_eq("下变频路：LED 逐拍等于 i_out 的符号位 + 幅值高 3 位", dn_led_err, 0);
        `check(dn_cross >= 3, "下变频路：窗口里数到 >=3 次上升过零（输出在动）");
        `check_eq("下变频：输出周期 = 64 拍 = 2^16/(FTW_IN-FTW_LO)，即差频 16 Hz",
                  dn_span, PER_DOWN);
        $display("下变频输出峰值 |i_out| = %0d（输入单音周期是 65536/1536 ≈ 42.67 拍，",
                 dn_max_abs);
        $display("            输出却正好 %0d 拍 → 频率被搬到差值上，这就是混频）", dn_span);
        `check(dn_max_abs >= 2035 && dn_max_abs <= 2055,
               "下变频：输出幅度 ≈ 2047（SHIFT=AW-1 是单位增益，没被削顶）");
        `check(dn_q_at_peak >= -3 && dn_q_at_peak <= 3,
               "下变频：i_out 峰值处 q_out ≈ 0（I/Q 正交，相位关系没接反）");

        // ══ 5. 上变频：和频 ═════════════════════════════════════
        measure_up(256);
        `check_eq("上变频路：LED 逐拍等于 i_out 的符号位 + 幅值高 3 位", up_led_err, 0);
        `check(up_cross >= 3, "上变频路：窗口里数到 >=3 次上升过零");
        `check_eq("上变频：输出周期 = 32 拍 = 2^16/(FTW_IN+FTW_LO)，即和频 32 Hz",
                  up_span, PER_UP);
        `check(up_max_abs >= 2035 && up_max_abs <= 2055,
               "上变频：输出幅度 ≈ 2047（同样的单位增益）");
        `check(up_q_at_peak >= -3 && up_q_at_peak <= 3,
               "上变频：i_out 峰值处 q_out ≈ 0（正交性）");
        `check(PER_UP * 2 == PER_DOWN,
               "和频周期正好是差频周期的一半（32 vs 64）——CONJ 只改了搬移方向");

        // ══ 6. 输出确实不是"输入原样穿过去" ═════════════════════
        // 输入单音的周期是 65536/1536 = 42.67 拍：如果谁把 mixer 接成了直通，
        // 下变频那路就会量出 ~43 拍，而不是 64 拍。
        `check(dn_span !== (1 << PHASE_W) / FTW_IN && dn_span !== (1 << PHASE_W) / FTW_LO,
               "输出周期既不是输入单音周期、也不是本振周期（不是直通，也不是只留一路）");

        tb_done;
    end

endmodule
