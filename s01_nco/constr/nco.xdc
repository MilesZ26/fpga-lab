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
##   ★ 写这份文件时**只有 led[0] = V9** 是硬件反证过的（s00_blinky 用它）。
##     **2026-10-18 更新**：s03 让四颗灯接同一个 1 Hz 心跳，**Y8 / Y7 / W7 全部实测
##     正常闪烁** → 三个引脚号确认无误，以后不用再怀疑。
##     （保留原来的排障思路：如果只有一颗不闪，先怀疑那颗灯的引脚，别怀疑 RTL。）
##
## 完整上板流程见 docs/上板指南.md
##=============================================================================


## ── 时钟 ────────────────────────────────────────────────────────────────────
## 周期 20.000 ns = 50 MHz。
##
## 这个值和 nco_top.v 里 CLK_HZ 的默认值（50_000_000）**必须一致** ——
## 后者决定 PHI_INC = FREQ_HZ * 2^PHASE_W / CLK_HZ，进而决定实际输出频率。
## 两者不一致时 LED 照样会动，但节奏不是你想要的，而且很难从现象反推。

set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]


## ── 复位 ────────────────────────────────────────────────────────────────────
## U7 = sys_rst_n，厂商表标注「低有效」，对上 rst_n，直接连不用取反。
##
## 注意本设计里按键**先过 reset_sync**（见 nco_top.v），
## 所以机械抖动和异步释放都由 reset_sync 兜住了，XDC 这边不需要额外处理。

set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports rst_n]


## ── LED ─────────────────────────────────────────────────────────────────────
## 映射见 nco_top.v：
##   led[0]   = fsin_o[11]     符号位（FREQ_HZ=1 时约 1 Hz 方波）
##   led[3:1] = fsin_o[10:8]   幅值高 3 位（二进制斜坡）
##
## LED 极性和 IOSTANDARD 一样不影响"能不能看出来在动"：
## 低电平点亮只会让亮灭反向，方波还是方波。

set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {led[3]}]


##=============================================================================
## ⚠️ 综合前必须先解决的一件事：$readmemh 找不到 lut/
##-----------------------------------------------------------------------------
## nco.v 里是这么读表的：
##
##     `ifndef NCO_LUTDIR
##       `define NCO_LUTDIR "s01_nco/lut/"   // 兜底：手工跑 iverilog / Vivado 综合
##     `endif
##     initial $readmemh({`NCO_LUTDIR, "sin.mem"}, sin_rom);
##
## $readmemh 的路径是相对**综合进程的工作目录**，不是相对 .v 文件所在目录。
## Vivado 的 run 目录在工程里（仓库外），所以那个兜底相对路径**必然读不到**。
## 而且读不到时**不报错**——ROM 里全是 x，波形一片红，极难查。
##
## ⚠️ 2026-10-18 起宏名是 `NCO_LUTDIR`（以前叫 `LUTDIR`）。`nco.v` 仍兼容旧名，
##    但新工程请用新名 —— 全仓库已经改成"一个表一个宏"（FIR 用 `FIR_COEFDIR`）。
##
## 三种做法，按推荐度：
##
##   ① 给 Vivado 传宏（推荐，一行搞定；工程模式下在
##      Settings → Synthesis → Verilog Options → Verilog Macros 里加）：
##         Name  = NCO_LUTDIR
##         Value = "D:/Backup/Documents/GitHub/fpga-lab/s01_nco/lut/"
##      注意 **值里要带真正的双引号**，且**结尾必须有斜杠**（RTL 是拼 "sin.mem"）。
##
##   ② 非工程模式（Tcl）：synth_design 时给
##         -verilog_define {NCO_LUTDIR="D:/.../s01_nco/lut/"}
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
## [ ] NCO_LUTDIR 宏已按上面 ① 或 ② 配好
## [ ] 综合日志里没有 $readmemh 读文件的告警，report_utilization 里 RAMB 数量 > 0
## [ ] 下载后 led[0]（V9）以约 1 Hz 闪 —— 这一颗灯的引脚是上板反证过的
## [ ] 想用 ILA：FREQ_HZ 改成 100_000，Set up Debug 勾 fsin_o / fcos_o
##=============================================================================


##=============================================================================
## ⚠️ 这里原来有一段 Vivado "Set up Debug" 自动追加的 ILA 配置
##    （`create_debug_core u_ila_0 …` 共 22 行，含 `dbg_hub` 那 4 行），
##    **2026-10-17 已被删掉 —— 不是人手删的，是 Vivado 干的。**
##-----------------------------------------------------------------------------
## 怎么没的：在 Vivado 里删掉**综合后网表**中的 `u_ila_0` 之后，Vivado
## **自己改写了这个约束文件**：那段 Tcl 整段消失，顺手把上面几行
## `set_property` 里的双空格规范成了单空格。见 docs/学习备忘.md 第 11 节。
##
## 所以现在这个文件是 **"无 ILA" 版** —— Reset Synthesis 之后不会再插 ILA。
## 对仿真（`make sim`）零影响：ILA 只是板级调试器材，不进 RTL。
##
## 想重新开 ILA（三选一）：
##   ① 综合后走 Flow Navigator → SYNTHESIS → Set up Debug，勾 `fsin_o` / `fcos_o`；
##      点完 OK 它会**再自动追加一次**到本文件末尾（和以前一样）。
##   ② 从 git 取回带 ILA 段的那一版（提交 `ba807c3`）：
##        git show ba807c3:s01_nco/constr/nco.xdc > s01_nco/constr/nco.xdc
##   ③ 长期做法：把 ILA 段单独放 `ila_debug.xdc`，Sources 面板里右键 **Disable File**
##      开关 ILA，就不必动这个主约束文件。
##
## 重新生成时会再遇到的两个坑（先记着）：
##   - `dbg_hub` 的 `C_CLK_INPUT_FREQ_HZ` 默认写 300000000（300 MHz），
##     我们的时钟是 50 MHz。ILA 若"连不上 / 抓不到 / 超时"，先改成 50000000。
##   - 那段里**写死了网名**（`clk_IBUF_BUFG` / `fcos_o[*]` / `fsin_o[*]`），
##     设计一改就对不上 —— 那时把整段删掉重走 Set up Debug。
##=============================================================================


