//=============================================================================
// nco_top — s01_nco 的板级顶层
//-----------------------------------------------------------------------------
// 功能：
//   把 nco 接到板子的时钟 / 按键复位 / LED 上，让 NCO 的输出在实物上看得见。
//   本模块不含任何算法，只做三件事：复位同步、接线、挑哪几位上灯。
//
// 时钟域：clk（单一时钟域，无 CDC）
// 延迟：  led 是纯组合连线，和 fsin_o 同拍；
//        rst_n_sync 比按键输入晚 2 拍（reset_sync 的"异步复位、同步释放"）
// 复位值：led = 4'b0000
//
// LED 映射（led[0] 和 s00_blinky 用同一颗灯，那颗灯的引脚已被硬件反证）：
//   led[0]   = fsin_o[11]      符号位 → 每半周期翻转；FREQ_HZ=1 时约 1 Hz 方波
//   led[3:1] = fsin_o[10:8]    幅值高 3 位 → 能看到"二进制斜坡"
//
//   ⚠️ 特意**没有**写成 led[3:0] = fsin_o[11:8]：那样符号位会落在 led[3]（W7）上，
//      而 W7 只在厂商引脚表里、没上过板；V9 才是被 s00 反证过的那颗。
//      把符号位单独放 led[0] 更好对图，也保住了"和 s00 同级证据"的可比性。
//
// 两级复位的命名（容易看混，先说明）：
//   rst_n       顶层端口 = 板上的机械按键，异步、有抖动
//   rst_n_sync  reset_sync 的输出 = 对齐到 clk 的版本，只给内部逻辑用
//   内部逻辑一律用 rst_n_sync；顶层端口仍叫 rst_n，是为了和 XDC / 板上网络名对上。
//
// 关于 ILA（集成逻辑分析仪）：
//   fsin_o / fcos_o 上挂了 (* mark_debug = "true" *)，有两个作用：
//     ① 阻止综合把没连到引脚的那一路（fcos_o）整个优化掉 ——
//        否则 Vivado 里 "Set up Debug" 根本找不到这些网，ILA 探不到波形；
//     ② Vivado 的 "Set up Debug" 会直接认出这两组信号。
//   这个属性是 Verilog-2001 的标准语法，仿真器会忽略它，所以 make sim 不受影响。
//
//   **ILA 核本身绝对不要写进 RTL。** 它是 Vivado IP，iverilog 没有它的行为模型，
//   写进来 make sim 立刻编译不过。核请在 Vivado 里用 Set up Debug 挂。
//=============================================================================

`timescale 1ns/1ps

module nco_top #(
    parameter integer CLK_HZ  = 50_000_000,   // 输入时钟频率（板子上是 50 MHz）
    parameter integer FREQ_HZ = 1,            // 期望输出频率
    parameter integer PHASE_W = 32            // 相位累加器位宽
)(
    input  wire       clk,     // 板级时钟 R4
    input  wire       rst_n,   // 板级按键，低有效（异步）
    output wire [3:0] led      // led[0]=V9，led[1..3]=Y8/Y7/W7
);

    // ── 复位：异步复位、同步释放 ──
    // 按键是机械的，直接接 rst_n 等于"异步释放"——松手那一刻和时钟无关，
    // 可能让触发器进入亚稳态；机械触点松手还会抖十几毫秒。
    // 所以先过 reset_sync 再给内部逻辑（s00 是把这条将就过去了，s01 补上）。
    wire rst_n_sync;
    reset_sync u_reset_sync (
        .clk   (clk),
        .arst_n(rst_n),
        .rst_n (rst_n_sync)
    );

    // ── NCO ──
    (* mark_debug = "true" *) wire [11:0] fsin_o;
    (* mark_debug = "true" *) wire [11:0] fcos_o;

    nco #(
        .CLK_HZ (CLK_HZ),
        .FREQ_HZ(FREQ_HZ),
        .PHASE_W(PHASE_W)
    ) u_nco (
        .clk   (clk),
        .rst_n (rst_n_sync),
        .fsin_o(fsin_o),
        .fcos_o(fcos_o)
    );

    // ── LED ──
    assign led[0]   = fsin_o[11];    // 符号位：半周期翻转
    assign led[3:1] = fsin_o[10:8];  // 幅值高 3 位：二进制斜坡

endmodule
