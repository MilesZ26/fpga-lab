# logs — 从 Windows 机器带回来的 Vivado 产出

在 Windows 上跑完 Vivado 之后，把**文本**产出拷到这里再 commit：

| 文件 | 在 Vivado 里的名字 | 用途 |
|---|---|---|
| 综合日志 | `runme.log` / `*_synth.log` | 查综合警告、推断出的 latch、被优化掉的逻辑 |
| 实现日志 | `*_impl.log` | 布局布线问题 |
| 时序报告 | `*_timing_summary.rpt` | WNS / TNS / 违例路径 |
| 时序详情 | `*_timing.rpt` | 关键路径明细 |
| 资源报告 | `*_utilization.rpt` | LUT / FF / BRAM / DSP 用量 |
| CDC 报告 | `report_cdc` 输出 | 跨时钟域检查（多速率处理开始变重要） |

## 规矩

- **只放文本文件**，不要放 `.dcp`、`.bit`、`.runs/` 目录（动辄几百 MB 到几 GB）。
- 提交前可以 `git status` 看一眼，别把中间文件带进来。
- 不要在聊天里粘贴几万行的报告 —— 给出文件名，让 AI 用 grep 读。

## 目录约定

按阶段分子目录，例如：

```
logs/
├── s00_blinky/
│   ├── synth.log
│   ├── timing_summary.rpt
│   └── utilization.rpt
└── s01_nco/
    └── ...
```
