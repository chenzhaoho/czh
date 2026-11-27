# 双异步 FIFO 系统

硬件描述语言课程设计题目 27 的双异步 FIFO 工程。基础顶层包含两个 256×32 位 FIFO、独立的读写时钟和统一监控。唯一的应用拓展是 [双异步 FIFO 实时终端](doc/terminal_live/README.md)。网页上的文本经过 ModelSim 中的两个 RTL FIFO，原始握手和波形可下载核对。

实时终端使用的双向链路已封装为可导入 Vivado IP Catalog 的参数化 IP。可在一台 PC 上生成 IP 包、回归 16 种参数和时钟组合，并在两个独立的 Artix-7 工程中复验。[通用 IP 核使用与验证](ip/README.md)

## 环境

- Windows 10/11，Git，Python 3.10 或更新版本，现代浏览器。
- 已实测 ModelSim-Altera Starter Edition 10.3c。安装的 ModelSim 需提供 `vsim.exe`、`vlog.exe`、`vlib.exe`。导出 WLF 还需 `vcd2wlf.exe`。启动前将其所在目录设为 `MODELSIM_BIN`，或加入 `PATH`。
- 用 ASCII 目录检出，例如 `C:\work\czh`。ModelSim 10.3c 的工作库路径对非 ASCII 字符支持有限，工具安装在短 ASCII 路径可减少旧版路径问题。
- 仿真和网页运行使用 Python 标准库，无需 Python 第三方包、FPGA 板或传感器。

## 从 GitHub 运行

在一个 ASCII 路径的目录中打开 PowerShell。下面的 ModelSim 路径需要换成你的安装目录。

```powershell
git clone --filter=blob:none --sparse https://github.com/chenzhaoho/czh.git
Set-Location czh
git sparse-checkout set dsh_fifo
Set-Location dsh_fifo
$env:MODELSIM_BIN = 'C:\tools\modelsim_ase\win32aloem'

.\scripts\run_terminal_live.cmd --gui
```

命令窗口出现 `LIVE_TERMINAL_READY` 后打开 [本机实时终端](http://127.0.0.1:8765/)。窗口需要保持运行。去掉 `--gui` 可只用网页和命令行。端口占用时可追加 `--port 8766` 并访问对应端口。若系统没有 `py` 或 `python`，可用 `TERMINAL_PYTHON` 指向已安装的 Python 可执行文件。

点击“运行堵塞实验”后，A→B 达到 256 字并产生背压，B→A 的测试消息仍可到达。点击 B 端“恢复本端接收”，观察积压读出和 CRC32 校验。网页可以切换按需、连续和手动推进。退出服务请在启动窗口按 Ctrl+C。

## 从源码复验

以下命令在 `dsh_fifo/` 根目录执行。仿真库、日志和波形由脚本生成。

| 目的 | 命令 | 通过判据 |
|---|---|---|
| 原题默认功能和波形 | `.\scripts\run_sim.cmd tc1 1 2 dump` | 输出 PASS，在 `sim/waves/` 生成 VCD |
| 原题双配置回归 | `.\scripts\regression.cmd` | 2 级、3 级同步各 9 项全部 PASS |
| 同步读专项 | `.\scripts\run_sim.cmd std 1 2 verify` | `tb_std_read` 输出 PASS |
| 终端 RTL 数据与波形 | `python scripts/test_terminal_live.py` | 通过字序、CRC、读写、指针及独立 VCD 核对 |
| 终端按需和单步推进 | `python scripts/test_terminal_scheduling.py` | 通过空闲和堵塞冻结、双向恢复及三种推进模式检查 |
| 在运行时导出波形 | `.\scripts\open_terminal_live_wave.cmd` | 独立 VCD 审计 PASS，并打开导出的 WLF |
| 验证报告 | `python scripts/verify_all.py --fast` | 18/18 回归及合并覆盖率写入 `doc/verify_report.html` |

如使用不同端口，在波形命令后加 `--port 8766`。终端测试报告和会话证据在 `build/terminal_live/`。原题的判据、覆盖率和变异测试见 [验证指南](VERIFY.md)。

## 课程报告与附加验证

- [课程设计报告](doc/课程设计报告_双异步FIFO系统.md) 包含基础设计、验证、PPA 分析和实时终端。安装 `python-docx==1.2.0` 后运行 `python scripts/build_docx.py` 可生成同目录的 Word 版本。
- Verilator 可选。用 `VERILATOR_EXE` 指定可执行文件，运行 `python scripts/lint_rtl.py`。
- 从当前 RTL 复算 PPA 需要 Vivado 2020.2 和 Artix-7 器件支持。设 `$env:VIVADO_EXE = 'C:\Xilinx\Vivado\2020.2\bin\vivado.bat'`，用 `powershell -NoProfile -ExecutionPolicy Bypass -File .\syn\run_vivado.ps1` 生成 `syn/vivado/` 报告。加 `-Config dual_rm1_pipe` 可单独运行同步读配置。当前源码复验中，该配置完成布线，`rd_clk_b` 在 4 ns 约束下 WNS 为 −0.058 ns，建时违例 9 个。
- [SKY130 参数与 MTBF 分析](pdk/README.md) 说明可选工艺模型的固定版本和提取方法。RTL 仿真无需安装该工艺库。

## 工程目录

| 目录 | 内容 |
|---|---|
| `rtl/common/`、`rtl/fifo/`、`rtl/top/` | 基础 FIFO、CDC 同步、双通道顶层和监控 |
| `rtl/ext/dual_fifo_link.v` | 实时终端使用的双向 RTL 数据链路 |
| `ip/` | 双向异步 FIFO IP 的参数、封装、约束、消费工程示例和验收记录 |
| `tb/` | 原题用例、同步读及实时终端 testbench |
| `scripts/` | 编译、仿真、审计和启动脚本 |
| `doc/terminal_live/` | 终端页面与操作说明 |
| `syn/` | 可选的 Vivado 综合和实现脚本 |
