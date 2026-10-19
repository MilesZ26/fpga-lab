# logs/s04_resample — Stage 4（2× 半带插值 / 抽取）的 Vivado 产出

> **状态：⬜ 待 Windows 侧执行**（Mac 侧仿真已闭环：18/18、393 个检查点）。
> 这个 README 是"要收什么、判据是什么"的骨架，数据回来之后按实际值改写。

## 出处（数据回来后填）

| 项 | 值 |
|---|---|
| 工程 | `…\vivado_projects\s04_resample\s04_resample.xpr`（待建） |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `resample_top`（`CLK_HZ=50e6`、`IMP_PERIOD=1024`、`IW=12`、`N=61`、`SHIFT_I=14`、`SHIFT_D=15`） |
| 关键宏 | `HB_COEFDIR = <仓库>/s04_resample/lut/`（**More Options 里写 `-verilog_define`**，见学习备忘 13） |
| ILA | `u_ila_0`：`imp_dbg` + `ye_dbg[12:0]` + `yo_dbg[12:0]` + `yrt_dbg[13:0]`，`C_DATA_DEPTH = 8192` |
| 触发 | `imp_dbg == 1`（**不是** `yrt_dbg == 1991`） |

## 要收的报告（和 s00/s01/s02/s03 同一套）

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（**不含 ILA** —— 调试核在 `opt_design` 才生成） |
| `resample_top_utilization_synth.rpt` | 综合后资源 —— **"设计本身"的规模看这份** |
| `impl_runme.log` | 实现日志（含调试 IP 生成、各阶段耗时） |
| `resample_top_utilization_placed.rpt` | 布局后资源（**含 ILA**） |
| `resample_top_timing_summary_routed.rpt` | 时序摘要（WNS / TNS / WHS） |
| `resample_top_drc_routed.rpt` | DRC（s03 的 551 条警告里 486 条是 DPOR-1，这里可能更多） |
| `resample_top_clock_utilization_routed.rpt` | 时钟资源（BUFGCTRL 应为 2） |
| `resample_top_methodology_drc_routed.rpt` | 方法论检查 |

> 波形图**不进仓库**（作者本地存）。仓库只收文本报告 + README 里的数字结论。

## 预期（仿真给的判据，按这个对账）

| 项 | 预期 | 来源 |
|---|---|---|
| DSP48E1 | **约 30**（插值 15 + 抽取 15） | `interp2` / `decim2` 各 15 个乘法器 |
| Slice Registers（纯设计） | **约 1100~1300** | 两条 30 抽头延迟线 + 2×15×29 乘积寄存器 |
| 冲激周期 | **1024 点** = 20.48 µs，8192 点窗口 **8 个** | `IMP_PERIOD` |
| `y_e` | 第 **15** 点 = **2047**，其余全 0 | 半带偶相 = 纯延迟 |
| `y_o` | 30 点，峰值 **1298** 在第 **14/15** 点 | `round(2047·10387/2^14)` |
| `y_rt` | 43 点（第 **9..51** 点），峰值 **1991** 在第 **30** 点 | 级联冲激响应 |
| 对称性 | `y_o` 关于 14.5；`y_rt` 关于 30 | 线性相位 |
| LED | 四颗都 1 Hz 闪 | 心跳 |

逐点表在 [`s04_resample/lut/expected_h.md`](../../s04_resample/lut/expected_h.md)。

## 排障顺序（写在 `constr/resample.xdc` 里，这里再抄一遍）

1. `y_e` 对 → 复位、冲激发生器、偶相 15 拍延迟都对。
2. `y_o` 对 → 系数表读对了、对称预加 / 流水线都对。
3. `y_rt` 对 → **两相相位对齐** + **位宽衔接（13 位喂 13 位）**都对。
4. 只有 `y_rt` 错时，**先查 `resample_top` 里 `u_decim` 的 `.x_e/.y_o` 有没有接反** ——
   接反时 `y_e`/`y_o` 完全正常（s04 的反向验证 S4 就是这个）。

## 数据回来之后要改哪里

- 本文件：把"状态"和"数字"换成实测值
- `docs/进度.md`：新增「板级实测（`s04_resample`）」一节，并更新状态表里那一行
- `docs/学习备忘.md`：如果又踩了 Vivado 的坑，补一节（s03 就是这么来的）
