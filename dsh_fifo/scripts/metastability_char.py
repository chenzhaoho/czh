# -*- coding: utf-8 -*-
"""metastability_char.py -- 亚稳态参数 tau 的电路级计算 + MTBF 数值

物理模型与结论边界
------------------
MTBF 公式：  MTBF = exp(t_r / τ) / (T_w × f_clk × f_data)

其中两个参数的性质不同，不能混为一谈：

* **τ（亚稳态分辨时间常数）** —— 由正反馈锁存器的**电路参数**决定，可以算：
      τ = C / (gm − gds)
  C 为锁存节点总电容, gm 为反相器跨导, gds 为输出电导。
  本脚本用这个式子算 τ，并用锁存器 ODE 的**数值积分**独立验证一次。

* **T_w（亚稳态窗口宽度）** —— 是**电路固有的输入时序窗口**，
  与时钟周期无关，不能从 T_clk 反推。它通常靠 SPICE 对 DFF 单元做边界扫掠测得，
  典型 20–100 ps。本脚本按"文献典型值 + 敏感性扫描"处理，并明确标注。

因此本脚本给出的是：**τ 的电路级计算结果（可信）** +
**T_w 取不同典型值时的 MTBF（敏感性）**，而不是单一"签核值"。

用法
----
    python scripts/metastability_char.py
    python scripts/metastability_char.py --gm 250e-6 --cap 4e-15 --tclk 4.0
"""
import argparse
import json
import math
import os
from pathlib import Path


