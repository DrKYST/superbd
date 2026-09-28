#!/usr/bin/env python3
"""
md2docx.py — сборка отчётов по лабораторным и пояснительной записки в .docx по ГОСТ 7.32 / 2.105
из упрощённого Markdown. Зависимости: pip install python-docx pyyaml

Использование:
  python tools/md2docx/md2docx.py labs/lab02/report.md -o labs/lab02/out/lab02.docx --kind lab --lab 2
  python tools/md2docx/md2docx.py coursework/pz/_pz.md -o coursework/out/pz.docx --kind pz

Поддерживаемый синтаксис (подробно — tools/md2docx/README.md):
  ---yaml---               фронтматтер: topic, lab, kind (перекрывает ключи командной строки)
  # ВВЕДЕНИЕ               уровень 1 без номера  -> структурный заголовок (по центру, прописными)
  # 1 Описание ...         заголовок с номером   -> с абзацного отступа, полужирный
  ## Задание               уровень 2+ без номера -> полужирный с абзацного отступа
  - пункт / 1. пункт       перечисления: «–» и «1)»; вложенность 2 пробела -> «а)»
  Таблица: Название {#tab:key}   подпись перед pipe-таблицей
  Листинг: Название {#lst:key}   подпись перед блоком ```кода```
  ![Название](path.png){#fig:key}  рисунок; нет файла -> заглушка «ВСТАВИТЬ СКРИНШОТ»
  [@fig:key]               ссылка -> номер рисунка/таблицы/листинга
  **жирный** *курсив* `код`
  \\newpage                разрыв страницы
  [[TOC]]                  поле оглавления (обновить в Word: F9)
"""
import argparse
import os
import re
import sys

try:
    import yaml
    from docx import Document
    from docx.enum.section import WD_SECTION
    from docx.enum.table import WD_TABLE_ALIGNMENT
    from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK, WD_LINE_SPACING, WD_COLOR_INDEX
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Cm, Mm, Pt
except ImportError as e:  # pragma: no cover
    sys.exit(f"Не хватает зависимости ({e}). Выполните: pip install python-docx pyyaml")

FONT = "Times New Roman"
MONO = "Courier New"
INDENT = Cm(1.25)
TEXT_WIDTH_MM = 170  # 210 - 30 - 10
RU_LETTERS = "абвгдежиклмнпрстуфхцшщэюя"  # без ё з й о ч ъ ы ь (ГОСТ 7.32)

# ---------------------------------------------------------------- утилиты стиля

def set_run_font(run, name=FONT, size=None, bold=None, italic=None):
    run.font.name = name
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    for attr in ("w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"):
        rfonts.set(qn(attr), name)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if italic is not None:
        run.italic = italic


def setup_document():
    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Mm(210), Mm(297)
    sec.left_margin, sec.right_margin = Mm(30), Mm(10)
    sec.top_margin, sec.bottom_margin = Mm(20), Mm(25)
    st = doc.styles["Normal"]
    st.font.name = FONT
    st.font.size = Pt(14)
    rpr = st.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    for attr in ("w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"):
        rfonts.set(qn(attr), FONT)
    # русский язык для переносов
    lang = OxmlElement("w:lang")
    lang.set(qn("w:val"), "ru-RU")
    rpr.append(lang)
    pf = st.paragraph_format
    pf.first_line_indent = INDENT
    pf.line_spacing_rule = WD_LINE_SPACING.ONE_POINT_FIVE
    pf.space_before = Pt(0)
    pf.space_after = Pt(0)
    pf.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
    pf.widow_control = True
    # автоматический перенос слов
    settings = doc.settings.element
    auto = OxmlElement("w:autoHyphenation")
    auto.set(qn("w:val"), "true")
    settings.append(auto)
    return doc


def add_page_numbers(doc):
    sec = doc.sections[0]
    sec.different_first_page_header_footer = True  # титульный лист без номера
    p = sec.footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.first_line_indent = Cm(0)
    run = p.add_run()
    set_run_font(run, size=14)
    for kind, text in (("begin", None), (None, "PAGE"), ("end", None)):
        if kind:
            el = OxmlElement("w:fldChar")
            el.set(qn("w:fldCharType"), kind)
        else:
            el = OxmlElement("w:instrText")
            el.set(qn("xml:space"), "preserve")
            el.text = text
        run._r.append(el)


