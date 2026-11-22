#!/usr/bin/env python3
"""Extract SKY130 dfxtp Liberty data and optionally smoke-test its SPICE model."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = PROJECT_ROOT / "pdk" / "sky130_config.json"


def flatten_numbers(value: Any) -> list[float]:
    if isinstance(value, (int, float)):
        return [float(value)]
    if isinstance(value, list):
        return [number for item in value for number in flatten_numbers(item)]
    return []


def time_range_ps(values: list[float]) -> dict[str, float] | None:
    if not values:
        return None
    return {"min_ps": min(values) * 1000.0, "max_ps": max(values) * 1000.0}


def pin_timing(pin: dict[str, Any]) -> list[dict[str, Any]]:
    timing = pin.get("timing", [])
    if isinstance(timing, dict):
        return [timing]
    return [item for item in timing if isinstance(item, dict)]


def constraint_values(pin: dict[str, Any], timing_type: str) -> list[float]:
    values: list[float] = []
    for timing in pin_timing(pin):
        if timing.get("timing_type") != timing_type:
            continue
        for key, table in timing.items():
            if key.startswith(("rise_constraint,", "fall_constraint,")):
                values.extend(flatten_numbers(table.get("values", [])))
    return values


def delay_values(pin: dict[str, Any], table_name: str) -> list[float]:
    values: list[float] = []
    for timing in pin_timing(pin):
        for key, table in timing.items():
            if key.startswith(table_name + ","):
                values.extend(flatten_numbers(table.get("values", [])))
    return values


def repository_revision(path: Path) -> str | None:
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None



def _load_metastability() -> dict[str, Any]:
    """读取 metastability_sweep.py 的相位扫掠结果。

    Liberty 本身不含 tau/Tw；这两项只能来自相位扫掠+拟合。
    sweep 脚本会把结果写到 doc/pdk/sky130_metastability_{model,spice}.json。
    优先用 spice（真表征），没有则用 model（行为模型，必须标注）。
    """
    out = {"tau_ps": None, "tw_ps": None, "mtbf": None,
           "status": "not characterized; run metastability_sweep.py"}
    base = PROJECT_ROOT / "doc" / "pdk"
    for mode, honest in (("spice", "SPICE phase sweep"),
                         ("model", "behavioral model (NOT a SPICE characterization)")):
        f = base / f"sky130_metastability_{mode}.json"
        if not f.exists():
            continue
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        if d.get("tau_ps") is None:
            continue
        out = {
            "tau_ps": d.get("tau_ps"),
            "tw_ps": d.get("Tw_ps"),
            "fit_r2": d.get("r2"),
            "source": honest,
            "artifact": str(f.relative_to(PROJECT_ROOT)),
            "status": f"characterized via {honest}",
            "mtbf": _mtbf_table(d.get("tau_ps"), d.get("Tw_ps")),
        }
        break
    return out


def _mtbf_table(tau_ps: float, tw_ps: float) -> dict[str, Any]:
    """用扫描得到的 tau/Tw 算几张 MTBF 表（t_setup 取 Liberty 最坏值）。"""
    import math
    if not tau_ps or not tw_ps:
        return {}
    tau = tau_ps * 1e-12
    tw = tw_ps * 1e-12
    tsu, tskew, fdata = 0.6207e-9, 0.05e-9, 1e8
    year = 3.1557e7
    res = {}
    for tclk_ns in (4.0, 10.0, 1.0):
        fclk = 1e9 / tclk_ns
        for stages in (2, 3):
            t_r = (stages - 1) * tclk_ns * 1e-9 - tsu - tskew
            if t_r <= 0:
                res[f"Tclk{tclk_ns}ns_{stages}stage"] = None
                continue
            lg = (t_r / tau) / math.log(10) - math.log10(tw * fclk * fdata)
            res[f"Tclk{tclk_ns}ns_{stages}stage"] = round(lg - math.log10(year), 2)
    return res


def load_metrics(config: dict[str, Any]) -> dict[str, Any]:
    stdlib = config["standard_cell_library"]
    lib_path = PROJECT_ROOT / "pdk" / stdlib["liberty_json"]
    if not lib_path.is_file():
        raise FileNotFoundError(f"Liberty JSON not found: {lib_path}")

    cell = json.loads(lib_path.read_text(encoding="utf-8"))
    pin_d = cell["pin,D"]
    pin_q = cell["pin,Q"]
    setup = constraint_values(pin_d, "setup_rising")
    hold = constraint_values(pin_d, "hold_rising")
    c2q = delay_values(pin_q, "cell_rise") + delay_values(pin_q, "cell_fall")

    metrics = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "pdk": config["name"],
        "cell": stdlib["cell"],
        "corner": stdlib["corner"],
        "source": {
            "standard_cell_repository": stdlib["repository"],
            "standard_cell_revision": repository_revision(
                PROJECT_ROOT / "pdk" / "sky130_fd_sc_hd"
            )
            or stdlib["revision"],
            "transistor_model_repository": config["transistor_models"]["repository"],
            "transistor_model_revision": repository_revision(
                PROJECT_ROOT / "pdk" / "sky130_fd_pr"
            )
            or config["transistor_models"]["revision"],
        },
        "units": config["metric_units"],
        "cell_area_um2": cell.get("area"),
        "cell_leakage_power_uW": cell.get("cell_leakage_power"),
        "input_capacitance_fF": {
            name: cell[f"pin,{name}"].get("capacitance", 0.0) * 1000.0
            for name in ("D", "CLK")
        },
        "setup_constraint_ps": time_range_ps(setup),
        "hold_constraint_ps": time_range_ps(hold),
        "clock_to_q_ps": time_range_ps(c2q),
        "metastability": _load_metastability(),
        "artifacts": {
            "liberty_json": str(lib_path.relative_to(PROJECT_ROOT)),
            "cell_spice": str(Path("pdk") / stdlib["spice_netlist"]),
        },
    }
    return metrics


def render_markdown(metrics: dict[str, Any]) -> str:
    setup = metrics["setup_constraint_ps"] or {}
    hold = metrics["hold_constraint_ps"] or {}
    c2q = metrics["clock_to_q_ps"] or {}
    caps = metrics["input_capacitance_fF"]
    meta = metrics.get("metastability") or {}
    tau = meta.get("tau_ps")
    tw = meta.get("tw_ps")
    fit = meta.get("fit_r2")
    if tau is None:
        metastability = "Liberty timing tables do not contain `tau` or `T_w`."
    else:
        metastability = f"tau = {tau:.2f} ps."
        if tw is None:
            metastability += " T_w is unavailable, so this result supplies no absolute MTBF estimate."
        else:
            metastability += f" T_w = {tw:.2f} ps."
        if fit is not None:
            metastability += f" R^2 = {fit:.4f}."
        metastability += f" Source: {meta['source']}."
    source = metrics["source"]
    lines = [
        "# SKY130 dfxtp_1 Characterization",
        "",
        f"- Cell: `{metrics['cell']}`",
        f"- Corner: `{metrics['corner']}`",
        f"- Standard-cell revision: `{source['standard_cell_revision']}`",
        f"- Transistor-model revision: `{source['transistor_model_revision']}`",
        f"- Cell area: {metrics['cell_area_um2']:.4f} um^2",
        f"- Cell leakage: {metrics['cell_leakage_power_uW']:.6g} uW",
        f"- D / CLK input capacitance: {caps['D']:.4f} / {caps['CLK']:.4f} fF",
        f"- Setup table range: {setup.get('min_ps', float('nan')):.2f} to {setup.get('max_ps', float('nan')):.2f} ps",
        f"- Hold table range: {hold.get('min_ps', float('nan')):.2f} to {hold.get('max_ps', float('nan')):.2f} ps",
        f"- Clock-to-Q table range: {c2q.get('min_ps', float('nan')):.2f} to {c2q.get('max_ps', float('nan')):.2f} ps",
        "",
        "## MTBF Parameters",
        "",
        metastability,
        "",
        "The setup, hold, and clock-to-Q figures above are ranges across the Liberty slew/load tables. They are not single fixed values and must be interpolated at the intended transition and load conditions for a timing budget. Clock skew and inter-stage routing delay come from the implementation, not this cell library.",
    ]
    smoke = metrics.get("spice_smoke")
    if smoke:
        lines.extend(
            [
                "",
                "## SPICE Smoke Test",
                "",
                f"- Simulator: `{smoke['ngspice']}`",
                f"- Conditions: {smoke['temperature_c']} C (model TNOM {smoke['model_nominal_temperature_c']} C), {smoke['supply_v']:.1f} V, {smoke['output_load_fF']:.1f} fF load, {smoke['max_step_s'] * 1e12:.1f} ps maximum step",
                f"- Measured clock-to-Q: {smoke['measured_tclk2q_s'] * 1e12:.2f} ps",
                "- This single-transition smoke test verifies model loading and ordinary DFF operation. It does not characterize `tau` or `T_w`.",
            ]
        )
    lines.append("")
    return "\n".join(lines)


def make_model_include(src: Path, dst: Path) -> None:
    text = src.read_text(encoding="utf-8")
    pattern = re.compile(r'(?m)^\s*\.include\s+"([^"]+\.pm3\.spice)"\s*$')
    match = pattern.search(text)
    if not match:
        raise ValueError(f"Expected PM3 include was not found in {src}")
    include_path = src.parent / match.group(1)
    if not include_path.is_file():
        raise FileNotFoundError(f"Transistor model include not found: {include_path}")
    replacement = f'.include "{include_path.as_posix()}"'
    mismatch_path = src.with_name(
        src.name.replace("__tt.corner.spice", "__mismatch.corner.spice")
    )
    if mismatch_path == src or not mismatch_path.is_file():
        raise FileNotFoundError(f"Transistor mismatch parameters not found: {mismatch_path}")
    wrapper = pattern.sub(replacement, text)
    wrapper += f'\n.include "{mismatch_path.as_posix()}"\n'
    dst.write_text(wrapper, encoding="ascii")


def run_spice_smoke(config: dict[str, Any], ngspice: str, workdir: Path) -> dict[str, Any]:
    models = config["transistor_models"]
    stdlib = config["standard_cell_library"]
    nfet = PROJECT_ROOT / "pdk" / models["nfet_corner"]
    pfet = PROJECT_ROOT / "pdk" / models["pfet_corner"]
    cell = PROJECT_ROOT / "pdk" / stdlib["spice_netlist"]
    for required in (nfet, pfet, cell):
        if not required.is_file():
            raise FileNotFoundError(f"Required SKY130 SPICE view not found: {required}")

    workdir.mkdir(parents=True, exist_ok=True)
    nfet_wrapper = workdir / "nfet_tt.spice"
    pfet_wrapper = workdir / "pfet_tt.spice"
    make_model_include(nfet, nfet_wrapper)
    make_model_include(pfet, pfet_wrapper)

    deck = workdir / "dfxtp_smoke.cir"
    deck.write_text(
        "\n".join(
            [
                "SKY130 dfxtp_1 TT smoke test",
                ".option scale=1.0u",
                ".temp 25",
                f'.include "{nfet_wrapper.as_posix()}"',
                f'.include "{pfet_wrapper.as_posix()}"',
                f'.include "{cell.as_posix()}"',
                "VVPWR VPWR 0 1.8",
                "VVPB VPB 0 1.8",
                "VVNB VNB 0 0",
                "VCLK CLK 0 PULSE(0 1.8 5n 10p 10p 5n 10n)",
                "VDATA D 0 PWL(0 0 14n 0 14.01n 1.8 30n 1.8)",
                "XU1 CLK D 0 VNB VPB VPWR Q sky130_fd_sc_hd__dfxtp_1",
                "CLOAD Q 0 2f",
                ".control",
                "set noaskquit",
                "tran 2p 25n 0 2p",
                "meas tran tclk2q trig v(CLK) val=0.9 rise=2 targ v(Q) val=0.9 rise=1",
                "print tclk2q",
                "quit",
                ".endc",
                ".end",
                "",
            ]
        ),
        encoding="ascii",
    )
    log_path = workdir / "ngspice.log"
    result = subprocess.run(
        [ngspice, "-b", "-o", str(log_path), str(deck)],
        cwd=workdir,
        text=True,
        capture_output=True,
        timeout=180,
        check=False,
    )
    log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
    if result.returncode != 0 or "tclk2q" not in log.lower() or re.search(
        r"(?im)^\s*(?:fatal\s+)?error\b", log
    ):
        raise RuntimeError(
            "ngspice failed to load or simulate the SKY130 dfxtp cell. "
            f"See {log_path}.\n{result.stderr.strip()}"
        )
    match = re.search(r"tclk2q\s*=\s*([0-9.eE+-]+)", log, re.IGNORECASE)
    if not match:
        raise RuntimeError(f"ngspice did not report tclk2q; see {log_path}")
    return {
        "status": "passed",
        "ngspice": Path(ngspice).name,
        "temperature_c": 25,
        "model_nominal_temperature_c": 27,
        "supply_v": 1.8,
        "output_load_fF": 2.0,
        "max_step_s": 2e-12,
        "deck": str(deck.relative_to(PROJECT_ROOT)),
        "log": str(log_path.relative_to(PROJECT_ROOT)),
        "measured_tclk2q_s": float(match.group(1)),
        "note": "smoke test only; this is not a metastability tau/Tw measurement",
    }


def write_outputs(metrics: dict[str, Any], outdir: Path) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    stem = "sky130_dfxtp_1_tt_025C_1v80"
    (outdir / f"{stem}.json").write_text(
        json.dumps(metrics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (outdir / f"{stem}.md").write_text(render_markdown(metrics), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    parser.add_argument("--outdir", type=Path, default=PROJECT_ROOT / "doc" / "pdk")
    parser.add_argument("--run-spice", action="store_true", help="run the transistor-level DFF smoke test")
    parser.add_argument("--ngspice", help="ngspice executable; defaults to PATH lookup")
    args = parser.parse_args()

    config = json.loads(args.config.read_text(encoding="utf-8"))
    metrics = load_metrics(config)
    if args.run_spice:
        ngspice = args.ngspice or shutil.which("ngspice")
        if not ngspice:
            print("ERROR: ngspice was not found; install it or pass --ngspice PATH", file=sys.stderr)
            return 2
        try:
            metrics["spice_smoke"] = run_spice_smoke(
                config, ngspice, PROJECT_ROOT / "build" / "sky130_spice"
            )
        except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1

    write_outputs(metrics, args.outdir)
    print(f"Cell: {metrics['cell']} ({metrics['corner']})")
    print(f"Area: {metrics['cell_area_um2']:.4f} um^2")
    print(f"Setup range: {metrics['setup_constraint_ps']['min_ps']:.2f}..{metrics['setup_constraint_ps']['max_ps']:.2f} ps")
    print(f"Clock-to-Q range: {metrics['clock_to_q_ps']['min_ps']:.2f}..{metrics['clock_to_q_ps']['max_ps']:.2f} ps")
    print(f"Report: {args.outdir / 'sky130_dfxtp_1_tt_025C_1v80.md'}")
    if "spice_smoke" in metrics:
        print(f"SPICE smoke test: {metrics['spice_smoke']['status']}")
    else:
        _m = metrics["metastability"]
        if _m.get("mtbf"):
            print(f"MTBF: tau={_m['tau_ps']:.2f} ps, T_w={_m['tw_ps']:.2f} ps "
                  f"(R2={_m.get('fit_r2'):.4f}) via {_m['source']}")
            for k, v in _m["mtbf"].items():
                print(f"   {k}: " + (f"10^{v} years" if v else "not usable"))
        else:
            print("MTBF: not characterized; run metastability_sweep.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
