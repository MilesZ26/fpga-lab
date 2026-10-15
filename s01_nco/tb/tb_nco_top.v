`timescale 1ns/1ps
//=============================================================================
// tb_nco_top — 顶层 nco_top 的验收测试
//-----------------------------------------------------------------------------
// 被测：s01_nco/rtl/nco_top.v（reset_sync + nco + LED 映射）
//
// nco 本身（相位累加器 + 查表 + 1 拍延迟 + 周期 + 幅度）已经由 tb_nco.v
// 用 21 个检查点逐拍验过。**本 TB 不重复那些**，只验顶层独有的几件事：
//
//   ① 复位同步：按键拉低是**异步**立刻生效；释放要**同步**等 2 拍
//   ② LED 映射：每拍 led[0]==fsin_o[11] 且 led[3:1]==fsin_o[10:8]
//   ③ 复位期间 led 恒 0（不是 x，也不是残留值）
//   ④ 顶层贯通：每拍 fsin_o / fcos_o 都等于参考表在相位高 12 位上的取值
//   ⑤ 运行中途异步复位：停在时钟中间拉低 rst_n，不等时钟沿就要清零
//
// 参数选得和 tb_nco.v 的 DUT A 一致，方便对照：
//   CLK_HZ=1024, FREQ_HZ=16, PHASE_W=16
//   FTW = 16 * 2^16 / 1024 = 1024    → 周期 = 2^16/1024 = 64 拍
//
// ⚠️ 对齐关系（写错这里会假红/假绿）：
//   nco 的输出是"相位累加器 1 拍 + 输出寄存器 1 拍"。
//   在某个 posedge 之后采样时，phase_acc 已经是**新值**，
//   而 fsin_o 还是用**旧地址**查出来的表值。
//   所以判据要写成  fsin_o == table[上一拍 phase_acc 的高 12 位]，
//   而不是 table[当前 phase_acc]。这里用 pa_before 显式记住上一拍的值。
//
// ⚠️ 为什么验周期用**峰值**而不是过零点：
//   地址序列是 i = n*64，过零点恰好落在采样格上，而 table[2048] 正好 = 0，
//   0 的符号位是 0 —— 于是相邻两次符号位翻转的间隔会在 31/33 之间跳，
//   **不是**恒定的 32。这是相位截断 + 过零落格的正常结果，不是 bug。
//   峰值（+2047）在周期内唯一，间隔稳定，所以拿它当尺子。
//=============================================================================
module tb_nco_top;
    `include "tb_common.vh"

`ifndef LUTDIR
  `define LUTDIR "s01_nco/lut/"
`endif

    localparam integer CLK_HZ  = 1024;
    localparam integer FREQ_HZ = 16;
    localparam integer PHASE_W = 16;
    localparam integer FTW     = (FREQ_HZ * (64'd1 << PHASE_W)) / CLK_HZ;   // 1024
    localparam integer PERIOD  = (1 << PHASE_W) / FTW;                      // 64 拍
    localparam integer ADDR_SH = PHASE_W - 12;                              // 4
    localparam integer DEPTH   = 1 << 12;
    localparam integer AMP     = 2047;                                      // 表满幅

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    wire [3:0] led;

    always #(`CLK_PERIOD/2) clk = ~clk;

    nco_top #(.CLK_HZ(CLK_HZ), .FREQ_HZ(FREQ_HZ), .PHASE_W(PHASE_W)) dut (
        .clk  (clk),
        .rst_n(rst_n),
        .led  (led)
    );

    // 顶层内部信号，用层次引用取出来看
    wire [11:0] fsin_o = dut.fsin_o;
    wire [11:0] fcos_o = dut.fcos_o;

    // ── 参考表：TB 自己把同一份 .mem 读进来做 golden model ──────
    reg signed [11:0] exp_sin [0:DEPTH-1];
    reg signed [11:0] exp_cos [0:DEPTH-1];

    integer n, j, map_err, sin_err, cos_err, span, pa_before, found;

