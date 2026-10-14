//=============================================================================
// tb_common.vh — testbench 公共定义
//-----------------------------------------------------------------------------
// 用法（在 testbench 模块内部 include）：
//
//     `timescale 1ns/1ps
//     module tb_xxx;
//         `include "tb_common.vh"     // ← 计数器由本文件声明，自己别再写一遍
//         ...
//         initial begin
//             `check(cond, "描述文字");
//             `check_eq("描述文字", actual, expected);
//             tb_done;                 // ← 结尾必须调用，否则脚本判不出结果
//         end
//     endmodule
//
// 注意：check / check_eq 是宏（为什么必须是宏，见下面长注释），
// 所以调用时前面要有反引号 `，而且断言要单独成行写。
//
// 脚本靠输出里的 "TEST PASSED" / "TEST FAILED" 判断成败，
// 所以结尾一定要调 tb_done。
//=============================================================================

`ifndef TB_COMMON_VH
`define TB_COMMON_VH

// 默认时钟周期（时间单位由各自 timescale 决定）
`define CLK_PERIOD 10

// ── 错误计数 ─────────────────────────────────────────────
// 必须声明在下面几个断言之前，否则 iverilog 报
// "Could not find variable tb_errors ... Check for declaration after use"。
// 放在这里，testbench 就不用（也不该）自己再声明一遍。
integer tb_errors = 0;

// ── 为什么 check / check_eq 是宏，而不是 task ───────────────
// iverilog 13.0 有个坑：把含非 ASCII 字节（中文就是）的字符串常量
// 赋给 reg / 向量时，只有一部分字节写得进去，其余位留成 x，
// $display("%s") 打出来就是一堆乱码字节（0xFF）。
// 字符串常量直接写在 $display 的参数位置上则完全正常。
//
// 所以这里用宏 —— 宏是文本替换，"描述文字"会原样落在 $display 里，
// 不会被搬进任何向量。实测对照：
//   $display("%s", "level 稳定为 0")                 → 正常
//   reg [8*40-1:0] m; m = "level 稳定为 0"; %s m     → 乱码
//   m[319-:8] = 8'hE7; ...（逐字节赋值）%s m         → 正常
//
// 推论：msg 必须是字符串常量。写成变量就会重新踩到这个坑。
//
// 副作用提醒：宏展开成 if/else，所以不要写成
//     if (x) check(a, "m"); else ...
// 那样 else 会挂到宏内部的 if 上（dangling else）。断言单独成行写。

// ── 条件检查 ─────────────────────────────────────────────
`define check(cond, msg) \
    if (cond) \
        $display("[PASS] %s", msg); \
    else begin \
        tb_errors = tb_errors + 1; \
        $display("[FAIL] %s   (time=%0t)", msg, $time); \
    end

// ── 数值比较 ─────────────────────────────────────────────
`define check_eq(msg, actual, expected) \
    if ((actual) === (expected)) \
        $display("[PASS] %s", msg); \
    else begin \
        tb_errors = tb_errors + 1; \
        $display("[FAIL] %s : actual=%0d expected=%0d   (time=%0t)", \
                 msg, actual, expected, $time); \
    end

// ── 结束仿真 ─────────────────────────────────────────────
task tb_done;
    begin
        if (tb_errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED: %0d error(s)", tb_errors);
        $finish;
    end
endtask

`endif
