#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 2× 半带（halfband）滤波器的系数表 —— s04 插值 / 抽取共用一张表。

为什么要有这个脚本：
    和 s03 的 gen_fir_coef.py 一样：Vivado 综合不了浮点设计，系数必须是常量。
    这里额外多一件事：**半带的结构约束必须在生成阶段就卡死**，不能靠 RTL 去保证。

半带到底是什么（这个 stage 的核心）：
    一个奇数长度、截止频率恰好为 1/4 采样率（归一化 0.25）的线性相位低通，
    如果用理想 sinc 设计，偶数偏移上的抽头**天生就是 0**：

        h[M] = 0.5        （M = (N-1)/2，中心抽头）
        h[k] = 0          （k-M 是偶数且 k != M）
        h[k] 非零         （k-M 是奇数，共 K = (N-1)/2 个）

    也就是说 61 抽头的滤波器只有 **30 个非零系数、15 个乘法器**（对称折叠后），
    而且其中一路（偶相）只剩一个 0.5 的直通 —— 这就是"半带白送一半乘法器"。

它和 2× 插值/抽取的关系（写 RTL 之前必须先看懂这两行）：
    把 H(z) 按 2 拆成两个多相分量：H(z) = E(z^2) + z^-1 O(z^2)。
    半带给的是  E(z) = 0.5·z^-M/2   —— 偶相就是一个延迟 + 乘 0.5。

    插值（x 在低速率上，y 在 2 倍速率上）：
        y[2n]   = 2·E(z)·x[n]   = x[n-M/2]            ← 恒等！连乘法器都不用
        y[2n+1] = 2·O(z)·x[n]   = Σ o[i]·x[n-i] >> 14  ← 15 个乘法器
    抽取（x 在 2 倍速率上，y 在低速率上）：
        y[n] = E(z)·x[2n] + O(z)·x[2n-1]
             = ( 2^14·x_e[n-M/2] + Σ o[i]·x_o[n-1-i] ) >> 15

    ⚠️ 插值的移位是 **CW-2（14）**、抽取是 **CW-1（15）**，差的那一位就是
       "插值要乘 2"（零插值之后信号功率掉一半，必须补回来）。
       这不是随手写的魔数，见 s04_resample/TASK_s04_resample.md 的「为什么插值少移一位」。

用法：
    python3 scripts/gen_hb_coef.py                       # 默认 61 抽头 / Hamming
    python3 scripts/gen_hb_coef.py --taps 45 --window blackman
    python3 scripts/gen_hb_coef.py --check s04_resample/lut   # 只校验，不写文件

输出（写到 --out 目录）：
    hb_odd.mem   主滤波器：K = (N-1)/2 = 30 行，每行 4 个十六进制字符（Q1.15 补码）
                 行序 = h[1], h[3], ..., h[N-2]（奇数下标的原始顺序，对称）
    hb5.mem      2 行：一个 5 抽头"教学小车" [8192, 8192]，和 = 16384。
                 N=5 时半带的奇相归一化后必然是 h[1]=h[3]=0.25，
                 对应插值的"线性内插" (x[n]+x[n-1])/2，手算就能对。

定点约定（和 s03 一样，但目标值不同）：
    系数是 Q1.15，整个滤波器的系数和 = 2^15 = 32768（直流增益 1）。
    半带固定 h[M] = 2^14 = 16384，所以奇数抽头的和必须也 = 16384 = 2^14。
    量化误差全部塞给**离中心最近的那一对抽头**（h[1] / h[N-2]），
    成对修改 → 对称性逐位保持，和精确保持。

检查（每次生成都会打印，`--check` 还会比对文件）：
    ① 偶数偏移上确实只有中心抽头非零（半带结构成立）
    ② 奇数抽头严格对称 h_odd[i] == h_odd[K-1-i]
    ③ 2*sum(奇数抽头) + 中心 = 32768（直流增益精确为 1）
    ④ 幅度互补 A(f) + A(0.5-f) = 1（半带的定义性质。注意它是**结构**性质：
       只要偶相只有中心抽头，它对任意奇数抽头都严格成立，量化不会破坏它）
    ⑤ 通带纹波 / 阻带衰减
