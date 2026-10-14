# Stage 1.2 — PWM 调光

## 目标

一个参数化 PWM 发生器，用占空比控制 LED 亮度。

## 要求

| 参数 / 端口 | 含义 |
|---|---|
| `CLK_HZ` | 输入时钟频率 |
| `PWM_HZ` | PWM 频率（例如 1 kHz，要远高于人眼闪烁感知） |
| `BITS` | 分辨率位数，占空比分成 `2^BITS` 档 |
| `duty[BITS-1:0]` | 占空比输入，0 ~ 2^BITS-1 |
| `pwm_out` | 输出 |

## 验收标准

- [ ] `duty = 0` 时 `pwm_out` 恒为 0
- [ ] `duty = 2^BITS - 1` 时 `pwm_out` 高电平占满整个周期
- [ ] `duty = 2^(BITS-1)` 时高电平周期数 ≈ 一半（允许 ±1 拍误差）
- [ ] PWM 周期 = `CLK_HZ / PWM_HZ` 拍
- [ ] 用 `check_eq` 精确验证高电平拍的个数
- [ ] `make lint` 无警告

## 提示

经典写法：一个自由运行的计数器 `cnt` 从 0 数到 `PERIOD-1`，
然后 `assign pwm_out = (cnt < duty);`

**要注意的坑：**

- `duty` 的位宽和 `cnt` 的位宽要能比较，别让 Verilog 悄悄扩展成错误宽度。
- `duty` 是异步输入（可能来自寄存器或外部），**如果来自别的时钟域，必须先同步**。
- 边界：`cnt < duty` 在 `duty = 0` 时永远为假 → 恒 0 ✓；
  `duty = 2^BITS - 1` 时 `cnt` 最大只到 `PERIOD-1`，
  如果 `PERIOD = 2^BITS` 则恒真 → 恒 1 ✓。
  想清楚这个边界关系再动手。
