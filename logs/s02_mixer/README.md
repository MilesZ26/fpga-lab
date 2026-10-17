# logs/s02_mixer — Stage 2（复数混频）的 Vivado 产出

**2026-10-17 上板实测通过**（Windows + Vivado 2020.2）：两个 NCO + 一个混频器，
ILA 里看到 `i_out` 的周期是 `sig_sin` 的 **5 倍** —— 250 kHz 与 200 kHz 混出 50 kHz。

## 出处（可复现）

| 项 | 值 |
|---|---|
| 工程 | `D:\Backup\Documents\vivado_projects\s02_mixer\s02_mixer.xpr` |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `mixer_top`（`FREQ_IN=250k`、`FREQ_LO=200k`、**`CONJ=1` 下变频**） |
| 综合 | 19:27（**没有 ILA**，ILA 是之后加的） |
| 实现 | 19:39–19:42（**有 ILA**，6 个探针） |
| 关键宏 | `LUTDIR = <仓库>/s01_nco/lut/`（s02 自己没有 `lut/`） |

## 这里有什么

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（**无 ILA** 那一步） |
| `mixer_top_utilization_synth.rpt` | 综合后资源 —— **"设计本身"的规模看这份** |
| `impl_runme.log` | 实现日志（含 ILA 生成、`opt_design` 耗时） |
| `mixer_top_utilization_placed.rpt` | 布局后资源（**含 ILA**） |
| `mixer_top_timing_summary_routed.rpt` | 时序摘要 |
| `mixer_top_drc_routed.rpt` | DRC（56 条警告） |
| `mixer_top_clock_utilization_routed.rpt` | 时钟资源（BUFGCTRL = 2） |
| `mixer_top_methodology_drc_routed.rpt` | 方法论检查 |

> ⚠️ **波形图不进仓库。** ILA 截图由作者自己存在本地电脑上（两张：
> 差频 `down_50k`、和频 `up_450k`）。仓库只收**文本报告**，外加这张表里的数字说明。
> 理由：PNG 不能 grep、会随截图区域变化、也不是可复现的证据 ——
> 真要看波形，拿这份报告里的实现结果重新烧一次就能抓到。

## 数字（全部能在文件里 grep 到）

| 指标 | 综合后（无 ILA） | 布局后（含 ILA） | 开销 |
|---|---|---|---|
| Slice LUTs | **129** | 1464 | +1335 |
| Slice Registers | **92** | 2416 | +2324 |
| Block RAM Tile | **6**（两个 NCO 各 3） | **23** | +17 |
| DSPs | **4** | 4 | 0 |
| BUFGCTRL | 1 | 2 | +1（`dbg_hub` 的 TCK） |
| WNS / TNS | — | **+5.697 ns** / 0.000，失败端点 0 / 5347 | — |
| WHS / THS | — | +0.059 / 0.000，失败端点 0 / 5331 | — |
| DRC | — | 0 Errors / **56 Warnings** | — |
| `opt_design` | — | **3 分 08 秒**（现场生成 debug IP） | — |

代价分解（`impl_runme.log` 的 `Time (s)` 行，都很快，看不出 3 分钟）：

| 阶段 | elapsed |
|---|---|
| `place_design` | 9 s |
| `route_design` | 37 s |
| `write_bitstream` | 18 s |
| **`opt_design`** | **3 分 08 秒** ← 全花在这里 |

> 这正是 s01 文档里记的"`opt_design` 3 分 04 秒"那个数 —— **它不是设计复杂，
> 而是 `opt_design` 要在这一步现场生成 `u_ila_0` + `dbg_hub` 两个调试 IP**。
> 无 ILA 的实现里这一步只要几十秒。

### 56 条 DRC 的构成

| 规则 | 条数 | 含义 |
|---|---|---|
| REQP-1839（RAMB36 异步控制脚） | 20 | ⇐ **撞到规则上限**，真实数量 ≥ 20 |
| REQP-1840（RAMB18 异步控制脚） | 20 | ⇐ 同样撞上限 |
| DPIP-1（输入流水） | 8 | ILA 探针没有输入流水级 |
| DPOP-1 / DPOP-2（输出流水） | 2 + 2 | ILA 输出寄存器流水 |
| CFGBVS-1 | 1 | 没设配置电压，与功能无关 |
| CHECK-3 | 2 | 上面两条撞了上限的标记 |

> **"REQP 是不是比 s01 翻倍了？"** —— 有**两个** NCO 在驱动 BRAM 地址脚，
> 按理应该翻倍，但因为 20 条是**规则上限**，报告里两边都是 20，**看不出来**。
> 想知道真实数量得 `set_property max_violations` 放开上限重跑 `report_drc`。
> 这不影响功能（见 `docs/学习备忘.md` 第 8 节）。

## 板级波形判据（这次实测）

| 检查 | 实测 | 判据 |
|---|---|---|
| `i_out` 周期 | 8192 点窗口里 **约 8 个周期** → 1000 点/周期 = 50 kHz（20 µs） | ≈ 1000 点 ✅ |
| `sig_sin` 周期 | 约 **41 个周期** → 200 点/周期 = 250 kHz（4 µs） | ≈ 200 点 ✅ |
| 比例 | **5 : 1** | `FREQ_IN / (FREQ_IN − FREQ_LO)` = 250/50 = 5 ✅ |
| LED | 半亮（50 kHz 人眼跟不上） | 与 `mixer.xdc` 注释一致 ✅ |

> **为什么是 50 kHz 而不是 450 kHz**：`mixer_top.v` 的默认参数是 **`CONJ = 1`（下变频）**，
> 输出 = `FREQ_IN − FREQ_LO` = 50 kHz。想看和频要把顶层的 `CONJ` 改成 0
> （输出 450 kHz，周期 2.22 µs，8192 点窗口里约 73 个周期）。
>
> ⚠️ 注意区分两个"默认值"：`mixer.v` 自己的默认是 `CONJ = 0`（上变频，DUC 用），
> **`mixer_top.v` 的默认是 `CONJ = 1`**（下变频，这样差频 50 kHz 在 ILA 窗口里
> 正好 8 个周期，好看又好数）。上板这轮跑的是下变频 —— **和频还没有板级证据**。

## ⚠️ 待确认（别当已完成）

1. **和频（`CONJ=0`，450 kHz）没有上板验证过。** 板级只证明了"频率被搬走了"、
   搬到的位置是差频；`CONJ` 这条通路在仿真里验过（`tb_mixer` 有专门的手算用例），
   但"改 `CONJ` 重新综合一版看上板波形"这件事没做。属于可选加强项。
2. **波形截图的周期数是按 ILA 网格数出来的**，不是用游标读的。作者本地的图
   （`down_50k` / `up_450k`）也只能"看着对" —— 想更硬就加两个游标再截图。
