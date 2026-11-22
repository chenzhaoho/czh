# -*- coding: utf-8 -*-
"""sky130_spice_sweep.py -- 在真实 SKY130 上进行亚稳态相位扫描（精细版）

第一版扫描步长 50 ps 太粗，把两类现象混在一起：
  * dt > 0  （data 晚于 clk）-> Q 不翻转，这是**正常的功能行为**，不是亚稳态
  * dt ≈ 0  （data 落在 setup 窗口边缘）-> c2q 变大 / 不翻转，这才是**亚稳态**

本版：
  * 只在 setup 边界附近加密（1~2 ps 步长）
  * 用"c2q 相对基线显著增大"作为亚稳态判据，排除"data 太晚导致的正常不采样"
  * 对 ln|dt−dt0| 拟合求 tau 与 Tw

前置条件（已解决）：.option scale=1.0u、精简 corner、8 个参数补丁、绝对路径。
"""
import argparse
import json
import math
import re
import subprocess
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WD = ROOT / "build/spice_test"
TRIM = WD / "tt_trim.spice"
SC = ROOT / "pdk/sky130_fd_sc_hd/cells/dfxtp/sky130_fd_sc_hd__dfxtp_1.spice"
OUT = ROOT / "doc/pdk/sky130_metastability_spice.json"

T_CLK_NS = 4.0
T_STOP_NS = 40.0


def make_deck(dt_ps, path):
    t_data = T_CLK_NS + dt_ps / 1000.0
    path.write_text(f"""* SKY130 meta sweep dt={dt_ps:+.3f}ps
.option scale=1.0u
.include "{TRIM.as_posix()}"
.include "{SC.as_posix()}"
.temp 25
VDD vdd 0 1.8
VGND vgnd 0 0
Vdata data 0 PULSE(0 1.8 {t_data:.6f}n 5p 5p 100n 200n)
Vclk  clk  0 PULSE(0 1.8 {T_CLK_NS:.6f}n 5p 5p 100n 200n)
X1 clk data vgnd vgnd vdd vdd q sky130_fd_sc_hd__dfxtp_1
Cload q 0 2f
.tran 1p {T_STOP_NS:.1f}n 0 2p
.measure tran tq   WHEN v(q)=0.9   RISE=1
.measure tran tclk WHEN v(clk)=0.9 RISE=1
.end
""", encoding="ascii")


