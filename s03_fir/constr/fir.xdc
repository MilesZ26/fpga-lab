##=============================================================================
## fir.xdc — s03_fir 的引脚与时序约束
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
##     fir_top.v 故意让**四颗灯都接同一个心跳**：哪颗不闪，先怀疑那颗灯的引脚，
##     别怀疑 RTL。排障顺序和 s01 的 nco.xdc 一样。
##
## 完整上板流程见 docs/上板指南.md
##=============================================================================


## ── 时钟 ────────────────────────────────────────────────────────────────────
## 周期 20.000 ns = 50 MHz。
##
## 这个值和 fir_top.v 里 CLK_HZ 的默认值（50_000_000）**必须一致** ——
## 后者决定心跳分频和冲激周期。FIR 本身不用 CLK_HZ，但 LED 和 ILA 的时间轴要用。

set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]


## ── 复位 ────────────────────────────────────────────────────────────────────
## U7 = sys_rst_n，低有效，直接连不用取反。
## fir_top.v 里 rst_n 先过 reset_sync，机械抖动和异步释放都由它兜住。

set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports rst_n]


## ── LED ─────────────────────────────────────────────────────────────────────
## fir_top.v 里 led = {4{hb}}，四颗灯都是 1 Hz 心跳。
## 想改频率就改 fir_top.v 的 HEART_HZ 参数（XDC 不用动）。

set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {led[3]}]


##=============================================================================
## ⚠️ 综合前必须解决：$readmemh 找不到 s03_fir/lut/coef.mem
##-----------------------------------------------------------------------------
## fir.v 里是这么读系数的：
##
##     `ifndef FIR_COEFDIR
##       `define FIR_COEFDIR "s03_fir/lut/"   // 兜底：手工跑 / Vivado 综合
##     `endif
##     initial $readmemh({`FIR_COEFDIR, COEF_FILE}, coef);
##
## $readmemh 的路径是相对**综合进程的工作目录**（Vivado 的 run 目录在工程里，
## 仓库外），所以兜底相对路径**必然读不到**。而且读不到时**不报错** ——
## 系数数组全是 x，综合出来的滤波器输出也是 x/0，极难查。
##
## 正确做法（工程模式，**2026-10-18 实测定案**）：
##   Settings → Synthesis → Options → 【More Options】里写**一整行**：
##
##       -verilog_define FIR_COEFDIR="D:/…/fpga-lab/s03_fir/lut/"
##
##   ⚠️ More Options 里的内容会**原样拼到 synth_design 命令行**上，
##      所以 `-verilog_define` 这个开关必须自己写。只写 `FIR_COEFDIR="…"`
##      会报：ERROR: [Common 17-165] Too many positional options when parsing
##      'FIR_COEFDIR="…"' —— 2026-10-18 本工程真的撞过这一下。
##      （不是那个 "Verilog Macros / Name + Value" 两栏对话框；本机 2020.2 没走通。
##        完整说明见 docs/学习备忘.md 第 13 节）
##
##   ⚠️ 值里要带真正的双引号，且**结尾必须有斜杠**（RTL 是拼 "coef.mem"）。
##   ⚠️ 路径**只能出现一次**，也别漏目录层（本仓库是 …\Documents\GitHub\fpga-lab\…）。
##   ⚠️ 改完设置记得 **Reset Synthesis**，否则不会生效（s01 踩过）。
##
##   怎么一眼确认配对了：看 …\s03_fir.runs\synth_1\fir_top.tcl 里 synth_design
##   那一行，四样齐全就对：① 有 -verilog_define ② 宏名是 FIR_COEFDIR
##                        ③ 只有一个路径 ④ 结尾有斜杠
##
## 非工程模式（Tcl）：
##   synth_design -verilog_define {FIR_COEFDIR="D:/…/fpga-lab/s03_fir/lut/"}
##
## 验收方法：综合完 report_utilization 里应该看到：
##   · DSP48E1 大约 24 个（23 对 + 1 个中心抽头）
##   · Slice Registers 至少有 47*12（延迟线）+ 24*29（乘积）这么多
##   如果 DSP 是 0、寄存器也少得可怜，多半是系数表没读进去、整个 FIR 被优化掉了。
##
## ⚠️ 宏名从 `LUTDIR` 改成了 `FIR_COEFDIR`（2026-10-18，"一个表一个宏"）。
##    nco.v 现在用 `NCO_LUTDIR`（旧名 LUTDIR 仍被它兼容，但新工程别再用旧名）。
##    本 stage 只需要 FIR_COEFDIR，不需要 NCO_LUTDIR —— 除非你把 s01 的 nco.v
##    也加进了工程（没必要，fir_top 不例化 NCO）。
##=============================================================================


