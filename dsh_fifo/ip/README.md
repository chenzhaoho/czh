# 双向异步 FIFO IP 1.0

一个 IP 在两个独立时钟域之间提供两条可同时使用的字流。A 的发送口写入 `u_ab`，B 的接收口读出。B 的发送口写入 `u_ba`，A 的接收口读出。每条队列各有存储、读写指针和满空判定。当 B 暂停接收并使 A→B 满时，B 仍能通过另一条队列给 A 发回数据。实时终端和 IP 包共用 [dual_fifo_link](../rtl/ext/dual_fifo_link.v)。

## 在一台 PC 上复现

使用 Windows、Python 3.10+、ModelSim 和带 Artix-7 器件支持的 Vivado 2020.2。本次采用 ModelSim-Altera 10.3c。PowerShell 在短 ASCII 路径下工作，例如 `C:\work`。把工具路径改为本机安装位置。

```powershell
git clone --filter=blob:none --sparse https://github.com/chenzhaoho/czh.git
Set-Location czh
git sparse-checkout set dsh_fifo
Set-Location dsh_fifo
$env:MODELSIM_BIN = 'C:\tools\modelsim_ase\win32aloem'
$vivado = 'C:\Xilinx\Vivado\2020.2\bin\vivado.bat'

.\scripts\run_ip_verify.cmd --seed 27
& $vivado -mode batch -nojournal -nolog -source ip/vivado/package_dual_fifo_ip.tcl -tclargs build/ip_repo
.\scripts\run_ip_verify.cmd --component build/ip_repo/dual_fifo_link_1_0/component.xml --seed 93
& $vivado -mode batch -nojournal -nolog -source ip/vivado/verify_dual_fifo_ip.tcl -tclargs build/ip_repo build/ip_verify
```

上述四步分别验证仓库里的 RTL、生成 IP 仓库、用包内文件重新编译仿真，以及在两个空工程中从 IP Catalog 实例化并布线。每条命令退出码应为 0。对应的结束标志依次是 `16/16 PASS`、`IP_PACKAGE_PASS`、`16/16 PASS`、`IP_CONSUMER_PASS`。ModelSim 矩阵每次创建独立工作库，每个消费工程保留自己的报告。安装路径排查可先运行 `& $vivado -version`。

若 64 位 Windows 工具终端缺失 `PROCESSOR_ARCHITECTURE` 且 Vivado 2020.2 启动器直接退出，可在当前 x64 PowerShell 执行 `$env:PROCESSOR_ARCHITECTURE = 'AMD64'` 后重试。单独复查实现时，可在最后一条命令末尾添加 `default` 或 `compact`。

## 导入另一个 Vivado 工程

1. 运行封装命令。可把整个 `build/ip_repo/dual_fifo_link_1_0/` 复制到对方的 IP 仓库目录，连同 `component.xml`、RTL、约束和参数界面一起保留。
2. 在 **Settings → IP → Repository** 添加包含该子目录的父目录。在 **IP Catalog** 搜索 **Duplex asynchronous FIFO**，核标识为 `chenzhaoho:user:dual_fifo_link:1.0`。
3. 双击核，按下表选择参数，将实例模块命名为 `duplex_i`，执行 **Generate Output Products**。从 **IP Sources → Instantiation Template** 复制端口模板。命令行集成可直接参照 [消费工程脚本](vivado/verify_dual_fifo_ip.tcl) 和 [连线示例](vivado/example/duplex_example.v)。
4. 在集成工程的 XDC 中为两个输入时钟分别建钟，或让已有时钟传到对应端口。让生产者、消费者和各自端口共用本域时钟。项目完成布线后检查 CDC、最大延迟、总线偏斜、建立及保持时间。

| 参数 | 默认 | 1.0 可选值 | 硬件含义 |
|---|---:|---|---|
| `DW` | 32 | 16、32 | 每字位数，两个方向相同 |
| `AW` | 8 | 6、8 | 每方向独享 `2**AW` 个字，即 64 或 256 字 |
| `SYNC_STAGES` | 2 | 2、3 | 跨域指针和复位释放同步链级数 |

## 信号与时序约定

下表中的 `p` 取 `a` 或 `b`。`a_*` 在 `clk_a` 上升沿采样，`b_*` 在 `clk_b` 上升沿采样。方向以 IP 为参照。

