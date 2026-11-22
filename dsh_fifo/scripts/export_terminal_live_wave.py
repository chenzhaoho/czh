"""Capture one coherent live session snapshot, audit it, and export ModelSim WLF."""
import argparse
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import urllib.request
import zipfile

from modelsim_tools import modelsim_bin
from terminal_live import ROOT
from verify_terminal_wave import verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--session", type=Path, help="Use a stopped session instead of capturing the running backend")
    parser.add_argument("--open", action="store_true", help="Open the exported snapshot in the ModelSim waveform GUI")
    args = parser.parse_args()
    try:
        simulator = modelsim_bin("vcd2wlf.exe", "vsim.exe") if args.open else modelsim_bin("vcd2wlf.exe")
    except FileNotFoundError as exc:
        parser.exit(2, f"{exc}\n")
    if args.session:
        folder = args.session.resolve()
    else:
        request = urllib.request.Request(f"http://127.0.0.1:{args.port}/api/bundle.zip")
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
        folder = ROOT / "build/terminal_live/captures" / (time.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3))
        folder.mkdir(parents=True)
        # Copy only fixed, expected names. Never extract arbitrary archive paths.
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for name in ("evidence.json", "handshakes.csv", "terminal_live.vcd", "transcript.log", "compile.log"):
                (folder / name).write_bytes(archive.read(name))
            # Newer sessions also carry native Transcript and simulator-side ACKs.
            # Keep old backends compatible and never extract arbitrary ZIP paths.
            for name in ("modelsim_transcript.log", "simulator_commands.log"):
                if name in archive.namelist():
                    (folder / name).write_bytes(archive.read(name))
    result = verify(folder)
    (folder / "wave_audit.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    output = folder / "terminal_live.wlf"
    subprocess.run([str(simulator / "vcd2wlf.exe"), str(folder / "terminal_live.vcd"), str(output)], check=True)
    print("PASS: every handshake and both clocks independently checked against VCD.")
    print("WLF: " + str(output))
    print("Audit: " + str(folder / "wave_audit.json"))
    if args.open:
        subprocess.Popen([str(simulator / "vsim.exe"), "-view", str(output), "-do",
                          "do {" + (ROOT / "scripts/wave_terminal_live.do").as_posix() + "}"], cwd=folder)


if __name__ == "__main__":
    main()