def latch_ode_dispersion(v0, gm, cap, gds, vdd, vsat, tmax, dt):
    """锁存器 ODE 积分：返回差分电压达到满摆幅(0.9*VDD)所需时间(None=未达)。

    用于独立验证 τ = C/(gm-gds) 这个解析式，不用于拟合 T_w。
    """
    v1, v2 = v0 / 2.0, -v0 / 2.0

    def isat(v):
        k = 1.0 / (1.0 + (v / vsat) ** 2)      # 大信号增益下降
        return gm * v * k + gds * v

    t = 0.0
    target = 0.9 * vdd
    # 正反馈锁存器: 反相器 A 的输入是 v2, 输出驱动 v1 (反相) -> i_A = -gm*v2
    #             反相器 B 的输入是 v1, 输出驱动 v2         -> i_B = -gm*v1
    # 于是差分 v = v1-v2 满足 C dv/dt = (gm-gds)*v, 即指数发散
    while t < tmax:
        d1 = (-isat(v2) - gds * v1) / cap
        d2 = (-isat(v1) - gds * v2) / cap
        v1 += dt * d1
        v2 += dt * d2
        t += dt
        if max(v1, -v2) >= target:
            return t
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gm", type=float, default=200e-6, help="反相器跨导 (S)")
    ap.add_argument("--cap", type=float, default=5e-15, help="锁存节点电容 (F)")
    ap.add_argument("--gds", type=float, default=20e-6, help="输出电导 (S)")
    ap.add_argument("--vdd", type=float, default=1.8)
    ap.add_argument("--vsat", type=float, default=0.6)
    ap.add_argument("--tclk", type=float, default=4.0, help="目的时钟周期 (ns)")
    ap.add_argument("--fdata", type=float, default=100e6, help="异步数据变化率 (Hz)")
    ap.add_argument("--tsetup", type=float, default=0.10, help="setup 时间 (ns)")
    ap.add_argument("--tskew", type=float, default=0.05, help="时钟偏斜 (ns)")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[1] / "doc/metastability_result.json"))
    args = ap.parse_args()

    Y = 3.1557e7          # s / year
    print("=" * 76)
    print("亚稳态参数计算（tau 由电路参数得到，T_w 取文献典型值做敏感性）")
    print("=" * 76)

    # ---------- 1) τ 解析计算 ----------
    tau_s = args.cap / max(args.gm - args.gds, 1e-12)
    tau_ps = tau_s * 1e12
    print(f"[1] tau = C/(gm-gds) = {args.cap*1e15:.1f}fF / "
          f"({args.gm*1e6:.0f}-{args.gds*1e6:.0f})uS = {tau_ps:.1f} ps")

    # ---------- 2) 数值积分独立验证 τ ----------
    print("\n[2] 数值积分验证（锁存器 ODE，检查发散是否符合 exp(t/tau)）")
    dt = 2e-13                # 200 fs 足够（tau ~ 28 ps）
    tmax = 5e-9
    pts = []
    for v0_mv in (50, 20, 10, 5, 2, 1):
        t = latch_ode_dispersion(v0_mv * 1e-3, args.gm, args.cap, args.gds,
                                 args.vdd, args.vsat, tmax, dt)
        if t is not None:
            pts.append((v0_mv * 1e-3, t))
    if len(pts) >= 3:
        xs = [t for _, t in pts]
        ys = [math.log(v0) for v0, _ in pts]
        n = len(xs)
        sx, sy = sum(xs), sum(ys)
        sxx = sum(x * x for x in xs)
        sxy = sum(x * y for x, y in zip(xs, ys))
        slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
        tau_fit = -1.0 / slope if slope < 0 else float("nan")
        print(f"    {'v0(mV)':>8} {'发散时间(ns)':>14}")
        for v0, t in pts:
            print(f"    {v0*1e3:>8.1f} {t*1e9:>14.3f}")
        print(f"    拟合 tau = {tau_fit*1e12:.1f} ps   "
              f"(解析值 {tau_ps:.1f} ps, 偏差 {abs(tau_fit*1e12-tau_ps)/tau_ps*100:.1f}%)")
        tau_used = tau_fit
    else:
        print("    积分点数不足，使用解析 tau")
        tau_used = tau_s

    # ---------- 3) MTBF: t_r 固定，T_w 扫典型值 ----------
    print(f"\n[3] MTBF 计算")
    print(f"    时钟周期 T_clk = {args.tclk} ns  (即 {1e3/args.tclk:.0f} MHz)")
    print(f"    异步数据率 f_data = {args.fdata/1e6:.0f} MHz")
    print(f"    t_setup = {args.tsetup} ns, t_skew = {args.tskew} ns")
    f_clk = 1e9 / args.tclk
    results = {}
    for Tw_ps in (20, 50, 100):
        Tw = Tw_ps * 1e-12
        print(f"\n    --- T_w = {Tw_ps} ps (文献典型值) ---")
        for stages in (2, 3):
            t_r_ns = (stages - 1) * args.tclk - args.tsetup - args.tskew
            if t_r_ns <= 0:
                print(f"      {stages} 级: t_r = {t_r_ns:.2f} ns <= 0, 不可用")
                continue
            t_r = t_r_ns * 1e-9
            lg10 = (t_r / tau_used) / math.log(10) - math.log10(Tw * f_clk * args.fdata)
            yrs = lg10 - math.log10(Y)
            results[f"{stages}stage_Tw{Tw_ps}ps"] = {"t_r_ns": t_r_ns, "log10_mtbf_years": yrs}
            if yrs > 15:
                print(f"      {stages} 级: t_r={t_r_ns:>4.2f} ns  MTBF ≈ 10^{yrs:.0f} 年")
            elif yrs > 0:
                print(f"      {stages} 级: t_r={t_r_ns:>4.2f} ns  MTBF ≈ 10^{yrs:.1f} 年")
            else:
                sec = 10 ** lg10
                print(f"      {stages} 级: t_r={t_r_ns:>4.2f} ns  MTBF ≈ {sec:.3g} s "
                      f"({sec/3600:.3g} 小时)")

    # ---------- 4) 保存 ----------
    data = {
        "model": "cross-coupled inverter latch; tau = C/(gm-gds), verified by ODE integration",
        "circuit_params": {
            "gm_S": args.gm, "cap_F": args.cap, "gds_S": args.gds,
            "vdd_V": args.vdd, "vsat_V": args.vsat,
        },
        "tau_analytic_ps": tau_ps,
        "tau_fit_ps": tau_used * 1e12,
        "clock": {"tclk_ns": args.tclk, "fdata_Hz": args.fdata,
                  "tsetup_ns": args.tsetup, "tskew_ns": args.tskew},
        "tw_assumed_ps": [20, 50, 100],
        "mtbf": results,
        "note": ("tau 由电路参数 C/(gm-gds) 得到并用 ODE 积分交叉验证；"
                 "T_w 是电路固有窗口宽度, 无法从 T_clk 反推, 故按文献典型值 20/50/100 ps "
                 "做敏感性。若要得到具体工艺的签核值, 需用 PDK 的 DFF 单元做 SPICE 边界扫掠。"),
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"\n结果已保存: {args.out}")
    print("=" * 76)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
