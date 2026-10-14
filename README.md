# fpga-lab — FPGA 复习实验室

复习方向：**通用数字设计 + 接口**（UART / SPI / I2C / AXI / DDR）

当前范围：**Stage 0（验证闭环） + Stage 1（时序基本功 + UART）**

- 完整规划 → [docs/路线图.md](docs/路线图.md)
- 当前状态 → [docs/进度.md](docs/进度.md) ← **每次开工先读这个**
- 工具链情况 → [docs/环境.md](docs/环境.md)

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
make            # 看所有可用命令
make setup      # 首次使用：安装仿真器（只需一次）
make sim        # 跑全部 testbench
make sim TB=s00_blinky/tb/tb_blinky.v    # 只跑一个
make lint       # 静态检查
make list       # 列出所有 testbench
```

---

## 这个仓库怎么用（两台机器）

**这台 Mac 是主战场**：写 RTL、跑仿真，秒级迭代。
**Windows 机器只是 Vivado 执行机**：综合、实现、上板。

```
Mac（写代码 + 跑仿真）                    Windows（只跑 Vivado）
────────────────────                      ──────────────────────
改 RTL → iverilog 仿真（1~5 秒）
git commit && push  ───────────────────→  git pull → 综合/实现/上板
                    ←─────────────────  日志/report 放进 logs/ 再 push
git pull → 读日志分析
```

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

---

## 目录结构

```
fpga-lab/
├── AGENTS.md              ← 编码规范与协作铁律（AI 每次自动读取）
├── Makefile               ← 统一入口
├── docs/
│   ├── 进度.md            ← 状态文件，每次开工先读、收工更新
│   ├── 路线图.md          ← Stage 0~6 规划与验收标准
│   └── 环境.md            ← 工具链现状与安装说明
├── scripts/
│   ├── sim.sh             ← 一键仿真（自动发现所有 tb_*.v）
│   ├── lint.sh            ← 静态检查
│   └── setup_tools.sh     ← 安装仿真器
├── rtl/common/            ← 跨项目复用的小模块
│   ├── reset_sync.v       ← 异步复位、同步释放
│   ├── edge_detect.v      ← 边沿检测
│   └── sync_2ff.v         ← 两级同步器（CDC）
├── tb/
│   ├── tb_common.vh       ← 仿真公共任务（check / check_eq / tb_done）
│   └── tb_edge_detect.v   ← rtl/common 的自测
├── s00_blinky/            ← Stage 0：LED + 验证闭环
├── s01_shift_led/         ← Stage 1：参数化流水灯
├── s01_pwm/               ← Stage 1：PWM 调光
├── s01_debounce/          ← Stage 1：按键消抖
├── s01_uart/              ← Stage 1：UART 收发（后面所有调试的眼睛）
├── logs/                  ← Windows 侧拿回来的 Vivado 日志与报告
└── ref/                   ← Python 参考模型、脚本
```

每个 `sXX_*/TASK.md` 是这个子任务的目标、验收标准和提示。
