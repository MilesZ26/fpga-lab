`timescale 1ns/1ps
//=============================================================================
// tb_serializer2 — 2:1 并串 + 1:2 串并回环
//-----------------------------------------------------------------------------
// 这是 s05/s06 留给"真正接 DAC/ADC"的接口块。板上没有 DAC，所以它不在
// 板级顶层里；但它是 DUC 两相输出到 1 路 DAC 的必经之路，必须逐拍验。
//
// 信号关系：
//   clk   = Fs，并行域：d_e/d_o 每个 clk 更新一次；
//   clk2x = 2Fs，串行域：serializer 在 posedge 更新 d，
//                        deserializer 在 negedge 采样 d（半个周期，眼图中间）。
//
// 这个 TB 用一串**互不相同的值**（1000+i / -1000-i）驱动，
// 捕获回环输出后搜索延迟 offset，再逐点比对 —— 这样不用手推
// "到底晚 1 拍还是 2 拍"，而且能抓住"偶相/奇相搞反"。
//=============================================================================
module tb_serializer2;
    `include "tb_common.vh"

    localparam integer DW = 15;
    localparam integer NP = 32;

    reg clk = 1;
    reg clk2x = 0;
    reg rst_n = 0;

    always #5   clk   = ~clk;      // Fs
    always #2.5 clk2x = ~clk2x;    // 2Fs（posedge 在 2.5/7.5/…，negedge 在 5/10/…）

    reg  signed [DW-1:0] d_e = 0, d_o = 0;
    wire signed [DW-1:0] ser;
    wire signed [DW-1:0] de_out, do_out;

    serializer2 #(.DW(DW)) u_ser (
        .clk(clk), .clk2x(clk2x), .rst_n(rst_n),
        .d_e(d_e), .d_o(d_o), .d(ser)
    );

    deserializer2 #(.DW(DW)) u_des (
        .clk(clk), .clk2x(clk2x), .rst_n(rst_n),
        .d(ser), .d_e(de_out), .d_o(do_out)
    );

    reg signed [DW-1:0] in_e  [0:NP-1];
    reg signed [DW-1:0] in_o  [0:NP-1];
    reg signed [DW-1:0] cap_e [0:NP-1];
    reg signed [DW-1:0] cap_o [0:NP-1];

    integer i, off, ok, found;


    initial begin
        // ── 1. 复位 ─────────────────────────────────────────────────
        rst_n = 1'b0;
        d_e = 15'sd1234;
        d_o = -15'sd4321;
        repeat (4) @(negedge clk2x);
        `check_eq("复位期间串行输出 = 0", ser, 0);
        `check_eq("复位期间偶相输出 = 0", de_out, 0);
        `check_eq("复位期间奇相输出 = 0", do_out, 0);

        rst_n = 1'b1;
        #2;                        // 避开和 clk2x 沿同时释放复位的竞争
        @(negedge clk);

        // ── 2. 驱动一串互不相同的值，捕获回环输出 ───────────────────
        for (i = 0; i < NP; i = i + 1) begin
            in_e[i] = 1000 + i;
            in_o[i] = -1000 - i;
            @(negedge clk);
            d_e = in_e[i];
            d_o = in_o[i];
            @(negedge clk);
            @(negedge clk);           // 等串并流水把偶相和奇相都吐出来
            #1;
            cap_e[i] = de_out;
            cap_o[i] = do_out;
        end

        // ── 3. 搜延迟 offset，再逐点比对 ────────────────────────────
        found = 0;
        off = 0;
        for (off = 0; off < 5 && !found; off = off + 1) begin
            ok = 1;
            for (i = off; i < NP; i = i + 1) begin
                if (cap_e[i] !== in_e[i-off]) ok = 0;
                if (cap_o[i] !== in_o[i-off]) ok = 0;
            end
            if (ok) found = 1;
        end
        `check(found, "回环输出等于输入序列的某个固定延迟（32 对逐点一致）");

        if (found) begin
            `check(off >= 1 && off <= 4,
                   "延迟 offset 在 1..4 拍（并串 + 串并的流水）");
            $display("    [info] 并串回环延迟 offset = %0d 拍（clk 域）", off);
        end

        // ── 4. 偶相/奇相没有互换：用两个不同的常数再确认一次 ────────
        // 如果 d_e/d_o 接反，上面的序列会整体错位或数值互换；这里再直接看一次。
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        #2;                        // 同样避开竞争
        @(negedge clk);
        d_e = 15'sd1234;
        d_o = -15'sd5678;
        repeat (4) @(negedge clk);
        #1;                           // 等流水走完，再核对最近一对
        cap_e[0] = de_out;
        cap_o[0] = do_out;
        `check(cap_e[0] == 15'sd1234,
               "稳态偶相 = +1234（d_e/d_o 没有互换）");
        `check(cap_o[0] == -15'sd5678,
               "稳态奇相 = -5678（d_e/d_o 没有互换）");

        // ── 5. 异步复位立刻清零 ─────────────────────────────────────
        rst_n = 1'b0;
        #1;
        `check_eq("异步复位立刻把串行输出清零", ser, 0);
        `check_eq("异步复位立刻把偶相输出清零", de_out, 0);
        `check_eq("异步复位立刻把奇相输出清零", do_out, 0);

        tb_done;
    end

endmodule
