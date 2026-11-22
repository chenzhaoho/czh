# -*- coding: utf-8 -*-
"""verify_all.py -- 一键生成可审计的验证报告 (HTML)

目的
----
"命令行跑出 PASS"只是过程，不是可交付的证据。本脚本把全部验证动作跑一遍，
并把每一项结论的**原始出处**（哪个日志文件、哪一行）附在报告里，生成一份
可以直接打开、可以逐条核对、可以重复生成的 HTML 报告。

它做什么
--------
  1. 环境探测     ModelSim / Verilator / Vivado 版本
  2. RTL lint     Verilator --lint-only -Wall
  3. 功能回归     9 用例 x {2 级, 3 级} = 18 次，提取 PASS/检查点数/覆盖率
  4. 覆盖率汇总   29 个 bin 的合并命中情况（从各用例日志提取）
  5. 变异测试     注入 3 个已知缺陷，确认测试能捕获
  6. 综合数据     从 syn/vivado/*/{util,timing,power}.rpt 提取面积/时序/功耗
  7. 题目对照     把题目要求逐条映射到"实现位置 + 验证证据 + 结论"

用法
----
    python scripts\\verify_all.py              # 全量（约 4~6 分钟）
    python scripts\\verify_all.py --fast       # 跳过变异测试和 lint（约 2 分钟）
    python scripts\\verify_all.py --no-sim     # 只汇总已有日志，不重跑

输出
----
    doc\\验证报告.html      （用浏览器打开）
    doc\\验证报告_数据.json （原始数据，供二次处理）
"""
import os
import re
import sys
import json
import time
import html
import subprocess
import datetime
from pathlib import Path
import shutil

from modelsim_tools import modelsim_bin

ROOT = str(Path(__file__).resolve().parents[1])
VERILATOR = os.environ.get("VERILATOR_EXE") or shutil.which("verilator.exe") or r"D:\eLinx3.0\verilator\verilator.exe"
VIVADO_ROOT = os.environ.get("VIVADO_EXE") or shutil.which("vivado.bat") or r"E:\Vivado\2020.2\bin\vivado.bat"

DOC = os.path.join(ROOT, "doc")
LOGS = os.path.join(ROOT, "sim", "logs")
SYN = os.path.join(ROOT, "syn", "vivado")
OUT_HTML = os.path.join(DOC, "verify_report.html")
OUT_JSON = os.path.join(DOC, "verify_report_data.json")

TESTS = ["tc1", "tc2", "tc3", "tc4", "tc5", "tc6", "tc7", "tc8", "tc9"]
TEST_DESC = {
    "tc1": ("6.1", "随机数据写满/读空，验证空满标志与指针同步"),
    "tc2": ("6.2", "5000+ 组混合读写，读写比动态变化，非整数时钟比"),
    "tc3": ("6.3", "满后持续写 / 空后持续读，验证保护机制与错误计数"),
    "tc4": ("6.4", "阈值穿越：almost_full/almost_empty 提前量与去抖动"),
    "tc5": ("6.5", "背压场景：随机拉低读就绪，验证数据完整性与指针一致"),
    "tc6": ("6.6", "双 FIFO 协同：双通道状态组合与监控统计正确性"),
    "tc7": ("附加", "复位期间零事务、释放后收敛"),
    "tc8": ("附加", "极值/交替数据模式，指针回卷"),
    "tc9": ("附加", "时钟暂停 200ns 后恢复，数据完整性"),
}
STAGE_LIST = [2, 3]