| 端口 | 方向及宽度 | 集成规则 |
|---|---|---|
| `clk_a`、`clk_b` | 输入，各 1 位 | 两个端点的时钟 |
| `rst_n_async` | 输入，1 位 | 公共低有效复位，异步置位、在各时钟域同步释放 |
| `p_tx_valid`、`p_tx_data` | 输入，1 位、DW 位 | 本端备好要发给对端的一个字。背压期间保持 valid 和 data |
| `p_tx_ready` | 输出，1 位 | 与 tx_valid 同时为 1 的上升沿接收一个字 |
| `p_rx_valid`、`p_rx_data` | 输出，1 位、DW 位 | 对端发来的队首字已可取。本端暂停时，IP 保持有效字直到成交或复位 |
| `p_rx_ready` | 输入，1 位 | 本端能接收时拉高，与 rx_valid 同时为 1 的上升沿取走一个字 |
| `p_tx_full` | 输出，1 位 | 本端发送队列已满。实际发送用 valid/ready 判断 |
| `p_tx_used`、`p_rx_used` | 输出，各 AW+1 位 | 各端基于同步后的远端指针估计占用，范围为 0 至每路深度 |

例如 A 连续提供两个字，A 在两次 `a_tx_valid && a_tx_ready` 的时钟沿分别提交。B 在自己的两次 `b_rx_valid && b_rx_ready` 时钟沿按序取走。B 即使还没取完，也能使用 `b_tx_*` 发回数据。FWFT 组合读使首字随 `rx_valid` 出现在数据口。集成逻辑仅在有效成交时使用收到的数据。远端读写通过同步链后本地才可见，因此同一队列两端的 used 读数会有短暂差异。

复位会丢弃两路在途数据。按本核复位同步器的使用约定，共同复位低电平至少覆盖两个域各自的 `SYNC_STAGES` 个时钟周期。释放后继续提供两个时钟，发送端依据本域 `tx_ready` 恢复，接收端依据 `rx_valid` 取数。

## 实现和 CDC 验收

- [功能测试台](../tb/tb_dual_fifo_ip.sv) 只观察外部端口，用两套独立参考队列比对顺序和数据。8 组参数均以 A 快 / B 快各跑一次，时钟为 10 和 14 ns，B 时钟错相 1.701 ns。测试先轮流写满单向队列，并在堵塞期间验证反向成交，然后测试随机并发、指针回绕、双向满时复位和复位后新数据。
- [实例约束](vivado/dual_fifo_link.xdc) 在实现时读取两个实际时钟的周期，以较短周期给四组 Gray 指针到首级同步寄存器设置 datapath-only 最大延迟和总线偏斜预算。同步器级间继续按目标时钟计时。分布式 RAM 的写时钟到对侧域数据捕获另有限时。集成时应检查已有全局异步时钟分组或 false path 是否覆盖这些限时。OOC 综合有单独的 [默认时钟文件](vivado/dual_fifo_ooc.xdc)。
- 独立参考工程使用 `xc7a35tcsg324-1`，时钟周期 10 ns 和 14 ns。两个方向都发送变化的数据、周期性暂停接收，并把捕获数据的奇偶校验送往输出。每路状态输出配一根转发时钟，在数据周期中部采样。参考工程的 FPGA 原语只用于这些输出时钟。默认组使用独立综合检查点，精简组使用全局综合。
- [实现验收脚本](vivado/verify_dual_fifo_ip.tcl) 检查每位 Gray 指针都命中有效的最大延迟和指定级数的同步寄存器。它还核对四组 skew、逐条分类 CDC、检查时钟与内部未约束端点、布线完成度以及建立和保持裕量。[本版验收记录](validation.md) 给出实测值、报告索引及终端复核方法。

## 运行实时终端

```powershell
.\scripts\run_terminal_live.cmd --gui
```

打开启动窗口给出的本机地址，点击“运行堵塞实验”。观察 A→B 写入 256 字后 `a_tx_ready=0`，此时 B→A 的消息仍能到达。点击 B 端“恢复本端接收”，查看积压消息按序到达及 CRC32 校验。页面可导出握手 CSV 和 VCD。按需模式在空闲或完全堵塞时停在当前仿真时间。操作说明见 [实时终端](../doc/terminal_live/README.md)。
