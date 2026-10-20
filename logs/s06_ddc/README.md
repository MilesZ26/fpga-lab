# logs/s06_ddc — Stage 6（DUC → DDC 回环）的 Vivado 产出

> **状态：✅ 2026-10-20 板级数据齐全** —— 综合 / 实现 / 上板 / ILA 全部跑通。
> **152 DSP / 9 BRAM、WNS 6.390 ns、3 MHz → 500 kHz（6:1）、I/Q 正交 90.00°、
> 复包络纹波 0.08%。** Mac 侧 `make sim` 24/24、538 个检查点仍全绿。

## 出处

| 项 | 值 |
|---|---|
| 工程 | `D:\Backup\Documents\vivado_projects\s06_ddc\s06_ddc.xpr` |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `ddc_top`（`CLK_HZ=50e6`、`FREQ_SIG=500 kHz`、`FREQ_LO=2.5 MHz`、**`LO_DLY_DDC=23`**） |
| 关键宏 | `NCO_LUTDIR` / `FIR_COEFDIR` / `HB_COEFDIR`（三行 `-verilog_define`，8 次 `$readmemh` 全成功） |
| ILA | `ie/io/qe/qo_dbg[14:0]`（DUC 四相 60 位）+ `di/dq_dbg[12:0]`（DDC 输出 26 位），共 **86 位**，深度 4096 |
| 触发 | **比较类触发**（ILA 不能对总线切位，没有边沿操作符）；触发点 sample 2048（窗口 50%） |
| 约束 | 工程 run 用的是 `constrs_2`（工程内副本 `ddc.xdc` + `new/debug.xdc`）；**仓库 `constr/ddc.xdc` 没有被追加调试段** |
| 波形 CSV | `D:\Backup\Documents\ila_data\20261020_ddc.csv`（**本地，不入库**） |

## 报告清单

| 文件 | 内容 |
|---|---|
| `synth_runme.log` | 综合日志（0 errors / 0 critical / 0 warnings） |
| `ddc_top_utilization_synth.rpt` | 综合后资源 —— **纯设计规模看这份** |
| `impl_runme.log` | 实现日志（`opt_design` 生成 ILA + `dbg_hub`、各阶段耗时） |
| `ddc_top_utilization_placed.rpt` | 布局后资源（**含 ILA**） |
| `ddc_top_timing_summary_routed.rpt` | 时序摘要（WNS / TNS / WHS / WPWS） |
| `ddc_top_drc_routed.rpt` | DRC（0 Errors / 356 Warnings） |
| `ddc_top_clock_utilization_routed.rpt` | 时钟资源（BUFGCTRL = 2） |
| `ila_check.txt` | ILA CSV 的频率比 / 幅度 / 正交性 / 包络判读 |

> 波形图 / CSV 不进仓库（作者本地存）。仓库只收文本报告 + 本文件的数字结论。

## 实测资源

| 指标 | 综合后（**纯设计**） | 布局后（**含 ILA**） | 对照 s05（纯设计） |
|---|---|---|---|
| Slice LUTs | **7642** | **8642** | 3346 |
| Slice Registers | **6358** | **8717** | 4999 |
| Block RAM Tile | **9**（RAMB36×6 + RAMB18×6） | **19**（设计 9 + ILA 10） | 6 |
| DSP48E1 | **152** | **152** | 76 |
| BUFGCTRL | **1** | **2**（`sys_clk` + `dbg_hub` 的 TCK） | 1 |
| BSCANE2 | **0** | **1** | 0 |
| 综合告警 | **0 errors / 0 critical / 0 warnings** | — | — |

**152 DSP = DUC 76 + DDC 76**（DDC = 2×decim 15 + mixer 4 + 2×FIR 21），
**9 BRAM = 三个 NCO 各 3 tile**（tone / DUC LO / DDC LO）—— 与预算完全一致。
综合阶段 `BSCANE2 = 0`，再次证明 ILA 是在实现的 `opt_design` 里才插进去的。

## 时序

| 项 | 值 | 说明 |
|---|---|---|
| **WNS / TNS** | **6.390 ns** / 0.000，失败端点 0 / 21930 | 全部约束满足 |
| 该路径属于 | `async_default`（`sys_clk → sys_clk`） | **异步复位释放 recovery**：`u_reset_sync/sync_reg[1]` → `u_ddc/u_fir_q/dly_reg[10][5]/CLR` |
| `sys_clk` 纯数据通路 | **7.606 ns**，失败 0 / 14503 | 数据通路比复位路径还宽松 |
| WHS / THS | **0.057 ns** / 0.000，失败 0 / 21914 | hold 余量很薄，但满足 |
| WPWS | **8.870 ns**，失败 0 / 9292 | — |

和 s05 一样：**WNS 由复位 recovery 决定，不是滤波器算术**。s06 的 6.390 ns 比 s05 的
2.704 ns 还宽松（逻辑翻倍但布局更松）。

## DRC（`ddc_top_drc_routed.rpt`，0 Errors / 356 Warnings）

| 规则 | 条数 | 说明 |
|---|---|---|
| DPIP-1 | 160 | DSP 输入未流水（性能提示） |
| DPOP-2 | 148 | DSP MREG 输出未流水（性能提示） |
| DPOP-1 | 4 | DSP PREG 输出未流水 |
| REQP-1839 / 1840 | 20 / 20 | NCO 相位累加器的异步复位驱动 BRAM 地址脚 |
| CFGBVS-1 | 1 | 配置 bank 电压属性未设（s00 起就有） |
| CHECK-3 | 2 | 规则条数上限（报告截断提示） |
| RTSTAT-10 | 1 | `dbg_hub` 内部 net 没有可布负载（调试 IP 自带） |

