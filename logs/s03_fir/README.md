# logs/s03_fir — Stage 3（FIR 低通）的 Vivado 产出

> **状态：⬜ 还没填**（2026-10-18 建目录）。综合 / 实现 / 上板 / ILA 都还没跑成功。
> 填完之后把本节改成和 `logs/s02_mixer/README.md` 一样的"实测结论 + 数字表"。

## 出处（可复现）

| 项 | 值 |
|---|---|
| 工程 | `D:\Backup\Documents\vivado_projects\s03_fir\s03_fir.xpr` |
| 工具 / 器件 | Vivado v2020.2 (win64) / `xc7a100tfgg484-2` |
| 顶层 | `fir_top`（`CLK_HZ=50e6`、`IMP_PERIOD=1024`、`IW=12`、`N=47`、`OW=13`） |
| 关键宏 | `FIR_COEFDIR = <仓库>/s03_fir/lut/`（More Options 里写 `-verilog_define`） |
| ILA | `u_ila_0`：`probe0 = fir_dbg[12:0]`、`probe1 = imp_dbg`，`C_DATA_DEPTH = 8192` |

## 该收哪些文件（报告命令，路径按本机改）

```tcl
# 综合后（"设计本身"的规模看这份）
open_run synth_1
report_utilization -file D:/Backup/Documents/GitHub/fpga-lab/logs/s03_fir/fir_top_utilization_synth.rpt

# 实现后（含 ILA）
open_run impl_1
report_utilization        -file D:/Backup/Documents/GitHub/fpga-lab/logs/s03_fir/fir_top_utilization_placed.rpt
report_timing_summary     -file D:/Backup/Documents/GitHub/fpga-lab/logs/s03_fir/fir_top_timing_summary_routed.rpt
report_drc                -file D:/Backup/Documents/GitHub/fpga-lab/logs/s03_fir/fir_top_drc_routed.rpt
report_clock_utilization  -file D:/Backup/Documents/GitHub/fpga-lab/logs/s03_fir/fir_top_clock_utilization_routed.rpt
report_methodology        -file D:/Backup/Documents/GitHub/fpga-lab/logs/s03_fir/fir_top_methodology_drc_routed.rpt
```

另外**手动拷两个日志**（`report_*` 里没有这些信息）：

```
…\s03_fir.runs\synth_1\runme.log  →  logs/s03_fir/synth_runme.log
…\s03_fir.runs\impl_1\runme.log   →  logs/s03_fir/impl_runme.log
```

> ⚠️ 只收**文本报告**，不收 `.dcp` / `.bit` / `.runs/` / 波形 PNG。
> 波形图由作者本地保存，理由同 `logs/s02_mixer/README.md`。

## 数字（**待填**）

> **只收"带 ILA"这一版**（2026-10-18 决定，理由见 `docs/进度.md` 待决问题）：
> 无 ILA 时 `fir_out` 没有任何负载，`opt_design` 会把整个 FIR 裁掉，那一版数字是垃圾。
> 想要纯设计的 LUT/Reg/WNS，唯一触发条件是 **带 ILA 的 WNS < 0** 时分不清责任。

| 指标 | 综合后（含 ILA） | 布局后（含 ILA） | 对照 s02（含 ILA） |
|---|---|---|---|
| Slice LUTs | ⬜ | ⬜ | 1464 |
| Slice Registers | ⬜ | ⬜ | 2416 |
| Block RAM Tile | ⬜ | ⬜ | 23 |
| **DSP48E1** | ⬜ **（预估 ≈ 24；ILA 不占 DSP，所以这个数两版等价，是"系数表读没读进来"的判据）** | ⬜ | 4 |
| BUFGCTRL | ⬜ | ⬜ | 2 |
| WNS / TNS | — | ⬜ **（≥ 0 就等于纯设计也收敛）** | +5.697 ns |
| WHS / THS | — | ⬜ | +0.059 ns |
| DRC | — | ⬜ | 0 / 56 Warnings |
| `opt_design` 耗时 | — | ⬜ | 3 分 08 秒 |

## 板级波形判据（**待填实测**）

期望值见 [`s03_fir/lut/expected_h.md`](../../s03_fir/lut/expected_h.md)，要点：

| 检查 | 期望 | 实测 |
|---|---|---|
| 冲激周期 | **1024** 点（8192 点窗口里 8 个） | ⬜ |
| 响应长度 | 47 点后回 0 | ⬜ |
| 峰值 | **613** @ k=23（触发点后第 27 点） | ⬜ |
| 两端 | h[0] = h[46] = **1** | ⬜ |
| 对称性 | 关于 k=23 的 23 对全部相等 | ⬜ |
| LED | 四颗都 1 Hz 闪 | ⬜ |
