# -*- coding: utf-8 -*-
"""生成 syn_wrap_dual.v / syn_wrap_single.v

为什么要生成而不是手写:
    dual_async_fifo_top 有 89 个端口, fifo_a 有 34 个。手写例化容易漏引脚
    (第一次尝试就漏了 mon_a_ovf_cnt 等 11 个)。这里把端口清单写成数据,
    由脚本同时生成"声明 + 例化连接 + 汇聚寄存器拼接", 三者必然一致。

规则:
    * EXTERNAL 中的端口直接成为 wrapper 端口(真实数据通路);
    * 其余端口接内部 wire, 并全部参与 dbg_sink 拼接, 使综合不能优化掉它们,
      从而让面积/时序反映完整设计。
"""
import re
from pathlib import Path

SYN_DIR = Path(__file__).resolve().parent

# ---------------------------------------------------------------- dual 端口表
# (名称, 方向, 位宽表达式)  位宽为 "1" 表示单比特
DUAL_PORTS = [
    ("rst_n_async",            "input",  "1"),
    ("dbg_sig",                "output", "8"),
    ("wr_clk_a",               "input",  "1"),
    ("wr_valid_a",             "input",  "1"),
    ("wr_data_a",              "input",  "DW"),
    ("wr_ready_a",             "output", "1"),
    ("wr_full_a",              "output", "1"),
    ("full_check_a",           "output", "1"),
    ("wr_almost_full_a",       "output", "1"),
    ("wr_data_committed_a",    "output", "DW"),
    ("wr_data_valid_a",        "output", "1"),
    ("a_wr_event_cnt",         "output", "CNT_W"),
    ("a_overflow_cnt",         "output", "CNT_W"),
    ("a_overflow_flag_cnt",    "output", "CNT_W"),
    ("rd_clk_a",               "input",  "1"),
    ("rd_en_a",                "input",  "1"),
    ("rd_ready_a",             "input",  "1"),
    ("rd_data_a",              "output", "DW"),
    ("rd_valid_a",             "output", "1"),
    ("rd_empty_a",             "output", "1"),
    ("rd_almost_empty_a",      "output", "1"),
    ("a_rd_event_cnt",         "output", "CNT_W"),
    ("a_underflow_cnt",        "output", "CNT_W"),
    ("a_underflow_flag_cnt",   "output", "CNT_W"),
    ("a_backpressure_cnt",     "output", "CNT_W"),
    ("a_backpressure_active",  "output", "1"),
    ("wr_clk_b",               "input",  "1"),
    ("wr_valid_b",             "input",  "1"),
    ("wr_data_b",              "input",  "DW"),
    ("wr_ready_b",             "output", "1"),
    ("wr_full_b",              "output", "1"),
    ("full_check_b",           "output", "1"),
    ("wr_almost_full_b",       "output", "1"),
    ("wr_data_committed_b",    "output", "DW"),
    ("wr_data_valid_b",        "output", "1"),
    ("b_wr_event_cnt",         "output", "CNT_W"),
    ("b_overflow_cnt",         "output", "CNT_W"),
    ("b_overflow_flag_cnt",    "output", "CNT_W"),
    ("rd_clk_b",               "input",  "1"),
    ("rd_en_b",                "input",  "1"),
    ("rd_ready_b",             "input",  "1"),
    ("rd_data_b",              "output", "DW"),
    ("rd_valid_b",             "output", "1"),
    ("rd_empty_b",             "output", "1"),
    ("rd_almost_empty_b",      "output", "1"),
    ("b_rd_event_cnt",         "output", "CNT_W"),
    ("b_underflow_cnt",        "output", "CNT_W"),
    ("b_underflow_flag_cnt",   "output", "CNT_W"),
    ("b_backpressure_cnt",     "output", "CNT_W"),
    ("b_backpressure_active",  "output", "1"),
    ("clk_mon",                "input",  "1"),
    ("mon_a_status",           "output", "3"),
    ("mon_b_status",           "output", "3"),
    ("mon_status_word",        "output", "6"),
    ("mon_a_full",             "output", "1"),
    ("mon_a_almost_full",      "output", "1"),
    ("mon_a_empty",            "output", "1"),
    ("mon_a_almost_empty",     "output", "1"),
    ("a_used_wr_est",          "output", "AW1"),
    ("a_used_rd_est",          "output", "AW1"),
    ("b_used_wr_est",          "output", "AW1"),
    ("b_used_rd_est",          "output", "AW1"),
    ("mon_a_used",             "output", "AW1"),
    ("mon_a_wr_cnt",           "output", "CNT_W"),
    ("mon_a_rd_cnt",           "output", "CNT_W"),
    ("mon_a_ovf_cnt",          "output", "CNT_W"),
    ("mon_a_unf_cnt",          "output", "CNT_W"),
    ("mon_a_bp_cnt",           "output", "CNT_W"),
    ("mon_b_full",             "output", "1"),
    ("mon_b_almost_full",      "output", "1"),
    ("mon_b_empty",            "output", "1"),
    ("mon_b_almost_empty",     "output", "1"),
    ("mon_b_used",             "output", "AW1"),
    ("mon_b_wr_cnt",           "output", "CNT_W"),
    ("mon_b_rd_cnt",           "output", "CNT_W"),
    ("mon_b_ovf_cnt",          "output", "CNT_W"),
    ("mon_b_unf_cnt",          "output", "CNT_W"),
    ("mon_b_bp_cnt",           "output", "CNT_W"),
    ("mon_total_err_cnt",      "output", "CNT_W"),
    ("mon_any_full",           "output", "1"),
    ("mon_any_empty",          "output", "1"),
    ("mon_both_almost_full",   "output", "1"),
    ("mon_both_almost_empty",  "output", "1"),
    ("mon_any_backpressure",   "output", "1"),
    ("mon_bp_event_cnt",       "output", "CNT_W"),
    ("mon_latency_ns",         "output", "32"),
    ("mon_latency_cycles",     "output", "32"),
    ("mon_a_ideal_max_wr_words","output", "32"),
    ("mon_b_ideal_max_wr_words","output", "32"),
    ("mon_status_valid",       "output", "1"),
]

