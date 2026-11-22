# 双异步 FIFO 实时信息终端

网页输入的文字经正在运行的 ModelSim 进入 `dual_fifo_link.u_ab` 或 `u_ba`。对端收件箱从 RTL 的读握手中重建内容。

## 启动

在工程根目录运行。Windows、Python 3.10+ 和 ModelSim 的配置步骤见 [工程 README](../../README.md)。

```bat
scripts\run_terminal_live.cmd
```

看到 `LIVE_TERMINAL_READY` 后打开 <http://127.0.0.1:8765/>。
命令窗口需要保持运行；Ctrl+C 关闭后端及其启动的 ModelSim。页面上的“停止 ModelSim”
只停止本会话的仿真器，保留网页和证据，之后可点击“重启仿真器”。

`MODELSIM_BIN` 指向 `vsim.exe`、`vlog.exe` 和 `vlib.exe` 所在目录。也可以把该目录加入 `PATH`。
需要指定 Python 时，用 `TERMINAL_PYTHON` 设置可执行文件的完整路径。
端口被占用时使用 `run_terminal_live.cmd --port 8766`，并访问对应端口。

不要直接双击 `index.html`：实时页面需要后端，不包含离线模拟数据。

## ModelSim 运行显示

页面顶部新增“ModelSim / 运行实况”，显示实际 PID、返回的仿真时间、命令/回执数量，
以及三个原始文件视图：ModelSim Transcript、在仿真器 Tcl 内记录的执行命令/回执、RTL 编译日志。
日志不是网页拼出来的模拟运行文本；停止仿真后记录不再增长。运行实况只读，不推进仿真。
页面仅显示日志末尾，可下载完整文件。软件响应耗时以毫秒显示，和 DUT 仿真时间不是一回事。

若需要**真的 ModelSim 窗口与网页同时运行**，使用：

```bat
scripts\run_terminal_live.cmd --gui
```

也可点击页面“启用原生窗口（新会话）”，确认后重启为窗口模式。旧会话日志和波形保留，
但当前页面消息与待发数据会清空。原生 Transcript/Wave 和网页控制的是同一份 `tb_terminal_live`
与两实例 DUT，不是另开一个回放仿真。Wave 自动跟随最近 2000 ns 的仿真窗口。
页面默认采用“按需”推进：发送或恢复接收后自动运行，传完或无法继续传输后自动暂停。
顶部显示“空闲 · 已暂停”“正在传输”“同步收尾”或“堵塞 · 已暂停”，并给出等待原因。
暂停的是整份仿真的时间，ModelSim 进程仍在线；反向新消息也能唤醒同一仿真。
需要近距离看时钟和握手时，在运行区把推进模式设为“手动单步”，再点击“推进 200 ns”或在原生窗口缩放。
“连续运行”保留原来一直推进时钟的行为，适合观察空闲周期；“自动滚动”只控制日志的位置。
请由网页控制运行、暂停接收和复位，不要同时在原生 Transcript 另行 `run/restart/force`，
否则外部控制会破坏本轮的逐字审计。

正常关闭原生 ModelSim 也会使网页检测到进程退出；它不能继续产生新收件。
无窗口运行仍是默认设置，窗口模式是可选的实际仿真显示，不影响 FIFO RTL。

## 现场演示：三个能被反驳的检查

1. **临时输入新内容。** 在 A 输入任意中文、数字或 emoji，观察 B 的收件及 CRC32。
   内容并非预置；消息带编号、UTF-8 字节数和真实仿真接收时间。
2. **让一条路堵住，另一条路继续。** 点击“运行堵塞实验”。程序只做三件事：暂停 B
   的 `rx_ready`、在 A 提交 40 条消息、从 B 提交一条带随机后缀的反向消息。
   随着仿真推进，A→B 实际占用达到 **256 个 32 位字**，`full=1、tx_ready=0`，
   主机待发量仍大于零；B 不新增收件，但 A 可以收到 B 的消息。
   点击 B 端“恢复本端接收”，积压消息才按顺序读出，FIFO 占用逐渐归零。
3. **关掉仿真器。** 点击“停止 ModelSim”，发送操作禁用、收件和指针冻结。也可以在任务管理器
   仅结束页面显示的 ModelSim PID；后端会识别断开，不能继续收到新内容。

“双向随机挑战”每次产生新的 96 位随机标识。只有该内容在两个方向都经过 RTL 读出、
通过逐字比较及 CRC32 后才判通过；B 暂停接收时，不会靠计时器判成功。

## 文字究竟经过哪里

```text
A 输入 → 主机编码/待发 → TB 的 A 发送接口
                          ↓ clk_A 写
                    DUT.u_ab / async_fifo（256×32）
                          ↓ clk_B 读，valid && ready
B 收件 ← 从读握手数据解码/校验 ← RTL b_rx_data

B 输入 → 同样过程 → DUT.u_ba（B 写、A 读）→ A 收件
```

RTL 核未作替换：`rtl/ext/dual_fifo_link.v` 实例化两个原有 `rtl/fifo/async_fifo.v`。
网页不包含传输队列，也不会把输入文字直接复制到对端收件箱。

- 主机发送暂存上限为每端 16384 字，和 **RTL FIFO 的 256 字深度不是一回事**。
  暂存只按 DUT `valid && ready` 推进，不能代替跨域传输。
