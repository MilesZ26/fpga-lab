##=============================================================================
## duc.xdc — s05_duc 的引脚与时序约束
## 板子：正点原子达芬奇 Pro / Xilinx Artix-7 XC7A100T
##-----------------------------------------------------------------------------
## 【引脚来源】厂商官方《达芬奇Pro开发板IO引脚分配表》 + s00/s03 的上板反证
## 【频率来源】核心板晶振实测 50 MHz
##
##   板子网络名   → 管脚   RTL 端口
##   ------------------------------------------------------
##   sys_clk      → R4     clk        （系统时钟，50 MHz）
##   sys_rst_n    → U7     rst_n      （系统复位，低有效）
##   led[0]       → V9     led[0]
##   led[1]       → Y8     led[1]
##   led[2]       → Y7     led[2]
##   led[3]       → W7     led[3]
##
##   四颗 LED 都已被硬件反证：s00 反证 V9；s03 四灯同闪反证 Y8/Y7/W7。
##
## 完整上板流程见 docs/上板指南.md
##=============================================================================


## ── 时钟 ────────────────────────────────────────────────────────────────────
## 20.000 ns = 50 MHz。和 duc_top.v 的 CLK_HZ 默认值（50_000_000）一致。
## CLK_HZ 只影响 NCO 的相位增量和心跳分频，不影响多相算术。

set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]


## ── 复位 ────────────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports rst_n]


## ── LED ─────────────────────────────────────────────────────────────────────
## duc_top.v 里 led = {4{hb}}，四颗灯都是 1 Hz 心跳。

set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {led[3]}]


##=============================================================================
## ⚠️ 综合前必须解决：三张表都要找到！（s05 是第一个用三张表的 stage）
##-----------------------------------------------------------------------------
## duc_top 里同时例化了：
##   · s01 的 nco      → 读 sin.mem / cos.mem   （宏 NCO_LUTDIR）
##   · s03 的 fir      → 读 coef.mem            （宏 FIR_COEFDIR）
##   · s04 的 interp2  → 读 hb_odd.mem          （宏 HB_COEFDIR）
##
## $readmemh 的路径相对**综合进程的工作目录**（Vivado 的 run 目录在工程里，
## 仓库外），兜底相对路径**必然读不到**，而且读不到时**不报错** —— 表全是 x。
##
## 正确做法（s03 实测定案）：Settings → Synthesis → Options → **More Options**
## 里写**三整行**（每行一个开关）：
##
##   -verilog_define NCO_LUTDIR="D:/…/fpga-lab/s01_nco/lut/"
##   -verilog_define FIR_COEFDIR="D:/…/fpga-lab/s03_fir/lut/"
##   -verilog_define HB_COEFDIR="D:/…/fpga-lab/s04_resample/lut/"
##
##   ⚠️ `-verilog_define` 必须自己写（More Options 原样拼到 synth_design 命令行）。
##   ⚠️ 值带真双引号、结尾必须有斜杠。
##   ⚠️ 路径只能出现一次，别粘两遍。
##   ⚠️ 改完 **Reset Synthesis**，否则不生效。
##
## 验收：综合后 report_utilization 里应该看到
##   · DSP48E1 约 **76** 个：FIR 2×21 + 混频 4 + interp 2×15 = 76
##     （FIR 的 21 是 s03 实测值：两个系数量化后为 0，乘法器被删）
##   · Block RAM 约 **6** 个：两个 NCO 各 2 张 4096×12 表（s01 实测 3 个/两个表）
##   · Slice Registers 至少 4000 左右（4 条 FIR/插值流水 + LO 延迟线）
##   如果 DSP/BRAM 少得可怜 → 表没读进去，先查宏。
##
## ⚠️ 宏名是一个表一个：NCO_LUTDIR / FIR_COEFDIR / HB_COEFDIR。
##    不要再写旧的 LUTDIR。
##=============================================================================


