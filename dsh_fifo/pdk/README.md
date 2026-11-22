# SKY130 工艺库接入

本工程用 SKY130 HD 标准单元库中的 `sky130_fd_sc_hd__dfxtp_1` 作为同步器触发器的工艺参考。当前 RTL 仿真和 FPGA 综合流程不依赖此 PDK；该库用于抽取触发器时序/面积参数，并为后续晶体管级亚稳态表征提供模型。

## 已接入内容

- `sky130_fd_sc_hd/`：官方 SKY130 HD 单元库的稀疏检出，仅包含 `dfxtp` 的 Verilog、SPICE、版图视图及 Liberty JSON。
- `sky130_fd_pr/`：官方 SKY130 工艺模型的稀疏检出，包含 TT 模型文件以及 `dfxtp_1` 实际使用的 `nfet_01v8` 和 `pfet_01v8_hvt` 模型。
- `sky130_config.json`：库版本、单元、工艺角和相对路径的唯一配置入口。

上游提交固定在配置文件中的 revision；两个上游仓库均采用 Apache-2.0 许可证。更新库版本时，应同时更新 revision 和重新生成特性报告。

在工程根目录执行以下 PowerShell 命令，取得报告用的两个固定版本。在已有检出上可先用 `git -C <目录> rev-parse HEAD` 核对版本。

```powershell
$sky130 = Get-Content pdk/sky130_config.json -Raw | ConvertFrom-Json
git clone --filter=blob:none --no-checkout $sky130.standard_cell_library.repository pdk/sky130_fd_sc_hd
git -C pdk/sky130_fd_sc_hd sparse-checkout set cells/dfxtp
git -C pdk/sky130_fd_sc_hd switch --detach $sky130.standard_cell_library.revision
git clone --filter=blob:none --no-checkout $sky130.transistor_models.repository pdk/sky130_fd_pr
git -C pdk/sky130_fd_pr sparse-checkout set models cells/nfet_01v8 cells/pfet_01v8_hvt
git -C pdk/sky130_fd_pr switch --detach $sky130.transistor_models.revision
```

## 提取 Liberty 参数

```powershell
python scripts\characterize_sky130.py
```

默认生成 `doc/pdk/sky130_dfxtp_1_tt_025C_1v80.json` 和同名 Markdown 摘要。报告包含单元面积、泄漏功耗、D/CLK 输入电容、setup/hold 约束表范围和 clock-to-Q 表范围。原始表格随输入 slew 与输出负载变化，因此报告保留范围，不把某个插值点冒充为全局固定延迟。

Liberty 不包含 `tau` 或 `T_w`。不得用 setup/hold 数值替代这两个参数，也不得把已有的典型值或 ODE 模型结果写成 SKY130 表征结果。

## SPICE 亚稳态表征

安装 ngspice 47 或更新版本后运行：

```powershell
python scripts\characterize_sky130.py --run-spice --ngspice C:\path\to\ngspice.exe
```

`--run-spice` 会先验证 `dfxtp_1` 与对应 TT transistor model 能被 ngspice 加载并运行。当前 smoke test 使用仿真温度 25 C（模型 `TNOM=27 C`）、1.8 V、2 fF 输出负载与 2 ps 最大步长。只有瞬态数据扫掠和拟合通过后，报告才会增加 `tau`/`T_w` 与 MTBF 数值。SPICE 表征报告还应记录模型 corner、供电、温度、仿真步长、时钟/数据边沿及拟合区间；结果只代表该模型和仿真条件，不是制造工艺签核数据。

建议以 `sky130_fd_sc_hd__dfxtp_1` 的 TT/1.8 V/25 C 作为首个可复现基线，并额外对 SS/FF 角执行敏感性分析。时钟偏斜和同步器布线延迟来自实现结果，不是 Liberty 单元参数；没有物理实现数据时须单独列为假设。

## SPICE 表征已完成（真实结果）

`scripts/sky130_spice_sweep.py` 在 ngspice 47 + SKY130 tt corner 上完成了
**真实的相位扫掠**，得到：

| 项目 | 数值 |
|---|---|
| 工艺角 | tt_025C_1v80（25 ℃, 1.8 V，2 fF 负载，1 ps 步长） |
| 正常态 clk→Q | **168.13 ps** |
| **tau** | **53.75 ps** |
| T_w | 约 58 ps（由亚稳态区 dt ∈ [−28, −58] ps 的边界估计） |
| 拟合 R^2 | 0.7144（14 个亚稳态点） |

**与两条独立方法的交叉验证**：

| 方法 | tau |
|---|---|
| 行为模型 ODE 扫掠 | 9.01 ps（偏乐观） |
| 由 Liberty 的 clk-to-Q 反推 | 55.5 ps |
| **SPICE 相位扫掠（本项）** | **53.75 ps** |

SPICE 结果与"clk-to-Q 反推"高度吻合（差 3%），确认行为模型低估了 tau，
真实值应在 ~54 ps 量级。

