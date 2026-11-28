# 双向异步 FIFO IP 1.0 验收记录

2026-11-28。首版实现见 [d7c690d](https://github.com/chenzhaoho/czh/commit/d7c690da99bb2a0e52c44899501b0ceabad70b90)，课程工程起点为 `776f184`。复验环境为 Windows x64、Python 3.13.9、ModelSim-Altera 10.3c、Vivado 2020.2 build 3064766。完整命令见 [使用说明](README.md)。

## 1.0 修订 2 的复验

对照《异步FIFO通道验证与缺陷分析报告》，用发布包的 RTL 重跑 G1 和 G3。A→B、B→A 各通过 S1–S6，共 24/24。每方向的写满和排空分别为 256/256 或 64/64 字，错字均为 0。满时保持 valid、空时保持 ready 各 300 拍，成功计数无额外增长。该 IP 的读取路径使用 FWFT，读指针在外部读握手时推进。附件 G5 的预取输出寄存器和 G6 的同步读组合属于 `fifo_channel` 的实现选项。

在实际 Vivado IP Catalog 实例中，A 端使用 BUFGMUX 选择 10 ns 或 19 ns 时钟，B 端为 14 ns。首版 XDC 尝试把 `10.000 19.000` 作为一个浮点数计算，Vivado 给出 critical warning，Gray 路径缺少 datapath-only 例外。修订后从实际 Gray 寄存器的时钟引脚取时钟集合，给有效模式统一施加 10 ns 限时。精简参考工程另用 A 端 9 ns / 19 ns、B 端 14 ns 重做布线后分析。四组 28 位 Gray 路径和两种 A 模式下的 RAM 捕获均有 9 ns 限时，最大实际 Gray 总线偏斜为 0.812 ns。

| 修订后复验 | 结果 |
|---|---|
| 发布包的 8 组参数 × 常规两种时钟次序，种子 93 | 16/16 |
| 发布包的 8 组参数 × 同相及两种 50:1 时钟次序，种子 111 | 24/24，逐组暂停、恢复 A 和 B 时钟，并在停钟时复位 |
| Artix-7 参考工程布线 | 两组均通过，10 ns / 14 ns 下裕量与下表一致 |

压力仿真的 2 ns 时钟用于增加跨域采样跨度。FPGA 实现的时钟条件见下方布线表。附加 Vivado 检查的逐位路径、总线偏斜和两种时钟模式下的代表性路径分别记录在 `compact/clock_modes/gray_paths.tsv`、`bus_skew.rpt` 和 `clock_modes.tsv`。

## 从端口检验实际收发

| 编译输入 | 种子 | 运行数 | 通过数 |
|---|---:|---:|---:|
| `ip/rtl_sources.f` 中的仓库 RTL | 27 | 16 | 16 |
| 生成包的 `component.xml` 指定的仿真文件组 | 93 | 16 | 16 |

每轮覆盖 8 个合法参数组合和两种时钟快慢关系。两轮读入的 6 个 RTL 文件按文件名逐个比对，SHA-256 全部相同。每次都检查接受写入的数量、读出的字序、背压时的数据稳定、两路独立满及复位。默认配置、A 时钟为 10 ns 的种子 27 日志提供了一个可复算的例子。

| 时刻 | A→B 累计写 / 读 | B→A 累计写 / 读 | 可核对的事实 |
|---|---:|---:|---|
| 随机并发结束 | 1178 / 1178 | 1192 / 1192 | 双向读回数据均与对应参考队列一致，已跨过 512 字的扩展指针回绕点 |
| 公共复位之前 | 1434 / 1178 | 1448 / 1192 | 每路各剩 256 个字，同时为满 |
| 公共复位之后 | 19 / 19 | 23 / 23 | 两端只收到新一轮的有效字，两个参考队列均已排空 |

## Artix-7 布线结果

在两个独立工程中，Vivado 从 IP Catalog 创建 `duplex_i`。参考器件为 `xc7a35tcsg324-1`，A、B 的输入周期分别为 10 ns、14 ns。数字来自布线后的整套示例，包括两端的激励、采样及输出逻辑。

| 指标 | 默认 32 位 × 256 字 / 2 级 | 精简 16 位 × 64 字 / 3 级 |
|---|---:|---:|
| 综合方式 | IP 单独综合（OOC） | IP 随顶层综合 |
| 建立裕量 WNS | +2.703 ns | +2.703 ns |
| 保持裕量 WHS | +0.061 ns | +0.049 ns |
| 建立 / 保持违例端点 | 0 / 0 | 0 / 0 |
| 已布线 / 需布线网络 | 928 / 928 | 467 / 467 |
| 未约束内部端点 / 无时钟寄存器引脚 | 0 / 0 | 0 / 0 |
| Slice LUT（其中用作存储） | 647（352） | 211（48） |
| Slice Registers / Block RAM Tile | 460 / 0 | 346 / 0 |
| 四组 Gray 指针的首级端点数 | 36（4 × 9） | 28（4 × 7） |
| Gray 跨域最大延迟的最小裕量，预算 10 ns | +8.703 ns | +8.686 ns |
| 同步链级间最小建立裕量 | +8.636 ns | +8.542 ns |
| 四组中最大的实际总线偏斜，预算 10 ns | 0.956 ns | 0.812 ns |

`check_timing` 单独列出公共异步复位输入和两根转发时钟输出。前者在参考顶层对外部异步复位定义 false path，后两者本身是采样时钟。两根活动数据输出各有相对于对应转发时钟的最大、最小输出延迟。

### CDC 报告中保留的项目

| Vivado 分类 | 默认 / 精简 | 电路含义与检查 |
|---|---:|---|
| `CDC-6 Warning` | 4 / 4 | 两个 FIFO 各有读、写 Gray 指针。检查源位与首级目的位对应、每级 ASYNC_REG、跨域实际 datapath-only 限时、四组总线偏斜和后续同域路径 |
| `CDC-15 Warning` | 128 / 64 | 分布式 RAM 的异步读数据被同域使能控制的寄存器捕获。两方向、每数据位分别落到 FIFO 的上一次读出寄存器和示例消费寄存器。核对每条报告的源、目的和生效的限时，功能仿真用握手与参考队列检验读数 |
| `CDC-9 Info` | 6 / 6 | 外部低有效复位进入各本地同步释放链。核对首级复位引脚、同步级数以及 ASYNC_REG 识别结果 |

上述数量适用于随附的集成示例。接入不同的接收逻辑后应重查其实际捕获路径。此版验证到 FPGA 器件模型布线和 PC 上的真实 RTL 仿真。更换器件、时钟周期或系统时序例外时需要重新实现。课程原顶层的 4 ns 结果另见 [工程说明](../README.md)。实物板卡、其他器件系列及最高运行频率均未测量。

## 从输出目录复核

| 相对于工程根目录的位置 | 复核内容 |
|---|---|
| `build/ip_repo/dual_fifo_link_1_0/component.xml` | 核标识、参数、端口、综合和仿真文件组；目录中包括相对路径引用的全部源文件 |
| `build/ip_sim/run-*/matrix.json`、`source_hashes.json`、`dw*_aw*_s*_swap*.log` | 每种配置的种子、运行结果、源码指纹、时钟、读写计数和 IP_PASS 标记 |
| `build/ip_verify/run-*/{default,compact}/result.txt` | 配置、综合方式、建立和保持裕量、布线数、偏斜与 CDC 计数。脚本通过全部检查后写入 |
| 同目录的 `timing.rpt`、`utilization.rpt`、`route.rpt`、`check_timing.rpt` | 时序、资源、布线和未约束端点 |
| 同目录的 `cdc.rpt`、`exceptions.rpt`、`bus_skew.rpt`、`gray_paths.tsv` | 跨域分类、例外、四组总线及逐位同步路径 |
| `build/terminal_live/integration_results.json`、`scheduling_results.json` | 真实终端数据、调度和独立波形检查。检查两份文件的 `passed`、`wave_audit.passed` |

### 课程工程与实时终端回归

```powershell
python scripts/verify_all.py --fast
.\scripts\run_sim.cmd std 1 2 verify
python scripts/mutation_test.py
python scripts/lint_rtl.py
python scripts/test_terminal_live.py
python scripts/test_terminal_scheduling.py
$run = Get-Content build/terminal_live/integration_results.json -Raw | ConvertFrom-Json
python scripts/export_terminal_live_wave.py --session (Join-Path build/terminal_live/sessions $run.session)
```

原工程回归通过 18/18 项、合并覆盖 29/29 个功能 bin，同步读专项通过，3/3 个注入缺陷被检测到。Verilator 5.006 检查了课程顶层和双向 IP 顶层。终端集成和调度均通过，独立审计逐沿比对 VCD 和 CSV 后导出 ModelSim WLF。浏览器堵塞实验中，A→B 堵满期间 B→A 仍可送达。空闲与完全堵塞时按需模式停止推进，手动推进一次为 200 ns。