##=============================================================================
## ILA（Set up Debug，和 s01~s04 一样的流程）
##-----------------------------------------------------------------------------
## duc_top.v 挂了 6 组探针（共 84 位）：
##     (* mark_debug = "true", keep = "true" *)
##       tone_i_dbg  12 位   测试单音 I（cos，0.01 Fs = 500 kHz）
##       tone_q_dbg  12 位   测试单音 Q（sin，0.01 Fs）
##       ie_dbg / io_dbg / qe_dbg / qo_dbg  15 位 ×4  DUC 输出四相（2Fs）
##
## 采样深度建议 4096（84 位 × 4096 ≈ 8~9 块 RAMB36）。
##
## 默认参数下的预期波形（50 MHz、FREQ_SIG=500 kHz、FREQ_LO=2.5 MHz）：
##   ① tone_i/tone_q：500 kHz 正/余弦，周期 100 拍；幅度 ±2047。
##   ② DUC 输出频率 = 0.01 + 0.05 = 0.06 Fs = **3 MHz**，周期 ≈ 16.7 拍。
##      ie/qe 是复单音的两路，幅度 ≈ 2040（单位增益），相位差 90°。
##   ③ io/qo 与 ie/qe 同频；它们是同一输出时刻的奇相，
##      相差**一个 2Fs 采样**（= 10 ns，正好是半个输入采样）。
##      ⚠️ 2026-10-20 实测：3 MHz 时相位差 +10.8° = +10 ns。
##      早期写的"半个 2Fs 采样（5 ns）"是错的 —— y_e=y[2n]、y_o=y[2n+1]，
##      两者本来就差一个 2Fs 采样。
##   ④ 触发建议：tone_i_dbg[11] 的上升沿（或 ie_dbg[14] 的上升沿）。
##      别用 `== 峰值` 当触发（见学习备忘第 6 节）。
##   ⑤ 显示：ie/io/qe/qo 在 ILA 里改成 **signed**，否则负数是很大的正数。
##
## 排障顺序：
##   tone_i 有 → 时钟/复位/NCO 对；
##   ie 有且 3 MHz → FIR/混频/插值都对；
##   ie/qe 不正交或幅度不对 → 先查混频 sin/cos 有没有接反、LO_DLY 对不对；
##   ie/io 两相错位 → 查 interp2 的 y_e/y_o 对齐。
##
## ⚠️ dbg_hub 的 C_CLK_INPUT_FREQ_HZ 默认 300 MHz，我们时钟 50 MHz。
##    只有 ILA 连不上/抓不到/超时才改成 50000000。
## ⚠️ Vivado 会把它自己的调试配置**追加写回这个文件**（create_debug_core …）。
##    按 AGENTS.md「远端同步」第 5 条，**调试结束就整段删掉再提交**。
##    这个文件目前**是干净的**（没有调试脚手架），第一次上板时别把整段提交进来。
##=============================================================================


## ── 自查清单 ────────────────────────────────────────────────────────────────
## [ ] create_clock 20.000 ns，行首无 '#'
## [ ] duc_top.v 的 CLK_HZ = 50_000_000
## [ ] 器件封装 = xc7a100tfgg484-2（100T / fgg484 / -2）
## [ ] 三个宏都配了：NCO_LUTDIR / FIR_COEFDIR / HB_COEFDIR（带引号、结尾斜杠）
## [ ] 综合日志里没有 $readmemh 读文件的 CRITICAL WARNING
## [ ] report_utilization：DSP48E1 ≈ 76、Block RAM ≈ 6
## [ ] 下载后四颗 LED 都按 1 Hz 闪（哪颗不闪 → 怀疑引脚）
## [ ] ILA：tone_i 500 kHz / ie 3 MHz / 幅度 ≈ 2040 / ie、qe 正交
## [ ] 调试结束，把 Vivado 追加的 create_debug_core 段删掉
##=============================================================================
