#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 s05 DUC / s06 DDC 的参考向量 —— 整条链的逐位 golden vectors。

为什么要有这个脚本
------------------
s05/s06 不是新算法，而是**把 s01~s04 的零件接起来**。集成阶段真正会出错的
不是单个模块的算术（它们各自已经有 TB），而是：

  · 位宽衔接：mixer 出 13 位、fir 要 12 位、interp 出 13 位、decim 要 13 位……
  · NCO 相位和数据的对齐：本振晚几拍，整条链的相位就整体旋转；
  · 多相接口：interp2 一次吐两相，decim2 一次吃两相，两相不能错位；
  · 舍入/饱和在级联里累积。

这些问题用肉眼看波形都"差不多"，所以这里用 Python 任意精度整数把
**整条 DUC / DDC / 回环**逐位算一遍，TB 只负责回放 + 比对。

链的顺序（s05 定案，和 s03 TASK 里"FIR 在混频之后"的旧猜测不同）
------------------------------------------------------------------
    DUC: 符号 → FIR 成型 → 复数混频（上变频到低 IF）→ 2× 插值 → 两相并行
    DDC: 两相并行 → 2× 抽取 → 复数混频（下变频）→ FIR 信道滤波 → 符号

为什么 FIR 在混频之前：
    成型滤波必须在**基带**做。混频之后再低通，滤波器会按低通响应去"切"
    f_lo 附近的信号，过渡带和群延迟都不再是设计时看到的那条曲线
    （f_lo=0.05 Fs 时还能凑合，但那不是通用做法）。标准 DUC 是
    "成型 → 上变频 → 插值"；DDC 反过来"抽取 → 下变频 → 信道滤波"。
    旧文档里那句"DUC 里 FIR 在混频之后"是没集成时的猜测，s05 开工时改正。
    详见 s05_duc/TASK_s05_duc.md 的「写之前要决定的四件事」。

为什么 NCO 要延迟（LO_DLY）
----------------------------
    混频器的 LO 必须和**同一时刻进入混频器的数据**同相位。
    DUC：FIR 有 4 拍流水，NCO 输出本身有 1 拍，所以 LO 要再延迟 4 拍
         （本模型用"输入样本下标 n"作基准，正好是 4）。
    DDC：数据从 DUC 混频器出来之后，经过 interp、decim 才到 DDC 混频器。
         功能模型里 DDC 抽取输出 w[n] 携带的载波相位是 lo[n-10] ——
         **10 不是群延迟 15，而是半带在 f_lo 处的相位延迟**：
         群延迟描述"包络晚多少"，相位延迟描述"载波转了多少"，
         在 f_lo=0.05 Fs 这个窄带上两者不是同一个数。
         判别方法很直接：DC 输入（step 场景）混上去再混下来，
         只有 LO 下标 = 10 时输出才是 +1000；取 15 会得到 0/+1000（差 90°）。
         RTL 里 LO_DLY=14 拍产生这个序列：14 = 10 + 4，那个 +4 和 DUC 的
         LO_DLY=4 是**同一个**混频器 handoff 常数（DUC 模型下标 0 → RTL 4）。
    **这两个数不是随手写的**：把 LO_DLY 改 1，仿真里输出会整体旋转，
    但频率不变 —— 这正是"相位对齐"和"频率正确"的区别。

位宽 / 增益（详见 TASK 的增益预算表）
--------------------------------------
    DUC: 12 → FIR 13 → mixer 14 → interp 15
    DDC: 15 → decim 16 → mixer 17 → FIR 18 → 输出饱和到 13

用法
----
    python3 scripts/gen_duc_ddc_vec.py
    python3 scripts/gen_duc_ddc_vec.py --check s05_duc/vec s06_ddc/vec
    python3 scripts/gen_duc_ddc_vec.py --duc-out /tmp/duc --ddc-out /tmp/ddc

