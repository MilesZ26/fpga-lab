##=============================================================================
## nco.xdc — s01_nco 的引脚与时序约束
## 板子：正点原子达芬奇 Pro / Xilinx Artix-7 XC7A100T
##-----------------------------------------------------------------------------
## 【引脚来源】厂商官方《达芬奇Pro开发板IO引脚分配表》 + s00_blinky 的上板反证
## 【频率来源】核心板晶振实测 50 MHz
##
##   板子网络名   → 管脚   RTL 端口（本设计里用的名字）
##   ------------------------------------------------------
##   sys_clk      → R4     clk        （系统时钟，50 MHz）
##   sys_rst_n    → U7     rst_n      （系统复位，低有效）
##   led[0]       → V9     led[0]     （LED0）★
##   led[1]       → Y8     led[1]
##   led[2]       → Y7     led[2]
##   led[3]       → W7     led[3]
##
##   ⚠️ XDC 里写的是 **RTL 的端口名**（clk / rst_n / led[0]），
##      不是板子网络名（sys_clk / sys_rst_n / led[0]）。
##
##   ★ **只有 led[0] = V9 是"被硬件反证过"的** —— s00_blinky 就是用它，
##     实测按 1 Hz 闪。led[1..3] = Y8/Y7/W7 只来自厂商引脚表，**没上过板**。
##     如果 V9 会闪而 Y8/Y7/W7 不亮/乱亮，先怀疑这三个引脚号，别怀疑 RTL。
##     排障顺序：先把 led[3:1] 也接成 fsin_o[11]（四颗灯一起闪），
##     确认一亮俱亮，再换回斜坡映射。
##
## 完整上板流程见 docs/上板指南.md
##=============================================================================


## ── 时钟 ────────────────────────────────────────────────────────────────────
## 周期 20.000 ns = 50 MHz。
##
## 这个值和 nco_top.v 里 CLK_HZ 的默认值（50_000_000）**必须一致** ——
## 后者决定 PHI_INC = FREQ_HZ * 2^PHASE_W / CLK_HZ，进而决定实际输出频率。
## 两者不一致时 LED 照样会动，但节奏不是你想要的，而且很难从现象反推。

set_property -dict {PACKAGE_PIN R4  IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]


## ── 复位 ────────────────────────────────────────────────────────────────────
## U7 = sys_rst_n，厂商表标注「低有效」，对上 rst_n，直接连不用取反。
##
## 注意本设计里按键**先过 reset_sync**（见 nco_top.v），
## 所以机械抖动和异步释放都由 reset_sync 兜住了，XDC 这边不需要额外处理。

set_property -dict {PACKAGE_PIN U7  IOSTANDARD LVCMOS33} [get_ports rst_n]


## ── LED ─────────────────────────────────────────────────────────────────────
## 映射见 nco_top.v：
##   led[0]   = fsin_o[11]     符号位（FREQ_HZ=1 时约 1 Hz 方波）
##   led[3:1] = fsin_o[10:8]   幅值高 3 位（二进制斜坡）
##
## LED 极性和 IOSTANDARD 一样不影响"能不能看出来在动"：
## 低电平点亮只会让亮灭反向，方波还是方波。

set_property -dict {PACKAGE_PIN V9  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7  IOSTANDARD LVCMOS33} [get_ports {led[3]}]


##=============================================================================
## ⚠️ 综合前必须先解决的一件事：$readmemh 找不到 lut/
##-----------------------------------------------------------------------------
## nco.v 里是这么读表的：
##
##     `ifndef LUTDIR
##       `define LUTDIR "s01_nco/lut/"      // 兜底：手工跑 iverilog / Vivado 综合
##     `endif
##     initial $readmemh({`LUTDIR, "sin.mem"}, sin_rom);
##
## $readmemh 的路径是相对**综合进程的工作目录**，不是相对 .v 文件所在目录。
## Vivado 的 run 目录在工程里（仓库外），所以那个兜底相对路径**必然读不到**。
## 而且读不到时**不报错**——ROM 里全是 x，波形一片红，极难查。
##
## 三种做法，按推荐度：
##
##   ① 给 Vivado 传宏（推荐，一行搞定；工程模式下在
##      Settings → Synthesis → Verilog Options → Verilog Macros 里加）：
##         Name  = LUTDIR
##         Value = "D:/Backup/Documents/GitHub/fpga-lab/s01_nco/lut/"
##      注意 **值里要带真正的双引号**，且**结尾必须有斜杠**（RTL 是拼 "sin.mem"）。
##
##   ② 非工程模式（Tcl）：synth_design 时给
##         -verilog_define {LUTDIR="D:/.../s01_nco/lut/"}
##      （花括号保住引号）
##
##   ③ 临时把 .mem 拷到 Vivado 的 run 目录并改兜底路径 —— 不推荐，
##      仿真/综合就会用到两份不同的数据，正是"仿真对、上板错"最难查的那种 bug。
##
## **这条还没在 Vivado 上实测过**（进度.md 的待决问题）。验收方法：
## 综合完后 report_utilization 里应该看到若干 BRAM/RAMB（两张 4096×12 的表），
## 数量为 0 说明表被优化没了 → 路径没读进去；日志里也搜一下 readmemh / .mem。
##
## 另外：fsin_o / fcos_o 上挂了 (* mark_debug = "true" *)，
## 想用 ILA 就在综合后 Set up Debug 里勾这两个信号。
## ⚠️ ILA 采样时钟是 50 MHz、缓冲深度只有几千点，所以 **FREQ_HZ 必须调高**
## （建议 100_000 左右）才看得见正弦形状；FREQ_HZ=1 时一个周期 1 秒，
## 几千个采样点里相位几乎不动，屏幕上就是一条直线。
##=============================================================================


## ── 自查清单 ────────────────────────────────────────────────────────────────
## [ ] create_clock 已填 20.000 ns（= 50 MHz），行首无 '#'
## [ ] nco_top.v 里 CLK_HZ 默认值 = 50_000_000，与上面一致
## [ ] 器件封装 = xc7a100tfgg484-2（100T / fgg484 / -2）
## [ ] LUTDIR 宏已按上面 ① 或 ② 配好
## [ ] 综合日志里没有 $readmemh 读文件的告警，report_utilization 里 RAMB 数量 > 0
## [ ] 下载后 led[0]（V9）以约 1 Hz 闪 —— 这一颗灯的引脚是上板反证过的
## [ ] 想用 ILA：FREQ_HZ 改成 100_000，Set up Debug 勾 fsin_o / fcos_o
##=============================================================================
