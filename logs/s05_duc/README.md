# logs/s05_duc — Stage 5（DUC 集成）的 Vivado 产出

> **状态：✅ 2026-10-20 完成** —— Mac 侧 `make sim` 24/24、538 个检查点；
> Windows 侧综合 / 实现 / 上板 / ILA 全部跑通。
> **76 DSP（与预算一致）、WNS 2.704 ns、6:1 频率比、I/Q 正交 90.00°，
> 四颗 LED 1 Hz 心跳正常。**

## 出处

| 项 | 值 |
|---|---|
| 工程 | `D:\Backup\Documents\vivado_projects\s05_duc\s05_duc.xpr` |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `duc_top`（`CLK_HZ=50e6`、`FREQ_SIG=500 kHz`、`FREQ_LO=2.5 MHz`） |
| 关键宏 | `NCO_LUTDIR` / `FIR_COEFDIR` / `HB_COEFDIR`（More Options 里三行 `-verilog_define`） |
| ILA | `u_ila_0`：`tone_i/q_dbg[11:0]` + `ie/io/qe/qo_dbg[14:0]`，`C_DATA_DEPTH = 4096` |
| 触发 | `tone_i_dbg[11]` 上升沿（触发点落在窗口 50%，sample 2048） |
| 调试约束 | 独立文件 `constrs_2/new/debug.xdc`（`used_in_synthesis=false`） |
| 波形 CSV | `D:\Backup\Documents\ila_data\20261020_duc.csv`（**本地，不入库**） |

## 报告清单

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（0 errors / 0 critical / 0 warnings；三张 `.mem` 都读到） |
| `duc_top_utilization_synth.rpt` | 综合后资源 —— **纯设计规模看这份** |
| `impl_runme.log` | 实现日志（`opt_design` 生成 ILA + `dbg_hub`、各阶段耗时） |
| `duc_top_utilization_placed.rpt` | 布局后资源（**含 ILA**） |
| `duc_top_timing_summary_routed.rpt` | 时序摘要（WNS / TNS / WHS / WPWS） |
| `duc_top_drc_routed.rpt` | DRC（0 Errors / 1994 Warnings，见下） |
| `duc_top_clock_utilization_routed.rpt` | 时钟资源（BUFGCTRL = 2） |
| `ila_check.txt` | ILA CSV 的频率 / 幅度 / 正交性判读 |

> 波形图 / CSV 不进仓库（作者本地存）。仓库只收文本报告 + 本文件的数字结论。

## 实测资源

| 指标 | 综合后（**纯设计**） | 布局后（**含 ILA**） | 对照 s04（布局后） |
|---|---|---|---|
| Slice LUTs | **3346** | **4255** | 2351 |
| Slice Registers | **4999** | **7350** | 4113 |
| Block RAM Tile | **6** | **15.5**（设计 6 + ILA 缓存 9.5） | 9.5 |
| DSP48E1 | **76** | **76** | 30 |
| BUFGCTRL | **1** | **2**（`sys_clk` + `dbg_hub` 的 TCK） | 2 |
| BSCANE2 | **0** | **1** | 1 |
| **WNS / TNS** | — | **2.704 ns** / 0.000，失败端点 0 / 14944 | +9.311 |
| WHS / THS | — | **0.058 ns** / 0.000，失败端点 0 / 14928 | +0.068 |
| WPWS | — | **8.870 ns**，失败 0 / 7721 | +8.870 |
| DRC | — | **0 Errors / 1994 Warnings** | 0 / 797 |
| 综合告警 | **0 errors / 0 critical / 0 warnings** | — | — |

**综合资源与预算完全对上**：76 DSP = FIR 2×21 + 混频 4 + interp 2×15；
6 BRAM = 两个 NCO 各 2 张 4096×12 表；BSCANE2 = 0 证明**综合阶段还没插 ILA**。

**WNS 2.704 ns 不是数据通路**（和 s03/s04 同一个规律）：

| 路径组 | WNS | 是什么 |
|---|---|---|
| `async_default`（`sys_clk → sys_clk`） | **2.704 ns** | `u_reset_sync/sync_reg[1]` → `u_duc/u_nco/phase_acc_reg[18]/CLR`，**异步复位释放 recovery**，96% 是走线 |
| `sys_clk`（纯数据通路） | **8.402 ns** | 最紧的是 `u_duc/u_fir_i/y_out_reg[12]` 出发的路径 |

所以"WNS 只有 2.7 ns"听起来紧，实际数据通路还有 8.4 ns；限制它的是复位网络的布线延迟。
（后续想改善，方向是缩短复位树 / 每级本地复位同步，不是加时序例外。）

## DRC 构成（`duc_top_drc_routed.rpt`，0 Errors）

| 规则 | 条数 | 说明 |
|---|---|---|
| DPOR-1 | **1722** | 异步复位打到 DSP/BRAM 的控制脚；**不影响功能**，见学习备忘 8 |
| DPIP-1 | 80 | DSP 输入未流水（性能提示） |
| DPOP-1 / DPOP-2 | 74 / 74 | DSP 输出未流水（性能提示） |
| REQP-1839 / 1840 | 20 / 20 | NCO 的相位累加器异步复位驱动 BRAM 地址脚（读表地址） |
| CHECK-3 | 2 | 规则条数上限（报告截断提示，不是设计问题） |
| CFGBVS-1 | 1 | 配置 bank 电压属性未设（s00 起就有） |
| RTSTAT-10 | 1 | `dbg_hub` 内部 25 根 net 没有可布负载（调试 IP 自带） |