输出三个文件（$readmemh，32 位十六进制字）：
    s05_duc/vec/duc_vec.txt       每行 6 字： i_in q_in i_e i_o q_e q_o
    s06_ddc/vec/ddc_vec.txt       每行 6 字： i_e i_o q_e q_o i_out q_out
    s06_ddc/vec/loopback_vec.txt  每行 4 字： i_in q_in i_out q_out

文件头 16 个字（见 HEADER_DOC）；TB 先对一遍再回放。
"""

import argparse
import math
import os
import random
import sys

FK = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(FK)
DEFAULT_DUC_OUT = os.path.join(REPO, "s05_duc", "vec")
DEFAULT_DDC_OUT = os.path.join(REPO, "s06_ddc", "vec")
DEFAULT_FIR_COEF = os.path.join(REPO, "s03_fir", "lut", "coef.mem")
DEFAULT_HB_COEF = os.path.join(REPO, "s04_resample", "lut", "hb_odd.mem")
DEFAULT_SIN = os.path.join(REPO, "s01_nco", "lut", "sin.mem")
DEFAULT_COS = os.path.join(REPO, "s01_nco", "lut", "cos.mem")

# ── 和 RTL 默认参数必须一致 ────────────────────────────────────────────────
IW_SYM = 12           # DUC 输入符号位宽
CW = 16               # FIR / 半带系数位宽（Q1.15）
AW = 12               # NCO 幅度位宽
PHASE_W = 32          # NCO 相位累加器位宽
LUT_AW = 12           # NCO 查表地址位宽
N_FIR = 47            # 成型 FIR 抽头数
N_HB = 61             # 半带总抽头数

OW_FIR = 13           # DUC FIR 输出
OW_MIX = 14           # DUC 混频输出
OW_INT = 15           # DUC 插值输出（也是 DDC 输入）

OW_DEC = 16           # DDC 抽取输出
OW_DMIX = 17          # DDC 混频输出
OW_DFIR = 18          # DDC FIR 全宽输出
OW_OUT = 13           # DDC 最终输出（饱和到 13 位）

SHIFT_FIR = 15        # CW-1
SHIFT_MIX = 11        # AW-1
SHIFT_INT = 14        # CW-2：插值补 ×2
SHIFT_DEC = 15        # CW-1
SHIFT_DFIR = 15       # CW-1

# NCO：仿真用 CLK_HZ=100 / FREQ_HZ=5（= 0.05 Fs）；板上 50 MHz / 2.5 MHz 也是 0.05。
# 两种参数算出来的 PHI_INC 相同（整数除法结果都是 214748364），所以向量通用。
PHI_INC = (5 << PHASE_W) // 100
assert PHI_INC == (2_500_000 << PHASE_W) // 50_000_000

LAT_DUC = 9           # FIR 4 + mixer 1 + interp 4
LAT_DDC = 10          # decim 4 + mixer 1 + FIR 4 + 1 handoff
LAT_LOOP = LAT_DUC + LAT_DDC
LO_DLY_DUC = 4        # DUC 混频器：LO 要跟 FIR 的 4 拍流水对齐
LO_IDX_DDC = 10       # 功能模型里 DDC 混频器取的 LO 下标延迟（样本，见上）
LO_DLY_DDC = 14       # 独立 DDC 的 RTL 本振延迟（= LO_IDX_DDC + 4）
LO_DLY_LOOP = LO_DLY_DDC + LAT_DUC   # 回环时再加 DUC 的 9 拍（数据晚到 9 拍）

NSCEN = 4
NSAMP = 512
SEED = 20261020

SENTINEL_DUC = 0xD0C50001
SENTINEL_DDC = 0xDDC60001
SENTINEL_LOOP = 0xD0C6D0C6

# 测试音：0.01 × Fs（板上的 tone_nco 也用它：50 MHz / 500 kHz）
TONE_F = 0.01
TONE_AMP = 1000

# 场景
SCEN_NAMES = ["impulse", "step", "tone", "random"]


# ── 定点工具 ────────────────────────────────────────────────────────────────

def read_coef(path, cw):
    """读 .mem 文件，返回有符号整数列表（cw 位补码）。"""
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
    """32 位滚动校验和（和 s03/s04 的生成器同算法）。"""
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

    Python 的 >> 对负数是向下取整，和 Verilog 的 >>> 对 signed 一致。
    """
    if rnd and shift > 0:
        acc += 1 << (shift - 1)
    return acc >> shift


