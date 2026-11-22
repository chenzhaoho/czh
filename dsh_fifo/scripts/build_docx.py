# -*- coding: utf-8 -*-
"""Markdown -> DOCX converter for the course design report.

结构: 封面 + 目录(静态清单 + TOC 域) + 正文(标题/表格/代码块/列表)

关键处理:
  1) 预处理器把"同一段落内的软换行"合并为一行, 使跨行的 **粗体** 标记能被识别;
  2) 表格总宽固定为版心宽度(15.5cm), 列宽按各列内容长度加权分配;
  3) 中文使用宋体/黑体, 西文使用 Times New Roman, 代码使用 Consolas。
"""
import os
import re
from pathlib import Path
from docx import Document
from docx.shared import Pt, Cm
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "doc" / "课程设计报告_双异步FIFO系统.md"
DST = SRC.with_suffix(".docx")

PAGE_W_TW = 8790          # 版心宽度 15.5cm, 单位 twip
HEAD_FONTS = {1: 15, 2: 13, 3: 11.5, 4: 11}

doc = Document()

normal = doc.styles["Normal"]
normal.font.name = "Times New Roman"
normal.font.size = Pt(10.5)
normal.element.rPr.rFonts.set(qn("w:eastAsia"), "宋体")
normal.paragraph_format.line_spacing = 1.15
normal.paragraph_format.space_after = Pt(3)

sec = doc.sections[0]
# ??? A4 ???????? Letter(21.59cm ?), ???? 15.5cm ??
# ?????/?????, ????????????
sec.page_width  = Cm(21.0)
sec.page_height = Cm(29.7)
sec.top_margin = Cm(2.5); sec.bottom_margin = Cm(2.5)
sec.left_margin = Cm(3.0); sec.right_margin = Cm(2.5)


def set_font(run, cn="宋体", en="Times New Roman", size=None, bold=None, italic=None):
    run.font.name = en
    run._element.rPr.rFonts.set(qn("w:eastAsia"), cn)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if italic is not None:
        run.italic = italic


def add_page_break():
    doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)


def add_runs(par, text):
    """把 **粗体** 与 `代码` 标记转换成带格式的 run。"""
    for part in re.split(r"(\*\*.+?\*\*)", text):
        if part.startswith("**") and part.endswith("**") and len(part) > 4:
            set_font(par.add_run(re.sub(r"`([^`]*)`", r"\1", part[2:-2])), bold=True)
        else:
            set_font(par.add_run(re.sub(r"`([^`]*)`", r"\1", part)))


# ---------------------------------------------------------------- 读入 + 合并软换行
raw = open(SRC, encoding="utf-8").read()
paras = []
buf = ""
in_code = False
for line in raw.split("\n"):
    s = line.rstrip()
    st = s.strip()
    # 代码块必须原样保留: 若让下面的软换行合并逻辑处理, 多行代码会被空格
    # 拼成一行, 生成 docx 时既没有 <w:br/> 也丢失缩进, 代码全部糊在一起。
    if st.startswith("```"):
        if buf:
            paras.append(buf)
            buf = ""
        in_code = not in_code
        paras.append(s)
        continue
    if in_code:
        paras.append(s)
        continue
    open_bold = (buf.count("**") % 2 == 1)
    is_block = (st == "" or st.startswith(("#", "|", ">", "```", "!["))
                or re.match(r"^\s*[-*]\s+\S", s) is not None
                or re.match(r"^\s*[0-9]+\.\s+\S", s) is not None)
    if is_block and not open_bold:
        if buf:
            paras.append(buf)
            buf = ""
        paras.append(s)
    else:
        buf = (buf + " " + st).strip() if buf else st
if buf:
    paras.append(buf)

# ---------------------------------------------------------------- 封面
for _ in range(2):
    doc.add_paragraph()
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
set_font(p.add_run("课 程 设 计 报 告"), cn="黑体", size=26, bold=True)
doc.add_paragraph()
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
set_font(p.add_run("题目一：双异步 FIFO 系统"), cn="黑体", size=16, bold=True)
for _ in range(3):
    doc.add_paragraph()

info = doc.add_table(rows=0, cols=2)
info.alignment = 1
info.autofit = False
_tblPr = info._tbl.tblPr
_tw = OxmlElement("w:tblW"); _tw.set(qn("w:type"), "dxa"); _tw.set(qn("w:w"), "6120")
_tblPr.append(_tw)
_bd = OxmlElement("w:tblBorders")
for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
    e = OxmlElement("w:" + edge); e.set(qn("w:val"), "none"); _bd.append(e)
_tblPr.append(_bd)
_g = OxmlElement("w:tblGrid")
for w in (1930, 4190):
    gc = OxmlElement("w:gridCol"); gc.set(qn("w:w"), str(w)); _g.append(gc)
info._tbl.insert(list(info._tbl).index(_tblPr) + 1, _g)