def para(doc, text="", align=None, indent=True, bold=None, size=None, spacing=None, keep_next=False):
    p = doc.add_paragraph()
    if align is not None:
        p.alignment = align
    if not indent:
        p.paragraph_format.first_line_indent = Cm(0)
    if spacing == 1:
        p.paragraph_format.line_spacing_rule = WD_LINE_SPACING.SINGLE
    if keep_next:
        p.paragraph_format.keep_with_next = True
    if text:
        r = p.add_run(text)
        set_run_font(r, size=size, bold=bold)
    return p


def page_break(doc):
    p = doc.add_paragraph()
    p.paragraph_format.first_line_indent = Cm(0)
    p.add_run().add_break(WD_BREAK.PAGE)


def add_toc(doc):
    para(doc, "СОДЕРЖАНИЕ", align=WD_ALIGN_PARAGRAPH.CENTER, indent=False, bold=True)
    p = doc.add_paragraph()
    p.paragraph_format.first_line_indent = Cm(0)
    run = p.add_run()
    for kind, text in (("begin", None), (None, 'TOC \\o "1-2" \\h \\z \\u'), ("separate", None)):
        if kind:
            el = OxmlElement("w:fldChar")
            el.set(qn("w:fldCharType"), kind)
        else:
            el = OxmlElement("w:instrText")
            el.set(qn("xml:space"), "preserve")
            el.text = text
        run._r.append(el)
    r2 = p.add_run("Оглавление: нажмите F9 (Обновить поле) после открытия в Word.")
    set_run_font(r2, italic=True)
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    r2._r.append(end)

# ---------------------------------------------------------------- inline разметка

INLINE_RE = re.compile(r"(\*\*[^*]+\*\*|\*[^*\s][^*]*\*|`[^`]+`|\[@[\w:.-]+\])")


def add_inline(p, text, refs, size=None, mono_size=None):
    for part in INLINE_RE.split(text):
        if not part:
            continue
        if part.startswith("**") and part.endswith("**"):
            set_run_font(p.add_run(part[2:-2]), size=size, bold=True)
        elif part.startswith("`") and part.endswith("`"):
            set_run_font(p.add_run(part[1:-1]), name=MONO, size=mono_size or (size or 14) - 2)
        elif part.startswith("[@") and part.endswith("]"):
            key = part[2:-1]
            r = p.add_run(str(refs.get(key, f"??{key}??")))
            set_run_font(r, size=size)
            if key not in refs:
                r.font.highlight_color = WD_COLOR_INDEX.YELLOW
        elif part.startswith("*") and part.endswith("*") and len(part) > 2:
            set_run_font(p.add_run(part[1:-1]), size=size, italic=True)
        else:
            set_run_font(p.add_run(part), size=size)

# ---------------------------------------------------------------- разбор документа

LABEL_RE = re.compile(r"\s*\{#([\w:.-]+)\}\s*$")
FIG_RE = re.compile(r"^!\[(?P<cap>[^\]]*)\]\((?P<path>[^)]+)\)(?:\{#(?P<key>[\w:.-]+)\})?\s*$")
HEAD_RE = re.compile(r"^(#{1,4})\s+(.*)$")
NUM_HEAD_RE = re.compile(r"^(\d+(?:\.\d+)*)\s+\S")
UL_RE = re.compile(r"^(\s*)[-*+]\s+(.*)$")
OL_RE = re.compile(r"^(\s*)\d+[.)]\s+(.*)$")


def split_label(text):
    m = LABEL_RE.search(text)
    if m:
        return text[: m.start()].strip(), m.group(1)
    return text.strip(), None


