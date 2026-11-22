"""Exercise run modes through the live terminal interface and a real ModelSim DUT."""
import json
from pathlib import Path
import threading
import time

from terminal_live import LiveTerminal
from verify_terminal_wave import verify


def check(condition, label):
    if not condition:
        raise AssertionError(label)
    print("PASS: " + label, flush=True)


def wait_for(terminal, predicate, label, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = terminal.snapshot()
        if state["fault"]:
            raise AssertionError(state["fault"])
        if predicate(state):
            check(True, label)
            return state
        time.sleep(.04)
    state = terminal.snapshot()
    raise AssertionError(f"Timeout: {label}; {state['advancement']}; {state['counts']}")


def frozen(terminal, label):
    before = terminal.runtime()
    time.sleep(.6)  # Four worker intervals; both observations are read-only.
    terminal.snapshot()
    after = terminal.runtime()
    fields = ("time_ps", "commands_sent", "replies_received")
    check(all(before[k] == after[k] for k in fields)
          and before["commands"]["bytes"] == after["commands"]["bytes"]
          and before["transcript"]["bytes"] == after["transcript"]["bytes"], label)


def main():
    terminal = LiveTerminal()
    worker = threading.Thread(target=terminal.run_worker, daemon=True)
    worker.start()
    result = {"session": terminal.snapshot()["session"]}
    try:
        check(terminal.snapshot()["run_mode"] == "demand", "default mode is on-demand")
        frozen(terminal, "idle session advances neither time nor actual logs")
        text = "按需唤醒 / Unicode 🧪"
        terminal.send("a", text)
        state = wait_for(terminal, lambda s: s["advancement"]["state"] == "idle"
                         and s["totals"]["received"] == 1, "send wakes the DUT and automatically returns to idle")
        check(state["delivered"][0]["text"] == text and state["delivered"][0]["verified"],
              "on-demand delivery still comes from CRC-checked RTL reads")
        check(state["signals"]["ab_wr_gray_sync"] == state["signals"]["ab_wr_gray"]
              and state["signals"]["ab_rd_gray_sync"] == state["signals"]["ab_rd_gray"],
              "CDC pointers finish synchronizing before idle pause")
        frozen(terminal, "completed traffic stops clocks and both log files")

        terminal.receive("b", False)
        terminal.burst("a", 40)
        blocked = wait_for(terminal, lambda s: s["advancement"]["state"] == "blocked"
                           and s["signals"]["af"] == 1, "full A-to-B pauses with host words still pending")
        check(blocked["signals"]["pending_a"] > 0 and blocked["signals"]["rx_b"] == state["signals"]["rx_b"],
              "blocked receiver gets no fabricated delivery")
        frozen(terminal, "backpressure stops automatic STEP and Transcript growth")
        reverse = terminal.send("b", "A→B 堵塞时的独立反向唤醒")
        wait_for(terminal, lambda s: s["advancement"]["state"] == "blocked"
                 and any(m["id"] == reverse["id"] for m in s["delivered"]),
                 "reverse direction wakes and delivers despite the other full FIFO")

        terminal.receive("a", False)
        terminal.burst("b", 40)
        wait_for(terminal, lambda s: s["advancement"]["state"] == "blocked"
                 and s["signals"]["af"] == s["signals"]["bf"] == 1,
                 "both directions can reach a quiescent full state")
        frozen(terminal, "simultaneous full FIFOs do not cause endless background steps")
        terminal.receive("a", True)
        wait_for(terminal, lambda s: s["advancement"]["state"] == "blocked"
                 and s["signals"]["af"] == 1 and s["counts"]["BA"]["W"] == s["counts"]["BA"]["R"],
                 "resuming A drains B-to-A without waking blocked A-to-B forever")
        terminal.receive("b", True)
        drained = wait_for(terminal, lambda s: s["advancement"]["state"] == "idle"
                           and s["totals"]["received"] == s["totals"]["sent"],
                           "resuming B drains all remaining frames then pauses")
        check(drained["signals"]["errors"] == 0, "no RTL hold, pointer or word-order failures")
        frozen(terminal, "fully drained bidirectional session is quiet")

        terminal.reset()
        terminal.receive("b", False)
        terminal.send("a", "small paused frame")
        partial = wait_for(terminal, lambda s: s["advancement"]["state"] == "blocked",
                           "paused receiver also stops below FIFO capacity")
        check(partial["signals"]["af"] == 0 and partial["counts"]["AB"]["W"] > 0,
              "pause decision does not require full=1")
        frozen(terminal, "small blocked frame has no useless idle clock loop")
        terminal.receive("b", True)
        wait_for(terminal, lambda s: s["advancement"]["state"] == "idle"
                 and s["totals"]["received"] == 1, "small paused frame resumes correctly")

        terminal.set_run_mode("manual")
        terminal.send("a", "M" * 300)
        frozen(terminal, "manual mode does not automatically run queued traffic")
        before = terminal.snapshot()["time_ps"]
        terminal.step(200)
        check(terminal.snapshot()["time_ps"] == before + 200000, "manual single step advances exactly 200 ns")
        frozen(terminal, "manual single step does not restart an automatic loop")
        terminal.step(5000)
        check(terminal.snapshot()["totals"]["received"] == 2, "manual run still transports the actual frame")
        terminal.set_run_mode("continuous")
        before = terminal.runtime()
        wait_for(terminal, lambda s: s["time_ps"] > before["time_ps"], "continuous mode still runs empty clocks")
        terminal.set_run_mode("demand")
        wait_for(terminal, lambda s: s["advancement"]["state"] == "idle", "switching back to demand stops idle clocks")
        frozen(terminal, "demand mode remains quiet after continuous mode")
        try:
            terminal.set_run_mode("invalid")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid mode accepted")
        check(terminal.snapshot()["run_mode"] == "demand" and terminal.online,
              "invalid mode leaves the existing session intact")
        terminal.reset()
        frozen(terminal, "reset clears pending wakeups and does not start an idle loop")
        terminal.stop()
        result["wave_audit"] = verify(terminal.sim.folder)
        check(result["wave_audit"]["passed"], "all demand/manual/continuous handshakes independently match VCD")
        previous = terminal.snapshot()["session"]
        terminal.restart()
        check(terminal.snapshot()["session"] != previous and terminal.snapshot()["run_mode"] == "demand",
              "restart preserves the selected mode but not old pending work")
        frozen(terminal, "restarted demand session stays idle")
        result["passed"] = True
    finally:
        terminal.close()
        worker.join(timeout=3)
    output = Path(__file__).resolve().parents[1] / "build/terminal_live/scheduling_results.json"
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print("RESULT: PASS | " + str(output), flush=True)


if __name__ == "__main__":
    main()