# 对外保留的真实数据通路(其余为观测信号, 走内部 wire + sink)
DUAL_EXTERNAL = {
    "rst_n_async",
    "wr_clk_a", "wr_valid_a", "wr_data_a", "wr_ready_a", "wr_full_a", "wr_almost_full_a",
    "rd_clk_a", "rd_en_a", "rd_ready_a", "rd_data_a", "rd_valid_a", "rd_empty_a", "rd_almost_empty_a",
    "wr_clk_b", "wr_valid_b", "wr_data_b", "wr_ready_b", "wr_full_b", "wr_almost_full_b",
    "rd_clk_b", "rd_en_b", "rd_ready_b", "rd_data_b", "rd_valid_b", "rd_empty_b", "rd_almost_empty_b",
    "clk_mon", "mon_status_word", "dbg_sig",
}

# ---------------------------------------------------------------- single 端口表
SINGLE_PORTS = [
    ("rst_n_async",         "input",  "1"),
    ("dbg_sig",             "output", "8"),
    ("wr_clk",              "input",  "1"),
    ("wr_valid",            "input",  "1"),
    ("wr_data",             "input",  "DW"),
    ("wr_ready",            "output", "1"),
    ("wr_full",             "output", "1"),
    ("full_check",          "output", "1"),
    ("wr_almost_full",      "output", "1"),
    ("wr_data_committed",   "output", "DW"),
    ("wr_data_valid",       "output", "1"),
    ("wr_event_cnt",        "output", "CNT_W"),
    ("overflow_cnt",        "output", "CNT_W"),
    ("overflow_flag_cnt",   "output", "CNT_W"),
    ("wr_used_dbg",         "output", "AW1"),
    ("rd_clk",              "input",  "1"),
    ("rd_en",               "input",  "1"),
    ("rd_ready",            "input",  "1"),
    ("rd_data",             "output", "DW"),
    ("rd_valid",            "output", "1"),
    ("rd_empty",            "output", "1"),
    ("rd_almost_empty",     "output", "1"),
    ("rd_event_cnt",        "output", "CNT_W"),
    ("underflow_cnt",       "output", "CNT_W"),
    ("underflow_flag_cnt",  "output", "CNT_W"),
    ("backpressure_cnt",    "output", "CNT_W"),
    ("backpressure_active", "output", "1"),
    ("rd_used_dbg",         "output", "AW1"),
    ("clk_mon",             "input",  "1"),
    ("rst_n_mon",           "input",  "1"),
    ("wr_event_cnt_sync",   "output", "CNT_W"),
    ("rd_event_cnt_sync",   "output", "CNT_W"),
    ("overflow_cnt_sync",   "output", "CNT_W"),
    ("underflow_cnt_sync",  "output", "CNT_W"),
    ("backpressure_cnt_sync","output", "CNT_W"),
    ("used_sync",           "output", "AW1"),
    ("full_sync",           "output", "1"),
    ("almost_full_sync",    "output", "1"),
    ("empty_sync",          "output", "1"),
    ("almost_empty_sync",   "output", "1"),
]

