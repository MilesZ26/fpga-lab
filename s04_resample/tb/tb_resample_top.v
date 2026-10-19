`timescale 1ns/1ps
//=============================================================================
// tb_resample_top — s04_resample 板级顶层的系统级验收
//-----------------------------------------------------------------------------
// 验的是"实验台"本身，不是多相算术（算术在 tb_interp2 / tb_decim2 里）：
//   1. reset_sync 的 2 拍同步释放
//   2. 冲激发生器：宽度 1 拍、周期 IMP_PERIOD、幅度 2047
//   3. 整条顶层通路的冲激响应：
//        y_e  输出下标 k=15 原样 2047（ILA 第 19 个采样点）
//        y_o  峰值 1298（k=14/15，ILA 第 18/19 个采样点）
//        y_rt 43 个点，峰值 1991 在 k=30（ILA 第 38 个采样点），关于第 30 点对称
//   4. LED 四颗同步闪（板级排障：哪颗不闪就怀疑引脚）
//   5. 运行中途异步复位（不等时钟沿）
//
// 观测约定（前半段和 tb_fir_top 一致，后半段注意级联的 LAT 变了）：
//   冲激出现在某个下降沿 → 下一个上升沿被采样 → 从**之后第 1 个下降沿**
//   开始编号 cap[0]。
//     · 插值：cap[i] 对应输出下标 i-3（LAT=4）；
//       cap[3] 是 y_o[0]，cap[17]/cap[18] 是 y_o[14]/y_o[15]，
//       cap[18] 是 y_e[15]。
//     · 级联：cap[i] 对应输出下标 i-7（LAT=8，不是 4！）；
//       cap[16] 是 y_rt[9]，cap[37] 是 y_rt[30]。
//=============================================================================
module tb_resample_top;
    `include "tb_common.vh"

    localparam integer CLK_HZ     = 1000;   // 只影响心跳分频
    localparam integer HEART_HZ   = 100;    // 1000/(2*100)=5 拍翻转一次
    localparam integer IMP_PERIOD = 256;    // > 冲激响应长度 52 + 延迟 8
    localparam integer OW_INT     = 13;
    localparam integer OW_RT      = 14;
    localparam integer K          = 30;     // 半带奇数抽头数

    reg clk = 0;
    reg rst_n = 0;

    always #5 clk = ~clk;

    wire [3:0] led;

    resample_top #(
        .CLK_HZ(CLK_HZ),
        .HEART_HZ(HEART_HZ),
        .IMP_PERIOD(IMP_PERIOD)
    ) u_top (
        .clk(clk),
        .rst_n(rst_n),
        .led(led)
    );

    // 抓 64 个下降沿的三路输出
    reg signed [OW_INT-1:0] cap_e [0:63];
    reg signed [OW_INT-1:0] cap_o [0:63];
    reg signed [OW_RT-1:0]  cap_r [0:63];

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
        `check_eq("复位期间插值偶相为 0", u_top.y_e, 0);
        `check_eq("复位期间插值奇相为 0", u_top.y_o, 0);
        `check_eq("复位期间级联输出为 0", u_top.y_rt, 0);
        `check_eq("复位期间 imp 被门控为 0", u_top.imp, 0);

        // ── 2. reset_sync 同步释放（2 拍）──────────────────────────
        @(negedge clk);
        rst_n = 1'b1;
        cnt = 0;
        while (!u_top.rst_sync_n) begin
            @(posedge clk);
            #1;
            cnt = cnt + 1;
        end
        `check_eq("reset_sync 释放延迟 = 2 拍", cnt, 2);

        // ── 3. 冲激宽度 + 幅度 ─────────────────────────────────────
        @(negedge clk);
        while (!u_top.imp) @(negedge clk);
        `check_eq("检测到冲激：imp=1 时输入是 2047", u_top.x_in, 12'sd2047);
        @(negedge clk);
        `check_eq("冲激宽度 = 1 拍（下一拍 imp=0）", u_top.imp, 0);
        `check_eq("冲激结束后输入回到 0", u_top.x_in, 0);

        // ── 4. 抓整条链的冲激响应 ──────────────────────────────────
        for (i = 0; i < 64; i = i + 1) begin
            cap_e[i] = u_top.y_e;
            cap_o[i] = u_top.y_o;
            cap_r[i] = u_top.y_rt;
            @(negedge clk);
        end

        // 偶相：15 拍后原样出现，其它全 0
        `check_eq("y_e[15] = 2047（半带偶相 = 15 拍纯延迟）", cap_e[18], 2047);
        `check_eq("y_e[14] = 0", cap_e[17], 0);

        // 奇相：30 个点，峰值 1298，关于 k=14.5 对称
        `check_eq("y_o[0] = 4（2047*30/2^14 四舍五入）", cap_o[3], 4);
        `check_eq("y_o[14] = 1298（2047*10387/2^14）", cap_o[17], 1298);
        `check_eq("y_o[15] = 1298（和 y_o[14] 对称）", cap_o[18], 1298);
        `check_eq("y_o[30] = 0（30 个奇数抽头之后回零）", cap_o[33], 0);

        err = 0;
        for (i = 0; i < K/2; i = i + 1)
            if (cap_o[3+i] !== cap_o[3+K-1-i])
                err = err + 1;
        `check_eq("y_o 的 30 个点关于 k=14.5 严格对称（线性相位）", err, 0);

        // 级联：43 个点、峰值 1991、关于第 30 点对称
        // ⚠️ 级联的 LAT = 8（4 + 4），所以 cap[i] 对应下标 i-7，不是 i-3。
        //    这个 +4 的偏移就是"插值 4 拍 + 抽取 4 拍"，第一次写这个 TB 时漏了，
        //    结果整段响应右移 4 拍 —— 断言全红，但数值本身是"平移后仍然正确"的。
        `check_eq("y_rt 第一个非零点在输出下标 9（cap[16] = 1）", cap_r[16], 1);
        `check_eq("y_rt 峰值 1991 在输出下标 30（cap[37]）", cap_r[37], 1991);
        `check_eq("y_rt[29] = 53（峰值左边一格）", cap_r[36], 53);
        `check_eq("y_rt[31] = 53（峰值右边一格，对称）", cap_r[38], 53);

        err = 0;
        for (i = 9; i < 30; i = i + 1)
            if (cap_r[7+i] !== cap_r[7+60-i])
                err = err + 1;
        `check_eq("y_rt 关于第 30 点严格对称（21 对）", err, 0);

        err = 0;
        for (i = 52; i < 57; i = i + 1)
            if (cap_r[7+i] !== 0)
                err = err + 1;
        `check_eq("冲激响应结束后 y_rt 保持 0", err, 0);

        // ── 5. 冲激周期 ────────────────────────────────────────────
        while (u_top.imp) @(negedge clk);
        while (!u_top.imp) @(negedge clk);
        t1 = $time;
        while (u_top.imp) @(negedge clk);
        while (!u_top.imp) @(negedge clk);
        t2 = $time;
        `check_eq("冲激周期 = IMP_PERIOD = 256 拍", (t2 - t1) / 10, IMP_PERIOD);

        // ── 6. LED 心跳 ────────────────────────────────────────────
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

        // ── 7. 运行中途异步复位 ────────────────────────────────────
        while (!u_top.imp) @(negedge clk);
        repeat (8 + 24) @(negedge clk);
        `check(u_top.y_rt !== 0, "复位前级联输出非零（下面才测得出清零）");
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立即把 reset_sync 输出拉低", u_top.rst_sync_n, 0);
        `check_eq("异步复位立即熄灭 LED", led, 0);
        `check_eq("异步复位立即把级联输出清零", u_top.y_rt, 0);

        tb_done;
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_resample_top);
    end
`endif

endmodule
