#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 mixer（s02 复数混频器）的参考向量 —— 逐位精确的 golden vectors。

为什么要有这个脚本（这是"参考模型 + 向量回放"这套方法的最小实现）：
    RTL 的算术（位宽增长 / 舍入 / 饱和）用肉眼是看不出对错的，而如果在 testbench
    里再用 Verilog 写一遍同样的算术，两边很可能**犯同一个理解错误** ——
    那就成了"自己证明自己"，抓不到 bug。
    所以这里用 Python（任意精度整数，和 Verilog 的位宽规则完全无关）独立算一遍，
    把 (输入, 期望输出) 落到文件里，testbench 只负责回放 + 比对。
    仿真和综合之外的第三种语言，才算独立。

用法：
    python3 scripts/gen_mixer_vec.py                       # 生成全部预设 -> s02_mixer/vec/
    python3 scripts/gen_mixer_vec.py --out /tmp/vec
    python3 scripts/gen_mixer_vec.py --check s02_mixer/vec # 只校验已有文件

文件格式（$readmemh 直接读，空格分隔的 32 位十六进制字）：
    第 1 行  c0ffee01              哨兵：TB 用它确认"文件真的读进来了"
    第 2 行  测试个数 N
    之后 N 行，每行 6 个字： i_in q_in cos_in sin_in i_out q_out
    所有字都是 **32 位补码的原始位模式**（负数写成 FFFFFFFF 那样的形式），
    TB 按各自的位宽取低位并做符号扩展。

预设（和 tb_mixer.v 里的四个 DUT 一一对应）：
    a  IW=12 AW=12 OW=13 SHIFT=11 ROUND=1 CONJ=0   主配置（单位增益、四舍五入）
    b  IW=12 AW=12 OW=8  SHIFT=6  ROUND=0 CONJ=1   故意饱和 + 截断 + 下变频
    c  IW=8  AW=10 OW=12 SHIFT=9  ROUND=1 CONJ=0   换一组位宽（参数化真的生效吗）
    d  IW=12 AW=12 OW=13 SHIFT=11 ROUND=0 CONJ=0   与 a 同输入，只有舍入方式不同
