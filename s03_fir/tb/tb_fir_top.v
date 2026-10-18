`timescale 1ns/1ps
//=============================================================================
// tb_fir_top — s03_fir 板级顶层的系统级验收
//-----------------------------------------------------------------------------
// 这个 TB 验的是"实验台"本身，不是 FIR 的算术（算术在 tb_fir.v 里）：
//   1. reset_sync 的 2 拍同步释放
//   2. 冲激发生器：宽度 1 拍、周期 IMP_PERIOD
//   3. 冲激响应经过整条顶层通路后仍然是那 47 个点（峰值 613、对称、两端回零）
//   4. LED 四颗同步闪（板级排障用：哪颗不闪就怀疑引脚）
//   5. 运行中途异步复位（不等时钟沿）
//
// 时序约定和 tb_fir.v 一样：在下降沿观测。冲激被上升沿采样后，
// 第 4 个下降沿看到 h[0]。
//=============================================================================
module tb_fir_top;
    `include "tb_common.vh"

    localparam integer CLK_HZ     = 1000;   // 只影响心跳分频
    localparam integer HEART_HZ   = 100;    // 1000/(2*100)=5 拍翻转一次
    localparam integer IMP_PERIOD = 128;    // 冲激周期（要大于 N+LAT，避免响应重叠）
    localparam integer N          = 47;
    localparam integer OW         = 13;
    localparam integer LAT        = 4;

    reg clk = 0;
    reg rst_n = 0;

    always #5 clk = ~clk;

    wire [3:0] led;

    fir_top #(
        .CLK_HZ(CLK_HZ),
        .HEART_HZ(HEART_HZ),
        .IMP_PERIOD(IMP_PERIOD)
    ) u_top (
        .clk(clk),
        .rst_n(rst_n),
        .led(led)
    );

    // 抓 64 个下降沿的输出。cap[0] 是冲激被采样后的第 1 个下降沿，
    // 所以 cap[3] 是 h[0]（延迟 4 拍），cap[26] 是中心抽头 h[23]。
    reg signed [OW-1:0] cap [0:63];

    integer i;
    integer cnt;
    integer err;
    integer led_err;
    integer trans;
    reg prev;
    time t1, t2;

    initial begin
        // ── 1. 复位期间 ────────────────────────────────────────────
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        `check_eq("复位期间 LED 全灭", led, 0);
        `check_eq("复位期间 FIR 输出为 0", u_top.fir_out, 0);
        `check_eq("复位期间 imp 被门控为 0", u_top.imp, 0);

        // ── 2. reset_sync 同步释放（2 拍）──────────────────────────
        @(negedge clk);
        rst_n = 1'b1;
        cnt = 0;
        while (!u_top.rst_sync_n) begin
            @(posedge clk);
            #1;                                // 等 NBA 更新完再看，否则会多数一拍
            cnt = cnt + 1;
        end
        `check_eq("reset_sync 释放延迟 = 2 拍", cnt, 2);

        // ── 3. 冲激宽度 + 冲激响应 ─────────────────────────────────
        @(negedge clk);
        while (!u_top.imp) @(negedge clk);    // 等到 imp=1 的那一拍
        `check_eq("检测到冲激：imp=1 时输入是 2047",
                  u_top.x_in, 12'sd2047);
        @(negedge clk);
        `check_eq("冲激宽度 = 1 拍（下一拍 imp=0）", u_top.imp, 0);
        `check_eq("冲激结束后输入回到 0", u_top.x_in, 0);

        // 从"冲激被采样后的第 1 个下降沿"开始抓 64 个点
        for (i = 0; i < 64; i = i + 1) begin
            cap[i] = u_top.fir_out;
            @(negedge clk);
        end

        `check_eq("延迟 4 拍：h[-1] 位置仍是 0", cap[2], 0);
        `check_eq("h[0] = 1（2047*11/2^15 四舍五入）", cap[3], 1);
        `check_eq("中心抽头 h[23] = 613（2047*9810/2^15）", cap[26], 613);
        `check_eq("h[46] = 1", cap[49], 1);
        `check_eq("h[47] = 0（47 抽头之后回零）", cap[50], 0);

        err = 0;
        for (i = 1; i <= 23; i = i + 1)
            if (cap[26-i] !== cap[26+i])
                err = err + 1;
        `check_eq("顶层冲激响应关于 h[23] 严格对称（线性相位）", err, 0);

        err = 0;
        for (i = 50; i < 64; i = i + 1)
            if (cap[i] !== 0)
                err = err + 1;
        `check_eq("冲激响应结束后输出保持 0", err, 0);

        // ── 4. 冲激周期 ────────────────────────────────────────────
        while (u_top.imp) @(negedge clk);     // 离开当前冲激
        while (!u_top.imp) @(negedge clk);    // 等下一个冲激
        t1 = $time;
        while (u_top.imp) @(negedge clk);
        while (!u_top.imp) @(negedge clk);
        t2 = $time;
        `check_eq("冲激周期 = IMP_PERIOD = 128 拍", (t2 - t1) / 10, IMP_PERIOD);

        // ── 5. LED 心跳 ────────────────────────────────────────────
        led_err = 0;
        trans = 0;
        prev = led[0];
        for (i = 0; i < 30; i = i + 1) begin
            @(negedge clk);
            if (led !== 4'b0000 && led !== 4'b1111)
                led_err = led_err + 1;
            if (led[0] !== prev)
                trans = trans + 1;
            prev = led[0];
        end
        `check_eq("四颗 LED 始终同步（都是同一个心跳）", led_err, 0);
        `check_eq("30 拍内 LED 跳变 6 次（半周期 5 拍 = 6 个边沿）", trans, 6);

        // ── 6. 运行中途异步复位 ────────────────────────────────────
        // 先让输出回到非零（等一个冲激的响应）
        while (!u_top.imp) @(negedge clk);
        repeat (LAT + 24) @(negedge clk);
        `check(u_top.fir_out !== 0, "复位前 FIR 输出非零（下面才测得出清零）");
        rst_n = 1'b0;                          // 异步拉低，不等时钟沿
        #1;
        `check_eq("异步复位立即把 reset_sync 输出拉低", u_top.rst_sync_n, 0);
        `check_eq("异步复位立即熄灭 LED", led, 0);
        `check_eq("异步复位立即把 FIR 输出清零", u_top.fir_out, 0);

        tb_done;
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_fir_top);
    end
`endif

endmodule