for k, v in [("课程名称", "硬件描述语言"), ("实验名称", "双异步 FIFO 系统设计与验证"),
             ("学生学院", ""), ("专业班级", ""), ("学    号", ""), ("学生姓名", "")]:
    cells = info.add_row().cells
    cells[0].width = Cm(3.4); cells[1].width = Cm(7.4)
    p0 = cells[0].paragraphs[0]; p0.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    set_font(p0.add_run(k + "："), cn="黑体", size=14)
    p1 = cells[1].paragraphs[0]
    r = p1.add_run(v if v else "　　　　　　　　　　")
    set_font(r, size=14)
    if not v:
        r.underline = True

for _ in range(4):
    doc.add_paragraph()
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
set_font(p.add_run("2026 年 10 月"), cn="黑体", size=14)
add_page_break()

# ---------------------------------------------------------------- 目录
p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
set_font(p.add_run("目  录"), cn="黑体", size=18, bold=True)
for line in paras:
    m = re.match(r"^(#{1,3})\s+(.*)$", line.strip())
    if not m:
        continue
    lvl = len(m.group(1))
    if lvl == 1:
        continue
    txt = re.sub(r"[`*]", "", m.group(2)).strip()
    tp = doc.add_paragraph()
    tp.paragraph_format.line_spacing = 1.12
    tp.paragraph_format.left_indent = Cm(0.6 * (lvl - 2))
    tp.paragraph_format.space_after = Pt(2)
    set_font(tp.add_run(txt), cn="黑体" if lvl == 2 else "宋体",
             size=11.5 if lvl == 2 else 10.5, bold=(lvl == 2))
doc.add_paragraph()
tp = doc.add_paragraph()
fld = OxmlElement("w:fldSimple")
fld.set(qn("w:instr"), r'TOC \o "1-3" \h \z \u')
rr = OxmlElement("w:r"); tt = OxmlElement("w:t")
tt.text = "（在 Word 中选中本节后按 F9 可生成带页码的目录）"
rr.append(tt); fld.append(rr); tp._p.append(fld)
add_page_break()

