##=============================================================================
## ddc.xdc — s06_ddc 的引脚与时序约束（DUC → DDC 数字回环）
## 板子：正点原子达芬奇 Pro / Xilinx Artix-7 XC7A100T
##-----------------------------------------------------------------------------
## 引脚和 s05 完全一样，不再重复"四颗 LED 已被反证"的过程：
##   sys_clk R4 / sys_rst_n U7 / led V9 Y8 Y7 W7
##
## 完整上板流程见 docs/上板指南.md
##=============================================================================

set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]

set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports rst_n]

## led[0] = DDC 输出有活动；led[1] = DUC 输出有活动；led[3:2] = 1 Hz 心跳。
set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {led[3]}]


##=============================================================================
## ⚠️ 综合前：三张表 + 一个"跨 stage"的文件清单
##-----------------------------------------------------------------------------
## ddc_top 里同时有 DUC 和 DDC，所以工程里要加入的 RTL 比 s05 多：
##
##   s01_nco/rtl/nco.v
##   s02_mixer/rtl/mixer.v
##   s03_fir/rtl/fir.v
##   s04_resample/rtl/interp2.v
##   s04_resample/rtl/decim2.v
##   s05_duc/rtl/duc_core.v
##   s06_ddc/rtl/ddc_core.v
##   s06_ddc/rtl/ddc_top.v
##   rtl/common/reset_sync.v
##
## 顶层 = ddc_top。三行宏（More Options，每行一个 -verilog_define）：
##
##   -verilog_define NCO_LUTDIR="D:/…/fpga-lab/s01_nco/lut/"
##   -verilog_define FIR_COEFDIR="D:/…/fpga-lab/s03_fir/lut/"
##   -verilog_define HB_COEFDIR="D:/…/fpga-lab/s04_resample/lut/"
##
## 验收：report_utilization 里应该看到
##   · DSP48E1 约 **152** 个：DUC 76 + DDC 76
##     （DUC = 2×FIR 21 + mixer 4 + 2×interp 15；DDC = 2×decim 15 + mixer 4 + 2×FIR 21）
##   · Block RAM 约 **9** 个：三个 NCO 各 2 张表（tone / DUC LO / DDC LO）
##   · Slice Registers 至少 8000 左右（两条链的延迟线 + 流水）
##   如果 DSP/BRAM 少得可怜 → 表没读进去，先查宏。
##
## ⚠️ 回环的 DDC LO_DLY 必须是 **23**（独立 DDC 是 14 + DUC 的 9 拍）。
##    写成 14 的话：频率仍然对，但 I/Q 会整体旋转 90°，led[0] 可能还亮着，
##    只看 ILA 频率很容易漏掉。判据是 `di/dq` 的 I/Q 相对相位/符号。
##=============================================================================


##=============================================================================
## ILA（Set up Debug）
##-----------------------------------------------------------------------------
## ddc_top.v 挂了 6 组探针（共 86 位）：
##     ie_dbg / io_dbg / qe_dbg / qo_dbg  15 位 ×4  DUC 输出四相（2Fs）
##     di_dbg / dq_dbg                    13 位 ×2  DDC 回环输出（Fs）
##
## 采样深度建议 4096（86 位 × 4096 ≈ 9 块 RAMB36）。
##
## 默认参数下的预期波形（50 MHz、FREQ_SIG=500 kHz、FREQ_LO=2.5 MHz）：
##   ① DUC 侧：ie/qe 是 3 MHz（0.06 Fs）复单音，周期 ≈ 16.7 拍，幅度 ≈ 2040；
##      io/qo 与 ie/qe 同频、错开**一个 2Fs 采样**（10 ns = 半个输入采样）。
##   ② DDC 侧：di/dq 回到 **500 kHz（0.01 Fs）**，周期 100 拍，幅度 ≈ 2040；
##      di/dq 正交，复单音幅度基本恒定。
##   ③ 频率比 = 6:1（0.06 / 0.01）—— 这是"搬上去再搬下来"的最直观证据。
##   ④ 触发建议：ie_dbg[14] 或 di_dbg[12] 的上升沿。
##   ⑤ 显示：所有探针改成 signed。
##
## 排障顺序：
##   ie/qe 有且 3 MHz → DUC 侧对；
##   di/dq 完全没有 → 先查 DDC 的 LO_DLY 是不是 23，再查 IW 是不是 15；
##   di/dq 有但频率不对 → 查 FREQ_LO 和 DUC 是否一致；
##   di/dq 频率对但 I/Q 旋转/幅度不对 → 查 CONJ=1（两路都翻）、
##     混频 SHIFT=11、LO 的 sin/cos 有没有接反；
##   LED0 不亮但 ILA 有 di → 活动计数器（ACT_W=16，约 0.8 ms 才点亮）属正常。
##
## ⚠️ 回环是数字的（板上没有 ADC/DAC），DUC 的四相直接接 DDC 的四相。
##    1:2 串并模块 deserializer2 不在这个顶层里；它和 serializer2 在
##    rtl/common/ 里，由 tb_serializer2.v 逐拍验证。
## ⚠️ 调试结束把 Vivado 追加的 create_debug_core 段整段删掉；这个文件目前是干净的。
##=============================================================================


## ── 自查清单 ────────────────────────────────────────────────────────────────
## [ ] create_clock 20.000 ns，行首无 '#'
## [ ] ddc_top.v 的 CLK_HZ = 50_000_000
## [ ] 器件封装 = xc7a100tfgg484-2
## [ ] 三个宏都配了（带引号、结尾斜杠），改完 Reset Synthesis
## [ ] 综合日志没有 $readmemh 读文件的 CRITICAL WARNING
## [ ] report_utilization：DSP48E1 ≈ 152、Block RAM ≈ 9
## [ ] **DDC 的 LO_DLY = 23（回环值）**，不是 14
## [ ] 下载后 LED0/LED1 常亮、LED2/LED3 1 Hz 同闪
## [ ] ILA：ie 3 MHz / di 500 kHz / 幅度 ≈ 2040 / di、dq 正交
## [ ] 调试结束，把 Vivado 追加的 create_debug_core 段删掉
##=============================================================================
