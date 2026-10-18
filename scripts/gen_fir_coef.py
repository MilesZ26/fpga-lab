#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 FIR 低通滤波器的系数表（`$readmemh` 能直接读的十六进制 .mem）。

为什么要有这个脚本：
    Vivado 综合不了 `math.sin` / 浮点运算，FIR 的系数必须是**常量**。
    用 Python 离线把滤波器设计好、量化成定点、写成文本文件，RTL 只负责
    `$readmemh` 读进来 —— 这样仿真和综合用的是**同一份系数**，不会出现
    "仿真对、上板错"。这和 s01 的 NCO 查表是同一套思路。

用法：
    python3 scripts/gen_fir_coef.py                     # 默认 47 抽头 / 归一化截止 0.15
    python3 scripts/gen_fir_coef.py --taps 63 --cutoff 0.1
    python3 scripts/gen_fir_coef.py --check s03_fir/lut # 只校验，不写文件

输出（写到 --out 目录）：
    coef.mem    主滤波器：N 行，每行 CW/4 个十六进制字符（二进制补码）
    coef5.mem   一个 5 抽头的"教学小车"：[1,4,6,4,1]/16，
                系数恰好是 [2048, 8192, 12288, 8192, 2048]、和 = 32768。
                它给 tb_fir.v 做手算边界用例（tie / 饱和）用。

设计方法（为什么是窗函数法）：
    理想低通的冲激响应是 sinc，无限长、非因果。截断到 N 点会引入吉布斯
    振荡（旁瓣大约 -13 dB），所以再乘一个窗（默认 Hamming）把旁瓣压下去。
    这是"教科书里最笨但最容易解释"的设计法：没有迭代、没有优化器，
    每个数字都能手算核对。代价是同样的 N 下过渡带比等波纹（Remez）宽。

定点约定（这是 FIR 位宽设计的核心，和 mixer.v 一致）：
    系数按 Q1.(CW-1) 量化：c_int = round(h * 2**(CW-1))。
    低通滤波器的直流增益是 sum(h) = 1，所以**系数和必须等于 2**(CW-1)**。
    输出 = sum(c_int * x) >> (CW-1)，直流增益正好是 1.0 —— 这比"和 = 2**(CW-1)-1"
    更干净：常数输入经过滤波器后**逐位不变**，测试可以写成严格相等。
    量化后把舍入误差全部塞给中心抽头，使和精确等于 2**(CW-1)；
    对称性保持不变（奇数抽头只动中心，偶数抽头把误差均分给中间两个）。

检查（`--check` / 每次生成都会打印）：
    - 系数严格对称（线性相位）
    - 和 == 2**(CW-1)（直流增益 = 1）
    - 每个系数都在 CW 位补码范围内
    - 通带纹波、阻带衰减（在 --pb-edge / --sb-edge 划定的频带上）
"""

import argparse
import math
import os
import sys

FK = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(FK)
DEFAULT_OUT = os.path.join(REPO, "s03_fir", "lut")

# 5 抽头教学滤波器：[1,4,6,4,1]/16 的 Q15 定点版。
# 和 = 32768，直流增益精确为 1；中心附近的 8192 系数让 tb_fir.v 能构造
# "x=2 时乘积恰好 = 16384 = 半个 LSB" 的舍入 tie 用例。
COEF5 = [2048, 8192, 12288, 8192, 2048]


def quantize_sym(value, scale):
    """四舍五入（0.5 远离零），返回 int。

    不用 Python 内置 round()：它是"银行家舍入"（round(0.5) == 0），
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


def design_lowpass(taps, cutoff, kind):
    """返回长度为 taps、和为 1 的浮点低通系数。

    cutoff 是**归一化**截止频率（相对于采样率 Fs，范围 0..0.5）。
    例如 cutoff=0.15、Fs=50 MHz → 截止 7.5 MHz。
    理想低通 h[n] = 2*fc * sinc(2*fc*(n - M))，M = (taps-1)/2。
    """
    if taps < 3:
        raise ValueError("taps 至少为 3")
    if not 0.0 < cutoff < 0.5:
        raise ValueError("cutoff 必须在 (0, 0.5) 之间（归一化到采样率）")
    m = (taps - 1) / 2.0
    h = [2.0 * cutoff * sinc(2.0 * cutoff * (n - m)) for n in range(taps)]
    h = [h[n] * window_value(n, taps, kind) for n in range(taps)]
    total = sum(h)
    if abs(total) < 1e-12:
        raise ValueError("窗函数把系数压成 0 了，检查参数")
    return [v / total for v in h]


