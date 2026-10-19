# fpga-lab — FPGA 基带链路复健

**方向：5G 基带数据通路**
NCO → 复数混频 → FIR → 插值/抽取 → DUC / DDC

**当前：Stage 4（插值 / 抽取）已完成 —— 全仓库 18/18、393 个检查点全绿；
Vivado 实测 30 DSP、WNS 9.311 ns，ILA 上 7 个完整冲激逐点一致。**
Stage 0~4（LED / NCO / 复数混频 / FIR / 插值抽取）都完成了仿真 + 上板 + ILA 三闭环。

- 完整规划 → [docs/路线图.md](docs/路线图.md)
- 当前状态 → [docs/进度.md](docs/进度.md) ← **每次开工先读这个**
- 怎么上板（Vivado 全流程） → [docs/上板指南.md](docs/上板指南.md)

---

## 关于本仓库与许可

本仓库是个人 FPGA 复健练习。**部分文档与脚手架代码由 AI 助手（DeepSeek Harness）
辅助生成，所有代码均经过阅读、修改与仿真验证。**

依照《[DeepSeek 用户协议](https://cdn.deepseek.com/policies/zh-CN/deepseek-terms-of-use.html)》
第 3.1 条，在此显著标明本仓库含人工智能生成内容。

> ⚠️ 这是**学习记录**，不是经过验证的生产代码。
> 若你要复用其中任何部分，请自行评估正确性 —— 尤其是 Verilog 代码，
> 未经过仿真和时序收敛验证之前不要用于任何实际工程。

### 许可

代码以 [MIT 许可](LICENSE) 发布。

## 快速开始

```sh
make                    # 看所有可用命令
make setup              # 首次使用：安装仿真器（只需一次）
make sim                # 跑全部 testbench
make sim TB=s00_blinky/tb/tb_blinky.v    # 只跑一个
make lint               # 静态检查
make list               # 列出所有 testbench
make wave VCD=build/tb_blinky.vcd        # 用 Surfer 看波形
make fir-coef-check                      # 校验 FIR 系数表与生成器一致
make fir-vec-check                       # 校验 FIR 参考向量与生成器一致
make resample-coef-check                 # 校验半带系数表与生成器一致
make resample-vec-check                  # 校验插值/抽取参考向量与生成器一致
```

> iverilog 和 bison 由 `make setup` **源码编译**进 `tools/`（不进仓库，
> `.gitignore` 里有）。macOS 自带的 bison 2.3 太老，必须换。

---

## 目录结构

```
fpga-lab/
├── AGENTS.md              ← 编码规范与铁律（AI 每次自动读取）
├── Makefile               ← 统一入口
├── docs/
│   ├── 进度.md            ← 状态文件，每次开工先读、收工更新
│   ├── 路线图.md          ← 阶段规划与验收标准
│   └── 上板指南.md        ← Vivado 从零上板全流程（引脚 / 器件 / 排障）
├── scripts/
│   ├── sim.sh             ← 一键仿真（自动发现所有 tb_*.v，支持 deps.txt / VECDIR）
│   ├── lint.sh            ← 静态检查
│   ├── setup_tools.sh     ← 安装仿真器
│   ├── gen_lut.py         ← 生成 NCO 查表数据（sin/cos.mem）
│   ├── gen_mixer_vec.py   ← 生成混频器的 Python 参考向量（验收用）
│   ├── gen_fir_coef.py    ← 设计 FIR 低通并生成系数表（s03_fir/lut/*.mem）
│   ├── gen_fir_vec.py     ← 生成 FIR 的 Python 参考向量（验收用）
│   ├── gen_hb_coef.py     ← 设计 2× 半带并生成系数表（s04_resample/lut/*.mem）
│   ├── gen_resample_vec.py ← 生成插值/抽取/级联的参考向量（验收用）
│   └── hooks/pre-commit   ← git 守卫（make hooks 安装）
├── rtl/common/            ← 跨模块复用的小件
│   ├── reset_sync.v       ← 异步复位、同步释放
│   ├── edge_detect.v      ← 边沿检测
│   └── sync_2ff.v         ← 两级同步器（CDC）
├── tb/                    ← 公共 testbench
│   ├── tb_common.vh       ← 断言宏（check / check_eq / tb_done）
│   ├── tb_edge_detect.v
│   ├── tb_reset_sync.v
│   └── tb_sync_2ff.v
├── s00_blinky/            ← Stage 0：点亮 LED + 验证闭环
├── s01_nco/               ← Stage 1：NCO（相位累加器 + 查表）
│   └── lut/               ← sin/cos 查表数据（脚本生成，入库）
├── s02_mixer/             ← Stage 2：复数混频
│   ├── rtl/mixer.v        ← 算法本体
│   ├── rtl/mixer_top.v    ← 板级顶层（实验台）
│   ├── tb/                ← 算术级 + 系统级两个 testbench
│   ├── vec/               ← Python 参考向量（$readmemh 回放）
│   ├── constr/mixer.xdc   ← 引脚约束 + ILA 说明
│   └── deps.txt           ← 声明依赖 s01_nco（sim.sh 会读）
├── s03_fir/               ← Stage 3：FIR 低通（对称预加 + 4 级流水）
│   ├── rtl/fir.v          ← 算法本体
│   ├── rtl/fir_top.v      ← 板级顶层（冲激发生器实验台）
│   ├── tb/                ← 4 个 testbench（算术/系数/顶层/两张表回归）
│   ├── lut/               ← 系数表（脚本生成，入库）
│   ├── vec/               ← Python 参考向量（$readmemh 回放）
│   ├── constr/fir.xdc     ← 引脚约束 + FIR_COEFDIR + ILA 说明
│   └── deps.txt           ← 声明依赖 s01_nco（tb_table_binding 用）
├── s04_resample/          ← Stage 4：2× 半带插值 / 抽取（多相）
│   ├── rtl/interp2.v      ← 2× 插值（偶相恒等 + 奇相 15 乘）
│   ├── rtl/decim2.v       ← 2× 抽取（两相输入 + 15 乘 + 0.5 直通）
│   ├── rtl/resample_top.v ← 板级顶层（冲激 → 插值 → 抽取）
│   ├── tb/                ← 5 个 testbench
│   ├── lut/               ← 半带系数表（脚本生成，入库）
│   ├── vec/               ← Python 参考向量（interp/decim/cascade）
│   └── constr/resample.xdc ← 引脚约束 + HB_COEFDIR + ILA 说明
├── logs/                  ← 板级综合 / 实现日志与报告
└── ref/                   ← 参考资料
```

**每个 `sNN_*/` 下固定三个部分**：`rtl/`（设计）、`tb/`（测试）、`TASK.md`（目标与验收标准）；
另外按需有 `constr/`（XDC）、`lut/`（查表数据）、`vec/`（参考向量）、`deps.txt`（跨 stage 依赖）。
一个模块 = 一个 stage = 一个目录。

## 开发约定（摘要）

完整版见 [AGENTS.md](AGENTS.md)。几条要紧的：

- **Verilog-2001**（`iverilog -g2005`），不用 SystemVerilog 语法
- **每写一个模块就必须配一个 testbench**，没有测试的 RTL 视为未完成
- **RTL 改动后必须跑 `make sim` 并通过**，不许用"看起来对"结案
- 断言用 `tb/tb_common.vh` 里的 `` `check() `` / `` `check_eq() ``（是宏，要写反引号）
- 复位统一 `rst_n`：低有效、异步复位、同步释放，走 `rtl/common/reset_sync.v`
- 跨时钟域必须显式处理，注释标 `// CDC:`