SINGLE_EXTERNAL = {
    "rst_n_async", "wr_clk", "wr_valid", "wr_data", "wr_ready", "wr_full", "wr_almost_full",
    "rd_clk", "rd_en", "rd_ready", "rd_data", "rd_valid", "rd_empty", "rd_almost_empty",
    "clk_mon", "dbg_sig",
}


def width_bits(w):
    if w == "1":
        return 1
    if w == "DW":
        return 32
    if w == "CNT_W":
        return 32
    if w == "AW1":
        return 9
    return int(w)


def width_decl(w):
    """展开成可直接写在 wire 声明里的位宽片段。"""
    n = width_bits(w)
    return "" if n == 1 else "[%d:0] " % (n - 1)


def gen(name, ports, external, inst_name, module_name, sink_width, sink_fields,
        conn_override=None, param_decl=None, param_pass=None):
    """生成 wrapper 源文件。sink_fields 是 (端口名, 取值位宽) 列表。"""
    L = []
    L.append("`timescale 1ns / 1ps")
    L.append("//=====================================================================")
    L.append("// %s -- synthesis/implementation wrapper (PPA analysis only)" % (name + ".v"))
    L.append("//")
    L.append("// Why this wrapper exists:")
    L.append("//   %s exposes every statistic/debug output on its ports" % module_name)
    L.append("//   (hundreds of pins). xc7a35tcsg324 only has 210 user I/O, so")
    L.append("//   place_design fails with IO overutilization. On a real chip those")
    L.append("//   counters feed internal registers/buses, not package pins.")
    L.append("//")
    L.append("// This wrapper keeps only the real datapath ports and sinks the")
    L.append("// debug bus into a keep-register, so synthesis cannot optimise the")
    L.append("// statistic logic away -- area/timing still reflect the full design.")
    L.append("//")
    L.append("// GENERATED by syn/gen_wrappers.py -- do not edit by hand.")
    L.append("//=====================================================================")
    if param_decl:
        L.append("module %s #(" % name)
        pd = ["    " + x for x in param_decl]
        for i in range(len(pd) - 1):
            L.append(pd[i] + ",")
        L.append(pd[-1])
        L.append(") (")
    else:
        L.append("module %s (" % name)

    ext_ports = [p for p in ports if p[0] in external]
    # clk_mon / rst_n_mon 需要特殊处理(单通道 wrapper 内部生成 rst_n_mon)
    decl = []
    for nm, d, w in ext_ports:
        decl.append("    %-6s wire %s%s" % (d, width_decl(w), nm))
    # 去掉最后一个逗号
    for i in range(len(decl) - 1):
        L.append(decl[i] + ",")
    L.append(decl[-1])
    L.append(");")
    L.append("")

    # 内部 wire
    L.append("    //-------------------- internal observation nets --------------------")
    internal = [p for p in ports if p[0] not in external]
    for nm, d, w in internal:
        if d != "output":
            continue
        L.append("    wire %s%s;" % (width_decl(w), nm))
    L.append("")

    # 例化
    if param_pass:
        L.append("    %s #(" % module_name)
        pp = ["        " + x for x in param_pass]
        for i in range(len(pp) - 1):
            L.append(pp[i] + ",")
        L.append(pp[-1])
        L.append("    ) %s (" % inst_name)
    else:
        L.append("    %s %s (" % (module_name, inst_name))
    over = conn_override or {}
    conns = []
    for nm, d, w in ports:
        if nm == "dbg_sig":       # wrapper-only observation port, not a DUT pin
            continue
        conns.append("        .%-26s (%s)" % (nm, over.get(nm, nm)))
    for i in range(len(conns) - 1):
        L.append(conns[i] + ",")
    L.append(conns[-1])
    L.append("    );")
    L.append("")

    # observation checksum: 让所有统计量参与归约异或并输出,
    # 综合无法把它们当死逻辑优化掉, 面积/时序因此反映完整设计
    ngroups = 8
    L.append("    //-------------------- observation checksum --------------------")
    L.append("    // Every statistic participates in a reduction-XOR so synthesis cannot")
    L.append("    // drop the observing logic. 8 bits are exported for inspection.")
    names = [nm for nm, _ in sink_fields]
    groups = [[] for _ in range(ngroups)]
    for i, nm in enumerate(names):
        groups[i % ngroups].append(nm)
    L.append("    reg [7:0] dbg_sig_r;")
    L.append("    always @(posedge clk_mon or negedge rst_n_async) begin")
    L.append("        if (!rst_n_async) begin")
    L.append("            dbg_sig_r <= 8'd0;")
    L.append("        end else begin")
    L.append("            dbg_sig_r <= {")
    parts = []
    for g in groups:
        if not g:
            parts.append("                1'b0")
        else:
            parts.append("                ^{%s}" % ", ".join(g))
    for i in range(len(parts) - 1):
        L.append(parts[i] + ",")
    L.append(parts[-1])
    L.append("            };")
    L.append("        end")
    L.append("    end")
    L.append("    assign dbg_sig = dbg_sig_r;")
    L.append("")
    L.append("endmodule")
    return "\n".join(L) + "\n"


