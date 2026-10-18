# logs/s03_fir — Stage 3（FIR 低通）的 Vivado 产出

**2026-10-18 上板实测通过**（Windows + Vivado 2020.2）：47 抽头、延迟 4 拍、预加 + 4 级流水。
ILA 抓到 **8 个冲激**（周期 1024 点），每个冲激后面 47 点响应**和系数表逐点对上**：
**中心 613、两端 1、关于第 23 点对称**（`fir_dbg` 设成 signed 显示后，负的半边 −117 / −89 都在）。

## 出处（可复现）

| 项 | 值 |
|---|---|
| 工程 | `D:\Backup\Documents\vivado_projects\s03_fir\s03_fir.xpr` |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `fir_top`（`CLK_HZ=50e6`、`IMP_PERIOD=1024`、`IW=12`、`N=47`、`OW=13`、`SHIFT=15`） |
| 关键宏 | `FIR_COEFDIR = <仓库>/s03_fir/lut/`（**More Options 里写 `-verilog_define`**，见学习备忘 13） |
| ILA | `u_ila_0`：`probe0 = fir_dbg[12:0]`、`probe1 = imp_dbg`，`C_DATA_DEPTH = 8192` |
| 触发 | `imp_dbg == 1`（**不是** `fir_dbg == 613`） |

## 这里有什么

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（**不含 ILA** —— 调试核在 `opt_design` 才生成） |
| `fir_top_utilization_synth.rpt` | 综合后资源 —— **"设计本身"的规模看这份** |
| `impl_runme.log` | 实现日志（含调试 IP 生成、各阶段耗时） |
| `fir_top_utilization_placed.rpt` | 布局后资源（**含 ILA**） |
| `fir_top_timing_summary_routed.rpt` | 时序摘要 |
| `fir_top_drc_routed.rpt` | DRC（0 Errors / 551 Warnings） |
| `fir_top_clock_utilization_routed.rpt` | 时钟资源（BUFGCTRL = 2） |
| `fir_top_methodology_drc_routed.rpt` | 方法论检查 |

> ⚠️ **波形图不进仓库**（作者本地存 `20261018_fir_8_imp.png` / `20261018_fir_center.png`）。
> 仓库只收文本报告 + 下面的数字结论。理由同 `logs/s02_mixer/README.md`。

## 数字（全部能在文件里 grep 到）

| 指标 | 综合后（= 纯设计） | 布局后（含 ILA） | 调试开销 |
|---|---|---|---|
| Slice LUTs | **942** | **1913**（1812 Logic + 101 Memory） | +971 |
| Slice Registers | **1400** | **3242** | +1842 |
| Block RAM Tile | **0** | **3.5** | +3.5（ILA 缓存 8192×14 位） |
| **DSP48E1** | **21** | **21** | **0** |
| BUFGCTRL | **1** | **2** | +1（`dbg_hub` 的 TCK） |
| **WNS / TNS** | — | **+10.273 ns** / 0.000，失败端点 0 / 6493 | — |
| WHS / THS | — | +0.067 / 0.000，失败端点 0 / 6477 | — |
| WPWS | — | +8.870 ns | — |
| DRC | — | **0 Errors** / 551 Warnings | — |
| 综合告警 | **0 errors / 0 critical / 0 warnings** | — | — |

**时序结论**：周期 20 ns，WNS **+10.273 ns** → 最长路径约 **9.73 ns**，
**4 级流水在 50 MHz 下余量过半**（而且这还是**含 ILA** 的数，纯设计只会更宽松 ——
所以"要不要补无 ILA 基线"那条可以彻底结案，见 `docs/进度.md` 待决问题）。

阶段耗时（`impl_runme.log` 的 `Time (s)` 行）：

| 阶段 | elapsed |
|---|---|
| `opt_design`（现场生成 `u_ila_0` + `dbg_hub`） | **38 s** |
| `place_design` | 12 s |
| `route_design` | 37 s |
| `write_bitstream` | 22 s |

> s01/s02 的 `opt_design` 曾花 3 分 04 秒 / 3 分 08 秒，这次只有 38 s ——
> 因为调试 IP 在这次之前已经生成过、缓存命中。**首次**生成才是分钟级。