# ── 各模块的逐位模型（和 RTL 的定义一一对应，不含流水线延迟）──────────────

def nco_model(nsamp, sin_tab, cos_tab):
    """返回 (sin 序列, cos 序列)，长度 nsamp。

    RTL 的相位累加器和输出寄存器：第 n 个输出对应相位 n*PHI_INC
    （第 0 个输出是复位后的 table[0]）。
    """
    shift = PHASE_W - LUT_AW
    mask = (1 << PHASE_W) - 1
    ss, cc = [], []
    for n in range(nsamp):
        addr = ((n * PHI_INC) & mask) >> shift
        ss.append(sin_tab[addr])
        cc.append(cos_tab[addr])
    return ss, cc


def fir_model(xs, coef, ow, shift, rnd):
    """对称 FIR 的直卷模型。RTL 的预加是精确的，所以直接卷和等价。"""
    n_tap = len(coef)
    ys = []
    for n in range(len(xs)):
        acc = 0
        for k in range(n_tap):
            j = n - k
            if j >= 0:
                acc += coef[k] * xs[j]
        ys.append(sat(rshift(acc, shift, rnd), ow))
    return ys


def mixer_model(is_, qs_, cs_, ss_, ow, shift, rnd, conj):
    """复数混频（含舍入 + 饱和）。

    CONJ=0（上变频）：i*cos - q*sin, q*cos + i*sin
    CONJ=1（下变频）：i*cos + q*sin, q*cos - i*sin
    """
    oi, oq = [], []
    for n in range(len(is_)):
        if conj == 0:
            si = is_[n] * cs_[n] - qs_[n] * ss_[n]
            sq = qs_[n] * cs_[n] + is_[n] * ss_[n]
        else:
            si = is_[n] * cs_[n] + qs_[n] * ss_[n]
            sq = qs_[n] * cs_[n] - is_[n] * ss_[n]
        oi.append(sat(rshift(si, shift, rnd), ow))
        oq.append(sat(rshift(sq, shift, rnd), ow))
    return oi, oq


def interp_model(xs, hb, ow, shift, rnd):
    """2× 半带插值：返回 (y_e, y_o)。

        y_e[n] = x[n-K/2]
        y_o[n] = (Σ hb[i]·x[n-i]) >>> shift      （shift = CW-2）
    """
    k = len(hb)
    half = k // 2
    ye, yo = [], []
    for n in range(len(xs)):
        ye.append(sat(xs[n - half] if n >= half else 0, ow))
        acc = 0
        for i in range(k):
            j = n - i
            if j >= 0:
                acc += hb[i] * xs[j]
        yo.append(sat(rshift(acc, shift, rnd), ow))
    return ye, yo


def decim_model(xe, xo, hb, ow, shift, rnd):
    """2× 半带抽取：

        y[n] = ( 2^(CW-2)·x_e[n-K/2] + Σ hb[i]·x_o[n-1-i] ) >>> shift
    """
    k = len(hb)
    half = k // 2
    half_coef = 1 << (CW - 2)
    ys = []
    for n in range(len(xe)):
        acc = 0
        if n - half >= 0:
            acc += half_coef * xe[n - half]
        for i in range(k):
            j = n - 1 - i
            if j >= 0:
                acc += hb[i] * xo[j]
        ys.append(sat(rshift(acc, shift, rnd), ow))
    return ys


# ── 整条链 ──────────────────────────────────────────────────────────────────

