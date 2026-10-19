# Stage 0 — 建立验证闭环 + 点亮 LED

## 这一阶段的真正目标

**不是点亮 LED。** 是建立这三条命令的闭环：

```sh
make sim      # 秒级：编译 + 跑 testbench
make lint     # 秒级：语法与警告检查
make setup    # 一次性：安装仿真器
```

LED 只是用来证明"时钟 → 复位 → 约束 → 仿真 → 综合 → 上板"整条链路是通的。

**为什么先做这个：** 后面每个阶段都靠这套闭环迭代。
如果闭环不牢，所有调试都会退化成"改一改、上板试试"，那是效率最低的学法。

## 验收标准

- [x] `make setup` 成功（装好 iverilog）
- [x] `make sim` 全部通过
- [x] `build/tb_blinky.vcd` 生成，波形里能看到 led 周期翻转
- [x] `make lint` 无警告
- [x] （需要 Windows）Vivado 综合通过
- [x] （需要 Windows）XDC 引脚填对，板子上 LED 真的在闪 ← **2026-10-14 实测：1 Hz 闪烁**
- [x] `docs/进度.md` 更新
- [x] `logs/s00_blinky/` 有综合日志 + 实现日志 + 时序报告 + 资源报告
      （WNS **+16.830 ns**、0 条 CRITICAL WARNING、DRC 0 Errors）

> **这一阶段的意义**：LED 不是目的，**闭环**才是。从 `make sim` 到"板子上灯真的闪"，
> 再到日志回传，整条路都通了 —— 后面每个 stage 都直接复用，不用再摸索工具链。

## 板级参数（全部已确定并上板验证）

- 开发板：正点原子达芬奇 Pro / 板载时钟 **50 MHz**
- 引脚：时钟 **R4** / LED **V9** / 复位 **U7**（低有效）
- Vivado 器件全名：**`xc7a100tfgg484-2`**（100T / fgg484 / -2）

`constr/blinky.xdc` 里已无 TODO。

## 提示

- `DIV = CLK_HZ / (2 * BLINK_HZ)`：计数器数到 `DIV-1` 翻转一次，
  所以完整周期是 `2*DIV` 拍，闪烁频率就是 `BLINK_HZ`。
- testbench 里故意把 `CLK_HZ` 设成 100 而不是 50_000_000，
  仿真几百纳秒就跑完。**参数化就是为了这个。**
- 复位用"异步复位、同步释放"（`rtl/common/reset_sync.v`）。
  真实工程里外部按键要先过这个模块，这个习惯从头就要建立。
