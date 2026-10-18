# `s03_fir/lut/` — FIR 系数表

> 这两个 `.mem` 文件是 FIR 的**系数真值**：`rtl/fir.v` 用 `$readmemh` 读它们，
> 不读就出不了滤波。文件由脚本生成，**生成结果要入库** —— 理由和 s01 的
> `s01_nco/lut/` 一样：仿真和综合必须用同一份数据。

## 文件

| 文件 | 内容 | 大小 |
|---|---|---|
| `coef.mem` | 47 行，每行 4 个十六进制字符（16 位补码） | 47 × 5 字节 |
| `coef5.mem` | 5 行，5 抽头测试小车 | 5 × 5 字节 |

生成命令（改参数后要重新跑）：

```sh
make fir-coef                      # 默认参数，等价于 python3 scripts/gen_fir_coef.py --out s03_fir/lut
make fir-coef-check                # 只校验，不写文件（提交前 / CI 用）

python3 scripts/gen_fir_coef.py --taps 63 --cutoff 0.12 --out /tmp/fir   # 换一组参数
```

## 数据格式（写 RTL 前必须对上）

| 项 | 约定 |
|---|---|
| 位宽 | `CW = 16` 位，**二进制补码**（`reg signed [15:0]`） |
| 每行 | `CW/4 = 4` 个十六进制字符（大写，前导零），**一行一个系数**，无注释、无表头 |
| 顺序 | `coef[0]` 是**最新**样本乘的系数（`x[n]`），`coef[N-1]` 是最老样本（`x[n-N+1]`） |
| 定点 | Q1.15：`32768` 代表 `1.0`，`-32768` 代表 `-1.0` |
| 系数和 | **恰好 32768**（直流增益精确为 1.0） |
| 对称 | `c[k] == c[N-1-k]`（线性相位，逐位精确） |

## 默认设计

由 `scripts/gen_fir_coef.py` 用**窗函数法**生成：

- 理想低通 `h[n] = 2*fc*sinc(2*fc*(n-M))`，`M=(N-1)/2`
- 乘 Hamming 窗 `0.54 - 0.46*cos(2*pi*n/(N-1))`
- 归一化到 `sum(h)=1`，再量化到 Q1.15
- 量化误差全部塞给中心抽头，使系数和精确等于 32768

| 指标 | 值 |
|---|---|
| 抽头数 `N` | 47（奇数 → 群延迟 = 23 个采样，整数拍） |
| 归一化截止 `fc` | 0.15（Fs = 50 MHz 时是 7.5 MHz） |
| 窗 | Hamming |
| 系数位宽 `CW` | 16（Q1.15） |
| 系数和 | 32768 |
| 最大系数 | +9810（中心） |
| 最小系数 | −1867 |
| 通带 [0, 0.10] 纹波 | 0.037 dB |
| 阻带 [0.20, 0.5] 衰减 | 55.7 dB |
| 群延迟 | 23 个采样（= 23 拍 @ 单样本/拍） |

前 6 个系数：`11, 38, 39, 0, -65, -101`；
中心 3 个：`8385, 9810, 8385`。

> 注意第 4 个系数（`coef[3]`）量化后正好是 **0**。这不是 bug：
> 窗函数法的 sinc 在这个位置的值小于 0.5 LSB，量化成 0。
> 它不影响对称性，也不影响直流增益（误差已经被中心抽头吸收）。

## `coef5.mem` 是干什么的

它是一个 **5 抽头测试小车**：`[2048, 8192, 12288, 8192, 2048]`，
正好是 `[1,4,6,4,1]/16` 的 Q15 版本，系数和 32768，直流增益也精确为 1。

它**不是产品滤波器**（5 抽头的过渡带很宽）。它存在的唯一理由是给
`tb_fir.v` 提供能一眼手算的边界用例：

- `x=2` 打在系数 8192 上 → 乘积 `16384` = **半个 LSB**，正好是舍入 tie：
  `ROUND=1` 得 1，`ROUND=0` 得 0
- `x=-2` → `-16384`，`ROUND=1` 得 0，`ROUND=0` 得 −1（算术右移向 −∞）
- `OW=8` 实例上，满幅 ±2048 必须饱和到 +127/−128，而不是回绕
- `IW=8` 实例上，冲激 64 经过系数 8192 得 16，验证输入位宽参数

这些值在 `tb_fir_coef.v` 里被逐位钉死。

## ⚠️ `$readmemh` 的路径坑（和 s01 一模一样）

