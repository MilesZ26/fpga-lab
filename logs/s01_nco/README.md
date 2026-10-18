# logs/s01_nco — Stage 1（NCO）的 Vivado 产出

**2026-10-17 回传**：把 `s01_nco` 当年上板那轮的文本报告从工程目录拷进仓库，
补上 `docs/进度.md`「板级实测（`s01_nco`）」一节引用的数字对应的**文件证据**。

## 出处（可复现）

| 项 | 值 |
|---|---|
| 工程 | `D:\Backup\Documents\vivado_projects\nco\nco.xpr` |
| 工具 | Vivado v2020.2 (win64) Build 3064766 |
| 器件 | `xc7a100tfgg484-2` |
| 顶层 | `nco_top`，Design State = **Fully Routed** |
| 时间 | 综合 2026-10-15 23:45，实现 23:47–23:49 |
| 版本 | **ILA 版**（工程里有 `u_ila_0` + `dbg_hub`） |

## 这里有什么

| 文件 | 来源 | 内容 |
|---|---|---|
| `synth_runme.log` | `nco.runs/synth_1/runme.log` | 综合日志（BRAM 推断、0 critical warning） |
| `impl_runme.log` | `nco.runs/impl_1/runme.log` | 实现日志（opt/place/route 各阶段、DRC 结论） |
| `nco_top_utilization_synth.rpt` | `report_utilization`（综合） | 综合后资源用量、RAM 推断明细 |
| `nco_top_utilization_placed.rpt` | `report_utilization`（实现） | 布局后资源用量（**上表数字的出处**） |
| `nco_top_timing_summary_routed.rpt` | `report_timing_summary` | 时序摘要（**WNS 的出处**） |
| `nco_top_drc_routed.rpt` | `report_drc -file` | DRC 违例清单（**44 条警告的出处**） |
| `nco_top_clock_utilization_routed.rpt` | `report_clock_utilization` | 时钟资源（BUFGCTRL = 2） |
| `nco_top_methodology_drc_routed.rpt` | `report_methodology` | 方法论检查（CDC / 复位建议） |

> `nco_top_timing_summary_routed.rpt` 有 **500 KB**，是因为里面逐条列了各 corner 的
> 路径细节。**没有裁剪** —— 裁过的报告就不再是证据了。

## 读出来的结论（全部可在文件里 grep 到）

| 指标 | 值 | 出处 |
|---|---|---|
| **WNS / TNS** | **+14.653 ns** / 0.000 ns，失败端点 **0** / 4066 | `nco_top_timing_summary_routed.rpt` → `Design Timing Summary` |
| WHS / THS | +0.066 / 0.000 ns，失败端点 0 / 4050 | 同上 |
| WPWS / TPWS | +8.870 / 0.000 ns，失败端点 0 / 2177 | 同上 |
| 时序结论 | `All user specified timing constraints are met.` | 同上 |
| CRITICAL WARNING（综合） | **0 条**（`0 errors, 0 critical warnings and 0 warnings`） | `synth_runme.log` |
| CRITICAL WARNING（实现） | **0 条** | `impl_runme.log` |
| DRC | **0 Errors / 44 Warnings** | `impl_runme.log`（`DRC finished with 0 Errors, 42 Warnings` = opt 阶段）+ `nco_top_drc_routed.rpt`（routed，`Violations found: 44`） |
| Slice LUTs | **1124**（Logic 1015 + Memory 109）/ 63400 = 1.77% | `nco_top_utilization_placed.rpt` |
| Slice Registers | **1970** / 126800 = 1.55% | 同上 |
| Block RAM Tile | **9** / 135 = 6.67% | 同上 |
| DSPs | 0 | 同上 |
| BUFGCTRL | **2** | 同上（= `sys_clk` + `dbg_hub` 的 BSCAN 时钟） |

**44 条 DRC 的构成**（`nco_top_drc_routed.rpt` → `REPORT SUMMARY`）：

| 规则 | 严重性 | 条数 | 含义 |
|---|---|---|---|
| REQP-1839 | Warning | 20 | RAMB36 异步控制脚检查 |
| REQP-1840 | Warning | 20 | RAMB18 异步控制脚检查 |
| CHECK-3 | Warning | 2 | 上面两条撞到了 20 条的**规则上限** |
| CFGBVS-1 | Warning | 1 | 没设 `CFGBVS` / `CONFIG_VOLTAGE`（板级配置电压，与本设计功能无关） |
| RTSTAT-10 | Warning | 1 | 有不可布线的负载 |

> REQP-1839/1840 的成因（`phase_acc` 带**异步复位**又直接驱动 BRAM 地址脚）
> 写在 `docs/进度.md` 的「待决问题」和 `docs/学习备忘.md` 第 8 节。
> 注意 **20 + 20 不是真实条数** —— 撞到规则上限了，真实数量 ≥ 20。

**查表真的进了 BRAM**（`synth_runme.log`）：

```
|nco         | fsin_o_reg | 4096x12       | Block RAM      |
|nco         | fcos_o_reg | 4096x12       | Block RAM      |
```

这就是 `NCO_LUTDIR`（当时叫 `LUTDIR`）配对了的间接证据：`$readmemh` 读不到文件时表还是会被推断成 ROM，
但内容全是 x —— 所以**这条本身不能证明路径对**，它只证明"表没被优化掉"。
真正的证据是上板后 ILA 抓到了正弦（见 `docs/进度.md`）。

## ⚠️ 缺什么（说清楚，别当齐了）

1. **「无 ILA」那一版已经到了，在 [`no_ila/`](no_ila/README.md)**（2026-10-17）。
   **但基线只能取自综合报告**：综合 24 LUT / 34 Reg / **3 BRAM**，
   而布局后只剩 14 / 34 / **0.5** —— 因为没有 ILA 之后 `fcos_o` 没有负载，
   `opt_design` 把 cos 通路裁了（干净重跑也一样，不是流程问题）。
   完整分析见 [docs/学习备忘.md 第 11 节](../../docs/学习备忘.md)。
2. **没有 `report_drc` 之外的 methodology 结论摘录**：`.rpt` 原文件已回传，
   自己 grep 就行。
3. **没有 `.ltx` / `.bit`**：`.ltx` 是 ILA 探针定义、`.bit` 是比特流，
   都在 `.gitignore` 里，也**不该**入库（换一次综合就变）。

## 各阶段耗时（`impl_runme.log` 里的 `Time (s)` 行）

| 阶段 | elapsed |
|---|---|
| `link_design` | 8 s |
| `opt_design` | **34 s** |
| `place_design` | 8 s |
| `route_design` | 32 s |
| `write_bitstream` | 17 s |

> `docs/进度.md` 原来记的「`opt_design` 3 分 04 秒（现场生成两个 debug IP）」
> 是**另一次运行**的数 —— 那一版要先由 `opt_design` 现场生成 `u_ila_0` / `dbg_hub`；
> 这次 log 里 debug IP 已经存在（`Debug cores have already been implemented`），
> 所以只要 34 s。**两个数都对，前提不同。**

## 和 `docs/进度.md` 旧数字的差异

文档原来写 ILA 版是 **1117 LUT / 1971 Reg**，本次回传的文件是 **1124 / 1970**。
差 7 个 LUT、1 个 FF —— 同一天同一个工程跑过不止一次（`impl_1` 里留着好几个
`nco_top_*.backup.vdi`，时间戳从 22:58 到 23:47），**以文件里的 1124 / 1970 为准**。