def split_half(taps):
    """返回 (半长, 是否奇数)。奇数抽头时中心抽头单独一个。"""
    half = (taps + 1) // 2          # 0..half-1 是独立的一半（含奇数时的中心）
    odd = (taps % 2) == 1
    return half, odd


def quantize_coefs(h, cw):
    """把浮点系数量化成 CW 位补码，并让和精确等于 2**(CW-1)。

    - 先只算前一半（含奇数时的中心），再镜像到后半 → 严格对称。
    - 量化误差用中心抽头吸收：奇数抽头只动中心；偶数抽头把误差
      均分给中间两个（误差是奇数时会有 1 LSB 的不对称，打印警告）。
    """
    taps = len(h)
    scale = float(1 << (cw - 1))
    target = 1 << (cw - 1)
    half, odd = split_half(taps)
    q = [quantize_sym(h[n], scale) for n in range(half)]

    if odd:
        q = q + list(reversed(q[:-1]))
        delta = target - sum(q)
        q[half - 1] += delta
        if delta != 0:
            print("  [信息] 中心抽头吸收量化误差 %+d LSB" % delta)
    else:
        q = q + list(reversed(q))
        delta = target - sum(q)
        hi = half - 1      # 中间偏左
        lo = half          # 中间偏右
        q[hi] += delta // 2
        q[lo] += delta - delta // 2
        if delta % 2 != 0:
            print("  [警告] 偶数抽头时量化误差为奇数，对称性差 1 LSB")

    vmax = (1 << (cw - 1)) - 1
    for n, v in enumerate(q):
        if v < -vmax - 1 or v > vmax:
            raise ValueError("第 %d 个系数 %d 超出 %d 位补码范围" % (n, v, cw))
    return q


def freq_response(q, cw, freq):
    """在归一化频率 freq 处算复数频响（用 Python 的复数，不依赖 numpy）。

    H(f) = sum_n c[n] * exp(-j*2*pi*f*n) / 2**(CW-1)
    """
    re = 0.0
    im = 0.0
    for n, c in enumerate(q):
        ang = -2.0 * math.pi * freq * n
        re += c * math.cos(ang)
        im += c * math.sin(ang)
    scale = float(1 << (cw - 1))
    return complex(re / scale, im / scale)


def analyze(q, cw, pb_edge, sb_edge):
    """返回通带 / 阻带的幅度统计（dB）。"""
    step = 0.0005
    pb = []
    f = 0.0
    while f <= pb_edge + 1e-12:
        pb.append(abs(freq_response(q, cw, f)))
        f += step
    sb = []
    f = sb_edge
    while f <= 0.5 + 1e-12:
        sb.append(abs(freq_response(q, cw, f)))
        f += step
    pb_min = min(pb)
    pb_max = max(pb)
    sb_max = max(sb)
    ripple_db = 20.0 * math.log10(pb_max / max(pb_min, 1e-15))
    atten_db = -20.0 * math.log10(max(sb_max, 1e-15))
    return dict(pb_min=pb_min, pb_max=pb_max, sb_max=sb_max,
                ripple_db=ripple_db, atten_db=atten_db)


def render(values, cw):
    """每个系数一行，CW/4 个十六进制字符（补码）。"""
    if cw % 4 != 0:
        raise ValueError("系数位宽必须是 4 的倍数（每行 CW/4 个十六进制字符）")
    digits = cw // 4
    mask = (1 << cw) - 1
    return "".join("%0*X\n" % (digits, v & mask) for v in values)


def build(taps, cutoff, kind, cw):
    """返回 {文件名: 文本内容}。"""
    h = design_lowpass(taps, cutoff, kind)
    q = quantize_coefs(h, cw)
    return {
        "coef.mem": render(q, cw),
        "coef5.mem": render(COEF5, cw),
    }, q


