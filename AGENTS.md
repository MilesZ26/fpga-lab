# AGENTS.md — 本仓库的长期规矩

给 AI 助手也给我自己。每次会话开始自动生效。

## 项目性质

- FPGA 复健项目。方向：**5G 基带数据通路**（NCO → 混频 → FIR → 插值/抽取 → DUC/DDC）。
- 目标平台：Xilinx Artix-7（正点原子达芬奇 Pro，XC7A100T）。
- 当前范围：**Stage 4 — 插值/抽取**（s04 的 Mac 侧已完成；Windows 侧综合/上板待做）。
  完整规划见 `docs/路线图.md`。**s03/s04 是真正的硬骨头**，别用前三个 stage 的速度估算。
- **两台机器：Mac（Apple Silicon）写 RTL、跑 `make sim` 验收；Windows 跑综合/实现/上板。**
  **Vivado 只有 Windows / Linux x86-64 版，没有 macOS 版**，所以上板只能在 Windows 上做。
- 用户背景：大学学过 FPGA，做过通信基带信号处理项目，多年未用，现在重拾。
- **用户的目标是重新学会，不是拿到能跑的代码。** 多解释"为什么"。

## 铁律

1. **验证优先于完成。**
   任何 RTL 改动之后，必须实际运行 `make sim` 并通过，才能声称完成。
   禁止用"看起来正确""应该没问题"结案。
   **如果仿真器不可用，先停下来报告，不要改代码。**
   **`git pull` 之后也要重跑一次 `make sim` / `make lint`** —— 拉下来的可能是
   别人（另一台机器上）改过、但没在这台机器上验收过的 RTL。
   （**Windows 侧例外**：没有 `make` / `iverilog`，不要尝试；见「仿真」一节。）

2. **不允许跑 Vivado，但允许（并且应该）推 git。**
   `make sim` 通过、`make check`（pre-commit 守卫）通过之后，就提交并推两个远端
   （见「远端同步」一节）—— 用户靠在 Windows 上 `git pull` 拿到最新代码。

   综合/实现是分钟到小时级任务，由用户在自己机器上执行。
   需要综合结果时，请用户把日志/报告以**文件形式**放进 `logs/`，
   然后用 grep 读相关段落 —— 不要让他粘贴几万行内容进聊天。

3. **代码进文件，不进对话。**
   不要大段粘贴代码到回复里。改动写进文件，回复里只给路径和摘要。

4. **每写一个模块就必须配一个 testbench。** 没有 testbench 的 RTL 视为未完成。

5. **先读状态，后干活。**
   会话开始先读 `docs/进度.md`；会话结束前更新它
   （当前阶段 / 已完成 / 下一步 / 待决问题）。

6. **报告要给出证据。**
   结论必须附：改了哪些文件、`make sim` 的实际输出、还没验证的假设。

## 远端同步（两个远端，内容完全一致）

> 2026-10-16 定。原因：`git push` 会把提交的**全部祖先**一起推上去，
> 所以"让 GitHub 少一个平台的提交"在单分支上做不到（真要做得改写历史，
> 哈希一变就和另一个远端分叉）。结论：**不做裁剪，两个远端镜像同步。**

| 远端 | 谁推 | 说明 |
|---|---|---|
| `origin`（Gitee） | **Mac 和 Windows 都推** | Windows 那台机器**只认它** |
| `github` | **只有 Mac 推** | **Windows 连这个远端都不要配** —— 不配就不会手滑 pull/push 错 |

1. **动手前先 `git pull --rebase origin main`；收工后推两个远端。**
2. **推的顺序：先 Gitee，后 GitHub。** Gitee 是 Windows 的关键路径；
   GitHub 从国内时好时坏，失败**不要卡住**，报告一句、下次补推即可。
3. **不要在"没 pull 过的最新 main"之外提交。** 两台机器同时从同一个旧基点提交
   → 历史分叉，必须 merge，还得手工收拾。
4. `docs/进度.md` 两台机器都会改，**不按"谁只能改哪节"分工**。
   早期写过"Windows 只改板级实测、Mac 只改当前阶段/下一步"—— 这条**已放宽**：
   单人项目、也不会同时在两台机器上干活，按节切分工是多余的摩擦，
   而且实际上 Windows 侧顺手更新「状态表 / 下一步 / 待决问题」是合理的
   （板子跑完，谁最清楚结果？当时干活的那台）。
   **真正的保护只有一条：改之前先 `pull --rebase`，改完立刻推。**
   唯一建议：**别在两台机器上同时开同一个文件**。
5. **文本报告入库，调试脚手架不留。**
   `logs/` 里的综合/实现报告、`constr/*.xdc` 里的引脚与时钟约束
   **本来就该进 GitHub**，不要嫌它"是 Windows 产生的"而想办法甩掉。
   但 **Vivado 自动追加的 `create_debug_core u_ila_0 …` 那一段是调试脚手架**：
   里面写死了网名（`clk_IBUF_BUFG` / `i_out[*]` …），设计一改就对不上，
   还会让 `opt_design` 多花几分钟、多占十几块 BRAM。
   **调试结束就整段删掉再提交**（s01 的 `nco.xdc` 现在就是干净的；
   s02 的 `mixer.xdc` 里还留着，属于待清理项）。
