# 验证指南 — 如何自己确认这套设计确实工作

本文件回答两个问题：

1. 交付物中的"验证通过"是怎么得到的？
2. 你自己怎么复现并核对？

所有命令都在检出的 `czh/dsh_fifo/` 下执行。先按 [工程 README](README.md) 配置 `MODELSIM_BIN`。

---

## 一、验证方法的分层结构

功能验证不是"跑一遍没报错"就算通过。这套平台的通过标准由四层构成，
四层都成立才算真正验证过：

| 层次 | 手段 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| L1 自检断言 | 1065+ 条 `ck()` 检查点（每条打印时间戳与消息） | 特定场景下 DUT 行为符合预期 | 没写到的场景未知 |
| L2 参考模型比对 | 参考序列 `sent_a[]/sent_b[]` 逐项比对 `rd_data` | 数据无丢失/重复/乱序 | 吞吐与延迟特性 |
| L3 功能覆盖率 | 29 个覆盖 bin（7 类覆盖点） | 场景真的被激励到，不是空跑 | 断言本身是否有效 |
| L4 变异测试 | 向 RTL 注入已知缺陷，看是否被抓 | **测试套件本身有效** | 未注入的缺陷类型 |

**L4 是关键**：如果注入了 bug 测试还全绿，说明测试是空的。这一层由
`scripts/mutation_test.py` 自动完成。

---

## 二、三步快速核对（约 2 分钟）

### 步骤 1 — 单个用例

```bat
scripts\run_sim.cmd tc1 1 2 verify
```

**预期输出**（关键三行）：

```
[run_sim] failed checks    : 0
[run_sim] coverage bins    : 25/29
[run_sim] RESULT: *** PASS ***
```

`failed checks : 0` 表示所有检查点通过；`coverage bins` 表示该用例命中了
多少功能覆盖点。

### 步骤 2 — 完整回归（2 级 + 3 级同步器，18 次运行）

```bat
scripts\regression.cmd
```

**预期输出**：`SYNC_STAGES=2` 和 `SYNC_STAGES=3` 两段各 9 行 `tcN PASS`。
汇总另存于 `sim\coverage\regression_summary.txt`。

### 步骤 3 — 变异测试（证明测试有效，约 3 分钟）

```bat
python scripts\mutation_test.py
```

脚本在临时工程中修改 RTL 并编译变异，日常仿真可继续复用原工作库。

**预期输出**：

```
M1_off_by_one_full: CAUGHT (6 failed checks)
M2_wrong_threshold: CAUGHT (3 failed checks)
M3_no_hysteresis:   CAUGHT (2 failed checks)
结论: 3/3 个变异被捕获
```

这三个变异分别是：
- **M1**：把满判据改成 `DEPTH-1`（模拟经典格雷码比较的 255 字缺陷）
- **M2**：把 `ALMOST_FULL_TH` 从 224 改成 200
- **M3**：把 `DEADBAND` 从 2 改成 0（去掉回差）

脚本每次都会**自动恢复** RTL 原文件（用 `.mutbak` 备份，`finally` 里还原），
不会把工程改坏。

---

## 三、逐项深入核对

### 3.1 看日志确认"检查点真的在跑"

每个用例的日志在 `sim\logs\run_<用例>_seed<种子>_<级数>stage.log`。

```bat
type sim\logs\run_tc1_seed1_2stage.log
```

日志结构：

```
# TEST=tc1  SEED=1  SYNC_STAGES=2            <- 本次运行的配置
# clocks: T_wr_a=10000ps  T_rd_a=6000ps ...  <- 时钟参数
# ---- TC1: random fill-to-full / drain-to-empty (A and B) ----
# ---- TC1               PASS ----            <- 该用例结论
# ============ FUNCTIONAL COVERAGE REPORT [tc1] ============
#  C1 per-channel state : A{FULL=1460 EMPTY=439 ...}
#  ...
#  FUNCTIONAL COVERAGE = 86.2%  (25/29 bin)
#  TOTAL: checks=1065  failed=0  elapsed=17743.000 ns ps
#  RESULT: *** PASS ***  TEST=tc1 SEED=1 STAGES=2
```

`checks=1065` 说明 TC1 跑了 1065 个检查点，全部通过。若失败，每一处都会打印
`[FAIL] <时间戳> : <具体消息>`，例如：

```
# [FAIL] 5263.000 ns : TC1/A: wr_full not asserted at 256 words
```

### 3.2 核对阈值是否真的被检查（TC4 的跳变点扫描）

TC4 不是"看一眼标志对不对"，而是**逐字扫描并记录标志翻转时的占用量**：

```bat
scripts\run_sim.cmd tc4 1 2 verify
findstr /C:"[TC4]" sim\logs\run_tc4_seed1_2stage.log
```

**预期输出**（与设计值精确对应）：

```
[TC4] A almost_full  rise point = 224 (expected 224)   <- 224 置位
[TC4] A almost_full  fall point = 222 (expected 222)   <- 224-2 清除
[TC4] A almost_empty rise point =  32 (expected 32)    <- 32 置位
[TC4] A almost_empty fall point =  34 (expected 34)    <- 32+2 清除
[TC4] B almost_full  rise point = 224 (expected 224)
[TC4] B almost_empty rise point =  32 (expected 32)
```

这一步是变异测试 M2 能被抓到的原因：阈值若改成 200，`rise point` 会变成 200。

### 3.3 核对容量是否真的 256 字

