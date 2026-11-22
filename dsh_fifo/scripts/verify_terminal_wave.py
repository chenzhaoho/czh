"""Independently compare live-terminal CSV handshakes with actual VCD signal edges.

No browser, Python transport ledger or testbench counters are trusted here. Parse
the waveform and reconstruct each transfer from pre-edge valid, ready and data.
"""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path

TOP = "tb_terminal_live/"


def verify(folder):
    folder = Path(folder)
    vcd_path, csv_path = folder / "terminal_live.vcd", folder / "handshakes.csv"
    fields = {}
    codes = {}
    counts = Counter()
    clocks = {"a": 0, "b": 0}
    previous_edge = {}
    first_edge = {}
    periods = {"a": 10000, "b": 14000}
    with vcd_path.open(encoding="ascii") as vcd, csv_path.open(encoding="ascii", newline="") as record:
        scope = []
        for line in vcd:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "$scope":
                scope.append(parts[2])
            elif parts[0] == "$upscope":
                scope.pop()
            elif parts[0] == "$timescale":
                if next(vcd).strip() != "1ps":
                    raise ValueError("Expected 1ps waveform resolution")
            elif parts[0] == "$var":
                name = "/".join(scope + [parts[4]])
                width, code = int(parts[2]), parts[3]
                index = int(parts[5][1:-1]) if len(parts) > 6 and ":" not in parts[5] else None
                fields.setdefault(name, []).append((code, index, width))
            elif parts[0] == "$enddefinitions":
                break
        records = iter(csv.DictReader(record))

        def value(name):
            refs = fields[TOP + name]
            result = 0
            for code, bit, width in refs:
                number = codes.get(code)
                if number is None:
                    return None
                result |= number << bit if bit is not None else number
            return result

        def tick(ps, changes):
            for side in ("a", "b"):
                code = fields[TOP + "clk_" + side][0][0]
                if codes.get(code) != 0 or changes.get(code) != 1:
                    continue
                if side in previous_edge and ps - previous_edge[side] != periods[side]:
                    raise ValueError(f"Clock {side} period differs from real VCD edges")
                previous_edge[side] = ps
                first_edge.setdefault(side, ps)
                clocks[side] += 1
                if value("rst_n") != 1:
                    continue
                transfers = [("AB", "W", "av", "at", "ad"), ("BA", "R", "ax", "ar", "aq")] if side == "a" else [
                    ("BA", "W", "bv", "bt", "bd"), ("AB", "R", "bx", "br", "bq")]
                for direction, event, valid, ready, data in transfers:
                    if value(valid) != 1 or value(ready) != 1:
                        continue
                    row = next(records, None)
                    expected = (ps, direction, event, value(data))
                    if row is None or (int(row["time_ps"]), row["direction"], row["event"], int(row["data"], 16)) != expected:
                        raise ValueError(f"CSV does not match VCD handshake {expected}; CSV={row}")
                    for name in ("wr_bin", "rd_bin", "wr_gray", "rd_gray"):
                        if int(row[name]) != value(f"dut/u_{direction.lower()}/{name}"):
                            raise ValueError(f"CSV {name} differs from pre-edge VCD signal")
                    counts[direction + "_" + event] += 1
            codes.update(changes)

        current_ps, pending = 0, {}
        for line in vcd:
            line = line.strip()
            if not line or line[0] == "$":
                continue
            if line[0] == "#":
                tick(current_ps, pending)
                current_ps, pending = int(line[1:]), {}
            elif line[0] in "01xzXZ":
                pending[line[1:]] = int(line[0]) if line[0] in "01" else None
            elif line[0] in "bB":
                bits, code = line[1:].split()
                pending[code] = None if any(c in bits.lower() for c in "xz") else int(bits, 2)
        tick(current_ps, pending)
        if next(records, None) is not None:
            raise ValueError("CSV contains an extra handshake that does not exist in VCD")
    if not counts or not all(edges > 10 for edges in clocks.values()):
        raise ValueError("Insufficient waveform evidence")
    return dict(passed=True, session=folder.name, counts=dict(counts),
                clock_period_ns={side: period / 1000 for side, period in periods.items()},
                first_rising_edge_ns={side: ps / 1000 for side, ps in first_edge.items()},
                rising_edges=clocks,
                sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (vcd_path, csv_path)},
                method="Reconstruct every W/R from pre-edge VCD valid/ready/data, then compare CSV data and pointers.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path, help="Stopped or flushed live session directory")
    args = parser.parse_args()
    result = verify(args.session)
    output = args.session / "wave_audit.json"
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
