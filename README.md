# fpga-lab — FPGA 基带链路复健

**方向：5G 基带数据通路**
NCO → 复数混频 → FIR → 插值/抽取 → DUC / DDC

**当前：Stage 0 已完成 —— 仿真闭环 + LED 已上板验证（板子上真的 1 Hz 闪）**，
下一步做 **Stage 1 — NCO**

- 完整规划 → [docs/路线图.md](docs/路线图.md)
- 当前状态 → [docs/进度.md](docs/进度.md) ← **每次开工先读这个**
- 工具链情况 → [docs/环境.md](docs/环境.md)
- 两台机器怎么同步 → [docs/同步指南.md](docs/同步指南.md)
- **怎么上板（Vivado 全流程） → [docs/上板指南.md](docs/上板指南.md)**

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
```

---

## 这个仓库怎么用（两台机器）

**这台 Mac 是主战场**：写 RTL、跑仿真，秒级迭代。
**Windows 机器负责综合/上板，也能改文档**（装了 DSH + GitHub Desktop）。

```
Mac（写代码 + 跑仿真）                    Windows（Vivado 上板 + 文档）
────────────────────                      ──────────────────────────
改 RTL → iverilog 仿真（1~5 秒）
git commit && push  ───────────────────→  git pull → 综合/实现/上板
                    ←─────────────────  日志/report 放进 logs/ 再 push
git pull → 读日志分析
```

> ✅ **上板这条路 2026-10-14 已经走通**（Vivado 2020.2，板子上 LED 真的在闪）。
> 后面每个 stage 直接复用 [上板指南](docs/上板指南.md)，不用再摸索工具链。

### ⚠️ 只用 git 传文件，不要用网盘

网盘的问题：没有历史、没有 diff、冲突时静默覆盖、会锁正在写的文件。
而且 `*.runs/`、`*.cache/`、`.Xil/` 这些 Vivado 中间产物动辄几 GB
且每次综合都在变，同步它们是一场灾难。

**只传这些：** `rtl/` `tb/` `constr/` `scripts/` `docs/` `logs/`

### Windows 侧的约定

1. `git pull`
2. 在 Vivado 里打开工程（或新建），综合/实现/上板
3. 把 **综合日志、实现日志、时序报告、资源报告** 拷进 `logs/`
4. `git add logs && git commit && git push`

Mac 这边我 `git pull` 之后用 grep 读日志 —— 不要往聊天里粘贴几万行的报告。

详细的 git 操作见 [docs/同步指南.md](docs/同步指南.md)。

---

## 目录结构

```
fpga-lab/
├── AGENTS.md              ← 编码规范与协作铁律（AI 每次自动读取）
├── Makefile               ← 统一入口
├── docs/
│   ├── 进度.md            ← 状态文件，每次开工先读、收工更新
│   ├── 路线图.md          ← 阶段规划与验收标准
│   ├── 环境.md            ← 工具链现状与安装说明
│   ├── 上板指南.md        ← Windows/Vivado 从零上板全流程
│   └── 同步指南.md        ← Mac ↔ Windows 的 git 同步
├── scripts/
│   ├── sim.sh             ← 一键仿真（自动发现所有 tb_*.v）
│   ├── lint.sh            ← 静态检查
│   ├── setup_tools.sh     ← 安装仿真器
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
├── logs/                  ← Windows 侧拿回来的 Vivado 日志与报告
└── ref/                   ← Python 参考模型、脚本
```

**每个 `sNN_*/` 下固定三个部分**：`rtl/`（设计）、`tb/`（测试）、`TASK.md`（目标与验收标准）。
一个模块 = 一个 stage = 一个目录。

## 开发约定（摘要）

完整版见 [AGENTS.md](AGENTS.md)。几条要紧的：

- **Verilog-2001**（`iverilog -g2005`），不用 SystemVerilog 语法
- **每写一个模块就必须配一个 testbench**，没有测试的 RTL 视为未完成
- **RTL 改动后必须跑 `make sim` 并通过**，不许用"看起来对"结案
- 断言用 `tb/tb_common.vh` 里的 `` `check() `` / `` `check_eq() ``（是宏，要写反引号）
- 复位统一 `rst_n`：低有效、异步复位、同步释放，走 `rtl/common/reset_sync.v`
- 跨时钟域必须显式处理，注释标 `// CDC:`