```bat
scripts\run_sim.cmd tc1 1 2 verify
findstr /C:"TC1/A" sim\logs\run_tc1_seed1_2stage.log
```

TC1 写满 256 字后断言 `wr_full=1`、`wr_ready=0`、写入计数 `=256`、溢出计数 `=0`。
若有任何一条不满足，会以 `[FAIL]` 打印。

### 3.4 核对覆盖率

单用例覆盖率在日志里；跨用例合并覆盖率需要人工合并（每个 bin 只要任一用例命中
即算命中）：

| 用例 | 命中 bin |
|---|---|
| tc1 | 25/29 |
| tc2 | 17/29 |
| tc3 | 26/29 |
| tc4 | 20/29 |
| tc5 | 18/29 |
| tc6 | 26/29 |
| tc7 | 14/29 |
| tc8 | 20/29 |
| tc9 | 14/29 |

合并后 29/29。覆盖率定义见 `tb\env\tb_coverage.sv` 的 `report` 任务（29 个 bin，
7 类覆盖点 C1~C7）。

### 3.5 看波形

```bat
scripts\run_sim.cmd tc1 1 2 dump
```

生成 `sim\waves\dual_async_fifo_tc1_seed1.vcd`，可用 GTKWave 或 ModelSim 打开。
建议观察：
- `wr_clk_a` / `rd_clk_a` 的频率比（10 ns : 6 ns = 5:3）
- 写满时 `wr_full` 与 `wr_ready` 的联动
- 读空时 `rd_empty` 与 `rd_valid` 的联动
- 背压时 `rd_ready` 拉低而 `rd_data` 保持不变

### 3.6 RTL 静态检查

```bat
scripts\lint.cmd
```

或手动：

```bat
verilator --lint-only -Wall --top-module dual_async_fifo_top ^
  rtl\common\gray_codec.v rtl\common\sync_2ff.v rtl\common\sync_gray_bus.v ^
  rtl\common\rst_sync.v rtl\fifo\async_fifo.v rtl\fifo\fifo_a.v rtl\fifo\fifo_b.v ^
  rtl\top\monitor.v rtl\top\dual_async_fifo_top.v
```

**预期**：无输出（0 warning / 0 error）。

---

## 四、可调参数（自己设计实验）

```bat
scripts\run_sim.cmd <用例> <种子> <同步级数> <模式> <相位A_ps> <相位B_ps>
```

| 参数 | 取值 | 用途 |
|---|---|---|
| 用例 | `tc1`~`tc9`、`tcA`（全部） | 选择场景 |
| 种子 | 任意正整数 | 改变随机激励，验证鲁棒性 |
| 同步级数 | `2` / `3` | 对比 MTBF 与延迟 |
| 模式 | `verify`（重编译）/ `noverify`（复用）/ `dump`（出波形） | 运行方式 |
| 相位 | 任意 ps | 扫描读时钟初始相位，测试最坏相位对齐 |

**建议自己做的实验**：

1. **多种子鲁棒性**：`for %s in (1 7 23 99 1234) do scripts\run_sim.cmd tc2 %s 2 verify`
2. **相位扫描**：`scripts\run_sim.cmd tc1 1 2 verify 3000 0`（读时钟错开 3 ns）
3. **3 级同步器**：`scripts\run_sim.cmd tc5 1 3 verify`
4. **极端比例**：改 `tb\env\tb_harness.sv` 里的时钟参数后重跑

---

## 五、我验证时遇到并修掉的真问题（供你判断可信度）

验证过程中发现 7 个缺陷，其中 2 个是结构性的：

| # | 现象 | 根因 | 如何发现 |
|---|---|---|---|
| 1 | 写满 256 字后最后一字被拒 | 经典格雷码满判据提前一字成立（只能存 255） | TC1 写入计数比对 |
| 2 | 空 FIFO 报 `rd_valid=1` | 读域同步了写指针的**下一值** | TC1 读空断言 |
| 3 | 监控域占用量偶发 511 | 写/读状态分两条总线同步，到达时刻不同 | `check_mon` 与本地计数比对 |
| 4 | 监控域事件计数永久滞后 2~3 | 纯 toggle 握手对高速计数器丢增量 | 逐位比对 |
| 5 | 背压计数虚高 | 驱动器空闲时拉低 `rd_ready` | TC5 背压计数比对 |
| 6 | 参考队列与 DUT 错位 | 测试任务与 always 共享状态产生竞争 | `rd#x` 越界报错 |
| 7 | **阈值检查是永真式** | 曾写成 `(used > 220) \|\| (af == 0)`，左项恒真 | **变异测试 M2 未被捕获** |

第 7 条是本轮才发现的：当时的 TC4 检查在阈值附近"看起来通过"，
但把阈值从 224 改成 200 它照样通过——说明检查是空的。现已重写为
**跳变点扫描**（见 3.2），M2 现在能被捕获。

> 这一条也说明：只看"测试全绿"是不够的，必须验证测试本身有判别力。

---

## 六、一句话回答"你怎么验证的"

1. 写自检 testbench（参考模型 + 1065+ 检查点），**不是靠肉眼看波形**；
2. 用功能覆盖率确认场景被真的激励到（29 bin）；
3. 用**变异测试**确认断言有判别力（注入 3 个 bug，全部被抓）；
4. 全部通过后，把所有日志、覆盖率、波形留档，报告里的每个数字都能在
   `sim\logs\` 与 `sim\coverage\` 里查到原始出处。

你想核对报告里任何一个数据，都能按"用例 → 日志文件 → 对应行"的路径找到。