`ifdef DUMP_VCD
    // ROM 有 4096 项，不 dump；只 dump 关心的
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(1, tb_nco_top);
        $dumpvars(1, dut.u_nco.phase_acc, dut.fsin_o, dut.fcos_o, led);
    end
`endif

    // 采一拍：posedge 之后 #1，等非阻塞赋值落定
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        $readmemh({`LUTDIR, "sin.mem"}, exp_sin);
        $readmemh({`LUTDIR, "cos.mem"}, exp_cos);

        // ══ 1. 上电复位 ══════════════════════════════════════
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        `check(led === 4'b0000, "复位期间 led = 0000（不是 x，也不是残留值）");
        `check_eq("复位期间相位累加器 = 0", dut.u_nco.phase_acc, 0);
        `check(dut.u_reset_sync.rst_n === 1'b0, "复位期间 reset_sync 的输出为 0");

        // ══ 2. 同步释放：比按键晚 2 拍 ═══════════════════════
        // reset_sync 里是 {sync[0], 1'b1} 移位，输出取 sync[1]。
        // 释放后第 1 拍 sync=01 → 输出仍 0；第 2 拍 sync=11 → 输出变 1。
        rst_n = 1'b1;
        tick;
        `check(dut.u_reset_sync.rst_n === 1'b0, "释放后第 1 拍 rst_n_sync 仍为 0（同步释放）");
        `check_eq("释放后第 1 拍 NCO 仍在复位", dut.u_nco.phase_acc, 0);
        tick;
        `check(dut.u_reset_sync.rst_n === 1'b1, "释放后第 2 拍 rst_n_sync 变高");
        `check_eq("释放后第 2 拍相位仍为 0（这一拍才刚看到复位撤销）", dut.u_nco.phase_acc, 0);
        tick;
        `check_eq("释放后第 3 拍相位累加一次 = FTW", dut.u_nco.phase_acc, FTW);
        `check_eq("复位撤销后的第一个输出 = table[0] = 0", fsin_o, 0);

        // ══ 3. 每拍贯通检查：LED 映射 + 端口→查表→输出 ═══════
        map_err = 0;
        sin_err = 0;
        cos_err = 0;
        pa_before = 0;   // 复位时相位是 0，所以第一拍的 fsin_o 来自地址 0
        for (n = 0; n < 4 * PERIOD; n = n + 1) begin
            if (led[0] !== fsin_o[11] || led[3:1] !== fsin_o[10:8])
                map_err = map_err + 1;
            j = (pa_before >> ADDR_SH) & (DEPTH - 1);
            if (fsin_o !== exp_sin[j]) sin_err = sin_err + 1;
            if (fcos_o !== exp_cos[j]) cos_err = cos_err + 1;
            pa_before = dut.u_nco.phase_acc;   // 本拍相位，供下一拍比对
            tick;
        end
        `check_eq("每拍 led[0]==fsin_o[11] 且 led[3:1]==fsin_o[10:8]", map_err, 0);
        `check_eq("每拍 fsin_o == 参考表[上一拍相位的高 12 位]", sin_err, 0);
        `check_eq("每拍 fcos_o == 参考表[同一地址]（sin/cos 用同一个地址）", cos_err, 0);

        // ══ 4. 周期：黑盒测两个相邻 sin 峰值的间隔 ═════════════
        n = 0;
        while (fsin_o !== 12'sd2047 && n < 2 * PERIOD) begin
            tick;
            n = n + 1;
        end
        `check(n < 2 * PERIOD, "在有限拍内等到 sin 峰值 +2047（说明输出在动）");

        span = 0;
        found = 0;
        n = 0;
        while (!found && n < 2 * PERIOD) begin
            tick;                 // 先 tick，天然跳过当前这个峰值
            span = span + 1;
            n = n + 1;
            if (fsin_o === 12'sd2047) found = 1;
        end
        `check(found, "等到了第二个 sin 峰值");
        `check_eq("两个 sin 峰值间隔 = 2^PHASE_W / FTW = 64 拍", span, PERIOD);
        // 为什么峰值一定出现在地址 1024：这张表只在 i = N/4 处取到 +2047。
        // （不要去判 dut.u_nco.phase_acc >> ADDR_SH == 1024 —— 输出比相位晚 1 拍，
        //   峰值那一拍采到的 phase_acc 已经是**下一个**地址了，会假红。）
        `check_eq("表的顶点在地址 1024（i = N/4），值 +2047", exp_sin[1024], AMP);
        $display("周期对账：实测 %0d 拍 → %.6f Hz（请求 %0d Hz）",
                 span, CLK_HZ * 1.0 / span, FREQ_HZ);

        // ══ 5. 运行中途异步复位 ═══════════════════════════════
        // 故意停在时钟中间拉低 rst_n：异步复位不该等到下一个时钟沿才生效
        @(posedge clk);
        #3;
        rst_n = 1'b0;
        #1;
        `check(dut.u_reset_sync.rst_n === 1'b0, "异步复位：不在时钟沿也能立刻把 rst_n_sync 清零");
        `check(led === 4'b0000, "异步复位：不在时钟沿也能立刻把 LED 清零");
        `check_eq("异步复位：相位累加器立刻回 0", dut.u_nco.phase_acc, 0);

        tb_done;
    end

endmodule
