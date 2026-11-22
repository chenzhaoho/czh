# -*- coding: utf-8 -*-
"""规范化课程设计报告的 Markdown 源文件。

Markdown 语义: 段落内的单个换行在渲染时等价于空格(软换行), 只有空行才分段。
本脚本据此把"同一段落内的多行"合并为一行, 使 **粗体** 等行内标记不再被换行拆散。
同时:
  * 标题、表格、引用、代码块、列表项各自成行, 不做合并;
  * 不做任何启发式猜测(不依赖"粗体是否闭合"), 因此结果稳定可复现。
"""
import re
from pathlib import Path

SRC = str(Path(__file__).resolve().parents[1] / "doc" / "课程设计报告_双异步FIFO系统.md")
DST = SRC                      # 原地规范化
BAK = SRC + ".bak"

raw = open(SRC, encoding="utf-8").read()
open(BAK, "w", encoding="utf-8", newline="\n").write(raw)

lines = raw.split("\n")
out = []
buf = ""
in_code = False


def flush():
    global buf
    if buf:
        out.append(buf)
        buf = ""


for line in lines:
    s = line.rstrip()
    st = s.strip()

    # 代码块: 原样保留(含内部空行/缩进)
    if st.startswith("```"):
        flush()
        in_code = not in_code
        out.append(s)
        continue
    if in_code:
        out.append(s)
        continue

    # 硬边界: 空行 / 标题 / 表格 / 引用 / 列表项 / 分隔线
    hard = (st == ""
            or st.startswith(("#", "|", ">"))
            or re.match(r"^[-*+]\s+[^\s\u4e00-\u9fff]", st) is not None
            or re.match(r"^[0-9]+\.\s+\S", st) is not None
            or re.match(r"^([-*_])\1{2,}$", st) is not None)
    if hard:
        flush()
        out.append(s)
    else:
        buf = (buf + " " + st).strip() if buf else st

flush()

# 折叠连续空行, 保证文件末尾单个换行
collapsed = []
for s in out:
    if s.strip() == "" and collapsed and collapsed[-1].strip() == "":
        continue
    collapsed.append(s.rstrip())
while collapsed and collapsed[-1].strip() == "":
    collapsed.pop()

open(DST, "w", encoding="utf-8", newline="\n").write("\n".join(collapsed) + "\n")
print(f"规范化完成: {len(lines)} 行 -> {len(collapsed)} 行 (备份 {BAK})")

# 自检: 行内 ** 必须成对
bad = [(i, s[:70]) for i, s in enumerate(collapsed)
       if not s.strip().startswith("```") and s.count("**") % 2]
print("未配对粗体行数:", len(bad))
for i, s in bad[:3]:
    print("   ", i, s)
