#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 FIR 的参考向量 —— 逐位精确的 golden vectors。

为什么要有这个脚本：
    和 s02 的 gen_mixer_vec.py 一样：RTL 里的位宽 / 舍入 / 饱和用肉眼看不出对错，
    而在 testbench 里再用 Verilog 写一遍同样的算术，两边很可能**犯同一个理解错误**
    （s02 就是这么翻车的：参考模型和 RTL 都只翻了 q 路的符号，向量回放全绿）。
    所以这里用 Python（任意精度整数，和 Verilog 的位宽规则完全无关）独立算一遍，
    把 (输入, 期望输出) 落到文件里，testbench 只负责回放 + 比对。

用法：
    python3 scripts/gen_fir_vec.py                       # 生成 -> s03_fir/vec/
    python3 scripts/gen_fir_vec.py --out /tmp/vec
    python3 scripts/gen_fir_vec.py --check s03_fir/vec   # 只校验，不写文件

文件格式（$readmemh 直接读，空格分隔的 32 位十六进制字）：
    第 1 行  F12C0DE1      哨兵：TB 用它确认"文件真的读进来了"
    第 2 行  场景数（4）
    第 3 行  每场景样本数（512）
    第 4 行  数据行数（2048）
    第 5 行  IW
    第 6 行  OW
    第 7 行  SHIFT
    第 8 行  ROUND
    第 9 行  系数校验和（32 位滚动和，见 coef_checksum）
    之后 2048 行，每行 2 个字： x_in y_out
    所有字都是 **32 位补码的原始位模式**（负数写成 FFFFFFFF 那样的形式），
    TB 按各自的位宽取低位并做符号扩展。

为什么头里有 IW/OW/SHIFT/ROUND/系数校验和：
    向量必须和 RTL 的参数、以及 coef.mem **成对**。只改 RTL 参数不重新生成向量，
    仿真会失败得莫名其妙；改了 coef.mem 不重新生成向量，回放会全绿但测试的
    其实是旧滤波器。把参数和系数校验和写进头里，TB 一眼就能查出"谁跟谁没对上"。

四个场景（每个 512 点，TB 里按顺序回放）：
    0 impulse   单点冲激 2047 → 直接看冲激响应
    1 step      直流 1000 → 看直流增益（应该逐位恢复 1000）
    2 tones     通带 0.05 + 阻带 0.30 两个单音叠加 → 看低通到底有没有滤掉高频
    3 random    满量程随机 → 覆盖面最广，抓位宽/符号扩展/舍入的错