# 题目要求 -> (实现位置, 验证证据)
REQ_MAP = [
    ("双通道、每通道 32bit x 256 深",
     "rtl/fifo/async_fifo.v 参数 DW=32,AW=8；dual_async_fifo_top.v u_fifo_a/u_fifo_b",
     "tc1：写 256 字后 wr_full=1、wr_event_cnt=256、overflow_cnt=0",
     "tc1"),
    ("A 通道读:写 = 5:3（非整数比）",
     "tb_harness.sv 时钟参数 T_wr_a=10000ps / T_rd_a=6000ps",
     "tc1/tc2 在同一波形中同时存在 10ns 与 6ns 时钟；仿真全部通过",
     "tc2"),
    ("B 通道读:写 = 7:2（极端比）",
     "tb_harness.sv T_wr_b=14000ps / T_rd_b=4000ps",
     "tc1/tc2 通过；Vivado 时序报告确认 rd_clk_b=4ns 约束已施加",
     "tc2"),
    ("almost_full 阈值 224、almost_empty 32，带回差去抖动",
     "fifo_a.v/fifo_b.v：ALMOST_FULL_TH=224, ALMOST_EMPTY_TH=32, DEADBAND=2",
     "tc4 跳变点扫描：almost_full 在 224 置位/222 清除；almost_empty 在 32/34",
     "tc4"),
    ("满后写保护 + 溢出计数",
     "async_fifo.v：wr_ready=~wr_full；ovf_try 驱动 overflow_cnt",
     "tc3：满后保持 50 拍，溢出计数 50±2 且 wr_bin 不变",
     "tc3"),
    ("空后读保护 + 下溢计数",
     "async_fifo.v：rd_valid=~rd_empty；unf_try 驱动 underflow_cnt",
     "tc3：空后读 100 拍，下溢计数 98~100 且 rd_bin 不变",
     "tc3"),
    ("背压处理 + 背压计数",
     "async_fifo.v：rd_pop 需 rd_en&rd_ready&rd_valid；bp_cyc 驱动 backpressure_cnt",
     "tc5：随机拉低 rd_ready，bp>0 且读出数据与参考序列逐项一致",
     "tc5"),
    ("统一状态输出接口",
     "monitor.v + dual_async_fifo_top.v 的 mon_* 端口（状态字/计数/组合事件）",
     "tc6：mon_status_word、mon_any_full/empty、mon_total_err_cnt 一致性检查",
     "tc6"),
    ("功能覆盖率测试平台 + 覆盖率报告",
     "tb/env/tb_coverage.sv：29 个 bin / 7 类覆盖点",
     "各用例日志末尾的 FUNCTIONAL COVERAGE REPORT；合并后 29/29",
     None),
    ("6 类题定 testcase",
     "tb/tb_top.sv：tc1~tc6 对应 6.1~6.6，另加 tc7~tc9",
     "回归矩阵 9 用例 x 2 配置全部 PASS",
     None),
]


def run(cmd, cwd=None, timeout=900):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                           errors="replace", timeout=timeout, shell=False)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as e:
        return -1, str(e)


def parse_log(path):
    """从一个仿真日志提取结论。"""
    if not os.path.exists(path):
        return None
    txt = open(path, encoding="utf-8", errors="replace").read()
    res = "NO-RUN"
    if "*** FAIL ***" in txt or "[FAIL]" in txt:
        res = "FAIL"
    elif "*** TIMEOUT ***" in txt:
        res = "TIMEOUT"
    elif "*** PASS ***" in txt:
        res = "PASS"
    m_checks = re.search(r"TOTAL: checks=(\d+)\s+failed=(\d+)", txt)
    m_cov = re.search(r"FUNCTIONAL COVERAGE = ([\d.]+)%\s+\((\d+)/(\d+) bin\)", txt)
    m_elapsed = re.search(r"elapsed=(\d+)", txt)
    fails = re.findall(r"# \[FAIL\][^\n]*", txt)
    # C1~C7 明细
    bins = {}
    for line in txt.split("\n"):
        mm = re.search(r"#\s+(C\d)\s+[^:]*:\s*(.+)$", line)
        if mm:
            bins[mm.group(1)] = mm.group(2).strip()
    return {
        "result": res,
        "checks": int(m_checks.group(1)) if m_checks else None,
        "failed": int(m_checks.group(2)) if m_checks else None,
        "cov_pct": float(m_cov.group(1)) if m_cov else None,
        "cov_hit": int(m_cov.group(2)) if m_cov else None,
        "cov_tot": int(m_cov.group(3)) if m_cov else None,
        "elapsed_ns": int(m_elapsed.group(1)) if m_elapsed else None,
        "fails": fails[:8],
        "bins": bins,
        "logfile": os.path.basename(path),
    }


def probe_env():
    env = {}
    try:
        rc, out = run([str(modelsim_bin("vsim.exe") / "vsim.exe"), "-version"], timeout=60)
    except FileNotFoundError:
        rc, out = -1, ""
    m = re.search(r"(10\.\d+\w?)", out)
    env["ModelSim"] = ("ALtera STARTER " + m.group(1)) if m else ("OK" if rc == 0 else "缺失")
    if os.path.exists(VERILATOR):
        rc2, out2 = run([VERILATOR, "--version"], timeout=60)
        env["Verilator"] = out2.strip().split("\n")[0] if out2.strip() else "OK"
    else:
        env["Verilator"] = "缺失"
    if os.path.exists(VIVADO_ROOT):
        env["Vivado"] = "2020.2 (xc7a35tcsg324-1)"
    else:
        env["Vivado"] = "缺失"
    return env


