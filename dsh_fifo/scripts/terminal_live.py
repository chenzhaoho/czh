"""Single-host live terminal backed by a persistent, real ModelSim RTL session.

The browser never transports words. Received messages are reconstructed only from
the testbench's successful RTL read handshakes, audited against write handshakes.
Uses Python's standard library; ModelSim must be installed separately.
"""
from __future__ import annotations

import argparse
from collections import deque
import csv
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import threading
import time
import urllib.parse
import zlib
import zipfile

from modelsim_tools import modelsim_bin

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["rtl/common/gray_codec.v", "rtl/common/sync_2ff.v", "rtl/common/sync_gray_bus.v",
           "rtl/common/rst_sync.v", "rtl/fifo/async_fifo.v", "rtl/ext/dual_fifo_link.v",
           "tb/tb_terminal_live.sv"]
FIELDS = ("tx_a tx_b rx_a rx_b atu btu aru bru af bf at bt av bv ax bx ar br "
          "pending_a pending_b stalls_a stalls_b errors "
          "ab_wr_bin ab_rd_bin ab_wr_gray ab_rd_gray "
          "ba_wr_bin ba_rd_bin ba_wr_gray ba_rd_gray "
          "ab_wr_gray_sync ab_rd_gray_sync ba_wr_gray_sync ba_rd_gray_sync "
          "ad bd aq bq clk_a clk_b").split()
MAGIC = 0xD5F1F00D
MAX_BYTES = 4096
HOST_CAPACITY = 16384
SETTLE_NS = 200  # Covers the two-stage CDC pipelines after the last handshake.
RUN_MODES = ("demand", "continuous", "manual")


class _ProcessTree:
    """Windows job owns only this session's processes, including ModelSim kernels."""

    def __init__(self):
        self.handle = None
        if os.name != "nt":
            return
        import ctypes
        from ctypes import wintypes

        size_t = ctypes.c_size_t

        class BasicLimits(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_longlong), ("job_time", ctypes.c_longlong),
                        ("flags", wintypes.DWORD), ("min_ws", size_t), ("max_ws", size_t),
                        ("active_limit", wintypes.DWORD), ("affinity", size_t),
                        ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in ("read_ops", "write_ops", "other_ops",
                                                              "read_bytes", "write_bytes", "other_bytes")]

        class ExtendedLimits(ctypes.Structure):
            _fields_ = [("basic", BasicLimits), ("io", IoCounters),
                        ("process_memory", size_t), ("job_memory", size_t),
                        ("peak_process_memory", size_t), ("peak_job_memory", size_t)]

        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self.kernel.CreateJobObjectW.restype = wintypes.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            self.close()
            raise ctypes.WinError(ctypes.get_last_error())

    def attach(self, process):
        if self.handle and not self.kernel.AssignProcessToJobObject(self.handle, int(process._handle)):
            import ctypes
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