# ---------------- dual: sink 收录所有非 external 输出(单比特全收, 宽信号截低位)
dual_sink = []
for nm, d, w in DUAL_PORTS:
    if d != "output" or nm in DUAL_EXTERNAL or nm == "mon_status_word":
        continue
    wb = width_bits(w)
    dual_sink.append((nm, 1 if wb == 1 else min(wb, 16)))

dual_src = gen("syn_wrap_dual", DUAL_PORTS, DUAL_EXTERNAL,
               "u_dut", "dual_async_fifo_top", 640, dual_sink,
               param_decl=["parameter integer SYNC_STAGES = 2",
                   "parameter integer READ_MODE     = 0"],
               param_pass=[".SYNC_STAGES (SYNC_STAGES)",
                    ".READ_MODE   (READ_MODE)"])
(SYN_DIR / "syn_wrap_dual.v").write_text(dual_src, encoding="utf-8", newline="\n")
print("syn_wrap_dual.v  sink bits =", sum(width_bits(w) for _, w in dual_sink))

# ---------------- single: rst_n_mon 由 wrapper 内 rst_sync 生成
single_ports = list(SINGLE_PORTS)
single_ext = set(SINGLE_EXTERNAL)
single_sink = []
for nm, d, w in single_ports:
    if d != "output" or nm in single_ext:
        continue
    wb = width_bits(w)
    single_sink.append((nm, 1 if wb == 1 else min(wb, 16)))

single_ext = single_ext - {"rst_n_mon"}
single_src = gen("syn_wrap_single", single_ports, single_ext,
                 "u_fifo_a", "fifo_a", 256, single_sink,
                 conn_override={"rst_n_mon": "rst_n_mon_sync"})
# 在例化前插入 rst_sync 并连接 rst_n_mon
single_src = single_src.replace(
    "    fifo_a u_fifo_a (",
    "    // 监控域复位: 与原设计一致, 异步置位 + 同步释放\n"
    "    wire rst_n_mon_sync;\n"
    "    rst_sync #(.STAGES(2)) u_rst_sync_mon (\n"
    "        .clk(clk_mon), .rst_n_async(rst_n_async), .rst_n_sync(rst_n_mon_sync));\n"
    "\n"
    "    fifo_a u_fifo_a (")

(SYN_DIR / "syn_wrap_single.v").write_text(single_src, encoding="utf-8", newline="\n")
print("syn_wrap_single.v  sink bits =", sum(width_bits(w) for _, w in single_sink))
