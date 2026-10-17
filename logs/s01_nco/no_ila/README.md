# logs/s01_nco/no_ila — 无 ILA 版（2026-10-17 实测）

这是 `nco_top` 去掉 ILA 之后的报告。**但第一结论是：基线只能取自综合报告。**

## 出处

| 项 | 值 |
|---|---|
| 工程 | `D:\Backup\Documents\vivado_projects\nco\nco.xpr` |
| 约束 | `s01_nco/constr/nco.xdc`（**已无 ILA 段**，Vivado 在删调试核时自己删的） |
| 流程 | `Reset Synthesis` → `Run Synthesis`（19:10）→ `Run Implementation`（19:12） |
| 实现起步方式 | `link_design -top nco_top`（**正常全流程，不是增量实现**） |
| ILA | 综合 / 实现日志里 `ila_0` / `dbg_hub` 各 **0** 次命中 |
| 工具 / 器件 | Vivado v2020.2 / `xc7a100tfgg484-2` |

## 这里有什么

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（两张 `4096x12` 表都推断成 Block RAM） |
| `nco_top_utilization_synth.rpt` | **综合后资源 —— 基线就用这份** |
| `impl_runme.log` | 实现日志（`opt_design` 把 cos 通路当无用逻辑裁掉了） |
| `nco_top_utilization_placed.rpt` | 布局后资源（**裁剪后**的数，见下） |
| `nco_top_timing_summary_routed.rpt` | 时序摘要 |
| `nco_top_drc_routed.rpt` | DRC（13 条 warning） |
| `nco_top_clock_utilization_routed.rpt` | 时钟资源 |

## 关键结果：综合 3 tile，实现只剩 0.5 tile

| 指标 | 综合后 ✅ 用这个 | 布局后（被裁） | 有 ILA 那版（`../`） |
|---|---|---|---|
| Slice LUTs | 24 | 14 | 1124 |
| Slice Registers | 34 | 34 | 1970 |
| **Block RAM Tile** | **3**（RAMB36×2 + RAMB18×2） | **0.5**（只剩 1 个 RAMB18） | 9 |
| DSPs | 0 | 0 | 0 |
| BUFGCTRL | 1 | 1 | 2 |
| WNS | — | +17.474 ns | +14.653 ns |
| 时序端点 | — | 76 | 4066 |
| DRC | — | 0 Errors / 13 Warnings | 0 Errors / 44 Warnings |

### 为什么实现会裁

`fcos_o` 在板级顶层**唯一的消费者就是 ILA**（LED 只接 `fsin_o[11:8]`）。
没有 ILA 之后它就没有负载了；RTL 里的 `keep = "true"` **只在综合阶段生效**，
`opt_design`（实现阶段）照样把 cos 整张表扫掉、把 sin 表裁到只剩驱动 LED 的 4 位
（4096×4 = 16 Kb = 1 个 RAMB18）。

> ⚠️ 一开始以为是"增量实现 / 手改网表"造成的，**做过对照后否掉了**：
> 这次是干净 `Reset Synthesis` + `link_design` 起步的正常流程，结果一样。
> **所以 `keep` 保不住实现，是结论不是猜测。**
> 完整故事见 `docs/学习备忘.md` 第 11 节。

## 所以 s01 的"无 ILA 基线"是

```
Slice LUTs 24 / Slice Registers 34 / Block RAM Tile 3 / DSPs 0 / BUFGCTRL 1
```
（**取自 `nco_top_utilization_synth.rpt`**。）

> 顺带更正：`docs/进度.md` 原来记的「18 LUT / 35 Reg / 3 BRAM」和这次综合的
> 24 / 34 / 3 不完全一致（BRAM、Reg 对得上，LUT 差 6）—— 那组数同样来自综合阶段，
> 但不是同一次运行。**以本目录文件为准。**

## 想让实现也保住怎么办（没做，留个口子）

`keep` 是综合属性，要实现阶段也认，得在 XDC 里加
`set_property DONT_TOUCH true [get_cells u_nco/fsin_o_reg*]`（`DONT_TOUCH` 才是
实现阶段也认的属性）。这次没做 —— 因为"无 ILA 的仿真/上板"本来就不需要 cos 通路，
只是为了拿一个资源数。
