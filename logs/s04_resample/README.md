# logs/s04_resample — Stage 4（2× 半带插值 / 抽取）的 Vivado 产出

> **状态：✅ 2026-10-19 完成** —— Mac 侧仿真 18/18、393 个检查点；
> Windows 侧综合 / 实现 / 上板 / ILA 全部跑通。**30 DSP、WNS 9.311 ns，
> 7 个完整冲激的 `y_e` / `y_o` / `y_rt` 和 Python 整数模型逐位一致。**

## 出处

| 项 | 值 |
|---|---|
| 工程 | `D:\Backup\Documents\vivado_projects\s04_resample\s04_resample.xpr` |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `resample_top`（`CLK_HZ=50e6`、`IMP_PERIOD=1024`、`IW=12`、`N=61`、`SHIFT_I=14`、`SHIFT_D=15`） |
| 关键宏 | `HB_COEFDIR = D:/Backup/Documents/GitHub/fpga-lab/s04_resample/lut/`（More Options 里写 `-verilog_define`） |
| ILA | `u_ila_0`：`imp_dbg` + `ye_dbg[12:0]` + `yo_dbg[12:0]` + `yrt_dbg[13:0]`，`C_DATA_DEPTH = 8192` |
| 触发 | `imp_dbg == 1`（不是 `yrt_dbg == 1991`） |
| 波形 CSV | `D:\Backup\Documents\ila_data\20261019_resample.csv`（**本地，不入库**） |

## 报告清单

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（不含 ILA；0 errors / 0 critical / 0 warnings） |
| `resample_top_utilization_synth.rpt` | 综合后资源 —— **纯设计规模看这份** |
| `impl_runme.log` | 实现日志（含调试 IP 生成、各阶段耗时） |
| `resample_top_utilization_placed.rpt` | 布局后资源（**含 ILA**） |
| `resample_top_timing_summary_routed.rpt` | 时序摘要（WNS / TNS / WHS） |
| `resample_top_drc_routed.rpt` | DRC（0 Errors / **797 Warnings**） |
| `resample_top_clock_utilization_routed.rpt` | 时钟资源（BUFGCTRL = 2） |
| `resample_top_methodology_drc_routed.rpt` | 方法论检查（19 Warnings） |
| `ila_check.txt` | ILA CSV 与 Python 整数模型的逐点对账（7 个冲激） |

> 波形图 / CSV 不进仓库（作者本地存）。仓库只收文本报告 + 本文件的数字结论。

## 实测资源

| 指标 | 综合后（**纯设计**） | 布局后（**含 ILA**） | 对照 s03（布局后） |
|---|---|---|---|
| Slice LUTs | **1390**（Logic 1377 + Memory 13） | **2351**（Logic 2208 + Memory 143） | 1913 |
| Slice Registers | **2055** | **4113** | 3242 |
| Block RAM Tile | **0** | **9.5**（RAMB36×9 + RAMB18×1） | 3.5 |
| DSP48E1 | **30** | **30** | 21 |
| BUFGCTRL | **1** | **2**（`sys_clk` + `dbg_hub` 的 TCK） | 2 |
| **WNS / TNS** | — | **9.311 ns** / 0.000，失败端点 0 / 8403 | +10.273 |
| WHS / THS | — | **0.068 ns** / 0.000，失败端点 0 / 8387 | +0.067 |
| WPWS | — | **8.870 ns**，失败 0 / 4378 | +8.870 |
| DRC | — | **0 Errors / 797 Warnings** | 0 / 551 |
| 综合告警 | **0 errors / 0 critical / 0 warnings** | — | — |
| `opt_design` | — | **3 分 12 秒**（现场生成 ILA + dbg_hub） | 38 s |

**DRC 797 条的构成**（`resample_top_drc_routed.rpt`）：

| 规则 | 条数 | 说明 |
|---|---|---|
| DPOR-1 | **705** | `p_reg` 异步复位，DSP 内部寄存器只认同步复位；**不影响功能**，见学习备忘 8 |
| DPIP-1 | 30 | DSP 输入未流水（性能提示，不是功能问题） |
| DPOP-1 / DPOP-2 | 30 / 30 | DSP 输出未流水 |
| CFGBVS-1 | 1 | 配置 bank 电压属性未设（s00 起就有） |
| RTSTAT-10 | 1 | `dbg_hub` 内部 25 根 net 没有可布负载（调试 IP 自带） |

> 方法论检查 19 条：`LUTAR-1` 4、`PDRC-190` 10、`TIMING-18` 5，全部是
> `dbg_hub` 内部或顶层 I/O 的提示；**0 Errors**。

