#!/bin/sh
# 静态检查：只做语法与警告检查，不生成输出。

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1

SIM=""
if [ -x "$ROOT/tools/iverilog/bin/iverilog" ]; then
    SIM="$ROOT/tools/iverilog/bin/iverilog"
elif command -v iverilog >/dev/null 2>&1; then
    SIM=$(command -v iverilog)
fi

if [ -z "$SIM" ]; then
    echo "✗ 找不到 iverilog，先运行：make setup" >&2
    exit 1
fi

SRCS=$(find "$ROOT/rtl" "$ROOT"/s*/rtl -name '*.v' 2>/dev/null | sort)
if [ -z "$SRCS" ]; then
    echo "没有找到 RTL 文件"
    exit 0
fi

INCS="-I $ROOT/rtl/common"
for d in "$ROOT"/s*/rtl; do
    [ -d "$d" ] && INCS="$INCS -I $d"
done

N=$(printf '%s\n' "$SRCS" | wc -l | tr -d ' ')
echo "检查 $N 个 RTL 文件..."

# shellcheck disable=SC2086
"$SIM" -g2005 -Wall -t null $INCS $SRCS
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "✓ 通过"
else
    echo "✗ 发现问题（见上方输出）"
    exit 1
fi