"""

import argparse
import math
import os
import sys

FK = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(FK)
DEFAULT_OUT = os.path.join(REPO, "s04_resample", "lut")

# 5 抽头教学小车：半带在 N=5 时的唯一解（奇相归一化后）
HB5 = [8192, 8192]


def quantize_sym(value, scale):
    """四舍五入（0.5 远离零），返回 int。

    不用 Python 内置 round()：它是银行家舍入（round(0.5) == 0），
    会在对称的抽头上产生 1 LSB 的不对称。
    """
    x = value * scale
    if x >= 0.0:
        return int(math.floor(x + 0.5))
    return -int(math.floor(-x + 0.5))


def sinc(x):
    """归一化 sinc：sin(pi*x)/(pi*x)，x=0 时为 1。"""
    if abs(x) < 1e-15:
        return 1.0
    return math.sin(math.pi * x) / (math.pi * x)


def window_value(n, taps, kind):
    """窗函数。taps 是总长度，n 从 0 到 taps-1。"""
    if kind == "rect":
        return 1.0
    if kind == "hann":
        return 0.5 - 0.5 * math.cos(2.0 * math.pi * n / (taps - 1))
    if kind == "hamming":
        return 0.54 - 0.46 * math.cos(2.0 * math.pi * n / (taps - 1))
    if kind == "blackman":
        return (0.42 - 0.5 * math.cos(2.0 * math.pi * n / (taps - 1))
                + 0.08 * math.cos(4.0 * math.pi * n / (taps - 1)))
    raise ValueError("未知窗函数: %s" % kind)


def design_halfband(taps, kind):
    """返回长度为 taps 的浮点半带系数（和 = 1，中心 = 0.5）。

    截止频率固定为 0.25（1/4 采样率），这是半带的定义，**不是**可调参数。
    理想低通 h[n] = 2*fc*sinc(2*fc*(n-M))，fc=0.25 → 0.5*sinc(0.5*(n-M))。
    窗函数在 k-M 为偶数处乘的是 0（sinc 的零点），所以零抽头保持为零；
    中心处窗值 = 1，所以中心恰好是 0.5。
    """
    if taps % 4 != 1:
        raise ValueError(
            "半带要求 taps = 4q+1（这样中心下标 M=(taps-1)/2 才是偶数，"
            "偶相才只剩一个抽头），收到 %d" % taps)
    m = (taps - 1) // 2
    assert m % 2 == 0
    h = [0.5 * sinc(0.5 * (k - m)) * window_value(k, taps, kind)
         for k in range(taps)]
    # ① 半带结构自检：偶数偏移上必须是 0（浮点残差 ~1e-17，量化后必为 0）
    for k in range(taps):
        if (k - m) % 2 == 0 and k != m and abs(h[k]) > 1e-12:
            raise ValueError("k=%d 处偶数偏移抽头不是 0（%.3e）—— 设计有问题" % (k, h[k]))
    return h


def odd_taps(h):
    """返回奇数下标的抽头 h[1], h[3], ..., h[N-2]（长度 K=(N-1)/2）。"""
    return [h[k] for k in range(1, len(h), 2)]


def quantize_halfband(h, cw):
    """把浮点半带量化为整数表。

    返回 (hb_odd, center, info)：
        hb_odd  K 个整数（Q1.(cw-1) 补码），对称
        center  中心抽头 = 2^(cw-2)（Q1.15 里的 0.5）
    """
    taps = len(h)
    k = (taps - 1) // 2          # 奇数抽头个数
    scale = float(1 << (cw - 1))
    center = 1 << (cw - 2)       # 0.5
    pairs = k // 2               # 对称对的数量（k 恒为偶数：taps=4q+1 → K=2q）

    # 先把奇数抽头整体缩放，让它们的**浮点**和恰好 = 0.25（= 0.5 * 1/2）。
    # 窗函数会把理想低通的直流增益压低一点点，不补偿的话量化残差会全堆到
    # 某个小抽头上（第一版踩过：残差 -14 落在 h[1] 上，16 变 2）。
    odd_f = [h[2 * i + 1] for i in range(pairs)]
    lam = 0.25 / sum(odd_f)

    # 只量化前半（每对只存一个），再镜像 → 对称性逐位精确
    q = [quantize_sym(v * lam, scale) for v in odd_f]
    # 前半对的和目标：1.0 对应 2^(cw-1)，奇数抽头总和 0.5 → 2^(cw-2)，
    # 前半（每对只算一个）是它的一半 → 0.25 * 2^(cw-1) = 2^(cw-3) = 8192。
    target = 1 << (cw - 3)
    residual = target - sum(q)

    # 量化残差（只剩 ±几个 LSB 的舍入噪声）给**离中心最近的那一对**：
    # 它们本来就是最大的奇数抽头，相对误差最小；成对修改 → 对称性逐位保持。
    q[pairs - 1] += residual

    vmax = (1 << (cw - 1)) - 1
    for i, v in enumerate(q):
        if v < -vmax - 1 or v > vmax:
            raise ValueError("第 %d 对系数 %d 超出 %d 位补码范围" % (i, v, cw))

    # 镜像展开：h_odd[i] = q[min(i, K-1-i)]
    hb_odd = [q[min(i, k - 1 - i)] for i in range(k)]

    # ② 对称 ③ 和
    for i in range(k // 2):
        if hb_odd[i] != hb_odd[k - 1 - i]:
            raise ValueError("第 %d 对不对称" % i)
    total = sum(hb_odd) + center
    if total != (1 << (cw - 1)):
        raise ValueError("系数和 = %d，不是 2^%d" % (total, cw - 1))

    return hb_odd, center, dict(pairs=pairs, residual=residual)


def freq_response(hb_odd, center, cw, freq):
    """零相位幅度响应 A(f) = Σ h[k]·cos(2πf(k-M)) / 2^(CW-1)。

    用整数表重建完整的 2K+1 个抽头（偶相只有中心），所以 A(f) 就是
    "去掉线性相位之后"的实幅度 —— 半带的互补性质要用这个量来验。
    """
    k = len(hb_odd)
    m = k                          # 中心下标 = (N-1)/2 = K
    scale = float(1 << (cw - 1))
    acc = float(center)            # 中心抽头：偏移 0，cos = 1
    for i in range(k):
        off = (2 * i + 1) - m      # 奇数下标 - 中心
        acc += hb_odd[i] * math.cos(2.0 * math.pi * freq * off)
    return acc / scale


def analyze(hb_odd, center, cw, pb_edge, sb_edge):
    """通带 / 阻带统计 + 半带互补性残差。"""
    step = 0.0005
    pb = []
    f = 0.0
    while f <= pb_edge + 1e-12:
        pb.append(abs(freq_response(hb_odd, center, cw, f)))
        f += step
    sb = []
    f = sb_edge
    while f <= 0.5 + 1e-12:
        sb.append(abs(freq_response(hb_odd, center, cw, f)))
        f += step
    pb_min, pb_max, sb_max = min(pb), max(pb), max(sb)
    ripple_db = 20.0 * math.log10(pb_max / max(pb_min, 1e-15))
    atten_db = -20.0 * math.log10(max(sb_max, 1e-15))

    # ④ 半带定义性质：A(f) + A(0.5-f) = 1（理想情况严格成立）
    comp = 0.0
    f = 0.0
    while f <= 0.25 + 1e-12:
        a = freq_response(hb_odd, center, cw, f)
        b = freq_response(hb_odd, center, cw, 0.5 - f)
        comp = max(comp, abs(a + b - 1.0))
        f += step

    return dict(pb_min=pb_min, pb_max=pb_max, sb_max=sb_max,
                ripple_db=ripple_db, atten_db=atten_db, comp_err=comp)


def render(values, cw):
    """每个系数一行，CW/4 个十六进制字符（补码）。"""
    if cw % 4 != 0:
        raise ValueError("系数位宽必须是 4 的倍数（每行 CW/4 个十六进制字符）")
    digits = cw // 4
    mask = (1 << cw) - 1
    return "".join("%0*X\n" % (digits, v & mask) for v in values)


def build(taps, kind, cw):
    h = design_halfband(taps, kind)
    hb_odd, center, info = quantize_halfband(h, cw)
    return {
        "hb_odd.mem": render(hb_odd, cw),
        "hb5.mem": render(HB5, cw),
    }, hb_odd, center, info


def write_files(files, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name, text in sorted(files.items()):
        path = os.path.join(out_dir, name)
        with open(path, "w", newline="\n") as fh:   # 强制 LF：跨 Mac/Windows
            fh.write(text)
        print("  写入 %s（%d 行）" % (path, text.count("\n")))


def data_lines(text):
    """取数据行：忽略 CR、空行、行尾有无换行（--check 用，同 s03）。"""
    return [line.strip() for line in text.replace("\r\n", "\n").split("\n") if line.strip()]


def check_files(files, out_dir):
    bad = 0
    for name, text in sorted(files.items()):
        path = os.path.join(out_dir, name)
        if not os.path.isfile(path):
            print("  [FAIL] 找不到 %s" % path)
            bad += 1
            continue
        with open(path, "r") as fh:
            got = fh.read()
        if got == text:
            print("  [PASS] %s 与生成器一致" % path)
        elif data_lines(got) == data_lines(text):
            print("  [PASS] %s 数据一致（行尾/CRLF 与生成器不同，不影响读表）" % path)
        else:
            print("  [FAIL] %s 与生成器不一致（文件被改过？需重新生成）" % path)
            bad += 1
    return bad


def print_report(hb_odd, center, cw, taps, kind, pb_edge, sb_edge, info):
    k = len(hb_odd)
    total = sum(hb_odd) + center
    target = 1 << (cw - 1)
    print("  抽头数 N = %d（= 4q+1），窗 = %s，截止固定 0.25（1/4 采样率）"
          % (taps, kind))
    print("  非零抽头 = %d 个（中心 1 + 奇数下标的 %d 个），对称折叠后 **%d 个乘法器**"
          % (k + 1, k, info["pairs"]))
    print("  系数位宽 CW = %d（Q1.%d），中心抽头 = %d（= 0.5）"
          % (cw, cw - 1, center))
    print("  奇数抽头和 = %d（目标 %d），总系数和 = %d（目标 %d，%s）"
          % (sum(hb_odd), 1 << (cw - 2), total, target, "对" if total == target else "❌ 不对"))
    print("  量化残差 %+d LSB 全部给了离中心最近的那一对（h[%d]/h[%d]）"
          % (info["residual"], taps // 2 - 1, taps // 2 + 1))
    a = analyze(hb_odd, center, cw, pb_edge, sb_edge)
    print("  通带 [0, %.3f]：幅度 %.6f .. %.6f，纹波 %.4f dB"
          % (pb_edge, a["pb_min"], a["pb_max"], a["ripple_db"]))
    print("  阻带 [%.3f, 0.5]：最大幅度 %.3e，衰减 %.1f dB"
          % (sb_edge, a["sb_max"], a["atten_db"]))
    print("  半带互补性 max|A(f)+A(0.5-f)-1| = %.2e（结构性质，量化后也应≈0）"
          % a["comp_err"])
    print("  奇数抽头（前 6 个）：" + ", ".join("%d" % v for v in hb_odd[:6]))
    print("  A(0)=%.6f  A(0.25)=%.6f  A(0.5)=%.6f"
          % (freq_response(hb_odd, center, cw, 0.0),
             freq_response(hb_odd, center, cw, 0.25),
             freq_response(hb_odd, center, cw, 0.5)))
    if a["ripple_db"] > 0.1:
        print("  [警告] 通带纹波 > 0.1 dB")
    if a["atten_db"] < 40.0:
        print("  [警告] 阻带衰减 < 40 dB（抽头太少？）")
    if abs(a["comp_err"]) > 1e-3:
        print("  [警告] 半带互补性残差偏大，检查量化和表")
    return a


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="生成 2× 半带滤波器系数（$readmemh 格式）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--taps", type=int, default=61,
                    help="抽头数，必须是 4q+1（中心下标才是偶数）")
    ap.add_argument("--window", default="hamming",
                    choices=["rect", "hann", "hamming", "blackman"], help="窗函数")
    ap.add_argument("--cw", type=int, default=16, help="系数位宽（4 的倍数）")
    ap.add_argument("--pb-edge", type=float, default=0.20,
                    help="通带分析上边界（归一化到滤波器采样率）")
    ap.add_argument("--sb-edge", type=float, default=0.30,
                    help="阻带分析下边界（归一化到滤波器采样率）")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录")
    ap.add_argument("--check", metavar="DIR", default=None,
                    help="只校验 DIR 里已有的文件，不写入")
    args = ap.parse_args(argv)

    files, hb_odd, center, info = build(args.taps, args.window, args.cw)

    if args.check is not None:
        print("校验 %s（N=%d, CW=%d, 窗=%s）" % (args.check, args.taps, args.cw, args.window))
        print_report(hb_odd, center, args.cw, args.taps, args.window,
                     args.pb_edge, args.sb_edge, info)
        bad = check_files(files, args.check)
        if bad:
            print("结果：%d 个文件不一致" % bad)
            return 1
        print("结果：全部一致")
        return 0

    print("设计 2× 半带（N=%d, CW=%d, 窗=%s, 截止=0.25）"
          % (args.taps, args.cw, args.window))
    print_report(hb_odd, center, args.cw, args.taps, args.window,
                 args.pb_edge, args.sb_edge, info)
    write_files(files, args.out)
    print("完成。RTL 用 $readmemh 读 hb_odd.mem；目录由 HB_COEFDIR 给出，"
          "sim.sh 会自动传绝对路径，Vivado 里要配宏（见 constr/resample.xdc）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
