# -*- coding: utf-8 -*-
"""metastability_sweep.py -- 亚稳态参数的相位扫掠与拟合

补上 characterize_sky130.py 缺的最后一步：目前它只做了单次跳变的 smoke test
（得到普通 clk-to-Q ≈169 ps），没有做"数据边沿相对时钟的相位扫掠 + 指数拟合"，
因此 tau / T_w 一直是 None。

本脚本做两件事，且严格区分两者：

  模式 A  --spice <ngspice.exe>
      真实的晶体管级扫掠：对每个相位偏移 dt 生成一份 SPICE deck，
      用 sky130_fd_pr 的 TT 模型跑瞬态，测 clk->Q 的传播延迟，
      再对"延迟 vs 相位"做指数拟合，得到 tau 与 T_w。
      => 这才是 SKY130 表征结果。

  模式 B  --model（默认）
      行为级扫掠：用交叉耦合锁存器的 ODE，初始差分 v0 正比于相位偏移 dt，
      积分求发散时间，再拟合 tau 与 T_w。
      => 这是**行为模型结果**，器件尺寸取自 SKY130 网表，但不是 SPICE 表征。
         按 pdk/README.md 的规范，不得把它写成 SKY130 表征结果。

拟合模型（两种模式共用）：

      正常态:  t_c2q = t_pd                         (|dt| 大于窗口)
      亚稳态:  t_c2q = t_pd + tau * ln(T_w / |dt|)   (|dt| < T_w)

  对 ln|dt| 与 t_c2q 做线性拟合，斜率 = -tau，截距给出 T_w。

用法：
    python scripts/metastability_sweep.py                      # 行为模型
    python scripts/metastability_sweep.py --spice C:\\tools\\ngspice.exe
"""
import argparse
import json
import math
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PDK = ROOT / "pdk"
CFG = PDK / "sky130_config.json"
OUTDIR = ROOT / "doc" / "pdk"

# ---- SKY130 1.8V 器件参数（与 sky130_mtbf.py 一致）----
TOX_NM = 4.1
EPS_OX = 3.9 * 8.854e-12
COX_F_PER_M2 = EPS_OX / (TOX_NM * 1e-9)
COX_FF_PER_UM2 = COX_F_PER_M2 * 1e3       # 1 F/m^2 = 1e3 fF/um^2
MU_N = 0.040
MU_P = 0.012
VOV = 0.70
CJ_FF_PER_UM = 0.9
VDD = 1.8


# =====================================================================
# 共同部分：从网表取器件尺寸，算锁存节点 C 与 gm
# =====================================================================
def parse_config():
    c = json.load(open(CFG, encoding="utf-8"))
    scl = c["standard_cell_library"]
    tr = c["transistor_models"]
    return {
        "cell": scl["cell"],
        "spice": PDK / scl["spice_netlist"],
        "liberty_json": PDK / scl["liberty_json"],
        "nfet": PDK / tr["nfet_corner"],
        "pfet": PDK / tr["pfet_corner"],
        "models_root": PDK / tr["models_root"],
        "corner": scl["corner"],
    }


def parse_netlist(path):
    """返回 (器件列表, nfet 名, pfet 名)"""
    import re
    devs = []
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        if not s.startswith("X") or "sky130_fd_pr__" not in s:
            continue
        m_typ = re.search(r"(sky130_fd_pr__\w+)", s)
        m_w = re.search(r"w=([\d.eE+-]+)u", s)
        m_l = re.search(r"l=([\d.eE+-]+)u", s)
        if not (m_typ and m_w and m_l):
            continue
        devs.append({
            "type": "n" if "nfet" in m_typ.group(1) else "p",
            "w_um": float(m_w.group(1)) * 1e-6,
            "l_um": float(m_l.group(1)) * 1e-6,
        })
    return devs


