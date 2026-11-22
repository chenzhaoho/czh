"""Run RTL lint without Unix tee or a shell pipeline masking the exit status."""
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
def main():
    exe = Path(os.environ.get("VERILATOR_EXE") or shutil.which("verilator.exe")
               or "D:/eLinx3.0/verilator/verilator.exe").resolve()
    if not exe.is_file():
        print("Set VERILATOR_EXE to verilator.exe"); return 2
    env = dict(os.environ)
    env["PATH"] = str(exe.parent) + os.pathsep + env.get("PATH", "")
    common = ["rtl/common/gray_codec.v", "rtl/common/sync_2ff.v",
              "rtl/common/sync_gray_bus.v", "rtl/common/rst_sync.v", "rtl/fifo/async_fifo.v"]
    configs = [
        ("dual_async_fifo_top", ["rtl/fifo/fifo_a.v", "rtl/fifo/fifo_b.v",
                                "rtl/top/monitor.v", "rtl/top/dual_async_fifo_top.v"]),
        ("dual_fifo_link", ["rtl/ext/dual_fifo_link.v"]),
    ]
    directory = ROOT / "sim/logs"
    directory.mkdir(parents=True, exist_ok=True)
    all_ok = True
    for top, extra in configs:
        # Link wrappers intentionally leave the core's debug-only outputs open.
        options = ["-Wno-PINCONNECTEMPTY"] if top == "dual_fifo_link" else []
        result = subprocess.run([str(exe), "--lint-only", "-Wall", "-Wno-DECLFILENAME",
                                 *options, "--top-module", top, *common, *extra],
                                cwd=ROOT, env=env, capture_output=True)
        body = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        (directory / f"lint_{top}.log").write_text(body, encoding="utf-8")
        print(f"{top}: {'PASS' if result.returncode == 0 else 'FAIL'}")
        if body: print(body[:5000])
        all_ok &= result.returncode == 0
    return 0 if all_ok else 1

if __name__ == "__main__":
    raise SystemExit(main())