##=============================================================================
## ILA（这一步由你自己做，和 s01/s02 一样走 "Set up Debug"）
##-----------------------------------------------------------------------------
## fir_top.v 里挂了两个探针：
##     (* mark_debug = "true", keep = "true" *)
##       imp_dbg   1 位   冲激标志（建议当触发条件）
##       fir_dbg  13 位   FIR 输出（OW=13）
##
## 综合后 → Set up Debug → 勾这两个信号 → 采样深度建议 8192。
##
## 默认参数（50 MHz、IMP_PERIOD=1024）下的预期波形：
##
##   ① 冲激周期：1024 个采样点 = 20.48 µs。8192 点的窗口里能看到 **8 个**冲激。
##   ② 每个冲激后面跟 47 个点的冲激响应：
##        h[k] = floor( (coef[k]*2047 + 2^14) / 2^15 )   ← 不是"四舍五入"，见下
##      中心抽头 h[23] = **613**，两端 h[0] = h[46] = **1**
##      **47 个点的完整表在 s03_fir/lut/expected_h.md**（对账直接查，别手算）
##   ③ 响应必须**关于第 23 个点对称** —— 这是线性相位的直接证据，
##      也是最容易一眼看出来的性质。
##   ④ 触发建议：`imp_dbg == 1`（单点冲激很适合当触发）。
##      别用 `fir_dbg == 613` 当触发：量化的峰值只有一个点，触发会时有时无
##      （s01 的坑：别用 == 峰值当触发，见 学习备忘 第 6 节）。
##
## ⚠️ `dbg_hub` 的 `C_CLK_INPUT_FREQ_HZ` 是 300 MHz（Vivado 默认），我们的时钟是 50 MHz。
##    **不用急着改**：s02 就是带着这个默认值抓到波形的。只有 ILA
##    "连不上 / 抓不到 / 超时"时才把它改成 50000000 再试。
## ⚠️ Vivado 会把它自己的调试配置**追加写回这个文件**（create_debug_core …）。
##    按 AGENTS.md「远端同步」第 5 条，**调试结束就整段删掉再提交**：
##    那段写死了网名（clk_IBUF_BUFG / fir_dbg[*]），设计一改就对不上，
##    还会让 opt_design 多花几分钟、多占十几块 BRAM。
##=============================================================================


## ── 自查清单 ────────────────────────────────────────────────────────────────
## [ ] create_clock 已填 20.000 ns（= 50 MHz），行首无 '#'
## [ ] fir_top.v 里 CLK_HZ 默认值 = 50_000_000，与上面一致
## [ ] 器件封装 = xc7a100tfgg484-2（100T / fgg484 / -2）
## [ ] **FIR_COEFDIR 指向 s03_fir/lut/**，值带双引号、结尾带斜杠，改完 Reset Synthesis
## [ ] 综合日志里没有 $readmemh 读文件的 CRITICAL WARNING
## [ ] report_utilization 里 DSP48E1 约 24 个、寄存器数量合理
## [ ] 下载后四颗 LED 都按 1 Hz 闪（哪颗不闪 → 怀疑引脚，不是 RTL）
## [ ] ILA 上能看到周期 1024 点的冲激串，响应峰值 613、关于中心对称
## [ ] 调试结束，把 Vivado 追加的 create_debug_core 段删掉
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
connect_debug_port u_ila_0/probe0 [get_nets [list {fir_dbg[0]} {fir_dbg[1]} {fir_dbg[2]} {fir_dbg[3]} {fir_dbg[4]} {fir_dbg[5]} {fir_dbg[6]} {fir_dbg[7]} {fir_dbg[8]} {fir_dbg[9]} {fir_dbg[10]} {fir_dbg[11]} {fir_dbg[12]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 1 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list imp_dbg]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk_IBUF_BUFG]
