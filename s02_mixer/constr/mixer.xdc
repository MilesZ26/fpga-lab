##=============================================================================
## mixer.xdc — s02_mixer 的引脚与时序约束
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
##
## 完整上板流程见 docs/上板指南.md
##=============================================================================


## ── 时钟 ────────────────────────────────────────────────────────────────────
## 周期 20.000 ns = 50 MHz。
##
## 这个值和 mixer_top.v 里 CLK_HZ 的默认值（50_000_000）**必须一致** ——
## 后者决定两个 NCO 的 FTW，进而决定混频后的输出频率。
## 两者不一致时波形照样在动，但频率不是你要的，而且很难从现象反推。

set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]


## ── 复位 ────────────────────────────────────────────────────────────────────
## U7 = sys_rst_n，低有效，直接连不用取反。
## 按键先过 reset_sync（见 mixer_top.v），机械抖动和异步释放都由它兜住。

set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports rst_n]


## ── LED ─────────────────────────────────────────────────────────────────────
## 映射见 mixer_top.v：
##   led[0]   = i_out[12]     符号位
##   led[3:1] = i_out[11:9]   幅值高 3 位
##
## ⚠️ 默认参数（FREQ_IN=250k、FREQ_LO=200k）下输出是 50 kHz，
##    人眼看到的是"半亮"而不是闪。想看 LED 真的闪，把差频调成 1 Hz 左右
##    （例如 FREQ_IN=200_001、FREQ_LO=200_000）—— 但那时候 ILA 上就是一条直线，
##    两者不可兼得，想要哪个就综合哪一版。

set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {led[3]}]


##=============================================================================
## ⚠️⚠️ 综合前必须先解决的一件事：$readmemh 找不到 s01_nco/lut/
##-----------------------------------------------------------------------------
## 本设计的 RTL 里只有 nco.v 会读表，而 nco.v 在 s01_nco/rtl/。
## 所以 **NCO_LUTDIR 要指向 s01_nco/lut/，不是 s02_mixer/** —— 这个 stage
## 自己的数据在 s02_mixer/vec/ 里，但那是**仿真用的参考向量**，
## 综合根本不会去读（tb 才读）。
##
##   ⚠️ 2026-10-18 起宏名是 `NCO_LUTDIR`（以前叫 `LUTDIR`，nco.v 仍兼容旧名）。
##   nco.v 里是这么读表的：
##       `ifndef NCO_LUTDIR
##         `define NCO_LUTDIR "s01_nco/lut/"   // 兜底：手工跑 iverilog / Vivado 综合
##       `endif
##       initial $readmemh({`NCO_LUTDIR, "sin.mem"}, sin_rom);
##
## $readmemh 的路径是相对**综合进程的工作目录**，不是 .v 文件所在目录，
## 所以那个兜底相对路径**必然读不到**。而且读不到时**不报错**：
## ROM 里全是 x，波形一片红，极难查（这个坑 s01 已经实测过一次）。
##
## 正确做法（工程模式下）：
##   Settings → Synthesis → Verilog Options → Verilog Macros 里加
##       Name  = NCO_LUTDIR
##       Value = "D:/…/fpga-lab/s01_nco/lut/"
##   **值里要带真正的双引号**，且**结尾必须有斜杠**（RTL 是拼 "sin.mem"）。
##   改完设置记得 **Reset Synthesis**，否则不会生效（s01 踩过）。
##
## 非工程模式（Tcl）：
##   synth_design -verilog_define {NCO_LUTDIR="D:/…/fpga-lab/s01_nco/lut/"}
##
## 验收方法：综合完 report_utilization 里应该看到若干 RAMB
## （两个 nco 实例、每个两张 4096×12 的表，可能被共享），
## 数量为 0 说明表被优化没了 → 路径没读进去。
##=============================================================================