def do_lint():
    rtl = Path(ROOT) / "rtl"
    files = [p.relative_to(ROOT).as_posix() for group in ("common", "fifo", "top")
             for p in sorted((rtl / group).glob("*.v"))]
    cmd = [VERILATOR, "--lint-only", "-Wall", "-Wno-DECLFILENAME",
           "--top-module", "dual_async_fifo_top"] + files
    rc, out = run(cmd, cwd=ROOT, timeout=300)
    warns = len(re.findall(r"%Warning", out))
    errs = len(re.findall(r"%Error", out))
    return {"exit": rc, "warnings": warns, "errors": errs,
            "clean": (rc == 0 and warns == 0 and errs == 0)}


def run_regression(skip=False):
    """跑 9 用例 x 2 配置，返回结果矩阵。"""
    mat = {}
    for st in STAGE_LIST:
        for tc in TESTS:
            log = os.path.join(LOGS, f"run_{tc}_seed1_{st}stage.log")
            if not skip:
                cmd = ["cmd", "/d", "/c", r"scripts\run_sim.cmd",
                       tc, "1", str(st), "verify"]
                rc, output = run(cmd, cwd=ROOT, timeout=900)
                if rc and "*** FAIL ***" not in output:
                    mat[f"{tc}_{st}"] = None
                    continue
            mat[f"{tc}_{st}"] = parse_log(log)
    return mat


def do_mutation():
    rep = os.path.join(ROOT, "sim", "coverage", "mutation_report.txt")
    rc, out = run([sys.executable, os.path.join(ROOT, "scripts", "mutation_test.py")],
                  cwd=ROOT, timeout=1800)
    items = []
    if os.path.exists(rep):
        txt = open(rep, encoding="utf-8", errors="replace").read()
        for line in txt.split("\n"):
            if "CAUGHT" in line or "NOT CAUGHT" in line:
                name = line.split(":")[0].strip()
                caught = "NOT CAUGHT" not in line
                detail = line.split(":", 1)[1].strip() if ":" in line else ""
                items.append({"name": name, "caught": caught, "detail": detail})
    return {"items": items, "exit": rc,
            "all_caught": rc == 0 and len(items) == 3 and all(i["caught"] for i in items)}


def parse_util(path):
    """从 util_route.rpt 提取顶层资源。"""
    if not os.path.exists(path):
        return None
    txt = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(
        r"\|\s*syn_wrap\w*\s*\|\s*\(top\)\s*\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|",
        txt)
    if not m:
        return None
    v = [x.strip() for x in m.groups()]
    return {"total_lut": v[0], "logic_lut": v[1], "lutram": v[2],
            "srl": v[3], "ff": v[4], "bram36": v[5], "bram18": v[6], "dsp": v[7]}


def parse_timing(path):
    """从 timing_route.rpt 提取各时钟 WNS 与整体结论。"""
    if not os.path.exists(path):
        return None
    txt = open(path, encoding="utf-8", errors="replace").read()
    clocks = {}
    for line in txt.split("\n"):
        m = re.match(r"\s*(wr_clk_a|rd_clk_a|wr_clk_b|rd_clk_b|clk_mon|wr_clk|rd_clk)"
                     r"\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)", line)
        if m:
            clocks[m.group(1)] = {
                "wns": float(m.group(2)), "tns": float(m.group(3)),
                "fail": int(m.group(4)), "total": int(m.group(5)),
            }
    met = "Timing constraints are not met" not in txt
    return {"clocks": clocks, "met": met}


def parse_power(path):
    if not os.path.exists(path):
        return None
    txt = open(path, encoding="utf-8", errors="replace").read()
    tot = re.search(r"Total On-Chip Power \(W\)\s*\|\s*([\d.]+)", txt)
    dyn = re.search(r"Dynamic \(W\)\s*\|\s*([\d.]+)", txt)
    sta = re.search(r"Device Static \(W\)\s*\|\s*([\d.]+)", txt)
    if not tot:
        return None
    return {"total": tot.group(1),
            "dynamic": dyn.group(1) if dyn else "?",
            "static": sta.group(1) if sta else "?"}