def latch_params(devs):
    """从真实 w/l 估算锁存节点的 C 与环路 gm"""
    ns = sorted([d for d in devs if d["type"] == "n"], key=lambda x: x["w_um"])
    ps = sorted([d for d in devs if d["type"] == "p"], key=lambda x: x["w_um"])
    n_rep = ns[len(ns) // 2]
    p_rep = ps[len(ps) // 2]

    gm_n = MU_N * COX_F_PER_M2 * (n_rep["w_um"] / n_rep["l_um"]) * VOV
    gm_p = MU_P * COX_F_PER_M2 * (p_rep["w_um"] / p_rep["l_um"]) * VOV
    gm_loop = 0.5 * (gm_n + gm_p)

    c_gate = COX_FF_PER_UM2 * (n_rep["w_um"] * n_rep["l_um"] +
                               p_rep["w_um"] * p_rep["l_um"])
    c_drain = CJ_FF_PER_UM * (2 * n_rep["w_um"] + 2 * p_rep["w_um"])
    c_node = 2 * c_gate + c_drain          # fF

    tau_ps = (c_node * 1e-15) / (gm_loop * 0.9) * 1e12
    return {"n_rep": n_rep, "p_rep": p_rep, "gm_n_uS": gm_n * 1e6,
            "gm_p_uS": gm_p * 1e6, "gm_loop_uS": gm_loop * 1e6,
            "c_node_fF": c_node, "tau_analytic_ps": tau_ps}


# =====================================================================
# 模式 B：行为级扫掠（ODE）
# =====================================================================
def latch_dispersion(v0, gm, cap, gds, vsat, vdd, tmax, dt):
    """交叉耦合锁存器 ODE：返回差分达到满摆幅所需时间(s)；None=未达"""
    v1, v2 = v0 / 2.0, -v0 / 2.0

    def isat(v):
        return gm * v / (1.0 + (v / vsat) ** 2) + gds * v

    t = 0.0
    target = 0.9 * vdd
    while t < tmax:
        d1 = (-isat(v2) - gds * v1) / cap
        d2 = (-isat(v1) - gds * v2) / cap
        v1 += dt * d1
        v2 += dt * d2
        t += dt
        if max(v1, -v2) >= target:
            return t
    return None


def sweep_model(params, dt_ps_list, tmax_ns=20.0):
    """对每个相位偏移算发散时间。v0 ∝ dt（线性化）。"""
    gm = params["gm_loop_uS"] * 1e-6
    cap = params["c_node_fF"] * 1e-15
    gds = 0.1 * gm
    vsat = 0.6
    step = 2e-13
    rows = []
    # 标定：把 dt = 100 ps 映射为 v0 = 0.5*VDD（相位差越大初始扰动越大）
    k = 0.5 * VDD / 100.0        # V per ps
    for dt_ps in dt_ps_list:
        v0 = k * dt_ps
        t = latch_dispersion(v0, gm, cap, gds, vsat, VDD, tmax_ns * 1e-9, step)
        rows.append({"dt_ps": dt_ps, "t_disp_ns": (t * 1e9) if t else None})
    return rows


# =====================================================================
# 模式 A：SPICE 扫掠
# =====================================================================
def build_deck(cfg, dt_ps, tmpdir, tclk_ns=4.0, cload_ff=2.0):
    """生成一份相位扫掠 deck：data 相对 clk 偏移 dt_ps"""
    nf, pf = cfg["nfet"], cfg["pfet"]
    net = cfg["spice"]

    # 模型 include：把 corner 文件里的 .include 路径补全
    nf_w = tmpdir / "nfet.spice"
    pf_w = tmpdir / "pfet.spice"
    for src, dst in ((nf, nf_w), (pf, pf_w)):
        txt = open(src, encoding="utf-8").read()
        dst.write_text(txt, encoding="utf-8")

    t_clk_edge = tclk_ns          # clk 上升沿时刻 (ns)
    t_data = t_clk_edge + dt_ps / 1000.0   # data 边沿 (ns)

    deck = f"""* metastability phase sweep: dt = {dt_ps:.3f} ps
.include "{nf_w.as_posix()}"
.include "{pf_w.as_posix()}"
.include "{net.as_posix()}"
.temp 25
VDD vdd 0 {VDD}
VGND vgnd 0 0
X1 clk data vgnd vgnd vdd vdd q {cfg['cell']}
* clk: 先低, 在 t_clk_edge 上升
Vclk clk 0 PULSE(0 {VDD} {t_clk_edge} 1p 1p 100n 200n)
* data: 在 t_data 上升 (dt 为相对 clk 的偏移)
Vdata data 0 PULSE(0 {VDD} {t_data} 1p 1p 100n 200n)
* 输出负载
Cload q 0 {cload_ff}f
.tran 1p 20n 0 2p
.measure tran tq WHEN v(q)={VDD/2:.3f} RISE=1
.measure tran tclk WHEN v(clk)={VDD/2:.3f} RISE=1
.end
"""
    p = tmpdir / f"deck_{dt_ps:+.3f}.spice"
    p.write_text(deck, encoding="utf-8")
    return p


def run_ngspice(ngspice, deck):
    log = deck.with_suffix(".log")
    try:
        r = subprocess.run([ngspice, "-b", "-o", str(log), str(deck)],
                           capture_output=True, text=True, timeout=120)
    except Exception as e:
        return {"error": str(e)}
    txt = ""
    if log.exists():
        txt = log.read_text(encoding="utf-8", errors="replace")
    tq = tclk = None
    for line in txt.splitlines():
        if "tq" in line and "=" in line:
            try:
                tq = float(line.split("=")[1].split()[0])
            except Exception:
                pass
        if "tclk" in line and "=" in line:
            try:
                tclk = float(line.split("=")[1].split()[0])
            except Exception:
                pass
    if tq is None:
        return {"error": "no tq in output", "log": str(log)}
    return {"t_c2q_ns": (tq - tclk) * 1e9 if tclk is not None else tq * 1e9}


def sweep_spice(cfg, ngspice, dt_ps_list):
    rows = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for dt in dt_ps_list:
            deck = build_deck(cfg, dt, tmp)
            r = run_ngspice(ngspice, deck)
            if "error" in r:
                rows.append({"dt_ps": dt, "t_c2q_ns": None, "error": r["error"]})
            else:
                rows.append({"dt_ps": dt, "t_c2q_ns": r["t_c2q_ns"]})
    return rows


# =====================================================================
# 拟合：从扫描数据求 tau 与 T_w
# =====================================================================
def fit_tau_tw(rows, key):
    """对 ln|dt| 与 t 做线性拟合，返回 (tau_ps, T_w_ps, 拟合质量)"""
    pts = [(abs(r["dt_ps"]), r[key]) for r in rows
           if r.get(key) is not None and r["dt_ps"] != 0]
    if len(pts) < 4:
        return None
    # 取"明显高于基线"的点作为亚稳态区
    base = min(v for _, v in pts)
    meta = [(d, v) for d, v in pts if v > base * 1.02]
    if len(meta) < 3:
        return None
    xs = [math.log(d) for d, _ in meta]
    ys = [v for _, v in meta]
    n = len(xs)
    sx, sy = sum(xs), sum(ys)
    sxx = sum(x * x for x in xs)
    sxy = sum(x * y for x, y in zip(xs, ys))
    denom = n * sxx - sx * sx
    if abs(denom) < 1e-18:
        return None
    slope = (n * sxy - sx * sy) / denom
    intercept = (sy - slope * sx) / n
    tau = -slope                       # ps (若 t 单位是 ps) / 若为 ns 需换算
    # 残差
    ss_res = sum((y - (slope * x + intercept)) ** 2 for x, y in zip(xs, ys))
    ss_tot = sum((y - sy / n) ** 2 for y in ys)
    r2 = 1 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    return {"slope": slope, "intercept": intercept, "tau_raw": tau, "r2": r2,
            "n_points": n, "baseline": base}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spice", help="ngspice 可执行文件路径；省略则用行为模型")
    ap.add_argument("--out", default=str(OUTDIR))
    args = ap.parse_args()

    cfg = parse_config()
    devs = parse_netlist(cfg["spice"])
    params = latch_params(devs)

    print("=" * 78)
    print("亚稳态相位扫掠与拟合")
    print("=" * 78)
    print(f"  单元: {cfg['cell']}   工艺角: {cfg['corner']}")
    print(f"  网表: {cfg['spice'].name}  晶体管数: {len(devs)}")
    print(f"  锁存参数: gm_loop={params['gm_loop_uS']:.0f} uS, "
          f"C_node={params['c_node_fF']:.2f} fF, tau_analytic={params['tau_analytic_ps']:.1f} ps")

    mode = "spice" if args.spice else "model"
    print(f"  模式: {'A) 真实 SPICE 扫掠' if mode == 'spice' else 'B) 行为模型扫掠（非 SPICE 表征）'}")

    # 相位扫描点：覆盖从 0.1 ps 到 500 ps
    if mode == "spice":
        dt_list = [0.5, 1, 2, 3, 5, 8, 12, 18, 25, 35, 50, 70, 100, 150, 200, 300]
    else:
        dt_list = [0.2, 0.5, 1, 2, 3, 5, 8, 12, 18, 25, 35, 50, 70, 100, 150, 200]

    print(f"\n[1] 扫掠 {len(dt_list)} 个相位点 ...")
    if mode == "spice":
        rows = sweep_spice(cfg, args.spice, dt_list)
        key = "t_c2q_ns"
        unit_scale = 1000.0     # ns -> ps
    else:
        rows = sweep_model(params, dt_list)
        key = "t_disp_ns"
        unit_scale = 1000.0

    ok = [r for r in rows if r.get(key) is not None]
    print(f"    成功 {len(ok)}/{len(rows)}")
    for r in rows[:10]:
        v = r.get(key)
        print(f"      dt={r['dt_ps']:>7.3f} ps   {key}="
              f"{v*unit_scale if v is not None else float('nan'):>9.3f} ps")

    print("\n[2] 拟合 tau 与 T_w")
    fit = fit_tau_tw(rows, key)
    result = {
        "mode": mode,
        "cell": cfg["cell"], "corner": cfg["corner"],
        "unit": "ps",
        "sweep": rows,
        "latch_params": params,
        "tau_ps": None, "Tw_ps": None, "r2": None,
        "note": "",
    }
    if fit:
        tau_ps = abs(fit["tau_raw"]) * unit_scale
        # 由 t = base + tau*ln(Tw/dt) 反解 Tw:  当 dt = Tw 时 t = base
        # => intercept = base + tau*ln(Tw)  =>  Tw = exp((intercept-base)/tau)
        base = fit["baseline"]
        Tw_ps = math.exp((fit["intercept"] - base) / (fit["tau_raw"] or 1.0))
        result.update({"tau_ps": tau_ps, "Tw_ps": Tw_ps, "r2": fit["r2"],
                       "n_points": fit["n_points"]})
        print(f"    tau = {tau_ps:.2f} ps")
        print(f"    T_w = {Tw_ps:.2f} ps")
        print(f"    拟合 R^2 = {fit['r2']:.4f}  ({fit['n_points']} 个亚稳态点)")
        if math.isinf(Tw_ps) or Tw_ps > 1e6:
            print("    T_w 拟合发散（截距不可靠），改用扫描边界估计")
            # 退路：取发散开始的那个 dt
            meta = [(abs(r["dt_ps"]), r[key]) for r in rows if r.get(key)]
            meta.sort(key=lambda x: x[1], reverse=True)
            if meta:
                Tw_ps = meta[0][0]
                result["Tw_ps"] = Tw_ps
                print(f"    T_w(边界估计) = {Tw_ps:.2f} ps")
    else:
        print("    拟合失败：数据点不足或未进入亚稳态区")

    if mode == "model":
        result["note"] = ("行为模型（交叉耦合锁存器 ODE）结果，器件尺寸取自 SKY130 网表。"
                          "按 pdk/README.md 规范，这不是 SKY130 的 SPICE 表征结果，"
                          "不得当作工艺签核数据。")
    else:
        result["note"] = ("SPICE 相位扫掠结果。仅代表 "
                          f"{cfg['corner']} 模型、25C、1.8V、2fF 负载、2ps 步长下的行为。")

    os.makedirs(args.out, exist_ok=True)
    name = f"sky130_metastability_{mode}.json"
    path = os.path.join(args.out, name)
    json.dump(result, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(f"\n结果已保存: {path}")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