def write_files(files, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name, text in sorted(files.items()):
        path = os.path.join(out_dir, name)
        with open(path, "w", newline="\n") as fh:   # 强制 LF：跨 Mac/Windows
            fh.write(text)
        print("  写入 %s（%d 行）" % (path, text.count("\n")))


def data_lines(text):
    """取"数据行"：忽略 CR、空行、行尾有无换行。

    只用于 --check：换行属于排版（Windows 编辑器会改），不影响 $readmemh 读到的数。
    """
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


def print_report(q, cw, taps, cutoff, kind, pb_edge, sb_edge):
    total = sum(q)
    target = 1 << (cw - 1)
    print("  抽头数 N = %d，窗 = %s，归一化截止 = %.4f（Fs 的 %.1f%%）"
          % (taps, kind, cutoff, cutoff * 100.0))
    print("  系数位宽 CW = %d（Q1.%d），缩放 = 2^%d" % (cw, cw - 1, cw - 1))
    print("  系数和 = %d（目标 %d，%s）" % (total, target, "对" if total == target else "❌ 不对"))
    print("  最大系数 = %d，最小系数 = %d，群延迟 = %.1f 个采样"
          % (max(q), min(q), (taps - 1) / 2.0))
    a = analyze(q, cw, pb_edge, sb_edge)
    print("  通带 [0, %.3f]：幅度 %.6f .. %.6f，纹波 %.3f dB"
          % (pb_edge, a["pb_min"], a["pb_max"], a["ripple_db"]))
    print("  阻带 [%.3f, 0.5]：最大幅度 %.3e，衰减 %.1f dB"
          % (sb_edge, a["sb_max"], a["atten_db"]))
    if total != target:
        print("  [警告] 系数和不是 2^(CW-1)，直流增益不是 1.0")
    if a["ripple_db"] > 0.5:
        print("  [警告] 通带纹波 > 0.5 dB")
    if a["atten_db"] < 40.0:
        print("  [警告] 阻带衰减 < 40 dB（抽头太少或过渡带太窄？）")
    print("  首 6 个系数：" + ", ".join("%d" % v for v in q[:6]))
    print("  中心 3 个系数：" + ", ".join("%d" % v for v in q[(taps - 1) // 2 - 1:(taps - 1) // 2 + 2]))
    return a


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="生成 FIR 低通系数表（$readmemh 格式）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--taps", type=int, default=47, help="抽头数（>=3）")
    ap.add_argument("--cutoff", type=float, default=0.15,
                    help="归一化截止频率（0..0.5，相对采样率）")
    ap.add_argument("--window", default="hamming",
                    choices=["rect", "hann", "hamming", "blackman"], help="窗函数")
    ap.add_argument("--cw", type=int, default=16, help="系数位宽（4 的倍数）")
    ap.add_argument("--pb-edge", type=float, default=0.10,
                    help="通带分析上边界（归一化频率）")
    ap.add_argument("--sb-edge", type=float, default=0.20,
                    help="阻带分析下边界（归一化频率）")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录")
    ap.add_argument("--check", metavar="DIR", default=None,
                    help="只校验 DIR 里已有的文件，不写入")
    args = ap.parse_args(argv)

    files, q = build(args.taps, args.cutoff, args.window, args.cw)

    if args.check is not None:
        print("校验 %s（N=%d, CW=%d, 窗=%s, 截止=%.4f）"
              % (args.check, args.taps, args.cw, args.window, args.cutoff))
        print_report(q, args.cw, args.taps, args.cutoff, args.window,
                     args.pb_edge, args.sb_edge)
        bad = check_files(files, args.check)
        if bad:
            print("结果：%d 个文件不一致" % bad)
            return 1
        print("结果：全部一致")
        return 0

    print("设计 FIR 低通（N=%d, CW=%d, 窗=%s, 归一化截止=%.4f）"
          % (args.taps, args.cw, args.window, args.cutoff))
    print_report(q, args.cw, args.taps, args.cutoff, args.window,
                 args.pb_edge, args.sb_edge)
    write_files(files, args.out)
    print("完成。RTL 用 $readmemh 读 coef.mem；路径是相对**仿真/综合的工作目录**，"
          "所以 sim.sh 会传 FIR_COEFDIR，Vivado 里也要配这个宏。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
