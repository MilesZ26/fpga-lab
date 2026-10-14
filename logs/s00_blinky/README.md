# logs/s00_blinky — Stage 0 的 Vivado 产出

这个目录**必须在版本库里存在**：Vivado 的 `report_* -file` 不会替你创建目录，
目录不存在时命令会直接失败。所以留这个文件占位。

## 该放什么

| 文件名 | 在 Vivado 里的来源 | 看什么 |
|---|---|---|
| `synth_runme.log` | `<工程>.runs/synth_1/runme.log` | CRITICAL WARNING、被优化掉的逻辑 |
| `impl_runme.log` | `<工程>.runs/impl_1/runme.log` | 布局布线的问题 |
| `timing_summary.rpt` | `report_timing_summary` | **WNS / TNS** —— 有没有违例路径 |
| `utilization.rpt` | `report_utilization` | LUT / FF / BRAM / DSP 用量 |
| `drc.rpt` | `report_drc` | 设计规则检查 |

完整的操作步骤见 [../../docs/上板指南.md](../../docs/上板指南.md) 的「第 6 步」。

## 规矩

- **只放文本**。`*.dcp` / `*.bit` / `*.runs/` 一律不要 —— 几百 MB 到几 GB，
  而且每次综合都在变。`.gitignore` 和 `pre-commit` 守卫都会拦。
- `synth_runme.log` / `impl_runme.log` 是从 `*.runs/` 目录里**拷出来**的，
  因为 `.gitignore` 忽略整个 `*.runs/`。
- 不要把这些报告粘进聊天 —— 几万行，让 AI 用 grep 读。