def duc_model(x_i, x_q, fir, hb, lo_s, lo_c):
    """DUC：符号 → FIR → 混频（CONJ=0）→ 插值。返回 4 路输出。"""
    fi = fir_model(x_i, fir, OW_FIR, SHIFT_FIR, 1)
    fq = fir_model(x_q, fir, OW_FIR, SHIFT_FIR, 1)
    zi, zq = mixer_model(fi, fq, lo_c, lo_s, OW_MIX, SHIFT_MIX, 1, 0)
    ie, io = interp_model(zi, hb, OW_INT, SHIFT_INT, 1)
    qe, qo = interp_model(zq, hb, OW_INT, SHIFT_INT, 1)
    return ie, io, qe, qo


def ddc_model(ie, io, qe, qo, fir, hb, lo_s, lo_c):
    """DDC：抽取 → 混频（CONJ=1）→ FIR → 饱和到 OW_OUT。

    ⚠️ DDC 混频器用的本振是 lo[n-LO_IDX_DDC]：经过 interp/decim 后，
       抽取输出 w[n] 里携带的载波相位是 lo[n-10]。
       10 是**相位延迟**，不是半带的群延迟 15 —— 判别方法就是 step 场景：
       取 10 时 DC 输入回来还是 +1000；取 15 会变成 0/+1000（差 90°）。
       前 LO_IDX_DDC 个样本的 lo 取 0（RTL 的 LO 延迟线复位值），
       这样复位瞬态也逐位一致。
    """
    wi = decim_model(ie, io, hb, OW_DEC, SHIFT_DEC, 1)
    wq = decim_model(qe, qo, hb, OW_DEC, SHIFT_DEC, 1)

    n = len(wi)
    d = LO_IDX_DDC
    lo_s_d = [0] * d + list(lo_s[:max(0, n - d)])
    lo_c_d = [0] * d + list(lo_c[:max(0, n - d)])
    lo_s_d = lo_s_d[:n]
    lo_c_d = lo_c_d[:n]

    bi, bq = mixer_model(wi, wq, lo_c_d, lo_s_d, OW_DMIX, SHIFT_MIX, 1, 1)
    oi = fir_model(bi, fir, OW_DFIR, SHIFT_DFIR, 1)
    oq = fir_model(bq, fir, OW_DFIR, SHIFT_DFIR, 1)
    return ([sat(v, OW_OUT) for v in oi],
            [sat(v, OW_OUT) for v in oq])


# ── 输入场景 ────────────────────────────────────────────────────────────────

def gen_scenarios(nsamp):
    """4 个场景：冲激 / 直流 / 复单音 / 满量程随机。返回 [(i 列表, q 列表)]。"""
    lo = -(1 << (IW_SYM - 1))
    hi = (1 << (IW_SYM - 1)) - 1

    imp_i = [0] * nsamp
    imp_q = [0] * nsamp
    imp_i[0] = hi

    step_i = [1000] * nsamp
    step_q = [0] * nsamp

    tone_i, tone_q = [], []
    for n in range(nsamp):
        tone_i.append(sat(round(TONE_AMP * math.cos(2.0 * math.pi * TONE_F * n)), IW_SYM))
        tone_q.append(sat(round(TONE_AMP * math.sin(2.0 * math.pi * TONE_F * n)), IW_SYM))

    rng = random.Random(SEED)
    rnd_i = [rng.randint(lo, hi) for _ in range(nsamp)]
    rnd_q = [rng.randint(lo, hi) for _ in range(nsamp)]

    return [(imp_i, imp_q), (step_i, step_q), (tone_i, tone_q), (rnd_i, rnd_q)]


# ── 文件渲染 ────────────────────────────────────────────────────────────────

def word(v):
    return "%08X" % (v & 0xFFFFFFFF)


def render_header(sentinel, iw, ow, shift_fir, shift_mix, shift_res,
                  csum_fir, csum_hb, lat, lo_dly, rows):
    vals = [
        sentinel,
        NSCEN,
        NSAMP,
        rows,
        iw,
        ow,
        CW,
        AW,
        shift_fir,
        shift_mix,
        shift_res,
        csum_fir,
        csum_hb,
        PHI_INC,
        lat,
        lo_dly,
    ]
    return "".join(word(v) + "\n" for v in vals)


