"""Integration checks against a real ModelSim process, not a fake FIFO adapter."""
import json
from pathlib import Path
import time
import tempfile

from terminal_live import LiveTerminal
from verify_terminal_wave import verify


def check(condition, label):
    if not condition:
        raise AssertionError(label)
    print("PASS: " + label, flush=True)


def main():
    terminal = LiveTerminal(auto=False)
    result = {"session": terminal.sim.id, "checks": []}
    try:
        text_a = "随机中文 / 换行\nemoji 🧪🚀 / <script>no animation</script>"
        text_b = "B to A: independently clocked return path / " + str(time.time_ns())
        terminal.send("a", text_a)
        terminal.send("b", text_b)
        terminal.step(5000)
        runtime = terminal.runtime()
        check(runtime["process_running"] and runtime["replies_received"] == runtime["commands_sent"]
              and "ACK" in runtime["commands"]["text"] and "LOAD a" in runtime["commands"]["text"]
              and "STEP 5000" in runtime["commands"]["text"] and "LIVE READY" in runtime["transcript"]["text"],
              "runtime display reads actual ModelSim commands, replies and Transcript")
        serial = terminal.sim.serial
        terminal.runtime()
        check(terminal.sim.serial == serial, "runtime polling is read-only and does not advance simulation")
        try:
            terminal.restart(gui="yes")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid GUI mode accepted")
        check(terminal.online and terminal.sim.id == result["session"], "invalid window mode cannot interrupt the live session")
        check([m["text"] for m in terminal.delivered if m["target"] == "b"] == [text_a], "Unicode A-to-B through RTL")
        check([m["text"] for m in terminal.delivered if m["target"] == "a"] == [text_b], "independent B-to-A through RTL")

        terminal.receive("b", False)
        before_b = terminal.sim.state["rx_b"]
        terminal.burst("a", 40)
        terminal.step(20000)
        blocked = terminal.snapshot()
        check(blocked["signals"]["af"] == 1 and blocked["signals"]["atu"] == 256
              and blocked["signals"]["at"] == 0 and blocked["signals"]["pending_a"] > 0,
              "A-to-B full at 256 words with host backpressure")
        check(blocked["signals"]["rx_b"] == before_b and blocked["signals"]["stalls_a"] > 0,
              "paused B does not receive or advance read pointer")
        reverse = terminal.send("b", "Reverse path must survive a full A-to-B FIFO.")
        terminal.step(3000)
        check(terminal.by_id[reverse["id"]]["status"] == "received" and terminal.sim.state["af"] == 1,
              "B-to-A delivers while A-to-B remains full")
        challenge = terminal.challenge()
        terminal.step(5000)
        check(not terminal.snapshot()["challenges"][-1]["passed"], "challenge cannot pass on a timer while B paused")
        terminal.receive("b", True)
        terminal.step(50000)
        drained = terminal.snapshot()
        check(drained["challenges"][-1]["passed"], "challenge passes only after both RTL receivers decode it")
        check(drained["totals"]["sent"] == drained["totals"]["received"] and drained["signals"]["atu"] == 0,
              "all queued frames drain in order with exact CRC and content")
        check(drained["counts"]["AB"]["W"] > 512 and not drained["fault"], "binary/Gray pointer wrap audited past 512 writes")

        terminal.receive("a", False)
        terminal.receive("b", False)
        terminal.burst("a", 40)
        terminal.burst("b", 40)
        terminal.step(30000)
        check(terminal.sim.state["af"] == terminal.sim.state["bf"] == 1, "both physical RTL FIFOs fill independently")
        terminal.receive("a", True)
        terminal.step(50000)
        check(terminal.sim.state["af"] == 1 and terminal.sim.state["btu"] == 0,
              "releasing A drains only B-to-A")
        terminal.receive("b", True)
        terminal.step(50000)
        check(len(terminal.sent) == len(terminal.delivered), "both directions drain with zero lost or duplicate frames")

        long_text = "汉" * 1364 + "ABCD"  # exactly 4096 UTF-8 bytes
        terminal.send("a", long_text)
        terminal.step(50000)
        check(terminal.delivered[-1]["text"] == long_text, "maximum 4096-byte frame traverses many FIFO wraps")
        try:
            terminal.send("a", long_text + "E")
        except ValueError:
            pass
        else:
            raise AssertionError("oversize input accepted")
        check(not terminal.fault and terminal.sim.state["errors"] == 0, "source/read valid-data hold assertions remain clean")
        result["before_reset"] = terminal.evidence()

        terminal.receive("b", False)
        terminal.send("a", "Discard pending frame on explicit reset")
        terminal.reset()
        check(terminal.sim.state["tx_a"] == terminal.sim.state["rx_b"] == 0 and not terminal.sent,
              "reset discards pending frame and starts a fresh audited epoch")
        terminal.send("a", "After reset / 复位后")
        terminal.step(3000)
        check(len(terminal.delivered) == 1, "new traffic works after reset")
        terminal.stop()
        stopped_runtime = terminal.runtime()
        check(not stopped_runtime["process_running"] and "QUIT" in stopped_runtime["commands"]["text"]
              and stopped_runtime["last_response"].endswith("goodbye"), "runtime reflects real process exit and final QUIT acknowledgement")
        result["wave_audit"] = verify(terminal.sim.folder)
        check(result["wave_audit"]["passed"], "independent VCD edges match every CSV handshake, data and pointer")
        with tempfile.TemporaryDirectory(prefix="terminal_wave_negative_") as negative:
            # A deliberately falsified CSV must fail the independent waveform audit.
            fixture = Path(negative)
            original_csv = (terminal.sim.folder / "handshakes.csv").read_text(encoding="ascii")
            first_row = original_csv.splitlines()[1].split(",")
            first_row[3] = "00000000"
            bad_csv = original_csv.splitlines()
            bad_csv[1] = ",".join(first_row)
            (fixture / "handshakes.csv").write_text("\n".join(bad_csv) + "\n", encoding="ascii")
            (fixture / "terminal_live.vcd").write_bytes((terminal.sim.folder / "terminal_live.vcd").read_bytes())
            try:
                verify(fixture)
            except ValueError:
                pass
            else:
                raise AssertionError("altered CSV was trusted")
        check(True, "independent audit rejects a deliberately falsified data word")
        stopped = terminal.snapshot()
        size = (terminal.sim.folder / "handshakes.csv").stat().st_size
        for operation in (lambda: terminal.send("a", "must not arrive"), lambda: terminal.step(200)):
            try:
                operation()
            except ValueError:
                pass
            else:
                raise AssertionError("operation succeeded after simulator stopped")
        check(not stopped["online"] and len(terminal.delivered) == 1
              and size == (terminal.sim.folder / "handshakes.csv").stat().st_size,
              "stopped simulator cannot fabricate new delivery or handshake")
        previous = terminal.sim.id
        terminal.restart()
        result["restart_pid"] = terminal.sim.process.pid
        check(terminal.sim.id != previous and terminal.online and not terminal.delivered, "restart creates a new simulator session")
        terminal.sim.process.terminate()  # only the process created by this test
        terminal.sim.process.wait(timeout=5)
        check(not terminal.snapshot()["online"], "external simulator exit is detected")
        result["passed"] = True
    finally:
        terminal.close()
    output = Path(__file__).resolve().parents[1] / "build/terminal_live/integration_results.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print("RESULT: PASS | " + str(output), flush=True)


if __name__ == "__main__":
    main()
