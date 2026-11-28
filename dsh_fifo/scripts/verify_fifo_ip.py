"""Run the published duplex FIFO parameter and clock matrix in ModelSim."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import subprocess
from tempfile import mkdtemp
import xml.etree.ElementTree as ET

from modelsim_tools import modelsim_bin

ROOT = Path(__file__).resolve().parents[1]


def simulation_sources(component):
    if component is None:
        entries = (ROOT / "ip/rtl_sources.f").read_text(encoding="ascii").splitlines()
        return ROOT, [ROOT / entry for entry in entries]
    component = component.resolve()
    ns = {"ip": "http://www.spiritconsortium.org/XMLSchema/SPIRIT/1685-2009"}
    model = ET.parse(component).getroot()
    identity = ":".join(model.findtext("ip:" + tag, "", ns)
                        for tag in ("vendor", "library", "name", "version"))
    if identity != "chenzhaoho:user:dual_fifo_link:1.0":
        raise ValueError(f"Unexpected IP identity {identity!r}")
    for group in model.findall("ip:fileSets/ip:fileSet", ns):
        if group.findtext("ip:name", "", ns) == "xilinx_anylanguagebehavioralsimulation_view_fileset":
            sources = []
            for entry in group.findall("ip:file", ns):
                if entry.findtext("ip:fileType", "", ns) != "verilogSource":
                    continue
                rel = Path(entry.findtext("ip:name", "", ns))
                path = (component.parent / rel).resolve()
                if rel.is_absolute() or not path.is_relative_to(component.parent) or not path.is_file():
                    raise ValueError(f"Missing or nonportable packaged RTL entry: {rel}")
                sources.append(path)
            if sources:
                return component.parent, sources
    raise ValueError("Package has no behavioral Verilog file set")


def run(command, folder, log, timeout):
    with log.open("wb") as output:
        subprocess.run(command, cwd=folder, stdout=output, stderr=subprocess.STDOUT,
                       check=True, timeout=timeout)
    return log.read_text(encoding="utf-8", errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=27)
    parser.add_argument("--component", type=Path,
                        help="Compile the simulation file set in a packaged component.xml")
    parser.add_argument("--stress", action="store_true",
                        help="Test coincident edges and both 50:1 clock orders, including stop and reset")
    args = parser.parse_args()
    if not 0 <= args.seed <= 2147483647:
        parser.error("seed must fit a nonnegative signed 32-bit integer")
    simulator = modelsim_bin("vlib.exe", "vlog.exe", "vsim.exe")
    parent = ROOT / "build" / "ip_sim"
    parent.mkdir(parents=True, exist_ok=True)
    session = Path(mkdtemp(prefix="run-", dir=parent))
    print(f"Results: {session}", flush=True)
    source_root, sources = simulation_sources(args.component)
    manifest = {str(s.relative_to(source_root)): hashlib.sha256(s.read_bytes()).hexdigest()
                for s in sources}
    (session / "source_hashes.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    run([simulator / "vlib.exe", "work"], session, session / "vlib.log", 60)
    run([simulator / "vlog.exe", "-sv", *sources,
         ROOT / "tb/tb_dual_fifo_ip.sv"], session, session / "compile.log", 120)
    results = []
    clocks = ((1, 0), (2, 0), (2, 1)) if args.stress else ((0, 0), (0, 1))
    for dw, aw, stages, (clock_case, swap) in itertools.product((16, 32), (6, 8), (2, 3), clocks):
        marker = f"IP_PASS DW={dw} AW={aw} STAGES={stages} SWAP={swap} SEED={args.seed}"
        required = {marker}
        if clock_case:
            for stopped in (0, 1):
                required.add(f"CLOCK_PAUSE_PASS stopped={stopped} capacity={1 << aw} reverse={1 << (aw - 1)}")
        suffix = f"_clock{clock_case}" if clock_case else ""
        log = session / f"dw{dw}_aw{aw}_s{stages}_swap{swap}{suffix}.log"
        command = [simulator / "vsim.exe", "-c", "-quiet", "-onfinish", "stop",
                   f"-gDW={dw}", f"-gAW={aw}", f"-gSYNC_STAGES={stages}",
                   f"-gSWAP_CLOCKS={swap}", f"-gCLOCK_CASE={clock_case}",
                   "work.tb_dual_fifo_ip", f"+SEED={args.seed}",
                   "-do", "onerror {quit -code 1}; run -all; quit -f"]
        try:
            output = run(command, session, log, 120)
            lines = {line.removeprefix("# ").strip() for line in output.splitlines()}
            passed = required.issubset(lines)
        except (subprocess.SubprocessError, OSError) as error:
            print(error, flush=True)
            passed = False
        results.append(dict(dw=dw, aw=aw, stages=stages, swap=swap, clock_case=clock_case, seed=args.seed,
                            passed=passed, log=log.name))
        print(f"{'PASS' if passed else 'FAIL'} {log.name}", flush=True)
    (session / "matrix.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    total = sum(r["passed"] for r in results)
    print(f"{total}/{len(results)} PASS")
    return int(total != len(results))


if __name__ == "__main__":
    raise SystemExit(main())
