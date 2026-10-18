# `s01_nco/lut/` — NCO 查表数据

> 这两个 `.mem` 文件是 **NCO 的真值表**：`rtl/` 里的 ROM 用 `$readmemh` 读它们，
> 不读就出不了正弦。文件由脚本生成，**但生成结果要入库** —— 见下面"为什么入库"。

## 文件

| 文件 | 内容 | 大小 |
|---|---|---|
| `sin.mem` | 4096 行，每行 3 个十六进制字符 | 16 KB |
| `cos.mem` | 同上 | 16 KB |

生成命令（改参数后要重新跑）：

```sh
make lut                       # 默认参数，等价于 python3 scripts/gen_lut.py --out s01_nco/lut
make lut-check                 # 只校验，不写文件（CI / 提交前用）

python3 scripts/gen_lut.py --lut-aw 10 --aw 16 --out /tmp/lut   # 换一组参数试试
```

## 数据格式（写 RTL 前必须对上）

| 项 | 约定 |
|---|---|
| 表深 | `2**LUT_AW` = 4096 |
| 位宽 | `AW` = 12 位，**二进制补码**（`reg signed [11:0]`） |
| 每行 | `AW/4` 个十六进制字符 = 3 个字符（大写，前导零），**一行一个样本**，无注释、无表头 |
| 地址 | `i` 对应相位 `theta = 2*pi*i / 2**LUT_AW`，即 `i`＝相位的**高 `LUT_AW` 位** |
| 幅值 | `max = 2**(AW-1) - 1 = 2047`。**不会出现 -2048**，所以正负严格对称 |

两个刻意的选择，理由写清楚免得后来人改坏：

1. **有符号补码**，不加直流偏置。加偏置（`0..4095`）能省掉后面的符号处理，
   但混频是复数乘法，有符号更顺；而且偏置一旦没对齐，会直接变成载波泄漏。
2. **幅值 2047 而不是 2048**：留出 `+2047..-2047` 的对称范围。
   代价是满幅差 0.05%，换来的是 `sin[i] == -sin[N-i]` 严格成立 —— 表里没有直流分量。

## 生成器承诺的性质（`tb_lut.v` 全部检查）

- `sin[0]=0`、`sin[N/4]=+2047`、`sin[N/2]=0`、`sin[3N/4]=-2047`；`cos[0]=+2047` …
- `cos[i] == sin[(i + N/4) % N]`：**cos 表就是 sin 表移 1/4 圈**，逐位精确。
  两张表同源，所以第一版可以只做"读两张 ROM"这种最直白的实现，不引入象限逻辑。
- **幅度恒定**：`sin^2+cos^2` 相对起伏约 0.12%。这不是 bug，是 12 位量化的必然结果，
  推导见 `tb/tb_lut.v` 的注释（单边偏差上界 ≈ 2895，判据取 4096）。
  写 NCO 的 testbench 时按这个容差来，别写成"必须完全相等"。
- 量化用"四舍五入、0.5 远离零"而不是 Python 的 `round()`（银行家舍入），
  否则奇对称会被破坏 1 LSB。

## ⚠️ `$readmemh` 的路径坑（第一个会踩的坑）

`$readmemh` 的路径是相对**仿真/综合进程的工作目录**，**不是**相对 `.v` 文件所在目录。

- `make sim` 里 `vvp` 是在 `build/` 里跑的 → RTL 里写 `"s01_nco/lut/sin.mem"` **必然读不到**
  （注意 `$readmemh` 读不到时**不报错**，表里全是 x，输出一片红 —— 很难查）。
- 所以 `scripts/sim.sh` 会自动把绝对路径以宏传进来，RTL 侧统一这么写：

```verilog
`ifndef NCO_LUTDIR
  `define NCO_LUTDIR "s01_nco/lut/"   // 兜底：手工跑 iverilog / Vivado 综合
`endif