`$readmemh` 的路径相对**仿真/综合进程的工作目录**，不是相对 `.v` 文件所在目录。
`make sim` 里 `vvp` 在 `build/` 里跑，RTL 里写 `"s03_fir/lut/coef.mem"`
**必然读不到**，而且**不报错** —— 系数数组全是 x。

所以 `fir.v` 这么写：

```verilog
`ifndef FIR_COEFDIR
  `define FIR_COEFDIR "s03_fir/lut/"     // 兜底：手工跑 iverilog / Vivado 综合
`endif

initial $readmemh({`FIR_COEFDIR, COEF_FILE}, coef);
```

`sim.sh` 会按 stage 给宏：`s03_fir/lut/` → `FIR_COEFDIR`（绝对路径）。
**2026-10-18 起"一个表一个宏"**：NCO 的表用 `NCO_LUTDIR`，FIR 系数用
`FIR_COEFDIR`。旧的单一 `LUTDIR` 会导致"同一轮仿真里两张表只能指一个目录"，
s03 加表之前已经改掉。

### Vivado 侧（**2026-10-18 实测定案**）

工程模式：**Settings → Synthesis → Options → More Options**，写一整行：

```text
-verilog_define FIR_COEFDIR="D:/…/fpga-lab/s03_fir/lut/"
```

- `-verilog_define` **必须自己写**。More Options 的内容是**原样拼到
  `synth_design` 命令行**上的，不是"宏名 + 宏值"两个字段的对话框。
  只写 `FIR_COEFDIR="…"` 会报
  `ERROR: [Common 17-165] Too many positional options`（s03 撞过）。
- 值里**必须带真正的双引号**，**结尾的 `/` 不能少**（RTL 是拼 `"coef.mem"` 的），
  路径**只能出现一次**。
- 改完记得 **Reset Synthesis**（见 9.2 节），否则不生效。
- 非工程模式：`synth_design -verilog_define {FIR_COEFDIR="D:/…/s03_fir/lut/"}`
- 完整说明（含证据链和四个连带陷阱）见
  [学习备忘 第 13 节](../../docs/学习备忘.md#13-vivado-20202宏在-more-options-里传--verilog_define不是勾-namevalue)。

**怎么确认表真的进去了**（比翻日志快）：综合后看 `report_utilization`。

| 指标 | 表**没**读进去 | 表读进去了 |
|---|---|---|
| DSP48E1 | 0（逻辑被整体优化掉） | **约 24 个**（23 对 + 1 个中心） |
| Slice Registers | 很少（只剩复位同步） | 延迟线 47×12 + 乘积 24×29 + 流水寄存器 |

> s01 的教训：`$readmemh` 读不到时 Vivado 会给 `CRITICAL WARNING`，
> 然后**把整个模块优化掉**。板子上四颗灯全灭，日志里那句
> "please make sure the file is added to project" 是**误导** —— 加进工程也没用。
> 正确解法就是传绝对路径宏。详见 [学习备忘](../../docs/学习备忘.md) 第 1~3 节。

## 为什么 `.mem` 要入库

仿真和综合必须用**同一份**数据，否则会出现"仿真对、上板错"这种最难查的问题。
入库后 Windows 机器 `git pull` 就能拿到一模一样的系数，不需要装 Python 重新生成。
`make fir-coef-check` 负责保证文件没有被手改过。

## 换参数时注意（**会牵动三样东西**）

改 `--taps` / `--cutoff` / `--cw` 之后，下面三样必须**成套**更新：

1. `make fir-coef` → 重新生成 `coef.mem`
2. `make fir-vec` → 重新生成 `vec/fir_vec.txt`（头里存了系数校验和）
3. 如果 `N` / `CW` 变了，`tb_fir.v` 里的 `N` / `CW` 也要改；
   如果 `coef5.mem` 的手算值变了，`tb_fir_coef.v` 和 `tb_fir.v` 的断言也要改

**忘了第 2 步会怎样？** `tb_fir.v` 的头检查会报
"向量文件与 coef.mem 的系数校验和一致" FAIL —— 这是故意设计的，
不让"回放全绿但其实测的是旧滤波器"这种事发生。

另外：`N` 必须是 `>= 2`；奇数 `N` 的群延迟是整数，**建议保持奇数**。
`CW` 必须是 4 的倍数（十六进制字符数 = `CW/4`）。
`coef.mem` 的行数必须和 `fir.v` 里 `reg coef [0:N-1]` 的长度**恰好相等** ——
`$readmemh` 文件短了不报错，只会留下 x（`tb_fir_coef.v` 会检查）。