# ---------------------------------------------------------------- 正文
i = 0
first_h1 = True
while i < len(paras):
    line = paras[i]
    st = line.strip()

    if st.startswith("```"):
        code = []
        i += 1
        while i < len(paras) and not paras[i].strip().startswith("```"):
            code.append(paras[i])
            i += 1
        i += 1
        cp = doc.add_paragraph()
        cp.paragraph_format.left_indent = Cm(0.7)
        cp.paragraph_format.line_spacing = 1.0
        cp.paragraph_format.space_after = Pt(5)
        # 用中文等宽字体(新宋体): Consolas 在本机缺失, LibreOffice 回退后
        # 宽度计算不准, 长行会越过右边距; 新宋体对中英文都是等宽, 断行可靠
        set_font(cp.add_run("\n".join(code)), cn="新宋体", en="NSimSun", size=7.5)
        continue

    if st == "" or st in ("---", "***"):
        i += 1
        continue

    # 图片：![alt](相对路径)  居中插入，宽度限制在版心内
    _mimg = re.match(r"^!\[(.*?)\]\((.+?)\)\s*$", st)
    if _mimg:
        _alt, _rel = _mimg.group(1), _mimg.group(2)
        _cands = [
            os.path.join(os.path.dirname(SRC), _rel),
            os.path.join(ROOT, _rel),
            _rel,
        ]
        _img = next((c for c in _cands if os.path.exists(c)), None)
        if _img:
            try:
                _p = doc.add_paragraph()
                _p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                _p.paragraph_format.space_before = Pt(6)
                _p.paragraph_format.space_after = Pt(2)
                _p.add_run().add_picture(_img, width=Cm(15.4))
            except Exception as _e:
                doc.add_paragraph("[图片插入失败: {} — {}]".format(_rel, _e))
        else:
            doc.add_paragraph("[图片缺失: {}]".format(_rel))
        i += 1
        continue

    # 表格
    if st.startswith("|") and i + 1 < len(paras) and re.match(r"^\|[\s\-:|]+\|\s*$", paras[i + 1].strip()):
        rows = []
        while i < len(paras) and paras[i].strip().startswith("|"):
            cells = [c.strip() for c in paras[i].strip().strip("|").split("|")]
            if not re.match(r"^[\s\-:]+$", "".join(cells)):
                rows.append(cells)
            i += 1
        ncol = max(len(r) for r in rows)
        wmax = [max((len(r[c]) for r in rows if c < len(r)), default=1) for c in range(ncol)]
        tot = sum(wmax) or 1
        colw = [max(900, int(PAGE_W_TW * w / tot)) for w in wmax]
        # ?????????????????, ??????????
        s = sum(colw)
        if s > PAGE_W_TW:
            scale = PAGE_W_TW / float(s)
            colw = [max(700, int(c * scale)) for c in colw]
        colw[-1] = max(700, colw[-1] + (PAGE_W_TW - sum(colw)))
        tb = doc.add_table(rows=0, cols=ncol)
        tb.style = "Table Grid"
        tb.autofit = False
        _tp = tb._tbl.tblPr
        # python-docx 已经在 tblPr 里放了默认的 tblW(值为 0, type=auto)。
        # 直接 append 会出现两个 tblW, 生效的是默认那个 -> 表格按内容自动撑宽,
        # 越过版心, 连带把后续正文也推出去。必须先删掉再写。
        for _tag in ("w:tblW", "w:tblInd", "w:tblLayout", "w:tblCellMar"):
            _old = _tp.find(qn(_tag))
            if _old is not None:
                _tp.remove(_old)
        _w = OxmlElement("w:tblW"); _w.set(qn("w:type"), "dxa"); _w.set(qn("w:w"), str(PAGE_W_TW))
        _tp.append(_w)
        # Word/LibreOffice ???????????????, ????????????,
        # ?????????????????, ???????????????
        _ind = OxmlElement("w:tblInd"); _ind.set(qn("w:type"), "dxa"); _ind.set(qn("w:w"), "0")
        _tp.append(_ind)
        _mar = OxmlElement("w:tblCellMar")
        for _side, _v in (("left", "28"), ("right", "28"), ("top", "0"), ("bottom", "0")):
            _e = OxmlElement("w:" + _side)
            _e.set(qn("w:w"), _v); _e.set(qn("w:type"), "dxa")
            _mar.append(_e)
        _tp.append(_mar)
        _lay = OxmlElement("w:tblLayout"); _lay.set(qn("w:type"), "fixed")
        _tp.append(_lay)
        _g0 = tb._tbl.find(qn("w:tblGrid"))
        if _g0 is not None:
            tb._tbl.remove(_g0)
        _g = OxmlElement("w:tblGrid")
        for c in range(ncol):
            gc = OxmlElement("w:gridCol"); gc.set(qn("w:w"), str(colw[c])); _g.append(gc)
        tb._tbl.insert(list(tb._tbl).index(_tp) + 1, _g)
        for ri, row in enumerate(rows):
            cells = tb.add_row().cells
            for ci in range(ncol):
                txt = row[ci] if ci < len(row) else ""
                cells[ci].text = ""
                cells[ci].width = Cm(15.5 * colw[ci] / PAGE_W_TW)
                pr = cells[ci].paragraphs[0]
                pr.paragraph_format.line_spacing = 1.0
                pr.paragraph_format.space_after = Pt(1)
                set_font(pr.add_run(re.sub(r"[`*]", "", txt)), size=8.5, bold=(ri == 0))
        doc.add_paragraph()
        continue

    # 标题
    m = re.match(r"^(#{1,4})\s+(.*)$", st)
    if m:
        lvl = len(m.group(1))
        txt = re.sub(r"[`*]", "", m.group(2)).strip()
        if lvl == 1 and first_h1:
            first_h1 = False
            hp = doc.add_paragraph(); hp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            set_font(hp.add_run(txt), cn="黑体", size=17, bold=True)
            i += 1
            continue
        if lvl == 2 and txt.startswith("题目一"):
            hp = doc.add_paragraph(); hp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            set_font(hp.add_run(txt), cn="黑体", size=14, bold=True)
            i += 1
            continue
        hp = doc.add_heading(txt, level=min(max(lvl - 1, 1), 4))
        for r in hp.runs:
            set_font(r, cn="黑体", size=HEAD_FONTS.get(lvl, 11), bold=True)
        i += 1
        continue

    # 引用
    if st.startswith(">"):
        qp = doc.add_paragraph()
        qp.paragraph_format.left_indent = Cm(0.8)
        qp.paragraph_format.line_spacing = 1.2
        add_runs(qp, st[1:].strip())
        for r in qp.runs:
            r.italic = True
            r.font.size = Pt(10)
        i += 1
        continue

    # 无序列表
    m = re.match(r"^[-*]\s+(.*)$", st)
    if m:
        lp = doc.add_paragraph()
        lp.paragraph_format.left_indent = Cm(0.9)
        lp.paragraph_format.first_line_indent = Cm(-0.45)
        set_font(lp.add_run("· "), bold=True)
        add_runs(lp, m.group(1))
        i += 1
        continue

    # 有序列表
    m = re.match(r"^([0-9]+)\.\s+(.*)$", st)
    if m:
        lp = doc.add_paragraph()
        lp.paragraph_format.left_indent = Cm(0.75)
        lp.paragraph_format.first_line_indent = Cm(-0.75)
        set_font(lp.add_run(m.group(1) + ". "))
        add_runs(lp, m.group(2))
        i += 1
        continue

    # 普通段落
    pp = doc.add_paragraph()
    add_runs(pp, st)
    i += 1

doc.save(DST)
print("saved:", DST)
