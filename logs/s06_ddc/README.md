# logs/s06_ddc — Stage 6（DDC 回环）的 Vivado 产出

> **状态：⏳ 待 Windows 侧执行（Mac 侧仿真已完成）**
> Mac 侧：`make sim` 24/24、538 个检查点；`make lint` 19 个 RTL 文件无警告；
> DUC→DDC 整链回环 4 场景 × 512 样本逐位一致，step 回到 **+998/0**。
> 本文档只定"要回传哪些文件 / 判据是什么"，等上板后把实测数字填进来。

## 出处（上板后填）

| 项 | 值 |
|---|---|
| 工程 | `D:\…\vivado_projects\s06_ddc\s06_ddc.xpr` |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `ddc_top`（`CLK_HZ=50e6`、`FREQ_SIG=500 kHz`、`FREQ_LO=2.5 MHz`、**`LO_DLY_DDC=23`**） |
| 关键宏 | `NCO_LUTDIR` / `FIR_COEFDIR` / `HB_COEFDIR`（三行 `-verilog_define`） |
| ILA | `ie/io/qe/qo_dbg[14:0]`（DUC 四相）+ `di/dq_dbg[12:0]`（DDC 输出），深度 4096 |
| 触发 | `ie_dbg[14]` 或 `di_dbg[12]` 的上升沿 |

## 需要回传的报告（文本）

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（0 errors / 0 critical） |
| `ddc_top_utilization_synth.rpt` | 综合后资源 —— **纯设计规模看这份** |
| `impl_runme.log` | 实现日志（`opt_design` 耗时 / 调试 IP 生成） |
| `ddc_top_utilization_placed.rpt` | 布局后资源（含 ILA） |
| `ddc_top_timing_summary_routed.rpt` | 时序摘要（WNS / TNS / WHS） |
| `ddc_top_drc_routed.rpt` | DRC（0 Errors） |
| `ddc_top_clock_utilization_routed.rpt` | 时钟资源（BUFGCTRL = 2） |
| `ila_check.txt` | ILA CSV 的判读结论（频率比 6:1 / 幅度 / 正交） |

> 波形图 / CSV 不进仓库（作者本地存）。仓库只收文本报告 + 本文件的数字结论。

## 预期（不是实测，上板后替换）

| 指标 | 预期 | 依据 |
|---|---|---|
| DSP48E1 | **≈ 152** | DUC 76 + DDC = 2×decim2 15 + mixer 4 + 2×FIR 21 |
| Block RAM | **≈ 9** | 三个 NCO 各 2 张表（tone / DUC LO / DDC LO） |
| Slice Registers | **≥ 8000** | 两条链的延迟线 + 流水 |
| WNS | **≥ 0**（预计比 s05 略紧） | 4 个 FIR + 2 个 mixer + 2 个半带；50 MHz 下仍有几 ns |
| DRC | 0 Errors | DPOR-1 约为 s04 的 2 倍量级 |

## ILA 实测（上板后填）

| 检查 | 预期 | 实测 | 结论 |
|---|---|---|---|
| LED0 | 常亮 | | DDC 输出有活动（回环通了） |
| LED1 | 常亮 | | DUC 输出有活动 |
| LED2/LED3 | 1 Hz 同闪 | | 心跳 |
| `ie/qe` | **3 MHz**（0.06 Fs），幅度 ≈ 2040 | | DUC 输出 |
| `io/qo` | 与 `ie/qe` 同频、错开半个 2Fs 采样 | | 插值两相 |
| `di/dq` | **500 kHz**（0.01 Fs），周期 100 拍，幅度 ≈ 2040 | | 回环恢复 |
| `di` vs `dq` | 正交，幅度基本恒定 | | 复单音 |
| 频率比 | **6:1** | | 搬上去再搬下来 |

> 判读顺序：`ie/qe` 有且 3 MHz → DUC 侧对；`di/dq` 完全没有 → 先查
> **DDC 的 `LO_DLY` 是不是 23**、`IW` 是不是 15；`di/dq` 频率不对 → 查
> `FREQ_LO`；频率对但 I/Q 旋转/幅度不对 → 查 `CONJ=1`（两路都翻）、
> `SHIFT=11`、sin/cos 接反。
