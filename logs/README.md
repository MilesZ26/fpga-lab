# logs — 板级综合 / 实现的产出

在 Windows 上跑完 Vivado 后，把**文本**产出拷到这里再 commit。
**文件名不用改**，保持 Vivado 生成的带前缀名字，一眼能看出对应哪个工程。

| 文件 | 来源 | 用途 |
|---|---|---|
| `synth_runme.log` | `*.runs/synth_1/runme.log` | 综合警告：推断出的 latch、被优化掉的逻辑、位宽截断 |
| `impl_runme.log` | `*.runs/impl_1/runme.log` | 布局布线问题、DRC 结论 |
| `*_timing_summary_routed.rpt` | `report_timing_summary` | **WNS / TNS —— 时序收敛的证据** |
| `*_utilization_placed.rpt` | `report_utilization` | LUT / FF / BRAM / DSP 用量 |
| `*_clock_utilization_routed.rpt` | `report_clock_utilization` | 时钟资源 |
| `*_drc_routed.rpt` | `report_drc` | 设计规则违例 |

## 规矩

- **只放文本**（报告 / 日志 / ILA 导出的 CSV），不要 `.dcp` / `.bit` / `.runs/`
  目录（动辄几百 MB 到几 GB）。
- **ILA CSV 入库**（2026-10-20 改）：放在各 stage 的 `csv/` 下，文件名保持导出时的
  日期前缀。它是判读的原始数据 —— 配合 `scripts/ila_check.py` 可以重算
  `ila_check.txt` 里的每个数字：

  ```bash
  python3 scripts/ila_check.py logs/s06_ddc/csv/20261020_ddc.csv \
      --pairs ie:qe,io:qo,di:dq --iq ie:qe,di:dq --ratio ie:di
  ```

  （脚本只依赖 numpy；缺了 `pip install numpy`。）

- **不要放截图 / PNG**（2026-10-17 定）：PNG 不能 grep、会随缩放/区域变化，
  不是可复现的证据。波形结论写成**文字 + 数字**（周期几点、WNS 多少），比图有用。
- **`.ila` / `.ltx` 也不入库**：二进制、绑 Vivado 版本；CSV 已经够复算，
  真要复现采集得重新烧 bitstream。
- ⚠️ `report_drc` 只给 `-rpx` 参数会生成**二进制**文件，命令行读不了。
  要文本就明确给 `-file xxx.rpt`。
- 按阶段分子目录，例如 `logs/s00_blinky/`。
