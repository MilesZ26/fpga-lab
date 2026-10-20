# logs/s05_duc — Stage 5（DUC 集成）的 Vivado 产出

> **状态：⏳ 待 Windows 侧执行（Mac 侧仿真已完成）**
> Mac 侧：`make sim` 24/24、538 个检查点；`make lint` 19 个 RTL 文件无警告。
> 本文档只定"要回传哪些文件 / 判据是什么"，等上板后把实测数字填进来。

## 出处（上板后填）

| 项 | 值 |
|---|---|
| 工程 | `D:\…\vivado_projects\s05_duc\s05_duc.xpr` |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `duc_top`（`CLK_HZ=50e6`、`FREQ_SIG=500 kHz`、`FREQ_LO=2.5 MHz`、`LO_DLY=4`） |
| 关键宏 | `NCO_LUTDIR` / `FIR_COEFDIR` / `HB_COEFDIR`（More Options 里三行 `-verilog_define`） |
| ILA | `tone_i_dbg[11:0]` / `tone_q_dbg[11:0]` / `ie_dbg[14:0]` / `io_dbg[14:0]` / `qe_dbg[14:0]` / `qo_dbg[14:0]`，深度 4096 |
| 触发 | `tone_i_dbg[11]` 上升沿（不要用 `== 峰值`） |

## 需要回传的报告（文本）

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（0 errors / 0 critical） |
| `duc_top_utilization_synth.rpt` | 综合后资源 —— **纯设计规模看这份** |
| `impl_runme.log` | 实现日志（`opt_design` 耗时 / 调试 IP 生成） |
| `duc_top_utilization_placed.rpt` | 布局后资源（含 ILA） |
| `duc_top_timing_summary_routed.rpt` | 时序摘要（WNS / TNS / WHS） |
| `duc_top_drc_routed.rpt` | DRC（0 Errors；DPOR-1 会不少，见学习备忘 8） |
| `duc_top_clock_utilization_routed.rpt` | 时钟资源（BUFGCTRL = 2） |
| `ila_check.txt` | ILA CSV 的判读结论（频率 / 幅度 / 正交性） |

> 波形图 / CSV 不进仓库（作者本地存）。仓库只收文本报告 + 本文件的数字结论。

## 预期（不是实测，上板后替换）

| 指标 | 预期 | 依据 |
|---|---|---|
| DSP48E1 | **≈ 76** | DUC = 2×FIR 21 + mixer 4 + 2×interp2 15 |
| Block RAM | **≈ 6** | 两个 NCO 各 2 张 4096×12 表（s01 实测 3/两个表） |
| Slice Registers | **≥ 4000** | 4 条 FIR/插值流水 + LO 延迟线 |
| WNS | **≥ 0**（预计还有几 ns） | s03 +10.273、s04 +9.311；最紧的可能是 mixer 的组合路径 |
| DRC | 0 Errors | DPOR-1 预计 2× 左右 s04 的量（4 个 FIR/插值各有一排 p_reg） |

## ILA 实测（上板后填）

| 检查 | 预期 | 实测 | 结论 |
|---|---|---|---|
| LED | 四颗 1 Hz 同闪 | | |
| `tone_i/tone_q` | 500 kHz 正/余弦，周期 100 拍 | | |
| `ie/qe` 频率 | **3 MHz**（0.06 Fs），周期 ≈ 16.7 拍 | | |
| `ie/qe` 幅度 | ≈ 2040 | | |
| `ie` vs `qe` | 正交（相位差 90°） | | |
| `io/qo` | 与 `ie/qe` 同频、错开半个 2Fs 采样 | | |

> 判读顺序：`tone_i` 有 → 时钟/复位/NCO 对；`ie` 有且 3 MHz → FIR/混频/插值对；
> `ie/qe` 不正交/幅度不对 → 先查混频 `sin/cos` 和 `LO_DLY`；
> `ie/io` 两相错位 → 查 `interp2` 的 `y_e/y_o` 对齐。