def parse_blocks(lines):
    """Разбить Markdown на блоки: (тип, данные)."""
    blocks, i, n = [], 0, len(lines)
    buf = []

    def flush():
        if buf:
            blocks.append(("p", " ".join(s.strip() for s in buf)))
            buf.clear()

    while i < n:
        line = lines[i].rstrip("\n")
        s = line.strip()
        if not s:
            flush(); i += 1; continue
        if s.startswith("<!--"):
            flush()
            while i < n and "-->" not in lines[i]:
                i += 1
            i += 1; continue
        if s.startswith("```"):
            flush()
            lang = s[3:].strip()
            code = []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                code.append(lines[i].rstrip("\n"))
                i += 1
            blocks.append(("code", {"lang": lang, "lines": code}))
            i += 1; continue
        if s in ("\\newpage", "\\pagebreak"):
            flush(); blocks.append(("pagebreak", None)); i += 1; continue
        if s == "[[TOC]]":
            flush(); blocks.append(("toc", None)); i += 1; continue
        m = HEAD_RE.match(s)
        if m:
            flush(); blocks.append(("h", (len(m.group(1)), m.group(2).strip()))); i += 1; continue
        m = FIG_RE.match(s)
        if m:
            flush(); blocks.append(("fig", m.groupdict())); i += 1; continue
        if s.startswith("|"):
            flush()
            rows = []
            while i < n and lines[i].strip().startswith("|"):
                row = lines[i].strip().strip("|")
                cells = [c.strip() for c in re.split(r"(?<!\\)\|", row)]
                if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
                    rows.append([c.replace("\\|", "|") for c in cells])
                i += 1
            blocks.append(("table", rows)); continue
        if s.startswith("Таблица:") or s.startswith("Листинг:"):
            flush()
            kind = "tabcap" if s.startswith("Таблица:") else "lstcap"
            blocks.append((kind, split_label(s.split(":", 1)[1])))
            i += 1; continue
        mu, mo = UL_RE.match(line), OL_RE.match(line)
        if mu or mo:
            flush()
            items = []
            while i < n:
                l2 = lines[i].rstrip("\n")
                mu, mo = UL_RE.match(l2), OL_RE.match(l2)
                if mu:
                    items.append((len(mu.group(1)) // 2, "ul", mu.group(2)))
                elif mo:
                    items.append((len(mo.group(1)) // 2, "ol", mo.group(2)))
                elif l2.strip() and l2.startswith("  ") and items:
                    lvl, kind, t = items[-1]
                    items[-1] = (lvl, kind, t + " " + l2.strip())
                else:
                    break
                i += 1
            blocks.append(("list", items)); continue
        buf.append(line)
        i += 1
    flush()
    return blocks


def number_objects(blocks, appendix_letter_for=None):
    """Сквозная нумерация рисунков, таблиц, листингов; в приложениях — «А.1»."""
    refs, counters, letter = {}, {"fig": 0, "tab": 0, "lst": 0}, None
    numbered = []
    for kind, data in blocks:
        if kind == "h":
            m = re.match(r"^ПРИЛОЖЕНИЕ\s+([А-Я])", data[1].upper())
            if m and data[0] == 1:
                letter = m.group(1)
                counters = {"fig": 0, "tab": 0, "lst": 0}
        key = None
        if kind == "fig":
            key, obj = data.get("key"), "fig"
        elif kind == "tabcap":
            key, obj = data[1], "tab"
        elif kind == "lstcap":
            key, obj = data[1], "lst"
        else:
            numbered.append((kind, data, None)); continue
        counters[obj] += 1
        num = f"{letter}.{counters[obj]}" if letter else str(counters[obj])
        if key:
            refs[key] = num
        numbered.append((kind, data, num))
    return numbered, refs

# ---------------------------------------------------------------- рендеринг


def render_heading(doc, level, text, kind, first_block):
    struct = level == 1 and not NUM_HEAD_RE.match(text)
    if kind == "pz" and level == 1 and not first_block:
        page_break(doc)
    if struct:
        lines = text.split(" // ")  # «ПРИЛОЖЕНИЕ А // Руководство пользователя»
        for j, t in enumerate(lines):
            p = para(doc, align=WD_ALIGN_PARAGRAPH.CENTER, indent=False, keep_next=True)
            r = p.add_run(t.upper() if j == 0 else t)
            set_run_font(r, bold=True)
            if j == 0:
                p.style = doc.styles["Heading 1"] if "Heading 1" in doc.styles else p.style
                fix_heading_style(p)
    else:
        p = para(doc, keep_next=True)
        p.alignment = WD_ALIGN_PARAGRAPH.LEFT
        r = p.add_run(text)
        set_run_font(r, bold=True)
        style_name = f"Heading {min(level, 3)}"
        p.style = doc.styles[style_name]
        fix_heading_style(p)
        p.paragraph_format.first_line_indent = INDENT
    # пустая строка после заголовка
    para(doc)


def fix_heading_style(p):
    """Заголовочные стили Word по умолчанию синие и Calibri — привести к ГОСТ, но оставить уровень для оглавления."""
    st = p.style
    st.font.name = FONT
    st.font.size = Pt(14)
    st.font.bold = True
    st.font.italic = False
    st.font.color.rgb = None
    rpr = st.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts"); rpr.append(rfonts)
    for attr in ("w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"):
        rfonts.set(qn(attr), FONT)
    for attr in ("w:asciiTheme", "w:hAnsiTheme", "w:eastAsiaTheme", "w:cstheme"):
        if rfonts.get(qn(attr)) is not None:
            del rfonts.attrib[qn(attr)]
    color = rpr.find(qn("w:color"))
    if color is not None:
        rpr.remove(color)
    pf = st.paragraph_format
    pf.space_before, pf.space_after = Pt(0), Pt(0)
    pf.line_spacing_rule = WD_LINE_SPACING.ONE_POINT_FIVE
    pf.keep_with_next = True
    for r in p.runs:
        r.font.color.rgb = None


def render_list(doc, items, refs):
    counters, kinds = {}, {}
    for lvl, kind, text in items:
        counters = {k: v for k, v in counters.items() if k <= lvl}
        if kinds.get(lvl) != kind:  # смена типа списка на том же уровне — счёт заново
            counters[lvl] = 0
            kinds[lvl] = kind
        counters[lvl] = counters.get(lvl, 0) + 1
        c = counters[lvl]
        if lvl == 0:
            marker = "–" if kind == "ul" else f"{c})"
        elif lvl == 1:
            marker = f"{RU_LETTERS[(c - 1) % len(RU_LETTERS)]})"
        else:
            marker = f"{c})"
        p = doc.add_paragraph()
        p.paragraph_format.first_line_indent = INDENT
        if lvl:
            p.paragraph_format.left_indent = Cm(1.25 * lvl)
        set_run_font(p.add_run(marker + " "))
        add_inline(p, text, refs)


def render_table(doc, rows, refs):
    if not rows:
        return
    ncols = max(len(r) for r in rows)
    t = doc.add_table(rows=len(rows), cols=ncols)
    t.style = "Table Grid"
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for ri, row in enumerate(rows):
        for ci in range(ncols):
            cell = t.cell(ri, ci)
            cell.text = ""
            p = cell.paragraphs[0]
            p.paragraph_format.first_line_indent = Cm(0)
            p.paragraph_format.line_spacing_rule = WD_LINE_SPACING.SINGLE
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER if ri == 0 else WD_ALIGN_PARAGRAPH.LEFT
            txt = row[ci] if ci < len(row) else ""
            add_inline(p, txt, refs, size=12, mono_size=11)
            if ri == 0:
                for r in p.runs:
                    r.bold = True
    # повторять шапку на каждой странице
    trpr = t.rows[0]._tr.get_or_add_trPr()
    th = OxmlElement("w:tblHeader")
    th.set(qn("w:val"), "true")
    trpr.append(th)
    para(doc)  # пустая строка после таблицы


def render_code(doc, lines):
    for line in lines or [""]:
        p = doc.add_paragraph()
        pf = p.paragraph_format
        pf.first_line_indent = Cm(0)
        pf.line_spacing_rule = WD_LINE_SPACING.SINGLE
        pf.alignment = WD_ALIGN_PARAGRAPH.LEFT
        r = p.add_run(line.replace("\t", "    ") if line else " ")
        set_run_font(r, name=MONO, size=10)
    para(doc)


def render_figure(doc, data, num, base_dir, refs):
    path = os.path.join(base_dir, data["path"])
    caption = data["cap"].strip()
    if os.path.isfile(path):
        p = para(doc, align=WD_ALIGN_PARAGRAPH.CENTER, indent=False, keep_next=True)
        try:
            from docx.image.image import Image as DocxImage
            img = DocxImage.from_file(path)
            w_mm = img.px_width / (img.horz_dpi or 96) * 25.4
            width = Mm(min(w_mm, TEXT_WIDTH_MM - 5))
        except Exception:
            width = Mm(TEXT_WIDTH_MM - 5)
        p.add_run().add_picture(path, width=width)
    else:
        t = doc.add_table(rows=1, cols=1)
        t.style = "Table Grid"
        t.alignment = WD_TABLE_ALIGNMENT.CENTER
        cp = t.cell(0, 0).paragraphs[0]
        cp.alignment = WD_ALIGN_PARAGRAPH.CENTER
        cp.paragraph_format.first_line_indent = Cm(0)
        for txt in ("\n\nВСТАВИТЬ СКРИНШОТ", f"\nфайл: {data['path']}", f"\n{caption}\n\n"):
            r = cp.add_run(txt)
            set_run_font(r, size=12, bold=txt.strip().startswith("ВСТАВИТЬ"))
            r.font.highlight_color = WD_COLOR_INDEX.YELLOW
        print(f"  [!] нет файла рисунка: {data['path']} — вставлена заглушка", file=sys.stderr)
    p = para(doc, align=WD_ALIGN_PARAGRAPH.CENTER, indent=False)
    add_inline(p, f"Рисунок {num} — {caption}", refs)
    para(doc)


def render_caption(doc, word, text, num, refs):
    p = para(doc, align=WD_ALIGN_PARAGRAPH.LEFT, indent=False, keep_next=True)
    add_inline(p, f"{word} {num} — {text}", refs)

# ---------------------------------------------------------------- титульные листы


def title_lines(doc, lines):
    for text, opts in lines:
        p = para(doc, align=opts.get("align", WD_ALIGN_PARAGRAPH.CENTER), indent=False, spacing=1)
        if text:
            r = p.add_run(text)
            set_run_font(r, size=opts.get("size", 14), bold=opts.get("bold", False))


def title_page(doc, meta, kind, lab_no, topic):
    C, R = WD_ALIGN_PARAGRAPH.CENTER, WD_ALIGN_PARAGRAPH.RIGHT
    head = [
        ("МИНИСТЕРСТВО НАУКИ И ВЫСШЕГО ОБРАЗОВАНИЯ РОССИЙСКОЙ ФЕДЕРАЦИИ", {"size": 12}),
        ("ФЕДЕРАЛЬНОЕ ГОСУДАРСТВЕННОЕ БЮДЖЕТНОЕ ОБРАЗОВАТЕЛЬНОЕ УЧРЕЖДЕНИЕ ВЫСШЕГО ОБРАЗОВАНИЯ", {"size": 12}),
        (f"«{meta.get('university', 'ДОНЕЦКИЙ НАЦИОНАЛЬНЫЙ ТЕХНИЧЕСКИЙ УНИВЕРСИТЕТ')}»", {"size": 12, "bold": True}),
        ("", {}),
        (meta.get("faculty", "Факультет интеллектуальных систем и программирования"), {}),
        (meta.get("department", "Кафедра «Программная инженерия» им. Л. П. Фельдмана"), {}),
    ]
    title_lines(doc, head)
    for _ in range(5):
        para(doc, indent=False)
    discipline = meta.get("discipline", "Программирование систем с серверами баз данных")
    if kind == "lab":
        body = [
            ("ОТЧЁТ", {"bold": True, "size": 16}),
            (f"по лабораторной работе № {lab_no}", {}),
            (f"по дисциплине «{discipline}»", {}),
            (f"на тему: «{topic}»", {"bold": True}),
            (f"Вариант {meta.get('variant', 'Б-16')}", {}),
        ]
    else:
        body = [
            ("ПОЯСНИТЕЛЬНАЯ ЗАПИСКА", {"bold": True, "size": 16}),
            ("к курсовому проекту по курсу", {}),
            (f"«{discipline}»", {}),
            ("", {}),
            ("Тема работы:", {}),
            (f"«{topic}»", {"bold": True}),
        ]
    title_lines(doc, body)
    for _ in range(4):
        para(doc, indent=False)
    group, student = meta.get("group", "ПИ-__"), meta.get("student", "Фамилия И. О.")
    if kind == "lab":
        sign = [
            (f"Выполнил: ст. гр. {group}", {"align": R}),
            (f"{student}", {"align": R}),
            ("", {}),
            ("Проверил:", {"align": R}),
            (f"{meta.get('teacher_lab', 'Фамилия И. О.')}", {"align": R}),
        ]
    else:
        sign = [
            ("Руководители:", {"align": R}),
            (f"лектор {meta.get('teacher_lecture', 'Фамилия И. О.')}", {"align": R}),
            (f"ассистент {meta.get('teacher_lab', 'Фамилия И. О.')}", {"align": R}),
            ("", {}),
            (f"Разработал: ст. гр. {group}", {"align": R}),
            (f"{student} ____________ (подпись) ________ (дата)", {"align": R}),
        ]
    title_lines(doc, sign)
    for _ in range(4 if kind == "lab" else 2):
        para(doc, indent=False)
    title_lines(doc, [(f"{meta.get('city', 'Донецк')} – {meta.get('year', '2026')}", {})])
    page_break(doc)

# ---------------------------------------------------------------- main


def load_meta(md_path, explicit):
    candidates = [explicit] if explicit else []
    d = os.path.abspath(os.path.dirname(md_path))
    while True:
        candidates.append(os.path.join(d, "reports", "meta.yaml"))
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    for c in candidates:
        if c and os.path.isfile(c):
            with open(c, encoding="utf-8") as f:
                return yaml.safe_load(f) or {}, c
    return {}, None


def main():
    ap = argparse.ArgumentParser(description="Markdown -> .docx по ГОСТ")
    ap.add_argument("src")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--kind", choices=["lab", "pz", "plain"], default=None)
    ap.add_argument("--lab", type=int, default=None)
    ap.add_argument("--topic", default=None)
    ap.add_argument("--meta", default=None, help="путь к meta.yaml (по умолчанию ищется reports/meta.yaml вверх по дереву)")
    a = ap.parse_args()

    with open(a.src, encoding="utf-8") as f:
        text = f.read()
    front = {}
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            front = yaml.safe_load(text[3:end]) or {}
            text = text[end + 4:]
    kind = a.kind or front.get("kind", "lab")
    lab_no = a.lab or front.get("lab")
    topic = a.topic or front.get("topic", "ТЕМА НЕ УКАЗАНА")
    meta, meta_path = load_meta(a.src, a.meta)
    if not meta_path:
        print("  [!] reports/meta.yaml не найден — на титульном листе будут заглушки", file=sys.stderr)

    blocks = parse_blocks(text.splitlines())
    numbered, refs = number_objects(blocks)

    doc = setup_document()
    add_page_numbers(doc)
    if kind in ("lab", "pz"):
        title_page(doc, meta, kind, lab_no, topic)

    base_dir = os.path.dirname(os.path.abspath(a.src))
    first = True
    for kind_b, data, num in numbered:
        if kind_b == "h":
            render_heading(doc, data[0], data[1], kind, first)
        elif kind_b == "p":
            p = doc.add_paragraph()
            add_inline(p, data, refs)
        elif kind_b == "list":
            render_list(doc, data, refs)
        elif kind_b == "table":
            render_table(doc, data, refs)
        elif kind_b == "code":
            render_code(doc, data["lines"])
        elif kind_b == "fig":
            render_figure(doc, data, num, base_dir, refs)
        elif kind_b == "tabcap":
            render_caption(doc, "Таблица", data[0], num, refs)
        elif kind_b == "lstcap":
            render_caption(doc, "Листинг", data[0], num, refs)
        elif kind_b == "pagebreak":
            page_break(doc)
        elif kind_b == "toc":
            add_toc(doc)
        first = False

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    doc.save(a.out)
    missing = [k for k in re.findall(r"\[@([\w:.-]+)\]", text) if k not in refs]
    if missing:
        print(f"  [!] неизвестные ссылки: {', '.join(sorted(set(missing)))}", file=sys.stderr)
    print(f"Готово: {a.out}")


if __name__ == "__main__":
    main()
