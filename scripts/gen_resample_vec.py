#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 s04 插值 / 抽取 / 级联的参考向量 —— 逐位精确的 golden vectors。

为什么要有这个脚本：
    和 s02 / s03 一样：RTL 的位宽、舍入、饱和、相位对齐用肉眼看不出对错。
    这里用 Python 任意精度整数独立算一遍，TB 只负责回放 + 比对。

    s04 比前几个 stage 多一个**相位**维度：插值一对输出 (y_e, y_o) 对应一个输入，
    抽取一对输入 (x_e, x_o) 对应一个输出。所以模型里必须写清"哪个下标配哪一路"，
    这正是最容易错的地方（错一个下标，波形只是"有点毛刺"）。

用法：
    python3 scripts/gen_resample_vec.py                     # 生成 -> s04_resample/vec/
    python3 scripts/gen_resample_vec.py --out /tmp/vec
    python3 scripts/gen_resample_vec.py --check s04_resample/vec   # 只校验，不写文件

输出三个文件（都是 $readmemh 格式，32 位十六进制字，空格分隔）：
    interp_vec.txt   每行 3 个字： x_in   y_e   y_o
    decim_vec.txt    每行 3 个字： x_e    x_o   y_out
    cascade_vec.txt  每行 2 个字： x_in   y_out（interp2 → decim2 串起来）

文件头（10 个 32 位字，TB 先对一遍再回放）：
    1 哨兵 0xF04C0DE1      确认文件真的读进来了
    2 场景数（4）
    3 每场景样本数（512）
    4 数据行数（2048）
    5 IW
    6 OW
    7 SHIFT
    8 ROUND
    9 系数校验和（32 位滚动和，算法和 s03 相同）
   10 LAT（输入到输出的拍数：interp/decim = 4，cascade = 8）

四个场景（每个 512 点）：
    0 impulse   单点冲激 2047        → 直接看冲激响应 / 两相的相位关系
    1 step      直流 1000            → 看直流增益（应该逐位恢复 1000）
    2 tones     两个单音叠加         → 看通带 / 阻带（抽取场景专门放一个 0.4 的混叠音）
    3 random    满量程随机           → 覆盖面最广，抓位宽 / 符号 / 舍入

为什么抽取场景的 tones 是 0.05 + 0.40：
    抽取的输入在 2Fs 上。0.40（相对 2Fs）落在半带阻带 [0.30, 0.50] 里，
    抽取后它会混叠到 0.20 附近 —— 这正是"抽取前必须抗混叠"的证据。
    interp 场景则用 0.05 + 0.20（相对输入 Fs），都在通带内，
    用来验证"插值后的两相拼起来仍然是一条干净的正弦"（靠向量逐位比对）。