initial $readmemh({`NCO_LUTDIR, "sin.mem"}, sin_rom);
```

> **2026-10-18 宏改名**：以前全仓库只有一个 `LUTDIR`，s03 加 FIR 系数表后
> 同一轮仿真里会打架。现在一个表一个宏：NCO 用 `NCO_LUTDIR`，FIR 用 `FIR_COEFDIR`。
> `nco.v` 仍兼容旧名 `LUTDIR`（旧 Vivado 工程不用改），但新工程请用新名。

`tb_lut.v` 就是这么用的，可以直接抄。

### 末尾那个"第 4097 行"是假象

文件是 4096 行数据、每行以 `\n` 结尾。有些编辑器（Windows 上尤其是）会把最后那个换行
显示成"一行空行"（数出来 4097 行）—— 删掉它只是少了末尾换行，**数据一行没少**。

`make lut-check` 因此只比较**数据行**：行尾有无换行、是 LF 还是 CRLF 都不算问题
（`$readmemh` 读到的数值完全一样），但任何一个十六进制值被改动照样报 FAIL。
动手改 `.mem` 之前先想清楚：这两个文件是生成物，要改就改生成器再 `make lut`。


### ✅ Vivado 侧：**已实测（2026-10-15）**，结论和仿真侧一样

综合也是按"**相对 run 目录**"找文件（`<工程>.runs/synth_1/`，由 `runme.bat` 里的
`cd /d "%HD_SDIR%"` 设定），所以 RTL 里那个兜底相对路径**同样读不到**：

```
CRITICAL WARNING: [Synth 8-4445] could not open $readmem data file
  's01_nco/lut/sin.mem'; please make sure the file is added to project and
  has read permission, ignoring   [nco.v:23]
```

**两个实测结论，都是踩过才敢写的：**

| 做法 | 结果 |
|---|---|
| **把 `.mem` 加进工程 source** | ❌ **没用**。Vivado 报错里那句 "please make sure the file is added to project" 是**误导**——加进去了它也不会去搜 |
| **`-verilog_define NCO_LUTDIR="<绝对路径>/"`** | ✅ **正确解法** |
| 把 `.mem` 拷到 run 目录下的 `s01_nco/lut/` | ⚠️ 能跑通，但只适合做诊断（会造成仿真/综合各用一份独立数据，别长期用） |

工程模式下的填法：**Settings → Synthesis → Options → More Options**：

```
-verilog_define NCO_LUTDIR="D:/Backup/Documents/GitHub/fpga-lab/s01_nco/lut/"
```

⚠️ 两个容易翻车的点：

1. **值里必须带真正的双引号**，**结尾的 `/` 不能少**
   （RTL 里是 ``$readmemh({`NCO_LUTDIR, "sin.mem"}, ...)`` 拼起来的）。
2. **宏名一个字都不能错。** s01 上板时把它写成了 `LUDIR`（少一个 `T`），
   于是 `` `ifndef NCO_LUTDIR `` 判定"没定义"→ 走兜底路径 → 表全 x →
   **整个 NCO 被综合优化掉**，板上四颗灯全灭。
   **识别特征**：报错信息里显示的是**兜底相对路径**而不是你填的绝对路径 ——
   看到这个就说明宏压根没生效。

**怎么确认表真的进去了**（比翻日志快）：综合后看 `report_utilization`。

| 指标 | 表**没**读进去 | 表读进去了 |
|---|---|---|
| `Block RAM Tile` | **0** | **3**（两张 4096×12 的表） |
| `Slice Registers` | **2**（只剩 `reset_sync` 的两个触发器） | **35** |

> 来龙去脉见 [docs/学习备忘.md](../../docs/学习备忘.md) 第 1、2、3 节。

## 为什么 `.mem` 要入库（而不是像 `build/` 那样忽略）

仿真和综合必须用**同一份**数据，否则会出现"仿真对、上板错"这种最难查的问题。
入库后 Windows 机器 `git pull` 就能拿到一模一样的表，不需要装 Python 重新生成。
`make lut-check` 负责保证文件没有被手改过 —— 这条已经纳入 `make sim`（`tb_lut.v`）。

## 换参数时注意

- `AW` 必须是 4 的倍数（十六进制字符数 = `AW/4`）。
- `LUT_AW` 变浅 → 相位截断变狠 → 输出杂散变大。第一版建议保持 `LUT_AW = PHASE_W`。
- 换参数后：`make lut` → 改 `tb_lut.v` 和 `tb_nco.v` 里的 `LUT_AW`/`AW` →
  `make sim` 必须仍然全绿。
  （`nco.v` / `nco_top.v` 的 `LUT_AW` / `AW` 已经是**参数**，不用改 RTL；
  但**必须重新生成 `.mem`**——`$readmemh` 读不满时不报错，表里会留 x。）
