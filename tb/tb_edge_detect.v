//=============================================================================
// tb_edge_detect — edge_detect 的自测
//=============================================================================

`timescale 1ns/1ps

module tb_edge_detect;

    `include "tb_common.vh"

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    reg  level = 1'b0;

    wire rise, fall, both;

    always #(`CLK_PERIOD/2) clk = ~clk;

    edge_detect dut (
        .clk   (clk),
        .rst_n (rst_n),
        .level (level),
        .rise  (rise),
        .fall  (fall),
        .both  (both)
    );

`ifdef DUMP_VCD
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_edge_detect);
    end
`endif

    initial begin
        // ── 复位期间 ──
        rst_n = 1'b0;
        level = 1'b0;
        repeat (4) @(posedge clk);
        #1;
        `check(rise === 1'b0 && fall === 1'b0 && both === 1'b0,
              "复位期间所有边沿标志为 0");

        rst_n = 1'b1;
        @(posedge clk);
        #1;
        `check(both === 1'b0, "level 稳定为 0 时无边沿");

        // ── 上升沿 ──
        level = 1'b1;
        #1;
        `check(rise === 1'b1, "level 0->1：rise 立即拉高");
        `check(fall === 1'b0, "level 0->1：fall 保持 0");
        `check(both === 1'b1, "level 0->1：both 拉高");

        @(posedge clk);
        #1;
        `check(rise === 1'b0, "rise 只维持一个时钟周期");
        `check(both === 1'b0, "level 保持 1 时无边沿");

        // ── 下降沿 ──
        level = 1'b0;
        #1;
        `check(fall === 1'b1, "level 1->0：fall 立即拉高");
        `check(rise === 1'b0, "level 1->0：rise 保持 0");

        @(posedge clk);
        #1;
        `check(fall === 1'b0, "fall 只维持一个时钟周期");

        // ── 复位应清零 ──
        level = 1'b1;
        #1;
        `check(both === 1'b1, "复位前 both 有效（准备验证复位能清掉它）");

        rst_n = 1'b0;
        #1;
        `check(both === 1'b0, "异步复位立即清掉边沿标志");

        tb_done;
    end

endmodule
