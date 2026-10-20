#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ila_check.py — ILA CSV 的正弦判读（频率 / 周期 / 幅度 / 相位 / 正交 / 包络）

用途
----
把 Vivado ILA 的 "Export ILA Data" CSV 变成可复核的数字，对应各 stage 的
`logs/sNN_*/ila_check.txt`。判读方法和文档里写的一致：

    y = A·cos(ωn + φ) + c        （最小二乘拟合，频率在 FFT 峰附近细化）

用法
----
    python3 scripts/ila_check.py logs/s06_ddc/csv/20261020_ddc.csv \
        --pairs ie:qe,io:qo,di:dq --iq ie:qe,di:dq --ratio ie:di

    --fs     采样时钟（Hz），默认 50e6（sys_clk）
    --pairs  相位差对，逗号分隔的 a:b（同一采样点比较，单位度）
    --iq     复包络对，逗号分隔的 i:q（输出 |z| 的均值/标准差/纹波）
    --ratio  频率比，a:b

CSV 格式
--------
第一行列名，第二行是 "Radix - ..."（会被跳过）。列名里带 `[` 的列当作信号
（如 `ie_dbg[14:0]`），`Sample in Buffer` / `Sample in Window` / `TRIGGER` 忽略。
信号名可以写全（`ie_dbg[14:0]`）也可以写短（`ie`、`ie_dbg`）。