class ModelSimSession:
    """Owns exactly one simulator process; command set is allowlisted in Tcl."""

    def __init__(self, gui=False):
        self.tools = modelsim_bin("vsim.exe", "vlib.exe", "vlog.exe")
        self.id = time.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3)
        self.folder = ROOT / "build/terminal_live/sessions" / self.id
        self.folder.mkdir(parents=True)
        self.process = None
        self.channel = None
        self.stream = None
        self.serial = 0
        self.replies = 0
        self.gui = gui
        self.last_command = ""
        self.last_response = ""
        self.last_reply_at = None
        self.last_roundtrip_ms = None
        self.state = {}
        self.hashes = {}
        self.compiled_hashes = {}
        self.transcript = None
        self.tree = _ProcessTree()
        try:
            copied = []
            for name in SOURCES:
                source = (ROOT / name).read_bytes()
                self.hashes[name] = hashlib.sha256(source).hexdigest()
                dest = self.folder / Path(name).name
                # This older ModelSim uses the Windows ANSI code page for comments.
                dest.write_bytes(source.decode("utf-8-sig").encode("gbk", errors="replace"))
                self.compiled_hashes[name] = hashlib.sha256(dest.read_bytes()).hexdigest()
                copied.append(str(dest))
            bridge = ROOT / "scripts/terminal_live_bridge.tcl"
            self.hashes[str(bridge.relative_to(ROOT))] = hashlib.sha256(bridge.read_bytes()).hexdigest()
            bridge_copy = self.folder / bridge.name
            bridge_copy.write_bytes(bridge.read_bytes())
            wave = ROOT / "scripts/wave_terminal_live.do"
            self.hashes[str(wave.relative_to(ROOT))] = hashlib.sha256(wave.read_bytes()).hexdigest()
            (self.folder / wave.name).write_bytes(wave.read_bytes())
            self.library = self.folder / "work"
            self._compile([str(self.tools / "vlib.exe"), str(self.library)], "vlib.log")
            self._compile([str(self.tools / "vlog.exe"), "-sv", "-work", str(self.library), *copied], "compile.log")
            self.transcript = (self.folder / "transcript.log").open("wb")
            self.command = [str(self.tools / "vsim.exe"), "-gui" if gui else "-c", "-quiet", "-voptargs=+acc",
                            "-l", str(self.folder / "modelsim_transcript.log"),
                            "-lib", str(self.library), "tb_terminal_live", "-do",
                            f"set live_gui {int(gui)}; do {{" + bridge_copy.as_posix() + "}"]
            self.process = subprocess.Popen(self.command, cwd=self.folder, stdout=self.transcript,
                                            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
            self.tree.attach(self.process)
            deadline = time.monotonic() + (45 if gui else 20)
            port_path = self.folder / "bridge.port"
            while not port_path.exists():
                if self.process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("ModelSim did not start: " + self._log_tail())
                time.sleep(.05)
            port = int(port_path.read_text().strip())
            self.channel = socket.create_connection(("127.0.0.1", port), timeout=5)
            self.stream = self.channel.makefile("rwb", buffering=0)
            self.request("STATUS")
        except Exception:
            self.close()
            raise

    def _compile(self, command, name):
        result = subprocess.run(command, cwd=self.folder, capture_output=True, timeout=90)
        output = (result.stdout + result.stderr).decode("gbk", errors="replace")
        (self.folder / name).write_text(output, encoding="utf-8")
        if result.returncode or "** Error" in output or "** Fatal" in output:
            raise RuntimeError(output)

    def _log_tail(self):
        path = self.folder / "transcript.log"
        return path.read_bytes()[-5000:].decode("gbk", errors="replace") if path.exists() else ""

    @staticmethod
    def _tail(path, encoding="gbk", limit=14000):
        if not path.exists():
            return dict(text="", bytes=0, path=str(path))
        with path.open("rb") as stream:
            size = stream.seek(0, 2)
            stream.seek(max(0, size - limit))
            data = stream.read(limit)
        if size > limit:
            data = data.partition(b"\n")[2]
        return dict(text=data.decode(encoding, errors="replace"), bytes=size, path=str(path))

    def runtime(self):
        """Read-only view: raw ModelSim files plus observed process/socket replies."""
        return dict(pid=self.process.pid, process_running=self.process.poll() is None,
                    exit_code=self.process.poll(), mode="gui" if self.gui else "console",
                    executable=str(self.tools / "vsim.exe"), command_line=subprocess.list2cmdline(self.command),
                    commands_sent=self.serial, replies_received=self.replies,
                    last_command=self.last_command, last_response=self.last_response,
                    last_roundtrip_ms=self.last_roundtrip_ms,
                    reply_age_ms=round((time.monotonic() - self.last_reply_at) * 1000) if self.last_reply_at else None,
                    transcript=self._tail(self.transcript_path),
                    commands=self._tail(self.folder / "simulator_commands.log", "ascii"),
                    compile=self._tail(self.folder / "compile.log", "utf-8"))

    @property
    def transcript_path(self):
        # Console Tcl stdout bypasses ModelSim's -l file; GUI routes it to -l.
        return self.folder / ("modelsim_transcript.log" if self.gui else "transcript.log")

    @property
    def alive(self):
        return self.process is not None and self.process.poll() is None and self.channel is not None

    def request(self, operation):
        if not self.alive:
            raise RuntimeError("ModelSim is offline")
        self.serial += 1
        self.last_command = f"{self.serial} {operation}"
        started = time.monotonic()
        self.stream.write(f"{self.serial} {operation}\n".encode("ascii"))
        self.last_response = self.stream.readline().decode("ascii").strip()
        response = self.last_response.split()
        if len(response) < 3 or response[0] != "OK" or response[1] != str(self.serial):
            raise RuntimeError("ModelSim bridge rejected command: " + " ".join(response))
        if operation != "QUIT":
            if len(response[3:]) != len(FIELDS):
                raise RuntimeError("Invalid simulator state: " + " ".join(response))
            self.state = dict(zip(FIELDS, map(int, response[3:])))
            self.state["time"] = response[2]
        self.replies += 1
        self.last_reply_at = time.monotonic()
        self.last_roundtrip_ms = round((self.last_reply_at - started) * 1000, 2)
        return dict(self.state)

    def load(self, side, words):
        if side not in ("a", "b") or not 1 <= len(words) <= 4096:
            raise ValueError("Invalid load")
        (self.folder / f"input_{side}.hex").write_text("".join(f"{w:08x}\n" for w in words), encoding="ascii")
        return self.request(f"LOAD {side} {len(words)}")

    def close(self):
        if self.alive:
            try:
                self.request("QUIT")
            except (OSError, RuntimeError):
                pass
        if self.stream:
            self.stream.close()
        if self.channel:
            self.channel.close()
            self.channel = None
        if self.process and self.process.poll() is None:
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)
        self.tree.close()
        if self.transcript:
            self.transcript.close()


