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
	@echo "  make lut              重新生成 NCO 查表数据（s01_nco/lut/*.mem）"
	@echo "  make lut-check        只校验表文件与生成器一致，不写文件"
	@echo "  make mixer-vec        重新生成 s02 混频器的 Python 参考向量"
	@echo "  make mixer-vec-check  只校验参考向量与生成器一致，不写文件"
	@echo "  make fir-coef         重新生成 FIR 系数表（s03_fir/lut/*.mem）"
	@echo "  make fir-coef-check   只校验系数表与生成器一致，不写文件"
	@echo "  make fir-vec          重新生成 s03 FIR 的 Python 参考向量"
	@echo "  make fir-vec-check    只校验参考向量与生成器一致，不写文件"
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

# ── NCO 查表数据 ─────────────────────────────────────────────
# 表的"真值"由 scripts/gen_lut.py 离线生成（Vivado 综合不了 $sin，必须是常量）。
# .mem 文件本身入库（仿真和综合要用同一份数据），这个目标只负责重新生成。
PYTHON ?= python3

lut:
	@$(PYTHON) scripts/gen_lut.py --out s01_nco/lut

lut-check:
	@$(PYTHON) scripts/gen_lut.py --check s01_nco/lut

# ── s02 混频器参考向量 ───────────────────────────────────────
# 由 scripts/gen_mixer_vec.py 用 Python 参考模型生成（验收用的 golden vectors，
# 和 RTL 完全无关的一份实现 —— 这是它能抓 bug 的前提）。
# 生成器里带 assert（输入越界、用例数没对齐都会直接报错），所以重新生成是安全的。
# ⚠️ 用例数变了要同步改 s02_mixer/tb/tb_mixer.v 里的 VEC_MAX_CASES。
mixer-vec:
	@$(PYTHON) scripts/gen_mixer_vec.py --out s02_mixer/vec

mixer-vec-check:
	@$(PYTHON) scripts/gen_mixer_vec.py --check s02_mixer/vec

# ── s03 FIR 系数 / 参考向量 ──────────────────────────────────
# 系数表由 scripts/gen_fir_coef.py 用窗函数法离线设计 + Q1.15 量化；
# 参考向量由 scripts/gen_fir_vec.py 用 Python 逐位模型生成。
# 三者（coef.mem / fir_vec.txt / tb_fir.v 的参数）是**成套**的：
# 头 9 个字里存了 IW/OW/SHIFT/ROUND 和系数校验和，TB 会先对一遍。
fir-coef:
	@$(PYTHON) scripts/gen_fir_coef.py --out s03_fir/lut

fir-coef-check:
	@$(PYTHON) scripts/gen_fir_coef.py --check s03_fir/lut

fir-vec:
	@$(PYTHON) scripts/gen_fir_vec.py --out s03_fir/vec

fir-vec-check:
	@$(PYTHON) scripts/gen_fir_vec.py --check s03_fir/vec

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

.PHONY: help setup sim lint list wave lut lut-check mixer-vec mixer-vec-check fir-coef fir-coef-check fir-vec fir-vec-check clean hooks check
