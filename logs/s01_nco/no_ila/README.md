# logs/s01_nco/no_ila — 无 ILA 版的报告（**待填**）

这个目录是为「把 ILA 拆掉、量一次干净基线」准备的。**现在还是空的**，
因为 `nco` 工程里那一次无 ILA 的实现结果已经被覆盖了（详见上一级
[README](../README.md) 的「缺什么」一节）。

操作步骤写在 [docs/上板指南.md 第 7 步](../../../docs/上板指南.md#第-7-步可选把-ila-拆掉--量一次干净的基线)。

## 跑完之后要放这里的 5 个文件

| 文件名 | 来源 |
|---|---|
| `synth_runme.log` | `nco.runs/synth_1/runme.log` |
| `impl_runme.log` | `nco.runs/impl_1/runme.log` |
| `nco_top_utilization_placed.rpt` | `report_utilization` |
| `nco_top_timing_summary_routed.rpt` | `report_timing_summary` |
| `nco_top_drc_routed.rpt` | `report_drc -file` |

⚠️ **两个 `runme.log` 和上一级同名**。`nco.runs/` 里只有一份，一跑就被覆盖，
所以**开跑之前**先把现有 ILA 版的 `impl_1/runme.log` 备份成别的名字
（上一级那份 `logs/s01_nco/impl_runme.log` 已经是 ILA 版的副本，所以其实安全了；
但工程目录里那份不是）。

## 判据（跑完先自己核，别直接提交）

| 指标 | 无 ILA 应该是 | 有 ILA 那版（`../`） |
|---|---|---|
| `get_debug_cores` | **空** | `u_ila_0` + `dbg_hub` |
| Slice LUTs | ≈18 | 1124 |
| Slice Registers | ≈35 | 1970 |
| Block RAM Tile | **3** | 9 |
| BUFGCTRL | **1** | 2 |
| 日志里 `ila` / `dbg_hub` | 搜不到 | 有 |

数字对不上**先别提交**，把 `impl_runme.log` 里 `ila` 相关的行贴出来一起看 ——
最常见的原因是**忘了 `Reset Synthesis`**，增量综合把旧的 debug core 留下了。
