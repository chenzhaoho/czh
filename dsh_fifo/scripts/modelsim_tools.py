"""Locate the ModelSim tools used by the Windows simulation runners."""

import os
from pathlib import Path
import shutil


def modelsim_bin(*tools: str) -> Path:
    """Use an explicit installation, tools on PATH, or the original local install."""
    configured = os.environ.get("MODELSIM_BIN")
    if configured:
        folder = Path(configured).expanduser().resolve()
    else:
        vsim = shutil.which("vsim.exe")
        folder = Path(vsim).resolve().parent if vsim else Path("E:/modelsim_ase/win32aloem")
    missing = [tool for tool in tools if not (folder / tool).is_file()]
    if missing:
        raise FileNotFoundError(
            f"Missing {', '.join(missing)} in {folder}. "
            "Set MODELSIM_BIN to the directory containing your ModelSim executables."
        )
    return folder