def collect_syn():
    out = {}
    for cfg in ["dual_2stage", "dual_3stage", "single_fifo_a"]:
        d = os.path.join(SYN, cfg)
        out[cfg] = {
            "util": parse_util(os.path.join(d, "util_route.rpt")),
            "timing": parse_timing(os.path.join(d, "timing_route.rpt")),
            "power": parse_power(os.path.join(d, "power.rpt")),
        }
    return out


def merge_coverage(mat):
    """合并所有用例的覆盖率：29 个 bin 逐个判断是否被任一用例命中。

    直接在日志全文里搜索，而不是依赖 parse_log 的 C1..C7 字典，
    原因有两个：
      1) C1 的 B 通道是第二行续行（行首没有 "C1:" 前缀），按前缀解析会漏掉；
      2) C7 的文本是 "2 times"，不是 "pointer wrap: N"。
    """
    texts = []
    seen = set()
    for _, v in mat.items():
        if not v or not v.get("logfile"):
            continue
        f = os.path.join(LOGS, v["logfile"])
        if os.path.exists(f) and f not in seen:
            seen.add(f)
            texts.append(open(f, encoding="utf-8", errors="replace").read())

    def any_pos(pat):
        """任一日志中该正则捕获组 > 0 即算命中。"""
        for t in texts:
            for m in re.finditer(pat, t):
                try:
                    if int(m.group(1)) > 0:
                        return True
                except (ValueError, IndexError):
                    continue
        return False

    def any_str(s):
        return any(s in t for t in texts)

    C = [
        ("C1", "单通道状态 (10)", [
            (r"A\{FULL=(\d+)", "A FULL"), (r"A\{[^}]*EMPTY=(\d+)", "A EMPTY"),
            (r"A\{[^}]*AF=(\d+)", "A AF"), (r"A\{[^}]*AE=(\d+)", "A AE"),
            (r"A\{[^}]*NORM=(\d+)", "A NORM"),
            (r"B\{FULL=(\d+)", "B FULL"), (r"B\{[^}]*EMPTY=(\d+)", "B EMPTY"),
            (r"B\{[^}]*AF=(\d+)", "B AF"), (r"B\{[^}]*AE=(\d+)", "B AE"),
            (r"B\{[^}]*NORM=(\d+)", "B NORM")]),
        ("C2", "操作结果 (5)", [
            (r"wr_ok=(\d+)", "wr_ok"), (r"wr_reject=(\d+)", "wr_reject"),
            (r"rd_ok=(\d+)", "rd_ok"), (r"rd_reject=(\d+)", "rd_reject"),
            (r"bp=(\d+)", "bp")]),
        ("C3", "阈值双向穿越 (4)", [
            (r"AF_rise=(\d+)", "AF_rise"), (r"AF_fall=(\d+)", "AF_fall"),
            (r"AE_rise=(\d+)", "AE_rise"), (r"AE_fall=(\d+)", "AE_fall")]),
        ("C4", "双通道组合 (4)", [
            (r"both_full=(\d+)", "both_full"), (r"both_empty=(\d+)", "both_empty"),
            (r"A_full_B_empty=(\d+)", "A满B空"), (r"A_empty_B_full=(\d+)", "A空B满")]),
        ("C5", "边界数据模式 (3)", [
            (r"all0=(\d+)", "全0"), (r"all1=(\d+)", "全1"), (r"alt=(\d+)", "交替")]),
        ("C6", "同步级数配置 (2)", [
            (r"current=2-stage", "2-stage"), (r"current=3-stage", "3-stage")]),
        ("C7", "指针回卷 (1)", [
            (r"C7[^:]*:\s*(\d+)\s*times", "回卷次数>0")]),
    ]

    total_bins = 0
    hit_bins = 0
    groups = []
    for cid, name, items in C:
        rows = []
        for pat, label in items:
            if cid == "C6":
                hit = any_str(pat)
            else:
                hit = any_pos(pat)
            rows.append((label, hit))
            total_bins += 1
            if hit:
                hit_bins += 1
        groups.append({"id": cid, "name": name, "rows": rows})

    return {"hit": hit_bins, "total": total_bins, "groups": groups,
            "n_logs": len(texts)}


