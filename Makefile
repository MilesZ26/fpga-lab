# fpga-lab 顶层 Makefile —— 统一入口
SHELL := /bin/sh
.DEFAULT_GOAL := help

TB ?=
VCD ?=

help:
	@echo "fpga-lab — 可用命令"
	@echo ""
	@echo "  make setup            首次使用：安装仿真器 (iverilog)"
	@echo "  make sim              跑全部 testbench"
	@echo "  make sim TB=<路径>    只跑一个"
	@echo "                        例：make sim TB=s00_blinky/tb/tb_blinky.v"
	@echo "  make lint             静态检查所有 RTL"
	@echo "  make list             列出所有 testbench"
	@echo "  make wave             列出已有波形 / 打开指定波形"
	@echo "                        例：make wave VCD=build/tb_blinky.vcd"
	@echo "  make clean            删除 build/"
	@echo ""
	@echo "  make hooks            安装 pre-commit 守卫（拦住 Vivado 中间产物）"
	@echo "  make check            只检查暂存区，不提交"
	@echo ""
	@echo "注意：Vivado 的综合/实现/上板在 Windows 机器上做，本仓库不跑 Vivado。"
	@echo "      新克隆仓库后建议先跑一次： make hooks"

setup:
	@sh scripts/setup_tools.sh

sim:
	@sh scripts/sim.sh $(TB)

lint:
	@sh scripts/lint.sh

list:
	@sh scripts/sim.sh --list

wave:
	@if [ -z "$(VCD)" ]; then \
		echo "已生成的波形："; \
		ls -1 build/*.vcd 2>/dev/null || echo "  (还没有，先跑 make sim)"; \
		echo ""; \
		echo "打开某个波形：make wave VCD=build/tb_blinky.vcd"; \
	elif command -v surfer >/dev/null 2>&1; then \
		echo "用 Surfer 打开 $(VCD)"; \
		surfer "$(VCD)" & \
	elif command -v gtkwave >/dev/null 2>&1; then \
		echo "用 GTKWave 打开 $(VCD)"; \
		gtkwave "$(VCD)" & \
	else \
		echo "没找到波形查看器。装一个："; \
		echo ""; \
		echo "    brew install surfer     # 推荐，原生支持 Apple Silicon"; \
		echo ""; \
		echo "（Homebrew 本身也还没装的话，见 docs/进度.md 的「装图形界面」一节）"; \
		exit 1; \
	fi

clean:
	@rm -rf build
	@echo "已删除 build/"

# ── git 守卫 ─────────────────────────────────────────────────────────
# 新克隆下来的仓库没有钩子（.git/hooks 不进版本库），所以要装一次。
hooks:
	@if [ ! -d .git/hooks ]; then \
		echo "✗ 找不到 .git/hooks —— 这里不是 git 仓库根目录"; exit 1; \
	fi
	@cp scripts/hooks/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "✓ pre-commit 守卫已安装：.git/hooks/pre-commit"
	@echo "  以后 git commit 会在写库前自动拦截 Vivado 中间产物和大文件。"

check:
	@sh scripts/hooks/pre-commit && echo "✓ 暂存区没问题"

.PHONY: help setup sim lint list wave clean hooks check