"""

import argparse
import math
import os
import random
import sys

FK = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(FK)
DEFAULT_OUT = os.path.join(REPO, "s02_mixer", "vec")

SENTINEL = 0xC0FFEE01
N_RANDOM = 600
SEED = 20261016
# 所有预设的用例数都补齐到这个值。为什么要补：
#   testbench 里的 $readmemh 数组长度是编译期常量，而 $readmemh 只在
#   "文件字数**恰好等于**数组长度"时不告警（少了会打 Not enough words，
#   多了会截断）。四个预设的自然用例数略有差别（1617 / 1619），
#   让它们对齐成一个定值，TB 那边才能把数组开得刚刚好、日志干干净净。
N_PAD = 1620

PRESETS = {
    "a": dict(iw=12, aw=12, ow=13, shift=11, rnd=1, conj=0),
    "b": dict(iw=12, aw=12, ow=8, shift=6, rnd=0, conj=1),
    "c": dict(iw=8, aw=10, ow=12, shift=9, rnd=1, conj=0),
    "d": dict(iw=12, aw=12, ow=13, shift=11, rnd=0, conj=0),
}


def clog2_range(w):
    """返回 w 位补码的 [min, max]。"""
    return -(1 << (w - 1)), (1 << (w - 1)) - 1


def shifted(i, q, c, s, iw, aw, ow, shift, rnd, conj):
    """参考模型前半段：全精度乘加 + 舍入 + 右移，返回 (i_sh, q_sh)，**还没饱和**。

    和 RTL 的对应关系（这里故意用"数学"写法，完全不模拟位宽）：
      1) 全精度乘加（Python 整数没有位宽，所以就是精确值）
         conj=0：乘 e^{+jphi} → (i*c - q*s, i*s + q*c)
         conj=1：乘 e^{-jphi} → (i*c + q*s, q*c - i*s)   ← **两路都要翻符号**
         ⚠️ 第一版这里只翻了 q 路，RTL 也犯了同一个错，于是向量回放全绿 ——
            这就是"参考模型和 RTL 共享同一个理解错误"的经典翻车方式。
            最后是靠一条手算的性质断言抓住的（见 tb_mixer.v 第 7 节）。
      2) 加半个 LSB（ROUND）后右移 shift 位
    """
    if conj:
        i_sum = i * c + q * s
        q_sum = q * c - i * s
    else:
        i_sum = i * c - q * s
        q_sum = q * c + i * s

    out = []
    for v in (i_sum, q_sum):
        if rnd and shift > 0:
            v += 1 << (shift - 1)          # 加半个 LSB
        out.append(v >> shift)             # Python 的 >> 就是向 -inf 取整
    return out[0], out[1]


def model(i, q, c, s, iw, aw, ow, shift, rnd, conj):
    """参考模型：返回最终期望输出 (i_out, q_out)（饱和之后）。"""
    lo, hi = clog2_range(ow)
    i_sh, q_sh = shifted(i, q, c, s, iw, aw, ow, shift, rnd, conj)
    return max(lo, min(hi, i_sh)), max(lo, min(hi, q_sh))


def gen_cases(iw, aw, shift):
    """造输入用例。只依赖 (iw, aw, shift)，所以 a/b/d 的输入序列完全一致。"""
    imin, imax = clog2_range(iw)
    amin, amax = clog2_range(aw)
    cases = []

    # 1) 每个操作数取 {最小, -1, 0, 1, 最大} 的全组合：625 组，
    #    覆盖所有符号组合和边界值（溢出/符号扩展错了这里一定现形）。
    for i in (imin, -1, 0, 1, imax):
        for q in (imin, -1, 0, 1, imax):
            for c in (amin, -1, 0, 1, amax):
                for s in (amin, -1, 0, 1, amax):
                    cases.append((i, q, c, s))

    # 2) 单位幅度本振旋转（这才是混频器真正的工作场景）：
    #    本振幅度 = 2^(AW-1)-1，扫 64 个相位点。
    #    ⚠️ 输入 i/q 的满幅是 2^(IW-1)-1，**和本振的满幅不是一回事**（IW != AW 时）。
    #       第一版这里把 amax 同时当成了 i/q 的幅度，于是 IW=8 那组造出了
    #       i=511 这种 8 位装不下的输入 —— RTL 一截位就错，测试却"以为"测过了。
    amp_lo = amax
    amp_iq = imax
    iq_pairs = [(amp_iq, 0), (0, amp_iq), (amp_iq, amp_iq), (-amp_iq, amp_iq),
                (amp_iq // 3, -amp_iq // 5), (0, 0)]
    for k in range(64):
        th = 2.0 * math.pi * k / 64.0
        c = int(round(amp_lo * math.cos(th)))
        s = int(round(amp_lo * math.sin(th)))
        for (i, q) in iq_pairs:
            cases.append((i, q, c, s))

    # 3) 舍入的边界：被丢掉的低位刚好等于"半个 LSB"（tie），以及它的 ±1。
    #    这是唯一能区分"四舍五入"和"截断"的地方，必须专门造。
    if shift > 0:
        half = 1 << (shift - 1)
        for c0 in (half - 1, half, half + 1, 2 * half):
            if amin <= c0 <= amax:
                for i in (1, -1):
                    cases.append((i, 0, c0, 0))
        # 一路是负、一路是正的组合（看两路符号处理是否一致）
        if amin <= half <= amax:
            cases.append((1, 1, half, 1))
            cases.append((-1, -1, half, 1))

    # 4) 随机：一半取满量程（专门冲饱和/越界），一半取小幅度（像真实基带信号）
    rng = random.Random(SEED)
    small_i = max(1, imax // 8)
    for _ in range(N_RANDOM):
        if rng.random() < 0.5:
            i = rng.randint(imin, imax)
            q = rng.randint(imin, imax)
        else:
            i = rng.randint(-small_i, small_i)
            q = rng.randint(-small_i, small_i)
        c = rng.randint(amin, amax)
        s = rng.randint(amin, amax)
        cases.append((i, q, c, s))

    # 5) 补齐到 N_PAD：循环复用前面的用例（重复用例不增加覆盖，只是把长度对齐）
    base = len(cases)
    while len(cases) < N_PAD:
        cases.append(cases[len(cases) - base])

    # 6) 自查：每个数都必须装得进它自己的位宽。
    #    这条是**补上来的** —— 之前 IW=8 的配置混进了 511 这种值，
    #    RTL 静默截位、测试还以为自己测过了。生成器自己先拦住。
    for (i, q, c, s) in cases:
        assert imin <= i <= imax, "i=%d 超出 %d 位范围" % (i, iw)
        assert imin <= q <= imax, "q=%d 超出 %d 位范围" % (q, iw)
        assert amin <= c <= amax, "cos=%d 超出 %d 位范围" % (c, aw)
        assert amin <= s <= amax, "sin=%d 超出 %d 位范围" % (s, aw)

    return cases


def render(cfg, cases):
    lines = ["%08X" % SENTINEL, "%08X" % len(cases)]
    for (i, q, c, s) in cases:
        io, qo = model(i, q, c, s, **cfg)
        lines.append(" ".join("%08X" % (v & 0xFFFFFFFF)
                              for v in (i, q, c, s, io, qo)))
    return "\n".join(lines) + "\n"


def build_all():
    """返回 {文件名: 文本}。"""
    out = {}
    for name in sorted(PRESETS):
        cfg = PRESETS[name]
        cases = gen_cases(cfg["iw"], cfg["aw"], cfg["shift"])
        out["mixer_%s.txt" % name] = render(cfg, cases)
    return out


def write_files(files, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name, text in sorted(files.items()):
        path = os.path.join(out_dir, name)
        with open(path, "w", newline="\n") as fh:
            fh.write(text)
        n = int(text.split("\n")[1], 16)
        assert n == N_PAD, "%s 的用例数 %d != N_PAD %d" % (name, n, N_PAD)
        print("  写入 %s（%d 个用例）" % (path, n))


def data_lines(text):
    return [ln.strip() for ln in text.replace("\r\n", "\n").split("\n") if ln.strip()]


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
            print("  [PASS] %s 数据一致（行尾换行/CRLF 不同，不影响读表）" % path)
        else:
            print("  [FAIL] %s 与生成器不一致（文件被改过？需重新生成）" % path)
            bad += 1
    return bad


def report():
    """打印一些"这批向量到底覆盖了什么"的统计，方便判断测试有没有牙齿。"""
    print("覆盖统计：")
    for name in sorted(PRESETS):
        cfg = PRESETS[name]
        cases = gen_cases(cfg["iw"], cfg["aw"], cfg["shift"])
        sat = tot = 0
        for (i, q, c, s) in cases:
            lo, hi = clog2_range(cfg["ow"])
            i_sh, q_sh = shifted(i, q, c, s, **cfg)
            if i_sh < lo or i_sh > hi or q_sh < lo or q_sh > hi:
                sat += 1
            tot += 1
        print("  mixer_%s.txt  %4d 个用例，其中 %4d 个会碰到饱和（%.1f%%）"
              % (name, tot, sat, 100.0 * sat / tot))
    # a 与 d 只差舍入方式，统计有多少个用例结果不同
    ca, cd = PRESETS["a"], PRESETS["d"]
    cases = gen_cases(ca["iw"], ca["aw"], ca["shift"])
    diff = sum(1 for (i, q, c, s) in cases
               if model(i, q, c, s, **ca) != model(i, q, c, s, **cd))
    print("  a(ROUND=1) 与 d(ROUND=0) 有 %d / %d 个用例结果不同 —— "
          "这条差异必须能被测试抓到，否则 ROUND 参数是摆设" % (diff, len(cases)))


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="生成 s02 复数混频器的参考向量（Python 参考模型）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录")
    ap.add_argument("--check", metavar="DIR", default=None,
                    help="只校验 DIR 里已有的文件，不写入")
    args = ap.parse_args(argv)

    files = build_all()
    if args.check is not None:
        print("校验 %s" % args.check)
        bad = check_files(files, args.check)
        if bad:
            print("结果：%d 个文件不一致" % bad)
            return 1
        print("结果：全部一致")
        return 0

    print("生成 %d 组参考向量（种子 %d，每组 %d 个随机用例 + 边界/单位本振扫描）"
          % (len(PRESETS), SEED, N_RANDOM))
    write_files(files, args.out)
    report()
    print("完成。testbench 里用 $readmemh 读，注意路径是相对**仿真工作目录**的，")
    print("所以 sim.sh 会传宏 VECDIR（绝对路径）进来。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
