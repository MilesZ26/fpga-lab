#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 NCO 查表数据（sin / cos），输出 $readmemh 能直接读的十六进制 .mem 文件。

为什么要有这个脚本：
    仿真里可以 $sin() 现算，但 Vivado 综合不了 $sin —— 综合要求表里是常量。
    所以表的"真值"由这个脚本离线算好，落到文本文件里；RTL 只负责 $readmemh 读进来。
    这样仿真和综合用的是**同一份数据**，不会出现"仿真对、上板错"。

用法：
    python3 scripts/gen_lut.py                          # 默认 LUT_AW=12 / AW=12
    python3 scripts/gen_lut.py --lut-aw 10 --aw 16      # 换一组参数
    python3 scripts/gen_lut.py --out /tmp/lut           # 换个输出目录
    python3 scripts/gen_lut.py --check s01_nco/lut      # 只校验已有文件，不写

输出（写到 --out 目录）：
    sin.mem    2**LUT_AW 行，每行 AW/4 个十六进制字符（二进制补码）
    cos.mem    同上

数据约定（细节见 s01_nco/lut/README.md）：
    地址 i 对应相位 theta = 2*pi*i / 2**LUT_AW
    幅值缩放 max = 2**(AW-1) - 1（不产生 -2**(AW-1)，正负对称）
    量化：四舍五入、且"远离零"方向取整 -> sin 表严格奇对称
    cos 表 = 同一串量化样本的 1/4 圈循环移位（cos[i] == sin[(i + N/4) % N]）
"""

import argparse
import math
import os
import sys

FK = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(FK)
DEFAULT_OUT = os.path.join(REPO, "s01_nco", "lut")


def quantize(value, scale):
    """四舍五入（0.5 远离零），返回 int。

    不用 Python 内置 round()：它是"银行家舍入"（round(0.5) == 0），
    结果不对称，会破坏 sin 表的奇对称性。这里显式定义舍入方向。
    """
    x = value * scale
    if x >= 0.0:
        return int(math.floor(x + 0.5))
    return -int(math.floor(-x + 0.5))


def sine_table(lut_aw, aw):
    """返回 2**lut_aw 个定点正弦样本（int，范围 [-(2**(aw-1)-1), 2**(aw-1)-1]）。"""
    depth = 1 << lut_aw
    scale = float((1 << (aw - 1)) - 1)
    return [quantize(math.sin(2.0 * math.pi * i / depth), scale) for i in range(depth)]


def cosine_table(samples):
    """cos 表 = sin 表的 N/4 循环移位。

    数学上 cos(2*pi*i/N) == sin(2*pi*(i + N/4)/N)，直接复用同一串量化样本，
    能保证 cos[i] == sin[(i + N/4) % N] **逐位精确**成立（而不是差 1 LSB）。
    这条性质本身就是一个很好写的 testbench 断言。
    """
    n = len(samples)
    shift = n >> 2
    return [samples[(i + shift) % n] for i in range(n)]


def render(values, aw):
    digits = aw // 4
    mask = (1 << aw) - 1
    return "".join("%0*X\n" % (digits, v & mask) for v in values)


def build(lut_aw, aw):
    """返回 {文件名: 文本内容}。"""
    samples = sine_table(lut_aw, aw)
    return {
        "sin.mem": render(samples, aw),
        "cos.mem": render(cosine_table(samples), aw),
    }


def write_files(files, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name, text in sorted(files.items()):
        path = os.path.join(out_dir, name)
        with open(path, "w", newline="\n") as fh:   # 强制 LF：跨 Mac/Windows
            fh.write(text)
        print("  写入 %s（%d 行）" % (path, text.count("\n")))


def data_lines(text):
    """把文本取成"数据行"列表：忽略 CR、空行、行尾有无换行。

    只用来做 --check 的比较：换行符属于排版，不影响 $readmemh 读到的数值，
    而两台机器的编辑器（Windows 常把文件末尾换行吃掉、或写成 CRLF）会改它。
    数值被改动一定会在这里现形。
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
            # Windows 编辑器经常把文件末尾那个换行吃掉（或改成 CRLF）。
            # 这不影响 $readmemh 读到的数值，不该算"数据被改过"。
            print("  [PASS] %s 数据一致（行尾换行/CRLF 与生成器不同，不影响读表）" % path)
        else:
            print("  [FAIL] %s 与生成器不一致（文件被改过？需重新生成）" % path)
            bad += 1
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="生成 NCO 的 sin/cos 查表 .mem 文件（$readmemh 格式）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--lut-aw", type=int, default=12, help="查表地址位宽，表深 = 2**LUT_AW")
    ap.add_argument("--aw", type=int, default=12, help="输出幅值位宽（必须是 4 的倍数）")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录")
    ap.add_argument("--check", metavar="DIR", default=None,
                    help="只校验 DIR 里已有的文件，不写入")
    args = ap.parse_args(argv)

    if args.lut_aw < 2:
        ap.error("--lut-aw 至少为 2（cos 表要移 1/4 圈，深度至少 4）")
    if args.aw < 4 or args.aw % 4 != 0:
        ap.error("--aw 必须是 >= 4 且能被 4 整除（十六进制字符数 = AW/4）")

    if args.check is not None:
        print("校验 %s（LUT_AW=%d, AW=%d）" % (args.check, args.lut_aw, args.aw))
        bad = check_files(build(args.lut_aw, args.aw), args.check)
        if bad:
            print("结果：%d 个文件不一致" % bad)
            return 1
        print("结果：全部一致")
        return 0

    depth = 1 << args.lut_aw
    maxv = (1 << (args.aw - 1)) - 1
    print("生成 %d 深 / %d 位（幅值 %+d）的表" % (depth, args.aw, maxv))
    write_files(build(args.lut_aw, args.aw), args.out)
    print("完成。RTL 里用 $readmemh 读，注意路径是相对**仿真/综合的工作目录**，不是 RTL 文件所在目录。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
