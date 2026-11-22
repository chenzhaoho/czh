# -*- coding: utf-8 -*-
"""变异测试 (mutation test): 故意向 RTL 注入已知缺陷, 验证验证平台确实能抓到。

这是判断"测试是否真的有效"的硬证据: 一个测试套件如果在注入 bug 后仍然全绿,
说明它没有真正检查任何东西。

用法:
    python scripts/mutation_test.py            # 跑全部 3 个变异
    python scripts/mutation_test.py --list     # 只列出变异清单

每个变异: 备份 -> 改一行 RTL -> 重新编译 -> 跑相关用例 -> 检查是否报错 -> 恢复原文件。
结果写入 sim/coverage/mutation_report.txt
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = str(Path(__file__).resolve().parents[1])
FIFO = os.path.join(ROOT, r"rtl\fifo\async_fifo.v")
FIFO_A = os.path.join(ROOT, r"rtl\fifo\fifo_a.v")

# (名称, 目标文件, 正确片段, 变异片段, 用于暴露该缺陷的用例, 说明)
MUTANTS = [
    (
        "M1_off_by_one_full",
        FIFO,
        "assign wr_full  = (wr_occupancy_r == DEPTH[AW:0]);",
        "assign wr_full  = (wr_occupancy_r == DEPTH[AW:0] - 1'b1);",
        "tc1",
        "满判据提前一个字成立 -> FIFO 只能存 255 字(经典格雷码比较缺陷)",
    ),
    (
        "M2_wrong_threshold",
        FIFO_A,
        ".ALMOST_FULL_TH  (224),   // 7/8 x 256",
        ".ALMOST_FULL_TH  (200),   // 变异: 阈值故意改错",
        "tc4",
        "almost_full 阈值从 224 改为 200 -> 阈值穿越行为错误",
    ),
    (
        "M3_no_hysteresis",
        FIFO_A,
        ".DEADBAND        (2),",
        ".DEADBAND        (0),",
        "tc4",
        "去掉回差(DEADBAND=0) -> 阈值附近抖动, 迟滞判据失效",
    ),
]


def run_case(mutation, test, seed=1, stages=2):
    """跑一个用例, 返回 (是否通过, 日志文本)。"""
    log_dir = Path(ROOT) / "sim/logs/mutation" / mutation
    env = dict(os.environ, DSH_FIFO_LOG_DIR=str(log_dir))
    p = subprocess.run(
        ["cmd", "/d", "/c", r"scripts\run_sim.cmd", test, str(seed), str(stages), "verify"],
        capture_output=True, text=True, errors="replace", cwd=ROOT, env=env,
    )
    log = log_dir / f"run_{test}_seed{seed}_{stages}stage.log"
    body = ""
    if os.path.exists(log):
        body = open(log, encoding="utf-8", errors="replace").read()
    if p.returncode == 0 and "*** PASS ***" in p.stdout and "*** PASS ***" in body:
        return "pass", body
    if p.returncode == 1 and "*** FAIL ***" in p.stdout and "*** FAIL ***" in body and "[FAIL]" in body:
        return "caught", body
    return "error", p.stdout + p.stderr


def apply_mutation(path, old, new):
    txt = open(path, encoding="utf-8").read()
    if old not in txt:
        return False, "锚点未找到: " + old.strip()
    open(path, "w", encoding="utf-8", newline="\n").write(txt.replace(old, new, 1))
    return True, ""


def main():
    if "--list" in sys.argv:
        for name, path, old, new, test, desc in MUTANTS:
            print(f"{name}: [{os.path.basename(path)}] {desc}  (用例 {test})")
        return 0

    report = []
    all_caught = True

    for name, path, old, new, test, desc in MUTANTS:
        print(f"\n{'='*70}")
        print(f"变异 {name}")
        print(f"  说明: {desc}")
        print(f"  文件: {os.path.basename(path)}   用例: {test}")

        bak = path + ".mutbak"
        shutil.copyfile(path, bak)
        ok, msg = apply_mutation(path, old, new)
        if not ok:
            shutil.copyfile(bak, path)
            os.remove(bak)
            print("  跳过:", msg)
            report.append(f"{name}: SKIP ({msg})")
            all_caught = False
            continue

        try:
            outcome, body = run_case(name, test)
        finally:
            # 无论如何都恢复原文件
            shutil.copyfile(bak, path)
            os.remove(bak)

        if outcome == "pass":
            print("  结果: 未被捕获 (测试套件漏检!)")
            report.append(f"{name}: NOT CAUGHT  <-- 测试需要加强")
            all_caught = False
        elif outcome == "caught":
            fails = re.findall(r"# \[FAIL\][^\n]*", body)
            print(f"  结果: 已捕获, {len(fails)} 条失败检查")
            for f in fails[:3]:
                print("        " + f.replace("# [FAIL]", "").strip())
            report.append(f"{name}: CAUGHT ({len(fails)} failed checks)  [{desc}]")
        else:
            print("  结果: 执行异常")
            print(body[-2000:])
            report.append(f"{name}: ERROR (simulation did not produce a valid test result)")
            all_caught = False

    print(f"\n{'='*70}")
    print("变异测试汇总")
    for r in report:
        print("  " + r)

    out = os.path.join(ROOT, r"sim\coverage\mutation_report.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write("变异测试报告 (mutation test)\n")
        f.write("目的: 证明验证平台能捕获 RTL 缺陷, 而非仅仅运行通过\n")
        f.write("=" * 70 + "\n")
        for r in report:
            f.write(r + "\n")
        f.write("=" * 70 + "\n")
        f.write(f"结论: {sum(1 for r in report if ': CAUGHT' in r)}/{len(report)} 个变异被捕获\n")
    print(f"\n报告: {out}")
    return 0 if all_caught else 1


if __name__ == "__main__":
    sys.exit(main())