依赖：numpy（只用于 FFT 和最小二乘）。
"""
from __future__ import annotations

import argparse
import sys

try:
    import numpy as np
except ImportError:  # pragma: no cover
    sys.exit("需要 numpy：pip install numpy")


def wrap_deg(x: float) -> float:
    return (x + 180.0) % 360.0 - 180.0


def short_name(col: str) -> str:
    """`ie_dbg[14:0]` -> `ie`；`tone_i_dbg[11:0]` -> `tone_i`。"""
    base = col.split("[")[0]
    if base.endswith("_dbg"):
        base = base[:-4]
    return base


def load_csv(path: str):
    with open(path, "r", encoding="utf-8-sig") as f:
        lines = [ln.rstrip("\n\r") for ln in f if ln.strip()]

    header = [c.strip() for c in lines[0].split(",")]
    rows = []
    for ln in lines[1:]:
        if ln.startswith("Radix"):  # 第二行的进制说明
            continue
        parts = [p.strip() for p in ln.split(",")]
        if len(parts) != len(header):
            continue
        try:
            rows.append([int(float(p)) for p in parts])
        except ValueError:
            continue

    if not rows:
        sys.exit(f"{path}: no data rows")

    cols = {}
    for idx, name in enumerate(header):
        if "[" in name:  # 信号列
            cols[name] = np.array([r[idx] for r in rows], dtype=float)

    trigger = None
    if "TRIGGER" in header:
        ti = header.index("TRIGGER")
        trig = [r[ti] for r in rows]
        if 1 in trig:
            trigger = trig.index(1)

    return cols, len(rows), trigger


def fit_tone(y: np.ndarray, fs: float) -> dict:
    """最小二乘拟合 y = A·cos(ωn+φ) + c，频率在 FFT 峰附近细化。"""
    y = np.asarray(y, dtype=float)
    y0 = y - y.mean()
    n = len(y0)
    if n < 8:
        return dict(f=0.0, amp=0.0, phase=0.0, dc=y.mean(), rms=0.0)

    spec = np.abs(np.fft.rfft(y0 * np.hanning(n)))
    k = int(np.argmax(spec[1:]) + 1)
    f0 = k * fs / n
    df = fs / n

    idx = np.arange(n)
    best = None
    for f in np.linspace(f0 - df, f0 + df, 4001):
        w = 2.0 * np.pi * f / fs
        M = np.column_stack((np.cos(w * idx), np.sin(w * idx), np.ones(n)))
        coef, *_ = np.linalg.lstsq(M, y, rcond=None)
        r = y - M @ coef
        rss = float(np.sum(r * r))
        if best is None or rss < best[0]:
            best = (rss, f, coef)

    rss, f, (a, b, dc) = best
    return dict(
        f=float(f),
        amp=float(np.hypot(a, b)),
        phase=float(np.degrees(np.arctan2(-b, a))),
        dc=float(dc),
        rms=float(np.sqrt(rss / n)),
    )


def find_col(cols: dict, name: str) -> str:
    for full in cols:
        if full == name or short_name(full).lower() == name.lower():
            return full
    lowered = {short_name(c).lower(): c for c in cols}
    if name.lower() in lowered:
        return lowered[name.lower()]
    sys.exit(f"signal {name!r} not found; available: {', '.join(short_name(c) for c in cols)}")


def parse_pairs(spec: str):
    out = []
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            sys.exit(f"--pairs entries must be a:b, got {item!r}")
        a, b = item.split(":", 1)
        out.append((a.strip(), b.strip()))
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="ILA CSV sinusoidal analysis")
    ap.add_argument("csv", help="CSV exported from Vivado ILA")
    ap.add_argument("--fs", type=float, default=50e6, help="sample clock in Hz (default 50e6)")
    ap.add_argument("--pairs", default="", help="phase pairs, e.g. ie:qe,di:dq")
    ap.add_argument("--iq", default="", help="complex envelope pairs, e.g. ie:qe,di:dq")
    ap.add_argument("--ratio", default="", help="frequency ratio, e.g. ie:di")
    args = ap.parse_args()

    cols, n, trigger = load_csv(args.csv)
    fs = args.fs
    print(f"file      : {args.csv}")
    print(f"samples   : {n}   fs = {fs/1e6:.3f} MHz" +
          (f"   trigger_index = {trigger}" if trigger is not None else ""))
    print()

    fit = {c: fit_tone(y, fs) for c, y in cols.items()}

    print(f"{'signal':10s} {'min':>7s} {'max':>7s} {'amp':>8s} "
          f"{'f/kHz':>10s} {'period':>8s} {'phase/deg':>10s} {'rms':>6s}")
    for c, r in fit.items():
        y = cols[c]
        print(f"{short_name(c):10s} {y.min():7.0f} {y.max():7.0f} {r['amp']:8.1f} "
              f"{r['f']/1e3:10.3f} {fs/r['f']:8.3f} {wrap_deg(r['phase']):10.2f} "
              f"{r['rms']:6.2f}")
    print()

    for a, b in parse_pairs(args.pairs):
        ca, cb = find_col(cols, a), find_col(cols, b)
        d = wrap_deg(fit[cb]["phase"] - fit[ca]["phase"])
        dt = d / 360.0 / fit[ca]["f"] * 1e9 if fit[ca]["f"] else float("nan")
        print(f"{a} -> {b}: dphi = {d:+.2f} deg"
              f"   (period {1e9/fit[ca]['f']:.2f} ns -> {dt:+.2f} ns)")
    if args.pairs:
        print()

    for a, b in parse_pairs(args.iq):
        ca, cb = find_col(cols, a), find_col(cols, b)
        mag = np.hypot(cols[ca], cols[cb])
        m = float(mag.mean())
        print(f"|{a}+j{b}|: mean = {m:.1f}  std = {float(mag.std()):.2f}  "
              f"min = {float(mag.min()):.1f}  max = {float(mag.max()):.1f}  "
              f"ripple = {(float(mag.max())-float(mag.min()))/m*100:.2f}%")
    if args.iq:
        print()

    if args.ratio:
        a, b = [s.strip() for s in args.ratio.split(":", 1)]
        ca, cb = find_col(cols, a), find_col(cols, b)
        fa, fb = fit[ca]["f"], fit[cb]["f"]
        print(f"f({a}) / f({b}) = {fa/fb:.4f}")


if __name__ == "__main__":
    main()
