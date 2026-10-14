# logs/s00_blinky — Stage 0 的 Vivado 产出

**⚠️ 2026-10-14：这个目录还是空的。**

板级已经实测通过（`s00_blinky` 在板子上 LED 按 1 Hz 闪），
但**综合/实现日志和报告还没从 Windows 拷回来** —— 这是这次唯一没落地的步骤。

## 该放什么（按 [../../logs/README.md](../README.md) 的约定）

| 文件名 | 怎么来 | 用途 |
|---|---|---|
| `synth.log` | 拷 `s00_blinky.runs\synth_1\runme.log` | 查综合警告（latch、位宽截断、被优化掉的逻辑） |
| `impl.log` | 拷 `s00_blinky.runs\impl_1\runme.log` | 布局布线问题 |
| `timing_summary.rpt` | `report_timing_summary` | **WNS ≥ 0 的证据** |
| `utilization.rpt` | `report_utilization` | LUT / FF 用量 |
| `drc.rpt` | `report_drc` | 有没有 CRITICAL WARNING 级别的规则问题 |

命令在 [../../docs/上板指南.md](../../docs/上板指南.md) 第 6 步，直接粘进 Vivado 的 Tcl Console。

## 为什么非要补这个

板子上灯闪了，**结论已经可靠**（现象本身就是证据）。但日志是给**以后**用的：

- 复查"当时的 Vivado 版本 / 器件封装 / 时序余量到底是多少"
- 建立基线：后面 NCO / FIR 的资源用量要跟 s00 对比才知道涨了多少
- `AGENTS.md` 铁律 6：结论要给出证据。**现象是证据，报告是可复查的证据。**

> 工程建在仓库**外面**（`D:\vivado_prj\...`），所以要手动拷。
> 只拷文本，`.bit` / `.dcp` / `.runs/` 一律不要。
