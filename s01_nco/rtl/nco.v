`timescale 1ns/1ps
module nco #(
    parameter integer CLK_HZ   = 50_000_000,   // 输入时钟频率
    parameter integer FREQ_HZ  = 1,              // 输出频率
    parameter integer PHASE_W = 32              // 相位累加器位宽
)(
    input  wire        clk,       // 时钟输入
    input  wire        rst_n,     // 异步复位输入，低有效
    output reg  [11:0] fsin_o,    // 正弦波输出
    output reg  [11:0] fcos_o     // 余弦波输出
);

//"相位累加器 1 拍 + 输出寄存器 1 拍"，输出比当前相位晚 1 拍

`ifndef LUTDIR
  `define LUTDIR "s01_nco/lut/"
`endif

    // ── 正弦余弦查找表 ──
    reg signed [11:0] sin_rom [0:4095]; //用寄存器数组读常量表
    reg signed [11:0] cos_rom [0:4095];
    initial begin
        $readmemh({`LUTDIR, "sin.mem"}, sin_rom);
        $readmemh({`LUTDIR, "cos.mem"}, cos_rom);
    end

    localparam [63:0] PHI_INC_64 = FREQ_HZ << PHASE_W;  // 64 位里移位，编译期算
    localparam [31:0] PHI_INC    = PHI_INC_64 / CLK_HZ;   // 截回 32 位，编译期算
    
    // ── 相位累加器 ──
    reg [PHASE_W-1:0] phase_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase_acc <= {PHASE_W{1'b0}};
        else
            phase_acc <= phase_acc +  PHI_INC;
    end

    // ── 查表输出 ──
    wire [11:0] addr = phase_acc[PHASE_W-1:PHASE_W-12]; // 取高 12 位作为地址
    always @(posedge clk or negedge rst_n) begin
       if (!rst_n) begin
            fsin_o <= 12'd0;
            fcos_o <= 12'd0;
        end else begin
            fsin_o <= sin_rom[addr];
            fcos_o <= cos_rom[addr];
        end
    end

endmodule