class LiveTerminal:
    """Framing, RTL control and independent word/frame audit behind one interface."""

    def __init__(self, auto=None, gui=False, run_mode="demand"):
        self.lock = threading.RLock()
        self.sim = None
        self.set_run_mode(run_mode)
        if auto is not None:
            self.auto = auto  # Compatibility with existing explicit manual callers.
        self.gui = gui
        self.fault = ""
        self.stopped = False
        self.worker_stop = threading.Event()
        self.restart()

    def _new_ledger(self):
        self.epoch = getattr(self, "epoch", 0) + 1
        self.next_id = 1
        self.receiving = {"a": True, "b": True}
        self.sent = []
        self.delivered = []
        self.by_id = {}
        self.expected = {d: deque() for d in ("AB", "BA")}
        self.in_fifo = {d: deque() for d in ("AB", "BA")}
        self.frame_words = {d: [] for d in ("AB", "BA")}
        self.counts = {d: {"W": 0, "R": 0} for d in ("AB", "BA")}
        self.recent_events = deque(maxlen=80)
        self.challenges = []
        self.last_time_ps = 0
        self._settle_until_ps = 0
        self.fault = ""

    @property
    def auto(self):
        return self.run_mode != "manual"

    @auto.setter
    def auto(self, enabled):
        if not isinstance(enabled, bool):
            raise ValueError("自动推进设置无效。")
        self.set_run_mode("continuous" if enabled else "manual")

    def set_run_mode(self, mode):
        with self.lock:
            if mode not in RUN_MODES:
                raise ValueError("推进模式应为 demand、continuous 或 manual。")
            self.run_mode = mode

    def _schedule(self):
        """Decide from audited pending words and receiver enables, without running RTL."""
        if not self.online:
            return dict(state="offline", will_step=False, reason="仿真器离线或校验异常")
        if self.run_mode == "manual":
            return dict(state="manual", will_step=False, reason="等待点击“推进 200 ns”")
        if self.run_mode == "continuous":
            return dict(state="continuous", will_step=True, reason="连续推进时钟，包括空闲和堵塞阶段")
        blocked = []
        for direction, target in (("AB", "b"), ("BA", "a")):
            pending, buffered = len(self.expected[direction]), len(self.in_fifo[direction])
            if (self.receiving[target] and (pending or buffered)) or (pending and buffered < 256):
                return dict(state="transferring", will_step=True, reason="仍有可执行的 FIFO 读写")
            if pending or buffered:
                blocked.append(target.upper())
        # Do not freeze valid/ready or synchronized pointers in their trailing pipeline.
        if self._time_ps() < self._settle_until_ps:
            return dict(state="settling", will_step=True, reason="等待末笔握手后的 CDC 同步稳定")
        if blocked:
            return dict(state="blocked", will_step=False,
                        reason="等待 " + " / ".join(blocked) + " 端恢复接收；反向发送仍可唤醒仿真")
        return dict(state="idle", will_step=False, reason="暂无待传数据，等待发送或接收控制")

    def _settle_control(self):
        self._settle_until_ps = max(self._settle_until_ps, self._time_ps() + SETTLE_NS * 1000)

    def restart(self, gui=None):
        with self.lock:
            if gui is not None:
                if not isinstance(gui, bool):
                    raise ValueError("窗口模式设置无效。")
                self.gui = gui
            if self.sim:
                self.sim.close()
            if getattr(self, "event_stream", None):
                self.event_stream.close()
            self.sim = ModelSimSession(gui=self.gui)
            self.epoch_history = []
            self.event_stream = (self.sim.folder / "handshakes.csv").open("r", encoding="ascii")
            self.event_stream.readline()  # header; never truncate the original event file
            self._new_ledger()
            self.stopped = False
            self._audit_snapshot()

    @property
    def online(self):
        return bool(self.sim and self.sim.alive and not self.stopped and not self.fault)

    def _require_online(self):
        if not self.online:
            raise ValueError(self.fault or "ModelSim 已停止；请先重启仿真器。")

    @staticmethod
    def frame(message_id, text):
        payload = text.encode("utf-8")
        if not payload or len(payload) > MAX_BYTES:
            raise ValueError("每条消息需要 1～4096 个 UTF-8 字节。")
        crc = zlib.crc32(payload)
        padded = payload + b"\0" * (-len(payload) % 4)
        return [MAGIC, message_id, len(payload), crc, *struct.unpack(f"<{len(padded)//4}I", padded)], crc

    def send(self, side, text, challenge=None):
        with self.lock:
            self._require_online()
            if side not in ("a", "b") or not isinstance(text, str):
                raise ValueError("发送端或文本无效。")
            if len(self.sent) >= 4000:
                raise ValueError("本轮已达到 4000 条消息，请复位后继续。")
            direction = "AB" if side == "a" else "BA"
            message_id = self.next_id
            words, crc = self.frame(message_id, text)
            if self.sim.state[f"pending_{side}"] + len(words) > HOST_CAPACITY:
                raise ValueError("主机待发队列已满，请恢复接收后继续。")
            message = dict(id=message_id, source=side, target="b" if side == "a" else "a",
                           text=text, bytes=len(text.encode("utf-8")), words=len(words),
                           crc32=f"{crc:08X}", sent_ps=self._time_ps(), status="queued", challenge=challenge)
            self.next_id += 1
            self.sent.append(message)
            self.by_id[message_id] = message
            self.expected[direction].extend(words)
            try:
                self.sim.load(side, words)
                self._audit_snapshot()
                self._settle_control()
            except Exception as exc:
                self.fault = f"传输已中止：{exc}"
                raise
            return dict(message)

    def burst(self, side, count=40):
        if side not in ("a", "b") or type(count) is not int or not 1 <= count <= 80:
            raise ValueError("突发数量应为 1～80。")
        with self.lock:
            self._require_online()
            # Each message exceeds 16 words, so this visibly fills a 256-word FIFO.
            texts = [f"突发消息 {n+1:02d}/{count:02d} · {side.upper()}端 · "
                     f"{secrets.token_hex(12)} · 经过真实RTL接收后显示" for n in range(count)]
            required = sum(len(self.frame(self.next_id + n, t)[0]) for n, t in enumerate(texts))
            if self.sim.state[f"pending_{side}"] + required > HOST_CAPACITY or len(self.sent) + count > 4000:
                raise ValueError("待发容量不足，请先恢复接收或复位。")
            return [self.send(side, text) for text in texts]

    def challenge(self):
        with self.lock:
            self._require_online()
            if len(self.sent) > 3998 or any(self.sim.state["pending_" + side] > HOST_CAPACITY - 40 for side in ("a", "b")):
                raise ValueError("双向挑战需要两端均有待发空间，请先恢复接收。")
            token = secrets.token_hex(12).upper()
            pair = [self.send("a", f"随机挑战 A→B / {token}", token)["id"],
                    self.send("b", f"随机挑战 B→A / {token}", token)["id"]]
            record = dict(token=token, ids=pair)
            self.challenges.append(record)
            return record

    def receive(self, side, enabled):
        with self.lock:
            self._require_online()
            if side not in ("a", "b") or not isinstance(enabled, bool):
                raise ValueError("接收设置无效。")
            self.sim.request(f"RECEIVE {side} {int(enabled)}")
            self.receiving[side] = enabled
            self._audit_snapshot()
            self._settle_control()

    def step(self, ns=200):
        with self.lock:
            self._require_online()
            if type(ns) is not int or not 1 <= ns <= 100000:
                raise ValueError("单次推进范围为 1～100000 ns。")
            self.sim.request(f"STEP {ns}")
            self._audit_snapshot()

    def reset(self):
        with self.lock:
            self._require_online()
            self.epoch_history.append(dict(epoch=self.epoch, end_ps=self._time_ps(), counts=self.counts,
                                           sent=len(self.sent), received=len(self.delivered),
                                           discarded_ids=[m["id"] for m in self.sent if m["status"] == "queued"]))
            # Keep the original CSV and VCD, with per-reset audit offsets.
            self.sim.request("RESET")
            self.event_stream.seek(0, 2)
            self._new_ledger()
            self._audit_snapshot()

    def stop(self):
        with self.lock:
            if self.sim and self.sim.alive:
                try:
                    self.sim.request("FLUSH")
                    self._audit_snapshot()
                finally:
                    self.sim.close()
            self.stopped = True

    def close(self):
        self.worker_stop.set()
        self.stop()
        if getattr(self, "event_stream", None):
            self.event_stream.close()

    def _time_ps(self):
        # ModelSim's $now is an integer in the elaborated 1ps simulation resolution.
        return int(self.sim.state["time"])

    def _audit_snapshot(self):
        try:
            for line in self.event_stream:
                values = next(csv.reader([line]))
                if len(values) != 8:
                    raise RuntimeError("Incomplete handshake record")
                ps, direction, kind, raw, wb, rb, wg, rg = values
                event = dict(time_ps=int(ps), direction=direction, event=kind, data=raw.upper(),
                             wr_bin=int(wb), rd_bin=int(rb), wr_gray=int(wg), rd_gray=int(rg))
                self._audit_event(event)
                self.recent_events.append(event)
            for direction, tx, rx in (("AB", "tx_a", "rx_b"), ("BA", "tx_b", "rx_a")):
                c = self.counts[direction]
                s = self.sim.state
                prefix = direction.lower()
                if (c["W"], c["R"]) != (s[tx], s[rx]):
                    raise RuntimeError(f"{direction} RTL/event counters disagree")
                if not 0 <= c["W"] - c["R"] <= 256:
                    raise RuntimeError(f"{direction} occupancy out of range")
                for event_type, pointer in (("W", "wr"), ("R", "rd")):
                    value = s[f"{prefix}_{pointer}_bin"]
                    if value != c[event_type] % 512 or s[f"{prefix}_{pointer}_gray"] != value ^ (value >> 1):
                        raise RuntimeError(f"{direction} snapshot pointer mismatch")
            if self.sim.state["errors"]:
                raise RuntimeError("RTL valid/data hold assertion failed")
            self.last_time_ps = self._time_ps()
        except Exception as exc:
            self.fault = f"校验失败，已停止推进仿真：{exc}"
            raise

    def _audit_event(self, e):
        d, kind = e["direction"], e["event"]
        if d not in self.counts or kind not in ("W", "R"):
            raise RuntimeError("Unknown handshake")
        c = self.counts[d]
        if e["time_ps"] < self.last_time_ps:
            raise RuntimeError("Handshake time went backwards")
        self.last_time_ps = e["time_ps"]
        if e["wr_bin"] != c["W"] % 512 or e["rd_bin"] != c["R"] % 512:
            raise RuntimeError(f"{d} pointer did not advance with handshakes")
        if e["wr_gray"] != e["wr_bin"] ^ (e["wr_bin"] >> 1) or e["rd_gray"] != e["rd_bin"] ^ (e["rd_bin"] >> 1):
            raise RuntimeError(f"{d} invalid Gray encoding")
        word = int(e["data"], 16)
        if kind == "W":
            if not self.expected[d] or self.expected[d].popleft() != word:
                raise RuntimeError(f"{d} unexpected RTL write word")
            self.in_fifo[d].append(word)
        else:
            if not self.in_fifo[d] or self.in_fifo[d].popleft() != word:
                raise RuntimeError(f"{d} RTL read differs from FIFO write order")
            self.frame_words[d].append(word)
            self._decode_frame(d, e["time_ps"])
        c[kind] += 1
        self._settle_until_ps = max(self._settle_until_ps, e["time_ps"] + SETTLE_NS * 1000)

    def _decode_frame(self, direction, time_ps):
        words = self.frame_words[direction]
        if len(words) < 4:
            return
        magic, mid, length, crc = words[:4]
        if magic != MAGIC or not 1 <= length <= MAX_BYTES:
            raise RuntimeError("Invalid received frame header")
        count = 4 + (length + 3) // 4
        if len(words) < count:
            return
        payload = struct.pack(f"<{count-4}I", *words[4:count])[:length]
        if zlib.crc32(payload) != crc:
            raise RuntimeError("Received CRC32 mismatch")
        text = payload.decode("utf-8", errors="strict")
        original = self.by_id.get(mid)
        source = "a" if direction == "AB" else "b"
        if not original or original["source"] != source or original["status"] != "queued" or original["text"] != text:
            raise RuntimeError("Received frame missing, duplicated or corrupted")
        # Crucially, inbox text comes from RTL read words, never from original['text'].
        self.delivered.append(dict(id=mid, source=source, target=original["target"], text=text,
                                   bytes=length, crc32=f"{crc:08X}", received_ps=time_ps,
                                   verified=True, challenge=original["challenge"]))
        original["status"] = "received"
        original["received_ps"] = time_ps
        del words[:count]

    def snapshot(self):
        with self.lock:
            sim = self.sim
            if not sim.alive and not self.stopped and not self.fault:
                self.fault = "ModelSim 进程已退出，收件与指针停止更新。"
            challenges = [dict(c, passed=all(self.by_id[i]["status"] == "received" for i in c["ids"]))
                          for c in self.challenges[-8:]]
            return dict(online=self.online, fault=self.fault, stopped=self.stopped, auto=self.auto,
                        run_mode=self.run_mode, advancement=self._schedule(),
                        session=sim.id, epoch=self.epoch, pid=sim.process.pid, engine="ModelSim",
                        folder=str(sim.folder), clock_a_ns=10, clock_b_ns=14, phase_b_ns=1.701,
                        sync_stages=2, depth_words=256, time_ps=self._time_ps(), receiving=dict(self.receiving),
                        signals=dict(sim.state), sent=self.sent[-160:], delivered=self.delivered[-160:],
                        totals=dict(sent=len(self.sent), received=len(self.delivered),
                                    read_words=sum(c["R"] for c in self.counts.values()),
                                    handshakes=sum(sum(c.values()) for c in self.counts.values())),
                        counts=self.counts, events=list(self.recent_events)[-24:], challenges=challenges,
                        source_hashes=sim.hashes)

    def evidence(self):
        with self.lock:
            self.flush()
            return dict(self.snapshot(), sent=self.sent, delivered=self.delivered,
                        epoch_history=self.epoch_history, compiled_copy_hashes=self.sim.compiled_hashes,
                        frame_format="magic32, id32, utf8_bytes32, crc32, payload_le32",
                        source_files=SOURCES, simulator_command=self.sim.command, runtime=self.sim.runtime(),
                        note="Receiver text is decoded exclusively from successful RTL read handshakes. "
                             "CSV/VCD include all epochs; state counters refer to current epoch.")

    def bundle(self):
        """Capture evidence and waveform at the same locked simulation instant."""
        with self.lock:
            report = self.evidence()
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("evidence.json", json.dumps(report, ensure_ascii=False, indent=2))
                for name in ("handshakes.csv", "terminal_live.vcd", "transcript.log", "compile.log",
                             "modelsim_transcript.log", "simulator_commands.log"):
                    archive.write(self.sim.folder / name, name)
                for name in SOURCES + ["scripts/terminal_live_bridge.tcl", "scripts/wave_terminal_live.do"]:
                    copy = self.sim.folder / Path(name).name
                    archive.write(copy, "compiled_sources/" + copy.name)
            return buffer.getvalue()

    def runtime(self):
        with self.lock:
            return dict(self.sim.runtime(), session=self.sim.id, online=self.online, auto=self.auto,
                        run_mode=self.run_mode, advancement=self._schedule(),
                        time_ps=self._time_ps(), fault=self.fault, stopped=self.stopped)

    def flush(self):
        with self.lock:
            if self.online:
                self.sim.request("FLUSH")
                self._audit_snapshot()

    def run_worker(self):
        while not self.worker_stop.wait(.15):
            with self.lock:
                if self._schedule()["will_step"]:
                    try:
                        self.step(200)
                    except Exception as exc:
                        self.fault = f"仿真连接中断：{exc}"