"""

import argparse
import math
import os
import random
import sys

FK = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(FK)
DEFAULT_OUT = os.path.join(REPO, "s04_resample", "vec")
DEFAULT_COEF = os.path.join(REPO, "s04_resample", "lut", "hb_odd.mem")

SENTINEL = 0xF04C0DE1
NSCEN = 4
NSAMP = 512
SEED = 20261019

# 默认参数（必须和 tb_interp2.v / tb_decim2.v / tb_resample_cascade.v 一致）
IW = 12
OW = 13
CW = 16
SHIFT_INTERP = 14      # CW-2：插值要补 ×2
SHIFT_DECIM = 15       # CW-1
ROUND = 1
LAT_INTERP = 4
LAT_DECIM = 4
LAT_CASCADE = 8        # interp2 的 4 拍 + decim2 的 4 拍

# 场景 2 的单音（归一化到各自的输入采样率）
TONE_A = 0.05
TONE_B_INTERP = 0.20
TONE_B_DECIM = 0.40
TONE_AMP = 900


# ── 表 / 定点工具 ───────────────────────────────────────────────────────────

def read_coef(path, cw):
    """读 .mem 系数文件，返回有符号整数列表（cw 位补码）。"""
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
    """32 位滚动校验和（和 s03 的 gen_fir_vec.py 同算法）。"""
    h = 0x12345678
    for c in coef:
        h = (h * 33 + (c & 0xFFFF)) & 0xFFFFFFFF
    return h


def sat(v, ow):
    lo = -(1 << (ow - 1))
    hi = (1 << (ow - 1)) - 1
    return max(lo, min(hi, v))


def rshift(acc, shift, rnd):
    """算术右移；rnd=1 时先加半个 LSB。

    Python 的 >> 对负数是**向下取整**（-1 >> 1 = -1），
    和 Verilog 的 >>> 对 signed 的行为一致 —— 这一点必须确认，否则负数会差 1。
    """
    if rnd and shift > 0:
        acc += 1 << (shift - 1)
    return acc >> shift


def to_iw(x, iw):
    return sat(int(x), iw)


# ── 参考模型（和 RTL 的流水线结构无关，只按定义算）────────────────────────

def interp_model(xs, coef, cw, shift, rnd, ow):
    """2× 插值：返回 (y_e 列表, y_o 列表)。

        y_e[n] = x[n - K/2]
        y_o[n] = ( Σ_i coef[i]·x[n-i] ) >>> shift      （shift = CW-2）
    """
    k = len(coef)
    half = k // 2
    ye, yo = [], []
    for n in range(len(xs)):
        ye.append(sat(xs[n - half] if n >= half else 0, ow))
        acc = 0
        for i in range(k):
            if n - i >= 0:
                acc += coef[i] * xs[n - i]
        yo.append(sat(rshift(acc, shift, rnd), ow))
    return ye, yo


def decim_model(xe, xo, coef, cw, shift, rnd, ow):
    """2× 抽取：

        y[n] = ( 2^(CW-2)·x_e[n-K/2] + Σ_i coef[i]·x_o[n-1-i] ) >>> shift
    """
    k = len(coef)
    half = k // 2
    half_coef = 1 << (cw - 2)        # Q1.15 里的 0.5
    ys = []
    for n in range(len(xe)):
        acc = 0
        if n - half >= 0:
            acc += half_coef * xe[n - half]
        for i in range(k):
            j = n - 1 - i
            if j >= 0:
                acc += coef[i] * xo[j]
        ys.append(sat(rshift(acc, shift, rnd), ow))
    return ys


# ── 输入场景 ────────────────────────────────────────────────────────────────

def gen_scenarios(nsamp, kind):
    """返回 4 个长度为 nsamp 的序列。

    kind = "single"（插值：一串 x）或 "pair"（抽取：u 在 2Fs 上，拆成 x_e/x_o）。
    """
    lo = -(1 << (IW - 1))
    hi = (1 << (IW - 1)) - 1

    impulse = [0] * nsamp
    impulse[0] = hi

    step = [1000] * nsamp

    tones = []
    for n in range(nsamp):
        if kind == "single":
            v = (TONE_AMP * math.sin(2.0 * math.pi * TONE_A * n)
                 + TONE_AMP * math.sin(2.0 * math.pi * TONE_B_INTERP * n))
        else:
            # 抽取的输入是 2Fs 上的流：下标 n 就是 2Fs 的采样点
            v = (TONE_AMP * math.sin(2.0 * math.pi * TONE_A * n)
                 + TONE_AMP * math.sin(2.0 * math.pi * TONE_B_DECIM * n))
        tones.append(to_iw(round(v), IW))

    rng = random.Random(SEED)
    rnd = [rng.randint(lo, hi) for _ in range(nsamp)]

    return [impulse, step, tones, rnd]


# ── 文件渲染 ────────────────────────────────────────────────────────────────

def word(v):
    return "%08X" % (v & 0xFFFFFFFF)


def render_header(nscen, nsamp, rows, iw, ow, shift, rnd, csum, lat):
    vals = [SENTINEL, nscen, nsamp, rows, iw, ow, shift, rnd, csum, lat]
    return "".join(word(v) + "\n" for v in vals)


def render_rows(rows, nwords):
    out = []
    for r in rows:
        assert len(r) == nwords, "每行必须恰好 %d 个字" % nwords
        out.append(" ".join(word(v) for v in r) + "\n")
    return "".join(out)


def build_files(coef, cw):
    """返回 {文件名: 文本}，以及每个文件的统计信息。"""
    k = len(coef)
    csum = coef_checksum(coef)
    stats = {}

    # ── 插值 ────────────────────────────────────────────────────────
    scen = gen_scenarios(NSAMP, "single")
    rows = []
    for xs in scen:
        ye, yo = interp_model(xs, coef, cw, SHIFT_INTERP, ROUND, OW)
        for n in range(NSAMP):
            rows.append([xs[n], ye[n], yo[n]])
    files = {}
    files["interp_vec.txt"] = (
        render_header(NSCEN, NSAMP, NSCEN * NSAMP,
                      IW, OW, SHIFT_INTERP, ROUND, csum, LAT_INTERP)
        + render_rows(rows, 3))

    # ── 抽取 ────────────────────────────────────────────────────────
    # u 是 2Fs 上的流；x_e[n] = u[2n]，x_o[n] = u[2n+1]。
    # 每个场景要 2*NSAMP 个 u 样本才能凑出 NSAMP 对。
    scen = gen_scenarios(2 * NSAMP, "pair")
    rows = []
    for u in scen:
        xe = [u[2 * n] for n in range(NSAMP)]
        xo = [u[2 * n + 1] for n in range(NSAMP)]
        ys = decim_model(xe, xo, coef, cw, SHIFT_DECIM, ROUND, OW)
        for n in range(NSAMP):
            rows.append([xe[n], xo[n], ys[n]])
    files["decim_vec.txt"] = (
        render_header(NSCEN, NSAMP, NSCEN * NSAMP,
                      IW, OW, SHIFT_DECIM, ROUND, csum, LAT_DECIM)
        + render_rows(rows, 3))

    # ── 级联（interp2 → decim2）─────────────────────────────────────
    # 级联时 decim2 的 IW = interp2 的 OW = 13（不能截回 12！），输出 OW=14。
    # 这里把 13 位中间结果原样喂给抽取模型，和 RTL 的连线一一对应。
    OW_CAS = OW + 1
    scen = gen_scenarios(NSAMP, "single")
    rows = []
    for xs in scen:
        ye, yo = interp_model(xs, coef, cw, SHIFT_INTERP, ROUND, OW)
        ys = decim_model(ye, yo, coef, cw, SHIFT_DECIM, ROUND, OW_CAS)
        for n in range(NSAMP):
            rows.append([xs[n], ys[n]])
        # 统计"级联 ≈ 延迟"的误差，给 TB 的性质断言定阈值
        err = max(abs(ys[n] - (xs[n - k] if n >= k else 0)) for n in range(NSAMP))
        stats.setdefault("cascade_delay_err", []).append(err)
    files["cascade_vec.txt"] = (
        render_header(NSCEN, NSAMP, NSCEN * NSAMP,
                      IW, OW_CAS, SHIFT_DECIM, ROUND, csum, LAT_CASCADE)
        + render_rows(rows, 2))

    stats["k"] = k
    stats["ow_cas"] = OW_CAS
    return files, stats


def write_files(files, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name, text in sorted(files.items()):
        path = os.path.join(out_dir, name)
        with open(path, "w", newline="\n") as fh:
            fh.write(text)
        print("  写入 %s（%d 个字）" % (path, text.count("\n")))


def data_lines(text):
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
            print("  [PASS] %s 数据一致（行尾/CRLF 不同，不影响读表）" % path)
        else:
            print("  [FAIL] %s 与生成器不一致（文件被改过？需重新生成）" % path)
            bad += 1
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="生成 s04 插值/抽取/级联的参考向量",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录")
    ap.add_argument("--coef", default=DEFAULT_COEF, help="系数文件（hb_odd.mem）")
    ap.add_argument("--cw", type=int, default=CW, help="系数位宽")
    ap.add_argument("--check", metavar="DIR", default=None,
                    help="只校验 DIR 里已有的文件，不写入")
    args = ap.parse_args(argv)

    coef = read_coef(args.coef, args.cw)
    if len(coef) != 30:
        raise SystemExit("系数表有 %d 行，默认设计应该是 30（N=61）；"
                         "换了抽头数就要同步改 TB 的 N 参数" % len(coef))
    files, stats = build_files(coef, args.cw)

    print("参考向量（N=%d, CW=%d, IW=%d, OW=%d, SHIFT=%d/%d, ROUND=%d）"
          % (2 * stats["k"] + 1, args.cw, IW, OW, SHIFT_INTERP, SHIFT_DECIM, ROUND))
    print("  级联输出位宽 OW = %d（decim2 的 IW 必须 = interp2 的 OW = %d）"
          % (stats["ow_cas"], OW))
    print("  级联 ≈ 延迟 30 个输入样本，各场景最大偏差（LSB）："
          + ", ".join("%d" % e for e in stats["cascade_delay_err"]))
    print("  （这个数给 tb_resample_cascade.v 的性质断言定阈值；"
          "冲激/直流应该很小，随机场景也不会超过几个 LSB）")

    if args.check is not None:
        print("校验 %s" % args.check)
        bad = check_files(files, args.check)
        if bad:
            print("结果：%d 个文件不一致" % bad)
            return 1
        print("结果：全部一致")
        return 0

    write_files(files, args.out)
    print("完成。TB 用 VECDIR 找这些文件（sim.sh 会自动传绝对路径）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
