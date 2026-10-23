`timescale 1ns/1ps
//=============================================================================
// nco — 数控振荡器（相位累加器 + 查表）
//-----------------------------------------------------------------------------
// 功能：
//   相位累加器一直累加频率控制字 PHI_INC，取相位的高位当 ROM 地址，
//   同时读出正弦和余弦。相位自然溢出回绕 = 相位绕了一整圈 —— 这是 NCO 的巧妙处。
//
// 时钟域：clk
// 延迟：  输出比当前相位**晚 1 拍**（"相位累加器 1 拍 + 输出寄存器 1 拍"）
// 复位值：phase_acc = 0，fsin_o = fcos_o = 0
//
// 参数：
//   CLK_HZ    输入时钟频率（仿真时调小，例如 1024）
//   FREQ_HZ   期望输出频率（只能取整到 PHI_INC，会有量化误差）
//   PHASE_W   相位累加器位宽（频率分辨率 = CLK_HZ / 2**PHASE_W）
//   LUT_AW    查表地址位宽，表深 = 2**LUT_AW
//   AW        输出幅度位宽
//
//   ⚠️ LUT_AW / AW 决定 .mem 表的**形状**，改了必须重新生成表：
//        python3 scripts/gen_lut.py --lut-aw <LUT_AW> --aw <AW> --out s01_nco/lut
//      忘记重新生成的话 $readmemh 读不满也**不报错**，表里会留 x
//      （这个坑的过程记在 docs/学习备忘.md）。
//
// 输出格式：**有符号二进制补码**，幅值 ±(2**(AW-1) - 1)，不会出现满幅负值。
//   这样 sin[i] == -sin[N-i] 严格成立，表里没有直流分量 —— 理由见 lut/README.md。
//=============================================================================

module nco #(
    parameter integer CLK_HZ  = 50_000_000,   // 输入时钟频率
    parameter integer FREQ_HZ = 1,            // 输出频率
    parameter integer PHASE_W = 32,           // 相位累加器位宽
    parameter integer LUT_AW  = 12,           // LUT address width, 查表地址位宽（表深 = 2**LUT_AW）
    parameter integer AW      = 12            // amplitude width, 输出幅度位宽（补码）
)(
    input  wire                 clk,       // 时钟输入
    input  wire                 rst_n,     // 异步复位输入，低有效
    output reg  signed [AW-1:0] fsin_o,    // 正弦波输出（二进制补码）
    output reg  signed [AW-1:0] fcos_o     // 余弦波输出（二进制补码）
);

// ── 查表目录（一个表一个宏，2026-10-18 改）───────────────────────────────
// 以前全仓库只有一个 `LUTDIR`，s03 加 FIR 系数表后会打架（同一轮仿真只能指一个目录）。
// 现在每张表一个语义明确的宏：NCO 的表用 `NCO_LUTDIR`，FIR 系数用 `FIR_COEFDIR`。
//
// 兼容旧配置：如果只定义了老名字 `LUTDIR`（例如 Windows 上旧的 Vivado 工程），
// 就沿用它；什么都没定义时走兜底相对路径（手工跑 iverilog / Vivado 综合）。
//
// ⚠️ 和以前一样：$readmemh 的路径相对**仿真/综合进程的工作目录**，不是 .v 所在目录。
//    所以 make sim 会传绝对路径；Vivado 里必须配 NCO_LUTDIR（见 constr/nco.xdc）。
`ifndef NCO_LUTDIR
  `ifdef LUTDIR
    `define NCO_LUTDIR `LUTDIR
  `else
    `define NCO_LUTDIR "s01_nco/lut/"
  `endif
`endif

    localparam integer DEPTH = (1 << LUT_AW);   // 表深

    // ── 正弦余弦查找表 ──
    // 用寄存器数组读常量表。表由 scripts/gen_lut.py 生成并入库，
    // 保证仿真和综合用的是**同一份数据**。
    reg signed [AW-1:0] sin_rom [0:DEPTH-1];
    reg signed [AW-1:0] cos_rom [0:DEPTH-1];
    initial begin
        $readmemh({`NCO_LUTDIR, "sin.mem"}, sin_rom); //拼接地址和文件名，读进寄存器
        $readmemh({`NCO_LUTDIR, "cos.mem"}, cos_rom);
    end

    // FTW = FREQ_HZ / CLK_HZ * 2**PHASE_W，先用移位做乘法
    localparam [63:0] PHI_INC_64 = FREQ_HZ << PHASE_W;    // 64 位里移位，编译期算
    localparam [31:0] PHI_INC    = PHI_INC_64 / CLK_HZ;   // 截回 32 位，编译期算，不用综合除法

    // ── 相位累加器 ──
    reg [PHASE_W-1:0] phase_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase_acc <= {PHASE_W{1'b0}}; //累加器复位
        else
            phase_acc <= phase_acc + PHI_INC; //累加器递进
    end

    // ── 查表输出 ──
    // 地址 = 相位的**高 LUT_AW 位**。低位被丢掉，这叫**相位截断**，会引入杂散；
    // 第一版不管它（LUT_AW = 12、PHASE_W = 32 时丢掉 20 位）。
    wire [LUT_AW-1:0] addr = phase_acc[PHASE_W-1 : PHASE_W-LUT_AW];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsin_o <= {AW{1'b0}}; //输出寄存器复位
            fcos_o <= {AW{1'b0}};
        end else begin
            fsin_o <= sin_rom[addr]; //输出寄存器读地址，比相位累加器晚一拍
            fcos_o <= cos_rom[addr];
        end
    end

endmodule
