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

    # ── 跨 stage 依赖（sNN_xxx/deps.txt）─────────────────────────────
    # 板级顶层会复用别的 stage 的模块（比如 s02 的 mixer_top 要例化 s01 的 nco），
    # 而这个模块不在本 stage 的 rtl/ 里。deps.txt 每行写一个 **stage 目录名**：
    #     s01_nco
    # 这里就把它的 rtl/*.v 编进来，并把它加进 -I（`include 用）。
    DEPDIRS=""
    if [ -f "$ROOT/$STAGE/deps.txt" ]; then
        DEPDIRS=$(tr -d '\r' < "$ROOT/$STAGE/deps.txt" \
                  | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
    fi

    # 顶层模块（nco_top / mixer_top 这种）还会实例化 rtl/common 里的模块
    # （reset_sync / edge_detect / sync_2ff）。所以文件清单 = 本 stage rtl/
    # + rtl/common + 各依赖 stage 的 rtl/，最后 sort -u 去重 ——
    # 同一个文件列两次，iverilog 会报模块重复定义。
    COMMONDIR="$ROOT/rtl/common"
    RTLS="$DUTDIR $COMMONDIR"
    DEPINCS=""
    for D in $DEPDIRS; do
        if [ -d "$ROOT/$D/rtl" ]; then
            RTLS="$RTLS $ROOT/$D/rtl"
            DEPINCS="$DEPINCS -I $ROOT/$D/rtl"
        else
            echo "  ⚠ deps.txt 里写的 $D 没有 rtl/ 目录，已忽略" >&2
        fi
    done
    SRCS=$(for d in $RTLS; do find "$d" -name '*.v'; done | sort -u | tr '\n' ' ')

    # ── 查表数据目录（sNN_xxx/lut/）→ 一个表一个宏 ─────────────────────
    # $readmemh 的路径是相对**仿真进程的工作目录**，而 vvp 是在 build/ 里跑的 ——
    # RTL 里写 "s01_nco/lut/sin.mem" 这种相对路径一定找不到。所以这里把绝对路径
    # 以宏传进去，RTL 侧写：
    #     `ifndef NCO_LUTDIR
    #       `define NCO_LUTDIR "s01_nco/lut/"   // 综合/手工跑时的兜底
    #     `endif
    #     $readmemh({`NCO_LUTDIR, "sin.mem"}, rom);
    # 注意 -D 的值需要带**真正的双引号**，所以下面用 \"；路径含空格会散架（本仓库不会）。
    #
    # ⚠️ 2026-10-18 改：以前全仓库只有一个 LUTDIR，s03 有 FIR 系数表之后会打架
    #    （同一轮仿真里 nco.v 要 s01 的表、fir.v 要 s03 的表，一个宏只能指一个目录）。
    #    现在按 stage 给语义宏：s01_nco → NCO_LUTDIR，s03_fir → FIR_COEFDIR。
    #    新增带 lut/ 的 stage 时，在下面 table_macro_for 里加一行；RTL 里用对应宏。
    table_macro_for() {
        case "$1" in
            s01_nco) echo NCO_LUTDIR ;;
            s03_fir) echo FIR_COEFDIR ;;
            *)       echo "" ;;
        esac
    }

    # 当前 stage + 依赖 stage，去重后逐个查 lut/（同 stage 只传一次宏）
    TABLEDEF=""
    SEEN_STAGES=" "
    for D in $STAGE $DEPDIRS; do
        case "$SEEN_STAGES" in
            *" $D "*) continue ;;
        esac
        SEEN_STAGES="$SEEN_STAGES$D "
        [ -d "$ROOT/$D/lut" ] || continue
        TMAC=$(table_macro_for "$D")
        if [ -z "$TMAC" ]; then
            echo "  ⚠ $D/lut 存在但没有宏映射，这份表不会被加载" >&2
            continue
        fi
        TABLEDEF="$TABLEDEF -D${TMAC}=\"$ROOT/$D/lut/\""
    done

    # ── 参考向量目录（sNN_xxx/vec/）→ 宏 VECDIR ──────────────────────
    # 同查表：$readmemh 读不到文件时**不报错**，所以一律传绝对路径。
    # 向量文件由 scripts/gen_mixer_vec.py / gen_fir_vec.py 生成（Python 参考模型）。
    # 一个 testbench 只读自己 stage 的 vec/，所以这里不需要"一张表一个宏"。
    VECDEF=""
    if [ -d "$ROOT/$STAGE/vec" ]; then
        VECDEF="-DVECDIR=\"$ROOT/$STAGE/vec/\""
    fi

    echo "──────────────────────────────────────────────"
    echo "▶ $TB"

    # shellcheck disable=SC2086
    "$SIM" -g2005 -Wall -s "$NAME" \
        -I "$TBDIR" -I "$ROOT/tb" -I "$ROOT/rtl/common" -I "$DUTDIR" $DEPINCS \
        $TABLEDEF $VECDEF -DDUMP_VCD -o "$VVP" $SRCS "$TBPATH" > "$CLOG" 2>&1
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