def run_one(ngspice, dt_ps, idx):
    deck = WD / f"sw2_{idx:03d}.spice"
    make_deck(dt_ps, deck)
    try:
        r = subprocess.run([str(ngspice), "-b", deck.name], cwd=str(WD),
                           capture_output=True, text=True, timeout=240)
        out = (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return {"dt_ps": dt_ps, "c2q_ps": None, "state": "timeout"}
    tq = tclk = None
    for line in out.splitlines():
        m = re.match(r"\s*tq\s*=\s*([\d.eE+-]+)", line)
        if m:
            tq = float(m.group(1))
        m = re.match(r"\s*tclk\s*=\s*([\d.eE+-]+)", line)
        if m:
            tclk = float(m.group(1))
    if tq is None or tclk is None:
        return {"dt_ps": dt_ps, "c2q_ps": None, "state": "no_transition"}
    return {"dt_ps": dt_ps, "c2q_ps": (tq - tclk) * 1e12, "state": "ok"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ngspice", help="Path to ngspice or ngspice_con.exe")
    args = parser.parse_args()
    ngspice = args.ngspice or shutil.which("ngspice_con") or shutil.which("ngspice")
    if not ngspice:
        parser.error("Install ngspice or specify --ngspice.")
    models = ROOT / "pdk/sky130_fd_pr/cells"
    patches = {
        "nfet_01v8": ("toxe_slope", "voff_slope", "vth0_slope", "vth0_slope1"),
        "pfet_01v8_hvt": ("nfactor_slope", "toxe_slope", "voff_slope", "vth0_slope"),
    }
    parameters = []
    includes = []
    for device, names in patches.items():
        prefix = f"sky130_fd_pr__{device}__"
        model = models / device / f"{prefix}tt.pm3.spice"
        if not model.is_file():
            parser.error(f"Missing {model}. See pdk/README.md.")
        parameters.extend(f".param {prefix}{name} = 0.0" for name in names)
        includes.append(f'.include "{model.as_posix()}"')
    if not SC.is_file():
        parser.error(f"Missing {SC}. See pdk/README.md.")
    WD.mkdir(parents=True, exist_ok=True)
    TRIM.write_text("\n".join([".option scale=1.0u", *parameters, *includes, ""]), encoding="ascii")
    ngspice = Path(ngspice).resolve()
    print("=" * 74)
    print("SKY130 真实 SPICE 亚稳态相位扫描（精细）")
    print("=" * 74)

    # 粗定位 setup 边界：先扫 [-120, +30]
    coarse = list(range(30, -121, -10))
    print(f"\n[1] 粗扫 {len(coarse)} 点 (dt = +30 .. -120 ps, 步长 10 ps)")
    rows = []
    for i, dt in enumerate(coarse):
        r = run_one(ngspice, dt, i)
        rows.append(r)
        v = f"{r['c2q_ps']:7.1f}" if r.get("c2q_ps") else r["state"]
        print(f"    dt={dt:>+5d} ps   {v}")

    oks = [r for r in rows if r.get("c2q_ps")]
    base = min(r["c2q_ps"] for r in oks) if oks else None
    print(f"\n    基线 c2q = {base:.1f} ps" if base else "    无有效基线")
    if base is None:
        return 1

    # 判定：c2q > 1.02*base 视为进入亚稳态
    thr = base * 1.02
    meta_coarse = [r for r in rows if r.get("c2q_ps") and r["c2q_ps"] > thr]
    print(f"    亚稳态候选（c2q > {thr:.1f} ps）: "
          f"{[r['dt_ps'] for r in meta_coarse]}")

    # 在候选区 ±20 ps 内以 2 ps 步长加密
    if meta_coarse:
        lo = min(r["dt_ps"] for r in meta_coarse) - 20
        hi = max(r["dt_ps"] for r in meta_coarse) + 20
    else:
        lo, hi = -60, 10
    fine = list(range(int(hi), int(lo) - 1, -2))
    print(f"\n[2] 加密扫描 {len(fine)} 点 (dt = {hi} .. {lo} ps, 步长 2 ps)")
    fine_rows = []
    for i, dt in enumerate(fine):
        r = run_one(ngspice, dt, 100 + i)
        fine_rows.append(r)
        v = f"{r['c2q_ps']:7.1f}" if r.get("c2q_ps") else r["state"]
        mark = " *" if (r.get("c2q_ps") and r["c2q_ps"] > thr) else ""
        print(f"    dt={dt:>+5d} ps   {v}{mark}")

    all_rows = rows + fine_rows
    # 亚稳态点：c2q 显著高于基线
    pts = [(abs(r["dt_ps"]), r["c2q_ps"]) for r in all_rows
           if r.get("c2q_ps") and r["c2q_ps"] > thr]

    result = {
        "mode": "spice",
        "corner": "tt_025C_1v80", "vdd": 1.8, "temp_c": 25,
        "cload_fF": 2.0, "tstep_ps": 1.0, "clk_ns": T_CLK_NS,
        "baseline_c2q_ps": base, "meta_threshold_ps": thr,
        "coarse_sweep": rows, "fine_sweep": fine_rows,
        "tau_ps": None, "Tw_ps": None, "r2": None,
        "note": ("SPICE 相位扫描。dt<0 表示 data 早于 clk（正常采样），"
                 "dt>0 表示 data 晚于 clk（正常不采样，非亚稳态）。"
                 "仅 c2q 显著高于基线的点参与拟合。"),
    }

    print(f"\n[3] 拟合（{len(pts)} 个亚稳态点）")
    if len(pts) >= 3:
        xs = [math.log(d) for d, _ in pts]
        ys = [v for _, v in pts]
        n = len(xs)
        sx, sy = sum(xs), sum(ys)
        sxx = sum(x * x for x in xs)
        sxy = sum(x * y for x, y in zip(xs, ys))
        den = n * sxx - sx * sx
        if abs(den) > 1e-18:
            slope = (n * sxy - sx * sy) / den
            intercept = (sy - slope * sx) / n
            tau = -slope
            ss_res = sum((y - (slope * x + intercept)) ** 2 for x, y in zip(xs, ys))
            ss_tot = sum((y - sy / n) ** 2 for y in ys)
            r2 = 1 - ss_res / ss_tot if ss_tot > 0 else float("nan")
            result.update({"tau_ps": tau, "r2": r2, "intercept_ps": intercept})
            print(f"    tau = {tau:.2f} ps")
            print(f"    R^2 = {r2:.4f}")
            print(f"    点: {[f'{d:.0f}ps->{v:.0f}ps' for d, v in pts]}")
    else:
        print("    有效点不足，只记录扫描数据")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已保存: {OUT}")
    print("=" * 74)
    return 0


if __name__ == "__main__":
    sys.exit(main())