> `impl_runme.log` 里写的是 "0 Errors, 733 Warnings" —— 那是**消息条数**，
> 同一条规则的消息会被限流（CHECK-3）；上面 1994 是报告里的**违例条数**。
> s04 那次两者刚好相等，别拿它当规律。

**实现耗时**：`opt_design` 40 s（现场生成 `u_ila_0` + `dbg_hub`）→
`place_design` 23 s → `route_design` 44 s → `write_bitstream` 22 s。

## ILA 实测（CSV `20261020_duc.csv`，4096 点）

| 检查 | 实测 | 判据 | 结论 |
|---|---|---|---|
| LED | 四颗 1 Hz 同闪 | 心跳 | ✅ |
| `tone_i` / `tone_q` 频率 | **500.0 kHz**，周期 **100.000** 拍 | 0.01 Fs | ✅ |
| `tone_i` / `tone_q` 幅度 | **2047 / 2047** | ±2047 | ✅ |
| `tone_i → tone_q` | **−90.00°** | 正交（cos / sin） | ✅ |
| `ie` / `qe` 频率 | **3.000 MHz**，周期 **16.667** 拍 | 0.06 Fs | ✅ |
| `ie` / `qe` 幅度 | **2042.5 / 2042.2** | ≈2040（单位增益） | ✅ |
| `ie → qe` | **−90.01°** | 正交 | ✅ |
| 输出/输入频率比 | **6.0000** | 6:1 | ✅ |
| 和频 vs 差频 | **3 MHz = 0.01 + 0.05** | `CONJ=0` | ✅（差频会是 2 MHz） |
| 波形纯度 | 拟合残差 ≈ **1 LSB**（约 −66 dBc） | 干净正弦 | ✅ |
| `ie → io`（奇相 vs 偶相） | **+10.80° = +10.0 ns** | 一个 2Fs 采样 | ✅ |

> **奇相/偶相差的是"一个 2Fs 采样"（10 ns），不是半个。**
> `interp2` 的定义是 `y_e[n]=y[2n]`、`y_o[n]=y[2n+1]`，两者正好差 `1/(2Fs)`。
> 3 MHz 时一个 2Fs 采样 = `360°×3/100` = 10.8°，实测 +10.80°。
> 旧文档写的"半个 2Fs 采样（5 ns）"已改正 —— 5 ns 是半个 **2Fs 周期**，
> 不是半个采样；正确的说法是"10 ns = 半个**输入**采样"。

## 和 s04 比

| 指标 | s04（插值 + 抽取） | s05（DUC 整链） | 变化 |
|---|---|---|---|
| DSP | 30 | **76** | +46 |
| 纯设计 LUT | 1390 | **3346** | +1956 |
| 纯设计 Reg | 2055 | **4999** | +2944 |
| 纯设计 BRAM | 0 | **6** | +6（两个 NCO 的表） |
| 布局后 WNS | 9.311 ns | **2.704 ns** | 复位 recovery 路径变紧 |
| 数据通路 WNS | 11.043 ns | **8.402 ns** | −2.6 ns，仍有余量 |
| `opt_design` | 3:12 | **40 s** | 这次的 `dbg_hub` 生成快得多 |

## 这一轮踩的坑 / 顺手确认的流程

1. **`Set Used In` 是批量操作**：选文件时把 `duc.xdc` 和 `debug.xdc` 一起选中，
   两个都被设成"只 Synthesis、不 Implementation"，结果实现阶段一个引脚约束都没读，
   `write_bitstream` 报 `NSTD-1` / `UCIO-1`（6 个端口全是 DEFAULT / 无 LOC）。
   **一次只选一个文件设属性**；`duc.xdc` 必须两个阶段都勾。
2. **调试约束单独放 `debug.xdc` 是对的**：本次 ILA 约束在
   `s05_duc.srcs/constrs_2/new/debug.xdc`，仓库里的 `constr/duc.xdc` **一行没被追加**。
   `debug.xdc` 设 `used_in_synthesis=false` 后，改它/删它都不会让 `synth_1` 失效。
3. **"out of date" 不是错误**：改了 `used_in_implementation` 只会让实现重跑，
   不需要 `Reset Synthesis`；本次全程没有重综合。

## 还没做的 / 留给 s06

- **s06_ddc 上板**（DUC→DDC 回环）：9 个 RTL、同样三行宏、**`LO_DLY=23`**，
  判据在 `s06_ddc/constr/ddc.xdc`。
- 接 DAC/ADC 前的 2:1 并串（`rtl/common/serializer2.v` 已有，板上还没接）。
- WNS 受复位网络限制（见上），以后如果加流水/提速再处理。

判据来源：[`s05_duc/constr/duc.xdc`](../../s05_duc/constr/duc.xdc)、
[`s05_duc/TASK_s05_duc.md`](../../s05_duc/TASK_s05_duc.md)。
