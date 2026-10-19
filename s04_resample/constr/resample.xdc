##=============================================================================
## resample.xdc — s04_resample 的引脚与时序约束
## 板子：正点原子达芬奇 Pro / Xilinx Artix-7 XC7A100T
##-----------------------------------------------------------------------------
## 【引脚来源】厂商官方《达芬奇Pro开发板IO引脚分配表》 + s00/s03 的上板反证
## 【频率来源】核心板晶振实测 50 MHz
##
##   板子网络名   → 管脚   RTL 端口（本设计里用的名字）
##   ------------------------------------------------------
##   sys_clk      → R4     clk        （系统时钟，50 MHz）
##   sys_rst_n    → U7     rst_n      （系统复位，低有效）
##   led[0]       → V9     led[0]     （LED0）
##   led[1]       → Y8     led[1]
##   led[2]       → Y7     led[2]
##   led[3]       → W7     led[3]
##
##   ⚠️ XDC 里写的是 **RTL 的端口名**（clk / rst_n / led[0]），
##      不是板子网络名（sys_clk / sys_rst_n / led[0]）。
##
##   四颗 LED 都已被硬件反证：s00 反证 V9；s03 让四颗灯接同一个 1 Hz 心跳，
##   Y8 / Y7 / W7 全部实测闪烁 → 三个引脚号确认。本 stage 继续沿用"四灯同闪"，
##   哪颗不闪就怀疑那颗灯的引脚，而不是 RTL。
##
## 完整上板流程见 docs/上板指南.md
##=============================================================================


## ── 时钟 ────────────────────────────────────────────────────────────────────
## 周期 20.000 ns = 50 MHz。和 resample_top.v 的 CLK_HZ 默认值（50_000_000）一致 ——
## 后者只影响心跳分频；冲激周期由 IMP_PERIOD（拍数）决定，换算成时间才用到 CLK_HZ，
## 都不影响多相算术。

set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]


## ── 复位 ────────────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports rst_n]


## ── LED ─────────────────────────────────────────────────────────────────────
## resample_top.v 里 led = {4{hb}}，四颗灯都是 1 Hz 心跳。
## 想改频率就改 HEART_HZ 参数（XDC 不用动）。

set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {led[3]}]


##=============================================================================
## ⚠️ 综合前必须解决：$readmemh 找不到 s04_resample/lut/hb_odd.mem
##-----------------------------------------------------------------------------
## interp2.v / decim2.v 都是这么读系数的：
##
##     `ifndef HB_COEFDIR
##       `define HB_COEFDIR "s04_resample/lut/"   // 兜底：手工跑 / Vivado 综合
##     `endif
##     initial $readmemh({`HB_COEFDIR, COEF_FILE}, coef);
##
## $readmemh 的路径相对**综合进程的工作目录**（Vivado 的 run 目录在工程里，仓库外），
## 兜底相对路径**必然读不到**，而且读不到时**不报错** —— 系数全是 x。
##
## 正确做法（工程模式，2026-10-18 s03 实测定案）：
##   Settings → Synthesis → Options → 【More Options】里写**一整行**：
##
##       -verilog_define HB_COEFDIR="D:/…/fpga-lab/s04_resample/lut/"
##
##   ⚠️ `-verilog_define` 这个开关必须自己写（More Options 的内容原样拼到命令行）。
##      只写 `HB_COEFDIR="…"` 会报
##      ERROR: [Common 17-165] Too many positional options when parsing '…'
##   ⚠️ 值里要带真正的双引号，**结尾必须有斜杠**（RTL 是拼 "hb_odd.mem"）。
##   ⚠️ 路径**只能出现一次**，也别漏目录层。
##   ⚠️ 改完设置记得 **Reset Synthesis**，否则不会生效。
##
##   怎么一眼确认配对了：看 …\s04_resample.runs\synth_1\resample_top.tcl 里
##   synth_design 那一行，四样齐全就对：① 有 -verilog_define ② 宏名是 HB_COEFDIR
##   ③ 只有一个路径 ④ 结尾有斜杠
##
##   本 stage **只需要 HB_COEFDIR**（不需要 NCO_LUTDIR / FIR_COEFDIR）——
##   resample_top 不例化 nco / fir。s05 把 NCO+混频+插值串起来时才需要多个宏。
##
## 验收方法：综合完 report_utilization 里应该看到：
##   · **DSP48E1 约 30 个** —— 插值 15 + 抽取 15。
##     （单个模块各 15 个；resample_top 为了闭环把两个方向都例化了，所以是 30。
##      真实 DUC 只需要插值那一侧，也就是 15 个 —— 别看到 30 就以为半带没省。）
##   · Slice Registers 至少 1100 左右（两条 30 抽头延迟线 + 2×15×29 乘积寄存器）
##   · 系数表没读进去的话，DSP 和寄存器都会少得可怜。
##
## ⚠️ 宏名是 `HB_COEFDIR`（一个表一个宏）。别再写旧的 `LUTDIR`。
##=============================================================================