"""

import argparse
import math
import os
import random
import sys

FK = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(FK)
DEFAULT_OUT = os.path.join(REPO, "s03_fir", "vec")
DEFAULT_COEF = os.path.join(REPO, "s03_fir", "lut", "coef.mem")

SENTINEL = 0xF12C0DE1      # 32 位，写成十六进制一眼能认出来
NSCEN = 4
NSAMP = 512
SEED = 20261018

# 场景 2 的两个单音：归一化到采样率
TONE_PB = 0.05
TONE_SB = 0.30
TONE_AMP = 900


def read_coef(path, cw):
    """读 .mem 系数文件，返回有符号整数列表（CW 位补码）。"""
    q = []
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            v = int(line, 16)
            if v & (1 << (cw - 1)):
                v -= (1 << cw)
            q.append(v)
    if not q:
        raise ValueError("%s 里没有读到系数" % path)
    return q


def coef_checksum(coef):
    """32 位滚动校验和：h = h*33 + 系数低 16 位。

    和 RTL 无关、和 Python 版本无关，只用来保证"向量文件对应的就是这份系数"。
    不是密码学哈希，碰撞概率对本用途来说足够低。
    """
    h = 0x12345678
    for c in coef:
        h = (h * 33 + (c & 0xFFFF)) & 0xFFFFFFFF
    return h


def to_iw(x, iw):
    """把整数夹到 IW 位补码范围（生成测试输入时用）。"""
    lo = -(1 << (iw - 1))
    hi = (1 << (iw - 1)) - 1
    return max(lo, min(hi, int(x)))


def gen_inputs(iw, nsamp):
    """返回 4 个长度为 nsamp 的输入序列。"""
    lo = -(1 << (iw - 1))
    hi = (1 << (iw - 1)) - 1

    impulse = [0] * nsamp
    impulse[0] = hi

    step = [1000] * nsamp

    tones = []
    for n in range(nsamp):
        v = (TONE_AMP * math.sin(2.0 * math.pi * TONE_PB * n)
             + TONE_AMP * math.sin(2.0 * math.pi * TONE_SB * n))
        tones.append(to_iw(round(v), iw))

    rng = random.Random(SEED)
    rnd = [rng.randint(lo, hi) for _ in range(nsamp)]

    return [impulse, step, tones, rnd]


def fir_model(xs, coef, shift, rnd_flag, ow):
    """逐位精确的参考模型：全精度卷积 + 舍入 + 算术右移 + 饱和。

    RTL 用的是"对称预加再乘"的等价形式，但整数运算下
        c*(a+b) == c*a + c*b
    严格成立，所以这里直接写卷积，和 RTL 的流水线结构无关。
    """
    n = len(coef)
    ow_lo = -(1 << (ow - 1))
    ow_hi = (1 << (ow - 1)) - 1
    out = []
    for i in range(len(xs)):
        acc = 0
        for k in range(n):
            if i - k >= 0:
                acc += coef[k] * xs[i - k]
        if rnd_flag and shift > 0:
            acc += 1 << (shift - 1)       # 加半个 LSB
        acc >>= shift                     # Python 的 >> 就是向 -inf 取整
        out.append(max(ow_lo, min(ow_hi, acc)))
    return out


def render_word(v):
    """32 位补码的十六进制（8 个字符）。"""
    return "%08X" % (v & 0xFFFFFFFF)


def build(coef, iw, ow, shift, rnd_flag, nsamp, nscen):
    """返回文件文本 + 各场景的输入/输出（打印统计用）。"""
    inputs = gen_inputs(iw, nsamp)
    outputs = [fir_model(x, coef, shift, rnd_flag, ow) for x in inputs]

    lines = []
    lines.append(render_word(SENTINEL))
    lines.append(render_word(nscen))
    lines.append(render_word(nsamp))
    lines.append(render_word(nscen * nsamp))
    lines.append(render_word(iw))
    lines.append(render_word(ow))
    lines.append(render_word(shift))
    lines.append(render_word(rnd_flag))
    lines.append(render_word(coef_checksum(coef)))
    for x, y in zip(inputs, outputs):
        for a, b in zip(x, y):
            lines.append("%s %s" % (render_word(a), render_word(b)))
    return "".join(line + "\n" for line in lines), inputs, outputs


def dft_mag(sig, freq):
    """单频点 DFT 幅度（只用来打印统计，不参与期望值）。"""
    re = 0.0
    im = 0.0
    for n, v in enumerate(sig):
        ang = -2.0 * math.pi * freq * n
        re += v * math.cos(ang)
        im += v * math.sin(ang)
    return math.hypot(re, im) / max(len(sig), 1)


def print_stats(inputs, outputs, coef, shift, ow):
    print("  系数：N = %d，和 = %d，缩放 = 2^%d" % (len(coef), sum(coef), shift))
    names = ["impulse", "step", "tones", "random"]
    for name, x, y in zip(names, inputs, outputs):
        clipped = sum(1 for v in y if v >= (1 << (ow - 1)) - 1 or v <= -(1 << (ow - 1)))
        print("  %-8s 输入 [%6d, %6d]  输出 [%6d, %6d]  贴边 %d 点"
              % (name, min(x), max(x), min(y), max(y), clipped))

    # 场景 2 的频域证据：通带单音留下、阻带单音被压掉
    x = inputs[2]
    y = outputs[2]
    tail = slice(100, len(y))       # 跳过滤波器建立时间
    xpb = dft_mag(x[tail], TONE_PB)
    xsb = dft_mag(x[tail], TONE_SB)
    ypb = dft_mag(y[tail], TONE_PB)
    ysb = dft_mag(y[tail], TONE_SB)
    print("  tones   通带 %.3f → %.3f（%.2f dB），阻带 %.3f → %.3f（%.2f dB）"
          % (xpb, ypb, 20.0 * math.log10(max(ypb, 1e-12) / max(xpb, 1e-12)),
             xsb, ysb, 20.0 * math.log10(max(ysb, 1e-12) / max(xsb, 1e-12))))


def data_lines(text):
    """取"数据行"：忽略 CR、空行、行尾有无换行（只用于 --check）。"""
    return [line.strip() for line in text.replace("\r\n", "\n").split("\n") if line.strip()]


def check_file(text, out_dir):
    path = os.path.join(out_dir, "fir_vec.txt")
    if not os.path.isfile(path):
        print("  [FAIL] 找不到 %s" % path)
        return 1
    with open(path, "r") as fh:
        got = fh.read()
    if got == text:
        print("  [PASS] %s 与生成器一致" % path)
        return 0
    if data_lines(got) == data_lines(text):
        print("  [PASS] %s 数据一致（行尾/CRLF 与生成器不同，不影响读表）" % path)
        return 0
    print("  [FAIL] %s 与生成器不一致（文件被改过？需重新生成）" % path)
    return 1


def write_file(text, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "fir_vec.txt")
    with open(path, "w", newline="\n") as fh:
        fh.write(text)
    print("  写入 %s（%d 行）" % (path, text.count("\n")))


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="生成 FIR 的 Python 参考向量（$readmemh 格式）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--coef", default=DEFAULT_COEF, help="系数 .mem 文件")
    ap.add_argument("--cw", type=int, default=16, help="系数位宽（和 coef.mem 一致）")
    ap.add_argument("--iw", type=int, default=12, help="输入位宽")
    ap.add_argument("--ow", type=int, default=13, help="输出位宽")
    ap.add_argument("--shift", type=int, default=15, help="输出右移位数")
    ap.add_argument("--round", type=int, default=1, choices=[0, 1], help="1=四舍五入")
    ap.add_argument("--samples", type=int, default=NSAMP, help="每个场景的样本数")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录")
    ap.add_argument("--check", metavar="DIR", default=None,
                    help="只校验 DIR 里已有的 fir_vec.txt，不写入")
    args = ap.parse_args(argv)

    coef = read_coef(args.coef, args.cw)
    text, inputs, outputs = build(coef, args.iw, args.ow, args.shift,
                                  args.round, args.samples, NSCEN)

    print("FIR 参考向量：%d 个场景 × %d 样本，IW=%d OW=%d SHIFT=%d ROUND=%d"
          % (NSCEN, args.samples, args.iw, args.ow, args.shift, args.round))
    print_stats(inputs, outputs, coef, args.shift, args.ow)

    if args.check is not None:
        bad = check_file(text, args.check)
        print("结果：%s" % ("全部一致" if bad == 0 else "不一致"))
        return bad

    write_file(text, args.out)
    print("完成。TB 里用 $readmemh({`VECDIR, \"fir_vec.txt\"}, vec) 读，"
          "数组长度必须 = 9 + 2*场景数*样本数。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
