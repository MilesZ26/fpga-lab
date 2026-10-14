#!/bin/sh
# 安装仿真器。
#   1) 已有 iverilog       → 跳过
#   2) 有 Homebrew         → brew install
#   3) 都没有              → 源码编译进本仓库 tools/（不需要 sudo）
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
TOOLS="$ROOT/tools"

# 已验证：该 tag 的源码包自带 configure，无需 autoconf
IVERILOG_TAG="v13_0"

# macOS 自带的 /usr/bin/bison 是 2.3（2006 年），解析不了 iverilog vhdlpp/parse.y
# 里的 `%define api.pure`。bison >= 3 才够用，不够就自己编一个进 tools/。
BISON_TAG="3.8.2"
BISON_MIN_MAJOR=3

# 找出一个"够新"的 bison，把路径写进 $BISON_BIN；找不到就留空。
pick_bison() {
    for cand in "$TOOLS/bison/bin/bison" "$(command -v bison 2>/dev/null || true)"; do
        [ -n "$cand" ] && [ -x "$cand" ] || continue
        # "bison (GNU Bison) 3.8.2" → 3
        v=$("$cand" --version 2>/dev/null | sed -n '1s/[^0-9]*\([0-9][0-9]*\)\..*/\1/p' || true)
        if [ -n "$v" ] && [ "$v" -ge "$BISON_MIN_MAJOR" ]; then
            BISON_BIN="$cand"
            return 0
        fi
    done
    BISON_BIN=""
}

echo "══ 检查现有仿真器 ══"

if [ -x "$TOOLS/iverilog/bin/iverilog" ]; then
    echo "✓ 已在 tools/ 里："
    "$TOOLS/iverilog/bin/iverilog" -V 2>&1 | head -1
    exit 0
fi

if command -v iverilog >/dev/null 2>&1; then
    echo "✓ 系统已安装：$(command -v iverilog)"
    iverilog -V 2>&1 | head -1
    echo "无需再装。"
    exit 0
fi

echo "未找到 iverilog。"
echo ""

if command -v brew >/dev/null 2>&1; then
    echo "══ 检测到 Homebrew，用它安装 ══"
    brew install icarus-verilog
    echo ""
    echo "✓ 完成"
    echo ""
    echo "可选（推荐后续装）："
    echo "    brew install verilator    # 更严格的 lint、SVA 断言"
    echo "    brew install gtkwave      # 看波形"
    exit 0
fi

echo "══ 没有 Homebrew，改为源码编译到 tools/ ══"
echo "   （不写系统目录，不需要 sudo）"
echo ""

for t in clang curl make tar m4; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "✗ 缺少 $t" >&2
        echo "  clang 可以通过：xcode-select --install" >&2
        exit 1
    }
done

mkdir -p "$TOOLS/src"

# ---- 第一步：bison（iverilog 的语法分析器生成器）----
pick_bison
if [ -n "$BISON_BIN" ]; then
    echo "✓ bison 够新，直接用：${BISON_BIN}（$("$BISON_BIN" --version | head -1)）"
else
    echo "→ 系统 bison 版本过低（$(bison --version 2>/dev/null | head -1 || true)），源码编译 bison $BISON_TAG"
    BISON_URL="https://ftp.gnu.org/gnu/bison/bison-${BISON_TAG}.tar.gz"
    BISON_TAR="$TOOLS/src/bison-${BISON_TAG}.tar.gz"
    [ -f "$BISON_TAR" ] || curl -fL --progress-bar "$BISON_URL" -o "$BISON_TAR"
    BISON_DIR=$(tar tzf "$BISON_TAR" | head -1 | cut -d/ -f1)
    rm -rf "$TOOLS/src/$BISON_DIR"
    tar xzf "$BISON_TAR" -C "$TOOLS/src"
    (
        cd "$TOOLS/src/$BISON_DIR" || exit 1
        ./configure --prefix="$TOOLS/bison" > "$TOOLS/src/bison-configure.log" 2>&1 || {
            echo "✗ bison configure 失败，见 $TOOLS/src/bison-configure.log" >&2
            exit 1
        }
        make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" > "$TOOLS/src/bison-make.log" 2>&1 || {
            echo "✗ bison 编译失败，见 $TOOLS/src/bison-make.log" >&2
            tail -20 "$TOOLS/src/bison-make.log" >&2
            exit 1
        }
        make install > "$TOOLS/src/bison-install.log" 2>&1 || exit 1
    ) || exit 1
    BISON_BIN="$TOOLS/bison/bin/bison"
    echo "✓ bison 装好：$("$BISON_BIN" --version | head -1)"
fi

# 让后续 iverilog 的 make 用上这个 bison
PATH="$(dirname "$BISON_BIN"):$PATH"
export PATH
echo ""

# ---- 第二步：iverilog ----
URL="https://github.com/steveicarus/iverilog/archive/refs/tags/${IVERILOG_TAG}.tar.gz"
TARBALL="$TOOLS/src/iverilog-${IVERILOG_TAG}.tar.gz"

if [ ! -f "$TARBALL" ]; then
    echo "→ 下载 $URL"
    curl -fL --progress-bar "$URL" -o "$TARBALL"
fi

echo "→ 解包"
DIR=$(tar tzf "$TARBALL" | head -1 | cut -d/ -f1)
rm -rf "$TOOLS/src/$DIR"
tar xzf "$TARBALL" -C "$TOOLS/src"

cd "$TOOLS/src/$DIR"

echo "→ configure（安装到 $TOOLS/iverilog）"
./configure --prefix="$TOOLS/iverilog" > "$TOOLS/src/configure.log" 2>&1 || {
    echo "✗ configure 失败，见 $TOOLS/src/configure.log" >&2
    tail -20 "$TOOLS/src/configure.log" >&2
    exit 1
}

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
echo "→ 编译（-j${JOBS}，几分钟）"
make -j"$JOBS" > "$TOOLS/src/make.log" 2>&1 || {
    echo "✗ 编译失败，见 $TOOLS/src/make.log" >&2
    tail -30 "$TOOLS/src/make.log" >&2
    exit 1
}

echo "→ 安装"
make install > "$TOOLS/src/install.log" 2>&1

echo ""
echo "✓ 完成：$TOOLS/iverilog/bin/iverilog"
"$TOOLS/iverilog/bin/iverilog" -V 2>&1 | head -1
echo ""
echo "现在可以运行：  make sim"