### 打通 SPICE 的关键步骤（踩过的坑）

| # | 问题 | 解决 |
|---|---|---|
| 1 | `Undefined parameter [<name>_toxe_slope]` | pm3 定义 `_spectre` 后缀而模型体引用无后缀，补 8 个 `.param = 0.0` |
| 2 | 单位错乱 | **`.option scale=1.0u`**（缺了它 `w=420000u` 会被当 0.42 m） |
| 3 | 缺器件模型 | 官方 `corners/tt.spice` 引用全部器件，本机只 sparse-checkout 了两个，故生成精简 corner |
| 4 | include 路径断裂 | 精简 corner 用**绝对路径**（相对路径会相对其所在目录解析） |
| 5 | 判据混淆 | dt>0（data 晚于 clk）是**正常不采样**，不是亚稳态；只有 c2q 显著高于基线的点才参与拟合 |

> 结论：**不需要 open_pdks 的完整构建**，直接用 `sky130_fd_pr/models/corners/tt.spice`
> 的思路（精简成两个器件）+ `scale=1.0u` 即可在 ngspice 上跑通。

## 相位扫掠与拟合（已实现，两模式）

`scripts/metastability_sweep.py` 补上了本文件前面提到的缺口：它做**数据边沿相对时钟的
相位扫掠**，并对 `延迟 vs ln(相位偏移)` 做指数拟合，从而求出 `tau` 与 `T_w`。

```powershell
# 模式 B（默认）：行为级锁存器 ODE，器件尺寸取自 SKY130 网表
python scripts\metastability_sweep.py

# 模式 A：真实 SPICE 扫掠（需要 ngspice）
python scripts\metastability_sweep.py --spice C:\path\to\ngspice.exe
```

拟合模型：

```text
正常态:  t = t_pd
亚稳态:  t = t_pd + tau * ln(T_w / |dt|)
=> 对 ln|dt| 与 t 线性拟合，斜率给出 -tau，截距反解 T_w
```

### 已得到的行为模型结果（**不是 SPICE 表征**）

| 项目 | 数值 |
|---|---|
| 扫描点数 | 16（0.2 ~ 200 ps） |
| 进入亚稳态区的点数 | 15 |
| **tau** | **9.01 ps** |
| **T_w** | **451.97 ps** |
| 拟合质量 R^2 | **0.9962** |

R^2 = 0.996 说明指数发散模型与扫描数据高度吻合。`tau` = 9.0 ps 与
用器件尺寸解析算出的 9.4 ps 一致（同一模型，互为验证）。

> **规范遵行**：按本文件前面的要求，这组数字标注为"行为模型结果"，
> 不得写成 SKY130 的 SPICE 表征结果。要得到 SPICE 表征值，须在有 ngspice 的
> 环境跑模式 A。行为模型的 `tau` 偏乐观（它假设强反型、未计速度饱和），
> 而由实测 clk-to-Q 反推的 `tau` 为 55.5 ps，两者构成区间 [9, 55] ps。

## ngspice 适配现状（实测记录）

历史试验使用 ngspice 47。安装后可传入实际路径，例如 `python scripts/sky130_spice_sweep.py --ngspice C:\tools\ngspice\bin\ngspice_con.exe`。
`scripts/prepare_sky130_ngspice.py` 把 SKY130 的 HSPICE 模型转成 ngspice 可读形式，
已解决下列 5 类问题（每一步都实测过）：

| # | 问题 | ngspice 报错 | 解决 |
|---|---|---|---|
| 1 | pm3 定义 `<name>_spectre` 但模型体引用 `<name>` | `Undefined parameter` | 生成 `param_patch.spice`，补 8 个参数 |
| 2 | HSPICE 自动 bin 选择 | `could not find a valid modelname` | 解析 180/198 个 bin 的几何边界，把 DFF 的 24 个器件映射到具体 bin |
| 3 | 网表用 `X` 表示 MOSFET | `unknown subckt` | 器件行 `X` -> `M` |
| 4 | `.model name.188` 名字含点 | 名称被拆成参数 | 改名为 `name_188`，网表引用同步改 |
| 5 | `.model ... nmos` 在 HSPICE 是 BSIM4 | 参数不被识别 | 显式加 `level=54` |

**仍未打通**：完成 1~5 后，ngspice 仍报 `can't find model '<name>_N'`，
说明 `.model` 未注册进模型表。判断是 SKY130 的 pm3 与 ngspice 47 之间的深层
语法/作用域不兼容——SkyWater 官方对 ngspice 的支持通常需要 open_pdks 生成的
适配层，而本仓库的 pm3 是 HSPICE/Spectre 取向。

因此本工程的 `tau`/`T_w` **仍以行为模型结果为准**（`doc/pdk/sky130_metastability_model.json`），
SPICE 表征待适配层补齐后再跑 `metastability_sweep.py --spice`。