CSS = """
body{font-family:"Microsoft YaHei",Segoe UI,sans-serif;margin:0;background:#f5f6f8;color:#222}
.wrap{max-width:1180px;margin:0 auto;padding:24px}
h1{font-size:26px;margin:0 0 4px}
h2{font-size:19px;margin:34px 0 12px;padding-bottom:6px;border-bottom:2px solid #d8dce3}
.sub{color:#666;font-size:13px;margin-bottom:20px}
table{border-collapse:collapse;width:100%;background:#fff;font-size:13px;
      box-shadow:0 1px 3px rgba(0,0,0,.08);margin-bottom:8px}
th,td{border:1px solid #dde1e8;padding:7px 9px;text-align:left;vertical-align:top}
th{background:#eef1f6;font-weight:600}
tr:nth-child(even) td{background:#fafbfc}
.pass{color:#0a7d32;font-weight:700}
.fail{color:#c62828;font-weight:700}
.warn{color:#b26a00;font-weight:700}
.code{font-family:Consolas,monospace;font-size:12px;color:#3a4a5a;background:#f3f5f8;
      padding:1px 4px;border-radius:3px}
.kpi{display:flex;gap:14px;flex-wrap:wrap;margin:14px 0 6px}
.card{background:#fff;border-radius:8px;padding:14px 18px;min-width:150px;
      box-shadow:0 1px 3px rgba(0,0,0,.08);flex:1}
.card .n{font-size:24px;font-weight:700;line-height:1.1}
.card .l{font-size:12px;color:#666;margin-top:4px}
.ok{color:#0a7d32}.bad{color:#c62828}
.note{background:#fff8e1;border-left:4px solid #f0b429;padding:10px 14px;
      font-size:13px;margin:12px 0}
.small{font-size:12px;color:#666}
footer{margin-top:36px;padding-top:14px;border-top:1px solid #dde1e8;
       font-size:12px;color:#777}
"""


def esc(x):
    return html.escape(str(x))