这次**没有 DPOR-1**（s05 有 1722 条）：s06 的 FIR 流水被综合映射进 DSP 内部寄存器，
异步复位不再直接打到 DSP/BRAM 控制脚。356 条与 `impl_runme.log` 的
"0 Errors, 356 Warnings" 完全对得上。

**实现耗时**：`opt_design` **3 分 19 秒**（现场生成 `u_ila_0` + `dbg_hub`）→
`place_design` 36 s → `route_design` 52 s → `write_bitstream` 27 s。

## ILA 实测（CSV `20261020_ddc.csv`，4096 点）

| 信号 | 幅度 | 频率 | 周期（拍） | 拟合残差 |
|---|---|---|---|---|
| `ie` / `qe` | 2042.2 / 2042.4 | **3.000 MHz** | 16.667 | 0.70 / 0.88 LSB |
| `io` / `qo` | 2041.5 / 2041.8 | 3.000 MHz | 16.667 | 0.69 / 0.95 LSB |
| `di` / `dq` | 2037.1 / 2037.1 | **500.0 kHz** | **100.000** | 0.71 / 0.71 LSB |

| 检查 | 实测 | 判据 | 结论 |
|---|---|---|---|
| `ie` / `qe` 频率 | **3.000 MHz**（0.06 Fs） | DUC 输出 | ✅ |
| `ie → qe` 相位 | **−90.01°** | 正交 | ✅ |
| `ie → io` | **+10.80° = +10.0 ns** | 一个 2Fs 采样 | ✅ |
| `di` / `dq` 频率 | **500.0 kHz**（0.01 Fs） | 回环恢复 | ✅ |
| `di → dq` 相位 | **−90.00°** | 正交 | ✅ |
| 频率比 `ie : di` | **6.0000** | 6:1 | ✅ |
| DUC 复包络 | 2042.3，std 0.43（纹波 0.08%） | 幅度恒定 | ✅ |
| DDC 复包络 | 2037.1，std 0.47（纹波 0.08%） | 幅度恒定 | ✅ |
| 回环增益 | 2037.1 / 2042.3 = **0.9975** | 单位增益 | ✅ |
| 幅度上限 | DUC 2042 / DDC 2037 | ≈2040 | ✅ |

> **板级 ILA 能证明什么、不能证明什么**：
> 它能证明"搬上去（3 MHz）→ 搬下来（500 kHz）"、频率比 6:1、I/Q 正交、幅度守恒；
> **但它不能证明 `LO_DLY=23` 的绝对相位** —— 回环里没有独立参考，
> 把 23 写成 14 时频率、幅度、正交性**全都照样对**，只是整条链路旋转 90°。
> 那一项由 `tb_duc_ddc_loopback` 的逐位向量保证（step 场景 +998/0）。
> 这也正是 TASK 里那句话的意思：**"改 LO_DLY 只旋转相位，不改频率"**。

## 和 s05 比

| 指标 | s05（DUC） | s06（DUC → DDC） | 变化 |
|---|---|---|---|
| DSP | 76 | **152** | +76 |
| 纯设计 LUT | 3346 | **7642** | +4296 |
| 纯设计 Reg | 4999 | **6358** | +1359（部分寄存器进了 DSP） |
| 纯设计 BRAM | 6 | **9** | +3（第三个 NCO） |
| 布局后 WNS | 2.704 ns | **6.390 ns** | 更宽松 |
| 纯数据通路 WNS | 8.402 ns | **7.606 ns** | −0.8 ns |
| 布局后 BRAM | 15.5 | **19** | ILA 从 84 位涨到 86 位，但深度相同 |

## 这一轮踩的坑

1. **ILA 的 Trigger Setup 不能对总线切位**：`ie_dbg[14]` 这种"取一位做上升沿"在
   GUI 里做不到 —— 边沿操作符只对 1 位 probe 出现。改用**比较触发**
   （如 `ie_dbg < 0`，或二进制通配 `1xxxxxxxxxxxxxx`）即可；对整窗正弦拟合的
   判读没有影响。真要用 `$rise()` 得开 `C_ADV_TRIGGER` 并重跑实现。
2. **`Set Used In` 的教训延续**：工程里最终是两个约束集，
   `constrs_2`（工程内副本）才被 run 使用；仓库里的 `constr/ddc.xdc` 保持干净，
   调试段在 `constrs_2/new/debug.xdc`。
3. **WNS 依旧由复位网络决定**（6.390 ns recovery vs 7.606 ns 数据）。
   以后要提速，方向是缩短复位树，不是给数据路径加流水。

## 还没做的 / 留给以后

- **接真实 ADC/DAC**：`serializer2` / `deserializer2` 已在 `rtl/common/`，
  板上要加 MMCM 产生 2Fs 时钟；DDC 的 `LO_DLY` 要按实际模拟延迟重新标定
  （不是 14，也不是 23）。
- **载波/符号同步**：真实接收机要在 DDC 后加频偏估计、匹配滤波、定时恢复。
- **4× / 8×**：级联半带或 CIC。

**M1 达成**：DUC → DDC 整链在板上跑通，波形 + 资源 + 时序三样都有实测证据。