##=============================================================================
## ILA（这一步由你自己做，和 s01 一样走 "Set up Debug"）
##-----------------------------------------------------------------------------
## mixer_top.v 里已经给六个信号挂了
##     (* mark_debug = "true", keep = "true" *)
##       sig_cos / sig_sin   输入信号（实验台那个 NCO）
##       lo_cos  / lo_sin    本振
##       i_out   / q_out     混频输出
##
## 综合后 → Set up Debug → 勾这些信号 → 采样深度建议 8192。
## 探针宽度合计约 74 位；**只想证明"混频有效"的话探 i_out / q_out 就够了**
## （26 位），省一半以上的 BRAM。
##
## 看波形时对这三件事（默认参数 FREQ_IN=250k / FREQ_LO=200k）：
##
##   ① 输出周期对不对：50 kHz → 20 µs。在 50 MHz 采样下就是 **1000 个采样点**。
##      深度 8192 → 窗口 163.84 µs → 窗口里放得下约 8.19 个周期，形状清楚。
##   ② 是"搬移"不是"直通"：sig_cos 的周期是 4 µs（250 kHz，200 个点），
##      输出却是 20 µs —— 而且 1/20µs = 1/4µs - 1/5µs，正好是差频。
##   ③ I/Q 正交：i_out 和 q_out 应该是同频、相位差 90° 的两个正弦。
##      （建议把两条曲线放到同一个波形窗口里对照，或直接把 q_out 的符号位
##        也接到探针上当参考。）
##
##   想看"和频"就把 mixer_top 的 CONJ 改成 0 → 输出 450 kHz（周期 2.22 µs，
##   窗口里约 73 个周期，也看得清）。
##
## ⚠️ 别用 `i_out == 峰值` 当触发条件：量化的峰值会跳，触发会时有时无。
##    用 rst_n 或者某个过零/边沿都行（s01 的坑记在 docs/学习备忘.md 第 6 节）。
## ⚠️ Vivado 会把它自己的调试配置**追加写回这个文件**（s01 的 nco.xdc 里就有
##    这样一段 create_debug_core），那是正常现象，准备提交前删掉即可。
##=============================================================================


## ── 自查清单 ────────────────────────────────────────────────────────────────
## [ ] create_clock 已填 20.000 ns（= 50 MHz），行首无 '#'
## [ ] mixer_top.v 里 CLK_HZ 默认值 = 50_000_000，与上面一致
## [ ] 器件封装 = xc7a100tfgg484-2（100T / fgg484 / -2）
## [ ] **NCO_LUTDIR 指向 s01_nco/lut/**（不是 s02_mixer），改完 Reset Synthesis
## [ ] 综合日志里没有 $readmemh 读文件的告警，report_utilization 里 RAMB 数量 > 0
## [ ] Set up Debug 勾上 i_out / q_out（要省资源就别勾输入与本振）
## [ ] 下载后：led[0]（V9）半亮/微闪（50 kHz 太快，人眼看不清）
## [ ] ILA 上量输出周期 ≈ 1000 个采样点（50 kHz），并确认它≠输入周期（4 µs）
##=============================================================================

create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 8192 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list clk_IBUF_BUFG]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 13 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {i_out[0]} {i_out[1]} {i_out[2]} {i_out[3]} {i_out[4]} {i_out[5]} {i_out[6]} {i_out[7]} {i_out[8]} {i_out[9]} {i_out[10]} {i_out[11]} {i_out[12]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 13 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {q_out[0]} {q_out[1]} {q_out[2]} {q_out[3]} {q_out[4]} {q_out[5]} {q_out[6]} {q_out[7]} {q_out[8]} {q_out[9]} {q_out[10]} {q_out[11]} {q_out[12]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 12 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {lo_sin[0]} {lo_sin[1]} {lo_sin[2]} {lo_sin[3]} {lo_sin[4]} {lo_sin[5]} {lo_sin[6]} {lo_sin[7]} {lo_sin[8]} {lo_sin[9]} {lo_sin[10]} {lo_sin[11]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 12 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list {sig_sin[0]} {sig_sin[1]} {sig_sin[2]} {sig_sin[3]} {sig_sin[4]} {sig_sin[5]} {sig_sin[6]} {sig_sin[7]} {sig_sin[8]} {sig_sin[9]} {sig_sin[10]} {sig_sin[11]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 12 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list {sig_cos[0]} {sig_cos[1]} {sig_cos[2]} {sig_cos[3]} {sig_cos[4]} {sig_cos[5]} {sig_cos[6]} {sig_cos[7]} {sig_cos[8]} {sig_cos[9]} {sig_cos[10]} {sig_cos[11]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 12 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list {lo_cos[0]} {lo_cos[1]} {lo_cos[2]} {lo_cos[3]} {lo_cos[4]} {lo_cos[5]} {lo_cos[6]} {lo_cos[7]} {lo_cos[8]} {lo_cos[9]} {lo_cos[10]} {lo_cos[11]}]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk_IBUF_BUFG]