### 为什么 DSP 是 21 而不是预估的 24

24 个乘法器 = 23 对 + 1 个中心抽头。**但 `coef[3]` 和 `coef[13]` 量化后正好是 0**
（窗函数法 sinc 在此处小于半个 LSB，见 `lut/README.md`），乘 0 的乘法器被综合器
直接删掉 → 24 − 2 = **22**。剩下的 1 个差异**原因未坐实**（最可能是某个小常数乘被拆成
移位加法放进 LUT），**不影响功能** —— 数值正确性由 81 个仿真检查点 + 下面这份板级波形保证。
`DSP48E1 = 21 ≠ 0` 本身就是"系数表真的读进去了"的硬证据（读不到会整个优化成 0）。

### 551 条 DRC 的构成

| 规则 | 条数 | 含义 |
|---|---|---|
| **DPOR-1**（异步 load 检查） | **486** | ⭐ 见下 |
| DPIP-1 / DPOP-1 / DPOP-2（DSP 流水） | 21 + 21 + 21 | 21 个 DSP 各缺输入/输出流水级 |
| CFGBVS-1 | 1 | 没设配置电压，与功能无关（s00/s01/s02 都有） |
| RTSTAT-10 | 1 | 无布线负载的网 |

> ⭐ **DPOR-1 值得单独看一眼**：报文是
> "`DSP u_fir/prod[10]` output is connected to registers with an asynchronous reset
> (`u_fir/p_reg_reg[10][0]`). This is preventing the possibility of merging these registers
> into the DSP Block since the DSP block registers only possess **synchronous** reset capability."
>
> 也就是说：`fir.v` 里 `p_reg` 用**异步复位**（仓库规矩），于是 DSP48 内部那排输出寄存器
> **用不上**，乘积必须在 DSP 外面另起一组触发器。**代价是寄存器数量和一点性能，
> 不是功能错误** —— 和 s01 的 REQP-1839/1840（BRAM 地址脚带异步复位）是同一类问题的两面：
> **硬核内部寄存器只认同步复位**。（详细原理见 `docs/学习备忘.md` 第 8 节。）

## 板级波形判据（2026-10-18 实测）

`expected_h.md` 的 47 点表逐点对过：

| 检查 | 期望 | 实测 | 结论 |
|---|---|---|---|
| 冲激个数 | 8192 点窗口里 **8 个** | 8 个，间距 1024 点 | ✅ |
| 冲激周期 | 1024 点 = 20.48 µs | 1024 点 | ✅ |
| 响应长度 | 47 点后回 0 | 47 点后为 0，直到下一个冲激 | ✅ |
| **中心抽头** | **613** @ k=23 | **613**（游标落在第 27 点） | ✅ |
| 两端 | h[0] = h[46] = **1** | 开头/结尾都是 1 | ✅ |
| 对称性 | 关于 k=23 的 23 对全等 | 逐点对上 | ✅ |
| 负半边的值 | −117 / −89（第 18/19 点） | 与表一致（signed 显示） | ✅ |
| 延迟 4 拍 | h[0] 出现在触发点后第 4 点 | 对（峰值在触发点后第 27 点 = 4+23） | ✅ |
| LED | 四颗都 1 Hz 闪 | **实测四颗全闪 → V9/Y8/Y7/W7 引脚全部硬件反证** | ✅ |

## ⚠️ 已知的"没做完"

1. **`constr/fir.xdc` 里留着 Vivado 追加的 `create_debug_core` 段**（知情选择，
   见 `docs/进度.md` 待决问题）。后果：每次综合都会插 ILA，`opt_design` 多花几十秒到几分钟；
   段里写死了网名（`clk_IBUF_BUFG` / `fir_dbg[*]`），**改 `fir_top.v` 端口名会报错**。
2. **没有"无 ILA 的布局后"数据**。这不影响任何结论（见上面的时序说明），
   真要量得在 XDC 加 `DONT_TOUCH`（学习备忘 11）。
3. 波形判据是**肉眼看 ILA 网格 + 游标**得出的，不是脚本导出比对。
   想变成可 diff 的证据，得用 ILA 的 "Export ILA Data" 导 CSV 再和 `expected_h.md` 比。
