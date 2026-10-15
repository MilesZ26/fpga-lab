#!/bin/sh
# 一键仿真：自动发现所有 testbench，用 iverilog 编译并运行。
#
#   sh scripts/sim.sh                          跑全部
#   sh scripts/sim.sh s00_blinky/tb/tb_blinky.v  只跑一个
#   sh scripts/sim.sh --list                   列出所有 testbench

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
BUILD="$ROOT/build"
TARGET=$1

find_tbs() {
    cd "$ROOT" || exit 1
    find . -name 'tb_*.v' \
        -not -path './build/*' -not -path './tools/*' \
        | sed 's|^\./||' | sort
}

if [ "$TARGET" = "--list" ]; then
    find_tbs
    exit 0
fi

# ── 找仿真器 ─────────────────────────────────────────────
SIM=""
if [ -x "$ROOT/tools/iverilog/bin/iverilog" ]; then
    SIM="$ROOT/tools/iverilog/bin/iverilog"
    PATH="$ROOT/tools/iverilog/bin:$PATH"
    export PATH
elif command -v iverilog >/dev/null 2>&1; then
    SIM=$(command -v iverilog)
fi

if [ -z "$SIM" ]; then
    echo "✗ 找不到仿真器 iverilog" >&2
    echo "" >&2
    echo "  先运行：  make setup" >&2
    exit 1
fi

echo "仿真器: $SIM"
mkdir -p "$BUILD"
echo ""

if [ -n "$TARGET" ]; then
    TBS=$TARGET
else
    TBS=$(find_tbs)
fi

if [ -z "$TBS" ]; then
    echo "没有找到任何 testbench（tb_*.v）"
    exit 0
fi

TOTAL=0
FAILED=0

for TB in $TBS; do
    TOTAL=$((TOTAL + 1))
    TBPATH="$ROOT/$TB"

    if [ ! -f "$TBPATH" ]; then
        echo "✗ 找不到 $TB"
        FAILED=$((FAILED + 1))
        continue
    fi

    TBDIR=$(dirname "$TBPATH")
    STAGE=$(printf '%s' "$TB" | cut -d/ -f1)
    NAME=$(basename "$TB" .v)
    CLOG="$BUILD/$NAME.compile.log"
    RLOG="$BUILD/$NAME.run.log"
    VVP="$BUILD/$NAME.vvp"

    if [ -d "$ROOT/$STAGE/rtl" ]; then
        DUTDIR="$ROOT/$STAGE/rtl"
    else
        DUTDIR="$ROOT/rtl/common"
    fi

    SRCS=$(find "$DUTDIR" -name '*.v' | sort | tr '\n' ' ')

    # 查表数据目录（sNN_xxx/lut/）。$readmemh 的路径是相对**仿真进程的工作目录**，
    # 而 vvp 是在 build/ 里跑的 —— RTL 里写 "s01_nco/lut/sin.mem" 这种相对路径
    # 一定找不到。所以这里把绝对路径以宏 LUTDIR 传进去，RTL 侧写：
    #     `ifndef LUTDIR
    #       `define LUTDIR "s01_nco/lut/"    // 综合/手工跑时的兜底
    #     `endif
    #     $readmemh({`LUTDIR, "sin.mem"}, rom);
    # 注意 -D 的值需要带**真正的双引号**，所以下面用 \"；路径含空格会散架（本仓库不会）。
    LUTDEF=""
    if [ -d "$ROOT/$STAGE/lut" ]; then
        LUTDEF="-DLUTDIR=\"$ROOT/$STAGE/lut/\""
    fi

    echo "──────────────────────────────────────────────"
    echo "▶ $TB"

    # shellcheck disable=SC2086
    "$SIM" -g2005 -Wall -s "$NAME" \
        -I "$TBDIR" -I "$ROOT/tb" -I "$ROOT/rtl/common" -I "$DUTDIR" \
        $LUTDEF -DDUMP_VCD -o "$VVP" $SRCS "$TBPATH" > "$CLOG" 2>&1
    RC=$?

    if [ "$RC" -ne 0 ]; then
        echo "  ✗ 编译失败"
        sed -n '1,30p' "$CLOG" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
        continue
    fi

    rm -f "$BUILD/dump.vcd"
    ( cd "$BUILD" && vvp "$VVP" ) > "$RLOG" 2>&1

    if [ -f "$BUILD/dump.vcd" ]; then
        mv -f "$BUILD/dump.vcd" "$BUILD/$NAME.vcd"
    fi

    if grep -q 'TEST PASSED' "$RLOG"; then
        NPC=$(grep -c '\[PASS\]' "$RLOG")
        echo "  ✓ 通过（$NPC 个检查点）"
        [ -f "$BUILD/$NAME.vcd" ] && echo "    波形: build/$NAME.vcd"
    else
        echo "  ✗ 失败"
        grep '\[FAIL\]' "$RLOG" | head -20 | sed 's/^/    /'
        tail -5 "$RLOG" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "══════════════════════════════════════════════"
if [ "$FAILED" -eq 0 ]; then
    # 注意 ${TOTAL} 必须带花括号：见 docs/进度.md「已知坑 5」
    echo "结果：全部通过（${TOTAL}/${TOTAL}）"
    exit 0
else
    echo "结果：失败 $FAILED / $TOTAL"
    exit 1
fi
