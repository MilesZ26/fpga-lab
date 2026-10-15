# logs/s00_blinky — Stage 0 的 Vivado 产出

**2026-10-15：日志已回传，本目录不再为空。** 板级实测（LED 1 Hz 闪）发生在
2026-10-14，日志随后在 `be9df26` / `f28253f` 两个提交里补进仓库。

## 这里有什么

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合运行日志 |
| `impl_runme.log` | 实现运行日志 |
| `blinky_timing_summary_routed.rpt` | 时序摘要 |
| `blinky_utilization_placed.rpt` | 资源用量 |
| `blinky_clock_utilization_routed.rpt` | 时钟资源 |
| `blinky_drc_routed.rpx` | DRC 报告（**二进制**，需 Vivado GUI 打开） |

## 读出来的结论

| 指标 | 值 |
|---|---|
| **WNS** | **+16.830 ns**（周期 20 ns，最长路径仅约 3.17 ns） |
| TNS / 失败端点 | 0.000 / **0 个**（共 26） |
| WHS / THS | +0.243 / 0.000 |
| CRITICAL WARNING | **0 条**（综合 + 实现） |
| DRC | **0 Errors** |
| Slice LUT | **33** / 63400（0.05%） |

**这组数是以后的基线** —— NCO / FIR 的资源用量跟它比，才知道涨了多少。

> ⚠️ DRC 只留下了二进制的 `.rpx`，命令行读不了。本次的「0 Errors」是从
> `impl_runme.log` 里读到的（`DRC finished with 0 Errors`）。
> 以后导出时用 `report_drc -file xxx.rpt` 留一份文本版。

> 工程建在仓库**外面**（`D:\vivado_prj\...`），所以要手动拷。
> 只拷文本，`.bit` / `.dcp` / `.runs/` 一律不要。