- 每条文本最多 4096 个 UTF-8 字节，封装为：`magic32 / id32 / length32 / CRC32 / payload32...`。
  消息头、UTF-8 编解码和 CRC32 由 Python 处理，**不宣称它们是 RTL 硬件算法**。
- 时钟 A 周期 10 ns，B 周期 14 ns，B 的时钟发生器额外延迟 1.701 ns；同步级数为 2。
  `clk_A` 和 `clk_B` 在仿真中独立推进，不是两个浏览器定时器。
- 页面占用格子采用真实 `写入数 − 读出数`；本地域占用估计来自 DUT 同步后的指针，
  在正在传输时可能保守滞后。两者区别在页面中明确标注。
- 按需模式检查真实待写字数、已写未读字数和接收使能，有可执行的读写才每 150 ms 请求推进 200 ns。
  暂停接收后仍会先写到 FIFO 满或待发耗尽，之后暂停；另一方向有新数据时仍可继续传输。
  末笔握手或控制变化后留出至少 200 ns 使跨域同步稳定，再冻结时间和日志，避免只以“某一刻没有握手”误判空闲。
  连续模式会一直推进空闲时钟，手动模式仅在点击按钮时额外单步。可用 `--continuous` 或 `--manual` 选择启动模式，默认是按需。
  操作装载数据/更改接收使能会额外推进 40 ns，让控制在相应时钟下降沿安全采样。

单个标准的单向异步 FIFO 本身不提供两条相反方向的独立跨域队列。
若单 FIFO 方案另加仲裁、复用和同步逻辑，需要另行设计和比较，不能将本演示说成
“任意单 FIFO 系统在原理上都无法通信”。

## 波形与可审计证据

页面可下载原始握手 CSV、VCD、JSON。**优先使用“同一时刻证据包 ZIP”**：它在同一仿真锁内
抓取这些文件，避免分开下载时仿真已继续推进造成计数不一致，并附上实际编译使用的源文件副本。
源文件 SHA-256、编译副本 SHA-256、ModelSim PID、启动命令和会话目录均可核查。
原源码为 UTF-8，旧版 ModelSim 使用 GBK 编译副本，因此两个编码版本的哈希可能不同。

直接打开本轮波形：

```bat
scripts\open_terminal_live_wave.cmd
```

它从后端抓取一致快照，**先从 VCD 的时钟上升沿重建每一笔 W/R，再与 CSV 比较数据和指针**，
通过后转换为 WLF 并打开 ModelSim 波形窗口。波形是抓取时刻的快照，不随网页继续更新。
若端口改为 8766，命令追加 `--port 8766`。

只导出、校验，不打开窗口：

```bat
python scripts\export_terminal_live_wave.py
```

已有停止的会话也可离线核对：

```bat
python scripts\verify_terminal_wave.py "build\terminal_live\sessions\实际会话目录名"
```

在波形中依次看：

- `av && at` 时在 `clk_a` 上升沿写 A→B，`u_ab.wr_bin` 加一。
- B 停收后 `br=0`，`u_ab.rd_bin` 不变；满后 `af=1、at=0`，写指针也停止。
- 此时 `bv && bt`、`ax && ar` 仍可在各自时钟沿传输反向消息。
- 恢复 B 后 `bx && br` 读出，`u_ab.rd_bin` 前进，积压开始消退。
- 二进制指针为 9 位，低 8 位是地址，第 9 位用于回卷；本地 Gray 值为 `bin ^ (bin >> 1)`。
  跨域采样可能跳过中间 Gray 状态，不能要求目的域相邻两次观测永远只变一位。

## 已运行的验证与复现

```bat
python scripts\test_terminal_live.py
```

此测试启动实际 ModelSim，覆盖中文/emoji/HTML 字面文本、两向通信、单向和双向满、
独立恢复、随机挑战等待/通过、超过 512 次写的回卷、4096 字节长帧、非法长度、复位丢弃待发、
停止/重启、外部退出检测，以及所有 CSV 握手与 VCD 原始信号的独立一致性检查。
结果保存在 `build/terminal_live/integration_results.json`。

`python scripts\test_terminal_scheduling.py` 另外验证按需唤醒、空闲/堵塞时仿真时间与原日志不增长、
双向独立唤醒、恢复接收、CDC 收尾、手动单步和连续模式；结果在 `build/terminal_live/scheduling_results.json`。

可选的 Playwright 浏览器检查会复位并重启它连接的演示，所以请单独启动一个测试会话。先在一个窗口运行 `scripts\run_terminal_live.cmd --port 8767`，再从工程根目录打开 PowerShell 执行：

```powershell
npm install --no-save playwright@1.62.1
npx playwright install chromium
$env:TERMINAL_URL = 'http://127.0.0.1:8767'
node scripts/qa_terminal_live.cjs
```

浏览器检查需要 Node.js 18+。可用 `CHROME_BIN` 指定已安装的 Chrome，或用 `PLAYWRIGHT_MODULE` 指定另一个 Playwright 安装。脚本验证真实发送、堵塞、三种推进模式、导出和离线禁用。

功能范围：这是**单机 RTL 数字功能仿真**，不是 FPGA 板级通信，也没有验证模拟亚稳态、
布局布线后的时序和物理 CDC 约束。以前的综合报告不能直接视作本终端的板级验证结论。