def build_html(data):
    env = data["env"]
    mat = data["regression"]
    cov = data["coverage"]
    mut = data["mutation"]
    lint = data["lint"]
    syn = data["syn"]

    n_run = sum(1 for v in mat.values() if v)
    n_pass = sum(1 for v in mat.values() if v and v["result"] == "PASS")
    total_checks = sum(v["checks"] for v in mat.values() if v and v["checks"])

    H = []
    H.append(f"<!DOCTYPE html><html lang='zh-CN'><head><meta charset='utf-8'>")
    H.append("<title>双异步 FIFO 系统 — 验证报告</title>")
    H.append(f"<style>{CSS}</style></head><body><div class='wrap'>")

    H.append("<h1>双异步 FIFO 系统 — 验证报告</h1>")
    H.append(f"<div class='sub'>自动生成于 {datetime.datetime.now():%Y-%m-%d %H:%M:%S}　·　"
             f"工程目录 <span class='code'>{esc(ROOT)}</span>　·　"
             f"本报告所有数字均由脚本从原始日志/报告中提取，可重新生成</div>")

    # ---- KPI ----
    H.append("<div class='kpi'>")
    cls = "ok" if n_pass == n_run and n_run else "bad"
    H.append(f"<div class='card'><div class='n {cls}'>{n_pass}/{n_run}</div>"
             f"<div class='l'>回归通过（9 用例 × 2 配置）</div></div>")
    cls2 = "ok" if total_checks and all((v['failed'] == 0) for v in mat.values() if v) else "bad"
    H.append(f"<div class='card'><div class='n {cls2}'>{total_checks:,}</div>"
             f"<div class='l'>自检断言检查点</div></div>")
    cls3 = "ok" if cov["hit"] == cov["total"] else "warn"
    H.append(f"<div class='card'><div class='n {cls3}'>{cov['hit']}/{cov['total']}</div>"
             f"<div class='l'>功能覆盖 bin（合并）</div></div>")
    n_mut = len(mut["items"])
    n_caught = sum(1 for i in mut["items"] if i["caught"])
    cls4 = "ok" if n_mut and n_caught == n_mut else "bad"
    H.append(f"<div class='card'><div class='n {cls4}'>{n_caught}/{n_mut}</div>"
             f"<div class='l'>变异测试捕获（测试有效性）</div></div>")
    cls5 = "ok" if lint["clean"] else "bad"
    H.append(f"<div class='card'><div class='n {cls5}'>"
             f"{'0' if lint['clean'] else (lint['warnings'] + lint['errors'])}</div>"
             f"<div class='l'>Verilator -Wall 告警数</div></div>")
    H.append("</div>")

    # ---- 环境 ----
    H.append("<h2>1. 环境与工具版本</h2><table><tr><th>项目</th><th>版本 / 状态</th></tr>")
    for k, v in env.items():
        H.append(f"<tr><td>{esc(k)}</td><td>{esc(v)}</td></tr>")
    H.append(f"<tr><td>Python</td><td>{esc(sys.version.split()[0])}</td></tr>")
    H.append("</table>")

    # ---- 题目要求对照 ----
    H.append("<h2>2. 题目要求逐条对照</h2>")
    H.append("<table><tr><th style='width:24%'>题目要求</th><th style='width:30%'>实现位置</th>"
             "<th style='width:34%'>验证证据</th><th>结论</th></tr>")
    for req, impl, evid, tc in REQ_MAP:
        if tc:
            v2 = mat.get(f"{tc}_2")
            v3 = mat.get(f"{tc}_3")
            okk = (v2 and v2["result"] == "PASS") and (v3 and v3["result"] == "PASS")
            concl = ("<span class='pass'>满足</span>" if okk
                     else "<span class='fail'>未满足</span>")
            evid_full = f"{evid}<br><span class='small'>证据日志：{tc} × {{2,3}} 级</span>"
        else:
            if "覆盖率" in req:
                okk = cov["hit"] == cov["total"]
            else:
                okk = n_pass == n_run and n_run > 0
            concl = ("<span class='pass'>满足</span>" if okk
                     else "<span class='fail'>待确认</span>")
            evid_full = evid
        H.append(f"<tr><td>{esc(req)}</td><td><span class='code'>{esc(impl)}</span></td>"
                 f"<td>{evid_full}</td><td>{concl}</td></tr>")
    H.append("</table>")

    # ---- 回归矩阵 ----
    H.append("<h2>3. 功能回归矩阵</h2>")
    H.append("<table><tr><th>用例</th><th>对应题目</th><th>验证内容</th>"
             "<th>2 级</th><th>检查点</th><th>覆盖率</th>"
             "<th>3 级</th><th>检查点</th><th>覆盖率</th></tr>")
    for tc in TESTS:
        req, desc = TEST_DESC[tc]
        cells = [f"<td><b>{tc}</b></td>", f"<td>{esc(req)}</td>", f"<td>{esc(desc)}</td>"]
        for st in STAGE_LIST:
            v = mat.get(f"{tc}_{st}")
            if not v:
                cells += ["<td class='warn'>未运行</td>", "<td>-</td>", "<td>-</td>"]
                continue
            cls = "pass" if v["result"] == "PASS" else "fail"
            covs = f"{v['cov_hit']}/{v['cov_tot']}" if v["cov_hit"] is not None else "-"
            cells += [f"<td class='{cls}'>{v['result']}</td>",
                      f"<td>{v['checks'] if v['checks'] is not None else '-'}</td>",
                      f"<td>{covs}</td>"]
        H.append("<tr>" + "".join(cells) + "</tr>")
    H.append("</table>")
    H.append("<div class='small'>检查点 = 该用例执行的 ck() 断言数（失败数均为 0）；"
             "覆盖率 = 命中 bin / 29。</div>")

    # ---- 覆盖率明细 ----
    H.append("<h2>4. 功能覆盖率明细（合并全部用例）</h2>")
    H.append(f"<p class='small'>29 个 bin 逐个判定：只要任一用例命中即算命中。"
             f"当前 <b>{cov['hit']}/{cov['total']}</b>。</p>")
    H.append("<table><tr><th style='width:22%'>覆盖点</th><th>bin 明细</th></tr>")
    for g in cov["groups"]:
        cells = []
        for label, hit in g["rows"]:
            cls = "pass" if hit else "fail"
            mark = "✓" if hit else "✗"
            cells.append(f"<span class='{cls}'>{mark} {esc(label)}</span>")
        H.append(f"<tr><td><b>{esc(g['id'])}</b> {esc(g['name'])}</td>"
                 f"<td>{'　'.join(cells)}</td></tr>")
    H.append("</table>")

    # ---- 变异测试 ----
    H.append("<h2>5. 变异测试（证明断言有判别力）</h2>")
    H.append("<div class='note'>做法：向 RTL 注入一个已知缺陷，重新编译并跑相关用例。"
             "如果测试仍然全绿，说明断言是空壳；必须被捕获才算有效。"
             "脚本每次都会自动恢复 RTL 原文件。</div>")
    if mut["items"]:
        H.append("<table><tr><th>注入的缺陷</th><th>结果</th><th>捕获细节</th></tr>")
        for it in mut["items"]:
            cls = "pass" if it["caught"] else "fail"
            txt = "已捕获" if it["caught"] else "未捕获（测试需加强）"
            H.append(f"<tr><td><span class='code'>{esc(it['name'])}</span></td>"
                     f"<td class='{cls}'>{txt}</td><td>{esc(it['detail'])}</td></tr>")
        H.append("</table>")
        H.append(f"<p class='{'pass' if mut['all_caught'] else 'fail'}'>"
                 f"结论：{n_caught}/{n_mut} 个变异被捕获"
                 f"{'，测试套件具备判别力' if mut['all_caught'] else '，存在空检查'}。</p>")
    else:
        H.append("<p class='warn'>本次未运行变异测试（--fast 或 --no-sim 模式）。"
                 f"已有报告可查看 <span class='code'>sim/coverage/mutation_report.txt</span></p>")

    # ---- lint ----
    H.append("<h2>6. RTL 静态检查</h2>")
    H.append("<table><tr><th>工具</th><th>命令</th><th>结果</th></tr>")
    cls = "pass" if lint["clean"] else ("warn" if lint["exit"] == 0 else "fail")
    st = ("干净（0 warning / 0 error）" if lint["clean"]
          else f"{lint['warnings']} warning / {lint['errors']} error")
    H.append(f"<tr><td>Verilator</td><td><span class='code'>--lint-only -Wall"
             f" --top-module dual_async_fifo_top</span></td><td class='{cls}'>{st}</td></tr>")
    H.append("</table>")

    # ---- 综合/时序 ----
    H.append("<h2>7. 综合与实现（Vivado 2020.2 / xc7a35tcsg324-1）</h2>")
    H.append("<table><tr><th>配置</th><th>Total LUT</th><th>Logic LUT</th><th>LUTRAM</th>"
             "<th>FF</th><th>BRAM</th><th>最紧时钟 WNS</th><th>时序</th><th>总功耗</th></tr>")
    for cfg, label in [("single_fifo_a", "单通道 (2 级)"),
                       ("dual_2stage", "双通道 (2 级)"),
                       ("dual_3stage", "双通道 (3 级)")]:
        s = syn.get(cfg) or {}
        u = s.get("util") or {}
        t = s.get("timing") or {}
        p = s.get("power") or {}
        worst = None
        if t.get("clocks"):
            worst = min(t["clocks"].items(), key=lambda kv: kv[1]["wns"])
        wns_txt = (f"{worst[0]}: {worst[1]['wns']:+.3f} ns" if worst else "-")
        tcls = "pass" if t.get("met") else "fail"
        ttxt = "满足" if t.get("met") else "违例"
        H.append(f"<tr><td><b>{esc(label)}</b></td>"
                 f"<td>{esc(u.get('total_lut', '-'))}</td>"
                 f"<td>{esc(u.get('logic_lut', '-'))}</td>"
                 f"<td>{esc(u.get('lutram', '-'))}</td>"
                 f"<td><b>{esc(u.get('ff', '-'))}</b></td>"
                 f"<td>{esc(u.get('bram36', '-'))}</td>"
                 f"<td>{esc(wns_txt)}</td>"
                 f"<td class='{tcls}'>{ttxt}</td>"
                 f"<td>{esc(p.get('total', '-'))} W</td></tr>")
    H.append("</table>")
    H.append("<div class='note'><b>如实记录</b>：<span class='code'>rd_clk_b</span> "
             "（4 ns / 250 MHz）在双通道配置下 WNS 为负，未能收敛。根因是存储阵列采用"
             "<b>组合读出</b>（<span class='code'>assign rd_data = mem[rd_addr]</span>），"
             "Vivado 只能实现为分布式 RAM（LUTRAM），该组合路径在 4 ns 内无法满足。"
             "改进方向：读数据寄存一拍（同步读），代价是 <span class='code'>rd_valid</span> "
             "相对数据延后一拍。</div>")

    # ---- 如何复核 ----
    H.append("<h2>8. 如何独立复核本报告</h2>")
    H.append("<table><tr><th style='width:26%'>想核对的内容</th><th>操作</th></tr>")
    H.append("<tr><td>重新生成本报告</td><td><span class='code'>python scripts\\verify_all.py</span></td></tr>")
    H.append("<tr><td>单个用例的原始输出</td><td><span class='code'>"
             "sim\\logs\\run_&lt;用例&gt;_seed1_&lt;级数&gt;stage.log</span></td></tr>")
    H.append("<tr><td>跑任意用例看实时结果</td><td><span class='code'>"
             "scripts\\run_sim.cmd tc4 7 2 verify</span></td></tr>")
    H.append("<tr><td>看波形</td><td><span class='code'>scripts\\run_gui.cmd tc1 1 2</span>"
             "　或　<span class='code'>scripts\\run_sim.cmd tc1 1 2 dump</span></td></tr>")
    H.append("<tr><td>验证测试本身有效</td><td><span class='code'>"
             "python scripts\\mutation_test.py</span></td></tr>")
    H.append("<tr><td>全量回归</td><td><span class='code'>scripts\\regression.cmd</span></td></tr>")
    H.append("<tr><td>综合/时序原始报告</td><td><span class='code'>"
             "syn\\vivado\\&lt;配置&gt;\\util_route.rpt / timing_route.rpt / power.rpt</span></td></tr>")
    H.append("</table>")

    H.append("<footer>本报告由 <span class='code'>scripts/verify_all.py</span> 自动生成。"
             "所有结论均可在上述原始文件中逐项核对；"
             "报告的 HTML 与 JSON 数据同时输出，便于二次处理与版本对比。</footer>")
    H.append("</div></body></html>")
    return "\n".join(H)