def serve(terminal, port):
    token = secrets.token_urlsafe(24)
    origin = f"http://127.0.0.1:{port}"
    page_path = ROOT / "doc/terminal_live/index.html"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            if args and str(args[0]).startswith("POST"):
                print(fmt % args, flush=True)

        def respond(self, status, body, content_type="application/json; charset=utf-8", filename=None):
            if isinstance(body, (dict, list)):
                body = json.dumps(body, ensure_ascii=False).encode("utf-8")
            elif isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                             "style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
            if filename:
                self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.end_headers()
            self.wfile.write(body)

        def valid_host(self):
            return self.headers.get("Host") == f"127.0.0.1:{port}"

        def do_GET(self):
            if not self.valid_host():
                self.respond(403, {"error": "Loopback host required"})
                return
            path = urllib.parse.urlsplit(self.path).path
            try:
                if path == "/":
                    self.respond(200, page_path.read_text(encoding="utf-8").replace("__SESSION_TOKEN__", token),
                                 "text/html; charset=utf-8")
                elif path == "/api/state":
                    self.respond(200, terminal.snapshot())
                elif path == "/api/runtime":
                    self.respond(200, terminal.runtime())
                elif path == "/api/evidence.json":
                    self.respond(200, terminal.evidence(), filename="terminal_evidence.json")
                elif path == "/api/bundle.zip":
                    self.respond(200, terminal.bundle(), "application/zip", "terminal_evidence_bundle.zip")
                elif path in ("/api/events.csv", "/api/wave.vcd", "/api/transcript.txt", "/api/commands.txt"):
                    with terminal.lock:
                        terminal.flush()
                        name = {"/api/events.csv": "handshakes.csv", "/api/wave.vcd": "terminal_live.vcd",
                                "/api/transcript.txt": terminal.sim.transcript_path.name,
                                "/api/commands.txt": "simulator_commands.log"}[path]
                        self.respond(200, (terminal.sim.folder / name).read_bytes(), "application/octet-stream", name)
                else:
                    self.respond(404, {"error": "Not found"})
            except (OSError, RuntimeError, ValueError) as exc:
                self.respond(500, {"error": str(exc)})

        def do_POST(self):
            if (not self.valid_host() or self.headers.get("X-Terminal-Token") != token
                    or self.headers.get("Origin") not in (None, origin)):
                self.respond(403, {"error": "Local page token required"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 32768:
                    raise ValueError("请求长度无效。")
                data = json.loads(self.rfile.read(length))
                if not isinstance(data, dict):
                    raise ValueError("请求格式无效。")
                path = self.path
                with terminal.lock:
                    if path == "/api/send":
                        terminal.send(data.get("side"), data.get("text"))
                    elif path == "/api/receive":
                        terminal.receive(data.get("side"), data.get("enabled"))
                    elif path == "/api/burst":
                        terminal.burst(data.get("side"), data.get("count", 40))
                    elif path == "/api/challenge":
                        terminal.challenge()
                    elif path == "/api/step":
                        terminal.step(data.get("ns", 200))
                    elif path == "/api/auto":
                        if not isinstance(data.get("enabled"), bool):
                            raise ValueError("自动推进设置无效。")
                        terminal.auto = data["enabled"]
                    elif path == "/api/run-mode":
                        terminal.set_run_mode(data.get("mode"))
                    elif path == "/api/reset":
                        terminal.reset()
                    elif path == "/api/stop":
                        terminal.stop()
                    elif path == "/api/restart":
                        if "gui" in data and not isinstance(data["gui"], bool):
                            raise ValueError("窗口模式设置无效。")
                        terminal.restart(gui=data.get("gui"))
                    else:
                        self.respond(404, {"error": "Not found"})
                        return
                    self.respond(200, terminal.snapshot())
            except (KeyError, ValueError, OSError, RuntimeError) as exc:
                self.respond(400, {"error": str(exc)})

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=terminal.run_worker, daemon=True).start()
    print(f"LIVE_TERMINAL_READY {origin}/ | ModelSim PID={terminal.sim.process.pid} | session={terminal.sim.id}", flush=True)
    print(f"Evidence: {terminal.sim.folder}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true", help="Check the persistent simulator bridge")
    parser.add_argument("--port", type=int, default=8765)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--manual", action="store_true", help="Advance simulation only when requested")
    modes.add_argument("--continuous", action="store_true", help="Keep advancing idle clocks; default is on-demand")
    parser.add_argument("--gui", action="store_true", help="Show the same live simulation in native ModelSim Transcript/Wave windows")
    args = parser.parse_args()
    try:
        modelsim_bin("vsim.exe", "vlib.exe", "vlog.exe")
    except FileNotFoundError as exc:
        parser.exit(2, f"{exc}\n")
    if args.smoke:
        sim = ModelSimSession(gui=args.gui)
        try:
            print("START", sim.id, sim.process.pid, sim.state, flush=True)
            print("LOAD", sim.load("a", [0xD5F1F00D, 0x12345678]), flush=True)
            print("STEP", sim.request("STEP 300"), flush=True)
            print((sim.folder / "handshakes.csv").read_text(), flush=True)
        finally:
            sim.close()
    else:
        run_mode = "manual" if args.manual else "continuous" if args.continuous else "demand"
        terminal = LiveTerminal(run_mode=run_mode, gui=args.gui)
        try:
            serve(terminal, args.port)
        finally:
            terminal.close()


if __name__ == "__main__":
    main()