6. **两台机器都要开 `pull.rebase`**（见下），否则两台机器并发提交时
   `git pull` 的默认行为就是"分叉 + merge"。

### 为什么必须 rebase：分叉不需要谁做错事

**两台机器从同一个基点各自提交，就必然分叉。** 哪怕两边都规规矩矩
`pull → 改 → commit → push`，只要在同一个时间段里都提交过，后 push 的那台
就会遇到 non-fast-forward。这时 git 只给两个选择：

| pull 的方式 | 结果 | 代价 |
|---|---|---|
| `git pull --rebase` | 自己的提交被重放到远端最新之上 → **线性** | 自己的提交哈希会变（单人用，无所谓） |
| `git pull`（默认） | 生成 merge 提交 → **图上分叉** | 见下 |

本仓库**真的发生过一次**：`45eccaa`（2026-10-15，Stage 0 收尾），
一边 2 个提交（logs）、一边 3 个提交（docs），分叉了 5 个提交才被 merge 掉。

分叉的真实代价不是图难看，而是**那几天两台机器手上的代码不是同一份** ——
你可能拿着一份不含最新 RTL 改动的代码去综合，然后对着"明明改了却没生效"查半天。

### Windows 那台机器要做的一次性设置

```powershell
git remote -v                        # 先确认 origin 指向 gitee
git remote remove github             # 之前加过 github 就删掉（只删本地引用，不动远端仓库）
git config pull.rebase true          # pull 默认走 rebase，不再产生 merge 提交
git config rebase.autoStash true     # 有未提交改动时自动 stash，rebase 完再放回
```

> `git config` 存在 `.git/config` 里，**不进版本库**，所以两台机器各设一次。
> 换机器/重新 clone 之后要重设。

## 编码规范

- **Verilog-2001**（`iverilog -g2005`）。除非 testbench 里明确需要，不用 SystemVerilog 语法。
  - 用 `wire` / `reg`，不用 `logic`。
  - 用 `always @(posedge clk or negedge rst_n)` / `always @*`，不用 `always_ff` / `always_comb`。
- 一个文件一个模块，文件名 = 模块名（全小写、下划线分隔）。
- 端口用 ANSI 风格声明。实例化**一律具名连接** `.port(sig)`，禁止位置连接。
- 时钟命名 `clk`（多个时钟加用途后缀，如 `clk_50m`）。
  复位统一 `rst_n`：**低有效、异步复位、同步释放**（用 `rtl/common/reset_sync.v`）。
- 组合逻辑 `always @*` 的每个分支都必须给所有输出赋值，首行写默认值 —— **不允许推断出 latch**。
- 时序逻辑一律非阻塞 `<=`，组合逻辑用阻塞 `=`。
- 参数用 `parameter`，不写魔法数字。位宽显式写全（`1'b0` / `32'd0`），避免隐式截断。
- **跨时钟域必须显式处理**，注释里标注 `// CDC:`，用 `sync_2ff` 或异步 FIFO。
  绝不允许直接跨域采样。
- 模块头部写注释块：功能 / 时钟域 / 延迟多少拍出结果 / 复位值。

## 仿真

> **Windows 侧不跑仿真（2026-10-19 定）。** 这台机器没有 `make` / `iverilog` / `vvp`，
> **永远不要在这里尝试 `make sim` / `make lint`**，也不用每次 `git pull` 后“白跑一次”。
> 仿真验收由 Mac 侧负责；Windows 侧拉完直接进 Vivado 综合/实现/上板。
> 如果 Windows 侧改了 RTL，提交前仍要让 Mac 侧跑一次 `make sim`。

- 仿真器优先级：`iverilog`（默认，4 态、有 X 传播）> `verilator`（lint / SVA）。
  涉及 Vivado IP 行为模型时才考虑 `xsim`。
- 命令：`make sim` / `make sim TB=<路径>` / `make lint` / `make list`。
- testbench 必须：产生时钟与复位、覆盖复位行为、检查边界条件，
  结尾用 `tb_done` 打印 `TEST PASSED` 或 `TEST FAILED: N error(s)`。
- 断言用 `tb/tb_common.vh` 里的 `` `check() `` / `` `check_eq() ``，不要自己另造一套。
  这两个是**宏**（原因见 `docs/进度.md` 的「已知坑 1」：iverilog 把含中文的字符串常量
  赋给向量会损坏字节），所以调用要写反引号，且断言必须**单独成行**，不能写成
  `if (x) `check(...); else ...`。
- 仿真时把时钟频率参数调小（例如 `CLK_HZ = 100`），让仿真几微秒就跑完。
- VCD 波形自动输出到 `build/<tb名>.vcd`。

## 交互偏好

- 用中文回答。
- 解释设计选择，并说明另一种写法会有什么后果。
- 不确定就明说不确定，不要猜。
- 改动涉及多个文件或存在设计选择时，先给方案再动手。