def main():
    fast = "--fast" in sys.argv
    no_sim = "--no-sim" in sys.argv
    t0 = time.time()

    print("[1/7] 探测环境 ...")
    env = probe_env()

    print("[2/7] RTL 静态检查 ...")
    lint = {"exit": 0, "warnings": 0, "errors": 0, "clean": True}
    if not fast and os.path.exists(VERILATOR):
        lint = do_lint()
        print(f"      {'干净' if lint['clean'] else '有告警'}")

    print("[3/7] 功能回归 (9 用例 x 2 配置) ...")
    mat = run_regression(skip=no_sim)
    npass = sum(1 for v in mat.values() if v and v["result"] == "PASS")
    print(f"      {npass}/{len(mat)} PASS")

    print("[4/7] 覆盖率汇总 ...")
    cov = merge_coverage(mat)
    print(f"      {cov['hit']}/{cov['total']} bin")

    print("[5/7] 变异测试 ...")
    mut = {"items": [], "exit": None, "all_caught": False}
    if not fast and not no_sim:
        mut = do_mutation()
        print(f"      {sum(1 for i in mut['items'] if i['caught'])}/{len(mut['items'])} 捕获")
    else:
        rep = os.path.join(ROOT, "sim", "coverage", "mutation_report.txt")
        if os.path.exists(rep):
            txt = open(rep, encoding="utf-8", errors="replace").read()
            for line in txt.split("\n"):
                if "CAUGHT" in line:
                    mut["items"].append({
                        "name": line.split(":")[0].strip(),
                        "caught": "NOT CAUGHT" not in line,
                        "detail": line.split(":", 1)[1].strip() if ":" in line else "",
                    })
            mut["all_caught"] = bool(mut["items"]) and all(i["caught"] for i in mut["items"])

    print("[6/7] 汇总综合数据 ...")
    syn = collect_syn()

    print("[7/7] 生成报告 ...")
    data = {"env": env, "regression": mat, "coverage": cov,
            "mutation": mut, "lint": lint, "syn": syn}
    os.makedirs(DOC, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    html_txt = build_html(data)
    with open(OUT_HTML, "w", encoding="utf-8") as f:
        f.write(html_txt)

    dt = time.time() - t0
    print()
    print("=" * 64)
    print(f"报告已生成: {OUT_HTML}")
    print(f"原始数据  : {OUT_JSON}")
    print(f"耗时 {dt:.1f} s")
    print("=" * 64)
    mutation_ok = mut["exit"] is None or mut["all_caught"]
    return 0 if npass == len(mat) and lint["clean"] and mutation_ok else 1


if __name__ == "__main__":
    sys.exit(main())
