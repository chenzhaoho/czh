# -*- coding: utf-8 -*-
"""prepare_sky130_ngspice.py -- 把 SKY130 的 HSPICE 模型转成 ngspice 可读的形式

已解决的四类问题（每一步都实测验证过）：

  1) 未定义参数
     pm3.spice 定义的是 <name>_spectre，而模型体引用的是 <name>；
     ngspice 严格检查，报 `Undefined parameter`。
     -> 生成 param_patch.spice，按 0.0 补齐 8 个缺失参数。

  2) HSPICE 的自动 bin 选择
     pm3 用 `.model <name>.N` + lmin/lmax/wmin/wmax 自动选尺寸；
     ngspice 不支持，实例引用 <name> 时报 `could not find a valid modelname`。
     -> 解析全部 bin 的几何边界，把 DFF 的 24 个器件映射到具体 bin。

  3) 器件类型
     SKY130 网表用 `X` 开头表示任意器件（HSPICE 风格，靠模型名区分）；
     ngspice 要求 X 必须是子电路、MOSFET 必须用 M 开头。
     -> 器件行 X -> M。

  4) 模型名带点号
     ngspice 的 `.model` 名字不能含 '.'（会被当参数分隔），
     `.model name.188` 无法被引用。
     -> `.model name.N` 改名为 `name_N`，网表引用同步改名。

  5) BSIM4 级别
     `.model ... nmos` 在 HSPICE 里是 BSIM4，ngspice 的 nmos 默认 Level 1。
     -> 显式加 `level=54`。

仍未打通（如实记录）：
  完成 1~5 后，ngspice 仍报 `can't find model '<name>_N'`，说明 `.model`
  没有被注册到 ngspice 的模型表。判断是 SKY130 pm3 与 ngspice 47 之间存在
  更深层的语法/作用域不兼容（SkyWater 官方对 ngspice 的支持通常需要
  open_pdks 生成的适配层，本仓库的 pm3 是 HSPICE/Spectre 取向）。
  因此本工程的 tau/T_w 仍以行为模型结果给出，SPICE 表征待适配层补齐。

用法：
    python scripts/prepare_sky130_ngspice.py
    # 产物在 build/spice_test/ 下
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PDK = ROOT / "pdk"
OUT = ROOT / "build" / "spice_test"
OUT.mkdir(parents=True, exist_ok=True)

CFG = json.loads((PDK / "sky130_config.json").read_text(encoding="utf-8"))
SC = CFG["standard_cell_library"]
TR = CFG["transistor_models"]

PM3 = {
    "nfet": PDK / TR["nfet_corner"].replace(".corner.spice", ".pm3.spice"),
    "pfet": PDK / TR["pfet_corner"].replace(".corner.spice", ".pm3.spice"),
}
NETLIST = PDK / SC["spice_netlist"]

SKIP_SUFFIX = ("_01v8", "_hvt", "_lvt", "_hvl", "__model", "_spectre")


# ---------- 1) 参数补丁 ----------
def make_param_patch():
    lines = ["* SKY130 parameter patch for ngspice",
             "* pm3 defines <name>_spectre while the model body uses <name>"]
    seen = set()
    for tag, path in PM3.items():
        txt = path.read_text(encoding="utf-8", errors="replace")
        defined = set(re.findall(r"\.param\s+(sky130_fd_pr__\w+?__\w+)\s*=", txt))
        used = set(re.findall(r"(sky130_fd_pr__\w+?__\w+)", txt))
        for name in sorted(used):
            if name in defined or any(name.endswith(s) for s in SKIP_SUFFIX):
                continue
            if name in seen:
                continue
            seen.add(name)
            lines.append(".param {} = 0.0".format(name))
    p = OUT / "param_patch.spice"
    p.write_text("\n".join(lines) + "\n", encoding="ascii")
    print("[1] 参数补丁: {} 个参数 -> {}".format(len(seen), p.name))
    return len(seen)


# ---------- 2) bin 映射 ----------
def parse_bins(path):
    txt = path.read_text(encoding="utf-8", errors="replace")
    starts = [(m.start(), m.group(1)) for m in
              re.finditer(r"^\s*\.model\s+(sky130_fd_pr__\w+__model)\.(\d+)\s+\w+", txt, re.M)]
    res = []
    for i, (pos, base) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(txt)
        blk = txt[pos:end]
        num = re.match(r"^\s*\.model\s+sky130_fd_pr__\w+__model\.(\d+)", blk)
        def g(k):
            m = re.search(k + r"\s*=\s*([0-9.eE+-]+)", blk)
            return float(m.group(1)) if m else None
        res.append({"name": "{}_{}".format(base, num.group(1)),
                    "lmin": g("lmin"), "lmax": g("lmax"),
                    "wmin": g("wmin"), "wmax": g("wmax")})
    return res


def pick_bin(bins, w_m, l_m):
    for b in bins:
        if None in (b["lmin"], b["lmax"], b["wmin"], b["wmax"]):
            continue
        if (b["lmin"] * 0.999 <= l_m <= b["lmax"] * 1.001 and
                b["wmin"] * 0.999 <= w_m <= b["wmax"] * 1.001):
            return b["name"]
    return None


# ---------- 3+4) 网表重写（X->M、模型名去点、bin 具体化） ----------
def rewrite_netlist(bins_by_kind):
    src = NETLIST.read_text(encoding="utf-8")
    out, stats = [], {"m_converted": 0, "binned": 0, "unmatched": []}
    for line in src.split("\n"):
        s = line
        st = s.strip()
        if st.startswith("X") and "sky130_fd_pr__" in st:
            m_typ = re.search(r"(sky130_fd_pr__\w+)", st)
            m_w = re.search(r"w=([\d.eE+-]+)u", st)
            m_l = re.search(r"l=([\d.eE+-]+)u", st)
            if m_typ and m_w and m_l:
                kind = "nfet" if "nfet" in m_typ.group(1) else "pfet"
                # 420000u 表示 0.42um = 4.2e-7 m
                w_m = float(m_w.group(1)) * 1e-12
                l_m = float(m_l.group(1)) * 1e-12
                bn = pick_bin(bins_by_kind[kind], w_m, l_m)
                if bn:
                    s = st.replace(m_typ.group(1) + " ", bn + " ")
                    stats["binned"] += 1
                else:
                    stats["unmatched"].append((kind, w_m, l_m))
                if s.startswith("X"):
                    s = "M" + s[1:]
                    stats["m_converted"] += 1
        out.append(s)
    p = OUT / "dfxtp_1_ngspice.spice"
    p.write_text("\n".join(out), encoding="utf-8")
    print("[3/4] 网表重写: X->M {} 个, 映射到具体 bin {} 个{}".format(
        stats["m_converted"], stats["binned"],
        "" if not stats["unmatched"] else " , 未匹配 {}".format(stats["unmatched"])))
    return p, stats


# ---------- 5) 模型文件：改名 + level=54 ----------
def rewrite_models():
    for tag, path in PM3.items():
        txt = path.read_text(encoding="utf-8", errors="replace")
        txt = re.sub(r"\.model\s+(sky130_fd_pr__\w+__model)\.(\d+)", r".model \1_\2", txt)
        txt = re.sub(r"(\.model\s+sky130_fd_pr__\w+__model_\d+\s+)(nmos|pmos)\b(?!\s+level)",
                     r"\1\2 level=54", txt)
        dst = OUT / "pm3_{}_ngspice.spice".format(tag)
        dst.write_text(txt, encoding="utf-8")
        n = len(re.findall(r"level=54", txt))
        print("[5] {}: {} 个 .model 改为 level=54 -> {}".format(tag, n, dst.name))


def main():
    print("=" * 72)
    print("SKY130 -> ngspice 适配预处理")
    print("=" * 72)
    make_param_patch()
    bins_by_kind = {k: parse_bins(v) for k, v in PM3.items()}
    for k, b in bins_by_kind.items():
        print("[2] {}: {} 个 bin (带几何边界 {})".format(
            k, len(b), sum(1 for x in b if x["lmin"] is not None)))
    rewrite_netlist(bins_by_kind)
    rewrite_models()
    print("\n产物目录: {}".format(OUT))
    print("=" * 72)


if __name__ == "__main__":
    main()