def render_rows(rows, nwords):
    out = []
    for r in rows:
        assert len(r) == nwords, "每行必须恰好 %d 个字" % nwords
        out.append(" ".join(word(v) for v in r) + "\n")
    return "".join(out)


def build_files(fir, hb, sin_tab, cos_tab):
    lo_s, lo_c = nco_model(NSAMP, sin_tab, cos_tab)
    csum_fir = coef_checksum(fir)
    csum_hb = coef_checksum(hb)
    scen = gen_scenarios(NSAMP)

    duc_rows = []
    ddc_rows = []
    loop_rows = []
    duc_outs = []
    loop_outs = []

    for (xi, xq) in scen:
        ie, io, qe, qo = duc_model(xi, xq, fir, hb, lo_s, lo_c)
        duc_outs.append((ie, io, qe, qo))
        for n in range(NSAMP):
            duc_rows.append([xi[n], xq[n], ie[n], io[n], qe[n], qo[n]])

    for (ie, io, qe, qo) in duc_outs:
        oi, oq = ddc_model(ie, io, qe, qo, fir, hb, lo_s, lo_c)
        loop_outs.append((oi, oq))
        for n in range(NSAMP):
            ddc_rows.append([ie[n], io[n], qe[n], qo[n], oi[n], oq[n]])

    for (xi, xq), (oi, oq) in zip(scen, loop_outs):
        for n in range(NSAMP):
            loop_rows.append([xi[n], xq[n], oi[n], oq[n]])

    files = {}
    files["duc_vec.txt"] = (
        render_header(SENTINEL_DUC, IW_SYM, OW_INT, SHIFT_FIR, SHIFT_MIX,
                      SHIFT_INT, csum_fir, csum_hb, LAT_DUC, LO_DLY_DUC,
                      NSCEN * NSAMP)
        + render_rows(duc_rows, 6))
    files["ddc_vec.txt"] = (
        render_header(SENTINEL_DDC, OW_INT, OW_OUT, SHIFT_DFIR, SHIFT_MIX,
                      SHIFT_DEC, csum_fir, csum_hb, LAT_DDC, LO_DLY_DDC,
                      NSCEN * NSAMP)
        + render_rows(ddc_rows, 6))
    files["loopback_vec.txt"] = (
        render_header(SENTINEL_LOOP, IW_SYM, OW_OUT, SHIFT_FIR, SHIFT_MIX,
                      SHIFT_INT, csum_fir, csum_hb, LAT_LOOP, LO_DLY_LOOP,
                      NSCEN * NSAMP)
        + render_rows(loop_rows, 4))

    # 统计：给 TASK 文档和 TB 的阈值提供数据
    stats = {
        "duc_peak": max(max(abs(v) for v in ie + io + qe + qo)
                        for (ie, io, qe, qo) in duc_outs),
        "loop_peak": max(max(abs(v) for v in oi + oq)
                         for (oi, oq) in loop_outs),
        "tone_out_amp": max(max(abs(v) for v in loop_outs[2][0]),
                            max(abs(v) for v in loop_outs[2][1])),
    }
    return files, stats


def write_dir(files, out_dir, names):
    os.makedirs(out_dir, exist_ok=True)
    for name in names:
        text = files[name]
        path = os.path.join(out_dir, name)
        with open(path, "w", newline="\n") as fh:
            fh.write(text)
        print("  写入 %s（%d 个字）" % (path, text.count("\n")))


def data_lines(text):
    return [line.strip() for line in text.replace("\r\n", "\n").split("\n") if line.strip()]