**实现耗时**：`opt_design` 3:12 → `place_design` 14 s → `route_design` 40 s →
`write_bitstream` 19 s。首次生成 ILA / `dbg_hub` 时 `opt_design` 就是分钟级，
这和 s01/s02/s03 的规律一致；**调试核是在 `opt_design` 插的，不在综合报告里**。

## ILA 实测（CSV `20261019_resample.csv`）

窗口 8192 点，触发 `imp_dbg == 1` 落在 sample **4096**。

| 检查 | 实测 | 判据 | 结论 |
|---|---|---|---|
| 冲激周期 | **1024** 点 | `IMP_PERIOD` | ✅ |
| 窗口冲激数 | **8 个**；CSV 导出缺 sample 0，解析到 **7 个完整冲激** | 8192 / 1024 | ✅ |
| `y_e` | 每个冲激后 **+19** 一个 **2047**，其余全 0 | 半带偶相 = 纯延迟 | ✅ |
| `y_o` | **+4..+33** 共 30 点，峰值 **+18/+19 = 1298** | `round(2047·o[k]/2^14)` | ✅ |
| `y_rt` | **+17..+59** 共 43 点，峰值 **+38 = 1991** | 级联冲激响应 | ✅ |
| `y_o` 对称性 | 关于 k=14.5，15 对全相等 | 线性相位 | ✅ |
| `y_rt` 对称性 | 关于 k=30，21 对全相等 | 线性相位 | ✅ |
| 逐位一致性 | 7 个冲激 × 三路输出**全部等于 Python 整数模型** | 模型对比 | ✅ |

> **偏移量的口径（重要）**：上表的 `+N` 都从 `imp_dbg == 1` 的**触发行**算，
> 触发行 = 0。ILA 触发行比数据采样沿**早一拍**：`imp` 是组合逻辑，ILA 在它变 1
> 的那一拍就触发，而数据要到下一拍才进 `dly[0]`。所以
> **ILA 偏移 = k+4（插值）/ k+8（级联）**；
> TB 的 `cap` 从采样沿算，才是 `cap[k+3]` / `cap[k+7]`。
> 第一版 TASK/XDC 把 ILA 偏移写成了 +3/+7，CSV 实测后已改正。

> CSV 缺 sample 0 是导出/窗口起点的问题（文件第一行是 `1,1,...`），不是设计少
> 发一个冲激；sample 0 那个冲激的响应仍在 4..59 点可见。

## 这一轮顺手确认的 Vivado 流程

1. **Set Up Debug 后不需要 Reset Synthesis，也不需要重跑 synthesis**：
   调试核在 `opt_design` 插入。综合报告 BRAM 0 / BSCANE2 0，布局后 BRAM 9.5，
   `opt_design` 3:12 —— 和 s03 的规律完全一样。
2. **调试约束不要写进主 XDC**：本次 `resample.xdc` 被 Vivado 追加了
   `create_debug_core u_ila_0 …`，综合日志里有
   `INFO: [Project 1-236] Implementation specific constraints were found …`
   并建议用 `used_in_synthesis=false` 的独立 XDC。下次建议单独存 `debug.xdc`，
   调试完直接删，主 XDC 保持干净。
3. 本次调试结束后已把 `resample.xdc` 里的 `create_debug_core` 段删掉再提交；
   仓库里的主 XDC 是**干净**的。

## 和 s03 比

| 指标 | s03（FIR） | s04（插值 + 抽取） | 变化 |
|---|---|---|---|
| DSP | 21 | **30** | +9 |
| 纯设计 LUT | 942 | **1390** | +448 |
| 纯设计 Reg | 1400 | **2055** | +655 |
| 布局后 WNS | +10.273 ns | **+9.311 ns** | −0.962 ns，仍有余量 |
| 布局后 BRAM | 3.5 | **9.5** | ILA 探针从 14 位涨到 41 位 |

## 还没做的 / 留给 s05

- **接口是相位并行的**（1 进 2 出 / 2 进 1 出），不是真实 1 路流。接 DAC 前要加
  **2:1 并串**（ADC 方向是 1:2 串并）。
- **`resample_top` 是实验台**：冲激发生器不是 DUC 的一部分；s05 换成混频后的 I/Q。
- **位宽衔接**：`mixer` 出 13 位、`fir` 默认 12 位、`interp` 出 13 位，s05 要统一规划。
- **LED 心跳**：设计为四灯 1 Hz 同闪；本轮只导出了 ILA 数据，LED 未单独记录。

逐点期望表在 [`s04_resample/lut/expected_h.md`](../../s04_resample/lut/expected_h.md)。