##=============================================================================
## ILA（这一步由你自己做，和 s01/s02/s03 一样走 "Set up Debug"）
##-----------------------------------------------------------------------------
## resample_top.v 挂了四个探针：
##     (* mark_debug = "true", keep = "true" *)
##       imp_dbg    1 位   冲激标志（建议当触发条件）
##       ye_dbg    13 位   插值偶相（OW_INT=13）
##       yo_dbg    13 位   插值奇相
##       yrt_dbg   14 位   级联输出（OW_RT=14）
##
## 综合后 → Set up Debug → 勾这四个 → 采样深度建议 8192。
## 总探针 41 位，深度 8192 时约 9~10 块 RAMB36（比 s03 的 3.5 块大不少）。
##
## 默认参数（50 MHz、IMP_PERIOD=1024）下的预期波形：
##
##   ① 冲激周期 1024 点 = 20.48 µs；8192 点窗口里 **8 个**冲激。
##   ② 每个冲激后（先给"输出下标 k"；→ 后面是 ILA 上从 `imp_dbg == 1`
##      的触发行起算的偏移，触发行 = 0）：
##        y_e  ：输出下标 k=15 一个 2047，其余全 0（半带偶相 = 纯延迟）
##               → ILA **+19**
##        y_o  ：30 个点（k=0..29），峰值 **1298** 在 k=14/15（两格相等 → 线性相位）
##               → ILA **+4..+33**，峰值 **+18/+19**
##        y_rt ：43 个点（k=9..51），峰值 **1991** 在 k=30，关于 30 对称
##               → ILA **+17..+59**，峰值 **+38**
##      ⚠️ ILA 偏移比 TB 的 cap 多 1：`imp` 是组合逻辑，ILA 在它变 1 的那一拍
##         就触发，而数据要到下一拍才进 `dly[0]`。所以触发行 = TB cap[0] 的前一拍；
##         ILA 偏移 = k+4（插值）/ k+8（级联），而 TB cap = k+3 / k+7。
##      **逐点期望值在 `s04_resample/lut/expected_h.md`** —— 对账直接查，别手算。
##   ③ 触发建议：`imp_dbg == 1`。别用 `== 1991` 当触发（见学习备忘第 6 节）。
##   ④ 显示：`yo_dbg` / `yrt_dbg` 在 ILA 里改成 **signed**，否则负数是很大的正数。
##
## 判读顺序（排障时很有用）：
##   y_e 对 → 复位、冲激发生器、偶相延迟都对；
##   y_o 对 → 系数表读对了、对称预加和流水线都对；
##   y_rt 对 → **两相相位对齐**和**位宽衔接（13 位喂 13 位）**都对。
##   如果只有 y_rt 错，先查 resample_top 里 u_decim 的 .x_e/.x_o 有没有接反。
##
## ⚠️ `dbg_hub` 的 `C_CLK_INPUT_FREQ_HZ` 是 300 MHz（Vivado 默认），我们时钟是 50 MHz。
##    不用急着改；只有 ILA 连不上/抓不到/超时才改成 50000000 再试。
## ⚠️ Vivado 会把它自己的调试配置**追加写回这个文件**（create_debug_core …）。
##    按 AGENTS.md「远端同步」第 5 条，**调试结束就整段删掉再提交**。
##    这个文件目前**是干净的**（没有调试脚手架），第一次上板时别把整段提交进来。
##=============================================================================


## ── 自查清单 ────────────────────────────────────────────────────────────────
## [ ] create_clock 已填 20.000 ns（= 50 MHz），行首无 '#'
## [ ] resample_top.v 里 CLK_HZ 默认值 = 50_000_000
## [ ] 器件封装 = xc7a100tfgg484-2（100T / fgg484 / -2）
## [ ] **HB_COEFDIR 指向 s04_resample/lut/**，值带双引号、结尾带斜杠，改完 Reset Synthesis
## [ ] 综合日志里没有 $readmemh 读文件的 CRITICAL WARNING
## [ ] report_utilization 里 DSP48E1 约 30 个（单模块 15 个）
## [ ] 下载后四颗 LED 都按 1 Hz 闪（哪颗不闪 → 怀疑引脚）
## [x] ILA：7 个完整冲激（CSV 缺 sample 0）/ y_e +19 = 2047 /
##     y_o +4..+33、峰值 +18/+19 = 1298 / y_rt +17..+59、峰值 +38 = 1991
## [ ] 调试结束，把 Vivado 追加的 create_debug_core 段删掉
##=============================================================================