def check_dir(files, out_dir, names):
    bad = 0
    for name in names:
        path = os.path.join(out_dir, name)
        if not os.path.isfile(path):
            print("  [FAIL] 找不到 %s" % path)
            bad += 1
            continue
        with open(path, "r") as fh:
            got = fh.read()
        want = files[name]
        if got == want:
            print("  [PASS] %s 与生成器一致" % path)
        elif data_lines(got) == data_lines(want):
            print("  [PASS] %s 数据一致（行尾/CRLF 不同，不影响读表）" % path)
        else:
            print("  [FAIL] %s 与生成器不一致（文件被改过？需重新生成）" % path)
            bad += 1
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="生成 s05 DUC / s06 DDC / 回环的逐位参考向量",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--duc-out", default=DEFAULT_DUC_OUT, help="DUC 向量输出目录")
    ap.add_argument("--ddc-out", default=DEFAULT_DDC_OUT, help="DDC / 回环向量输出目录")
    ap.add_argument("--fir-coef", default=DEFAULT_FIR_COEF, help="47 抽头 FIR 系数")
    ap.add_argument("--hb-coef", default=DEFAULT_HB_COEF, help="30 个半带奇数抽头")
    ap.add_argument("--sin", default=DEFAULT_SIN, help="NCO sin 表")
    ap.add_argument("--cos", default=DEFAULT_COS, help="NCO cos 表")
    ap.add_argument("--check", nargs=2, metavar=("DUC_DIR", "DDC_DIR"), default=None,
                    help="只校验已有的两个目录，不写入")
    args = ap.parse_args(argv)

    fir = read_coef(args.fir_coef, CW)
    hb = read_coef(args.hb_coef, CW)
    sin_tab = read_coef(args.sin, AW)
    cos_tab = read_coef(args.cos, AW)
    if len(fir) != N_FIR:
        raise SystemExit("FIR 系数有 %d 行，期望 %d" % (len(fir), N_FIR))
    if len(hb) != (N_HB - 1) // 2:
        raise SystemExit("半带系数有 %d 行，期望 %d" % (len(hb), (N_HB - 1) // 2))
    if len(sin_tab) != (1 << LUT_AW) or len(cos_tab) != (1 << LUT_AW):
        raise SystemExit("NCO 表深度不是 %d" % (1 << LUT_AW))

    files, stats = build_files(fir, hb, sin_tab, cos_tab)
    print("参数：IW=%d CW=%d AW=%d PHASE_W=%d LUT_AW=%d PHI_INC=%d"
          % (IW_SYM, CW, AW, PHASE_W, LUT_AW, PHI_INC))
    print("  位宽链：DUC 12→%d→%d→%d；DDC %d→%d→%d→%d→%d"
          % (OW_FIR, OW_MIX, OW_INT, OW_INT, OW_DEC, OW_DMIX, OW_DFIR, OW_OUT))
    print("  延迟：DUC %d 拍、DDC %d 拍、回环 %d 拍；LO_DLY %d / %d / %d（DUC/DDC/回环）"
          % (LAT_DUC, LAT_DDC, LAT_LOOP, LO_DLY_DUC, LO_DLY_DDC, LO_DLY_LOOP))
    print("  场景：%s；每场景 %d 样本" % (" / ".join(SCEN_NAMES), NSAMP))
    print("  统计：DUC 输出峰值 %d；回环输出峰值 %d；tone 场景输出峰值 %d"
          % (stats["duc_peak"], stats["loop_peak"], stats["tone_out_amp"]))

    if args.check is not None:
        print("校验 %s / %s" % (args.check[0], args.check[1]))
        bad = check_dir(files, args.check[0], ["duc_vec.txt"])
        bad += check_dir(files, args.check[1], ["ddc_vec.txt", "loopback_vec.txt"])
        if bad:
            print("结果：%d 个文件不一致" % bad)
            return 1
        print("结果：全部一致")
        return 0

    write_dir(files, args.duc_out, ["duc_vec.txt"])
    write_dir(files, args.ddc_out, ["ddc_vec.txt", "loopback_vec.txt"])
    print("完成。TB 用 VECDIR 找这些文件（sim.sh 会自动传绝对路径）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
