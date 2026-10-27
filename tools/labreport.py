"""
Общая часть отчётов по лабораторным в оформлении образца reports/template_lab.docx
(labs/lab05, lab06, lab07 — build_report.py).

Титульный лист берётся из образца (меняются номер лабораторной, тема, вариант, данные студента),
всё после него строится заново. Правила оформления (замечания студента):
  * во всём тексте — только Times New Roman, в том числе в листингах и таблицах;
  * листинг, как рисунок, целиком на одной странице (если не помещается — кегль уменьшается до 7 пт);
  * подписи: «Листинг N.k – …» и «Таблица N.k – …» над объектом, «Рисунок N.k – …» под рисунком по центру;
    на каждый объект — ссылка в тексте до него (nxt()).
"""
import os
import re

import yaml
from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, Twips

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TEMPLATE = os.path.join(ROOT, "reports", "template_lab.docx")
FONT = "Times New Roman"
TEXT_WIDTH = 9350               # ширина текста, dxa (A4, поля образца 3 см и 1,5 см)
PAGE_TEXT_HEIGHT = 700          # пт: высота текста страницы (поля 2 см) минус подпись листинга


def read(*parts):
    with open(os.path.join(*parts), encoding="utf-8", newline="") as f:
        # выводы psql, снятые на Windows, бывают с концами строк \r\r\n
        return f.read().replace("\r\n", "\n").replace("\r", "")


# ------------------------------------------------------------------ разбор выводов psql и EXPLAIN
def trim(lines):
    while lines and not lines[0].strip():
        lines = lines[1:]
    while lines and not lines[-1].strip():
        lines = lines[:-1]
    return lines


def parse_psql(lines):
    """Таблица psql в выравненном формате -> (колонки, строки). Первая найденная таблица."""
    for i in range(len(lines) - 1):
        if lines[i].strip() and re.fullmatch(r"-+(\+-+)*", lines[i + 1].strip()):
            ncol = lines[i + 1].count("+") + 1
            cols = [c.strip() for c in lines[i].split("|")]
            rows = []
            for ln in lines[i + 2:]:
                if not ln.strip() or ln.startswith("("):
                    break
                cells = [c.strip() for c in ln.split("|")]
                if len(cells) > ncol:
                    cells = cells[:ncol - 1] + [" | ".join(cells[ncol - 1:])]
                rows.append(cells)
            return cols, rows
    return None, []


def all_psql_tables(lines):
    """Все таблицы psql в блоке строк по порядку."""
    out, i = [], 0
    while i < len(lines) - 1:
        if lines[i].strip() and re.fullmatch(r"-+(\+-+)*", lines[i + 1].strip()):
            cols, rows = parse_psql(lines[i:])
            out.append((cols, rows))
            i += 2 + len(rows)
        else:
            i += 1
    return out


def plan_lines(lines):
    """План EXPLAIN без служебных строк: узлы, условия, отброшенные строки, время выполнения."""
    keep = ("Index Cond:", "Recheck Cond:", "Filter:", "Rows Removed by Filter:", "Hash Cond:",
            "Join Filter:", "Execution Time:")
    out = []
    for ln in trim(lines):
        s = ln.strip()
        if "(cost=" in s or s.startswith(keep):
            ln = re.sub(r" width=\d+", "", ln.rstrip())
            ln = re.sub(r"rows=(\d+)\.00", r"rows=\1", ln)
            out.append(ln)
    return out


def sql_text(lines):
    return [ln.rstrip() for ln in trim(lines)]


def extract_query(sql_path, name):
    """Сам запрос из файла миграции: SELECT представления (без CREATE VIEW) или выборка RETURN QUERY функции
    (без заголовка, объявлений и проверок); комментарии убираются, общий отступ снимается."""
    text = read(sql_path)
    if name.startswith("v_"):
        head = text.index(f"CREATE OR REPLACE VIEW api.{name}")
        start = text.index("SELECT", head)
    else:
        head = text.index(f"CREATE OR REPLACE FUNCTION api.{name}(")
        start = text.index("RETURN QUERY", head) + len("RETURN QUERY")
        while text[start] in " \n":
            start += 1
    out = []
    for ln in text[text.rindex("\n", 0, start) + 1:].splitlines():
        if ln.strip().startswith("--"):
            continue
        m = re.search(r"\s+--\s", ln)               # комментарий в конце строки (в строковых литералах «--» нет)
        out.append((ln[:m.start()] if m else ln).rstrip())
        if out[-1].endswith(";"):                   # конец запроса — «;» вне комментария
            break
    indent = min(len(ln) - len(ln.lstrip()) for ln in out if ln.strip())
    return [ln[indent:] for ln in out]


def num(s):
    """«21 906.12» -> «21 906,12» (запятая — десятичный разделитель в тексте отчёта)."""
    return s.replace(".", ",")


def unmd(s):
    return s.replace("`", "").replace("**", "")


# ------------------------------------------------------------------ документ
TBLPR_ORDER = ["tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblStyleRowBandSize", "tblStyleColBandSize",
               "tblW", "jc", "tblCellSpacing", "tblInd", "tblBorders", "shd", "tblLayout", "tblCellMar", "tblLook"]


def _tnr(rpr):
    rf = rpr.find(qn("w:rFonts"))
    if rf is None:
        rf = OxmlElement("w:rFonts")
        rpr.insert(0, rf)
    for a in list(rf.attrib):
        if a.endswith("Theme"):
            del rf.attrib[a]
    for a in ("w:ascii", "w:hAnsi", "w:cs", "w:eastAsia"):
        rf.set(qn(a), FONT)


def _set_text(p, text):
    runs = p.runs
    runs[0].text = text
    for r in runs[1:]:
        r._r.getparent().remove(r._r)


class Report:
    def __init__(self, lab, topic):
        self.lab = lab
        self.topic = topic
        self.count = {"Таблица": 0, "Листинг": 0, "Рисунок": 0}
        self.listings = []                  # (номер, последняя строка) — для проверки разрывов по PDF
        meta = yaml.safe_load(read(ROOT, "reports", "meta.yaml"))
        d = self.d = Document(TEMPLATE)
        P = d.paragraphs
        # титульный лист (абзацы образца, как в labs/lab01/build_report.py)
        _set_text(P[10], f" к лабораторной работе № {lab}")
        _set_text(P[12], f"На тему: «{topic}»")
        _set_text(P[13], f"Вариант {meta['variant_short']}")
        _set_text(P[22], f"студент гр. {meta['group']}")
        P[23].runs[0].text = meta["student"]
        _set_text(P[25], meta["teacher_senior"])
        _set_text(P[27], meta["teacher_lab"])
        # только Times New Roman: прогоны и знаки абзацев титульного листа, стили, маркеры списка
        for p in P[:43]:
            for r in p.runs:
                _tnr(r._r.get_or_add_rPr())
            ppr = p._p.pPr
            if ppr is not None and ppr.find(qn("w:rPr")) is not None:
                _tnr(ppr.find(qn("w:rPr")))
        for rpr in d.styles.element.iter(qn("w:rPr")):
            _tnr(rpr)
        for lvl in d.part.numbering_part.element.iter(qn("w:lvl")):
            lt = lvl.find(qn("w:lvlText"))
            if lt is not None and lvl.find(qn("w:numFmt")).get(qn("w:val")) == "bullet":
                lt.set(qn("w:val"), "•")
            rpr = lvl.find(qn("w:rPr"))
            if rpr is not None:
                _tnr(rpr)
        # всё после титульного листа (ход работы ЛР 1 образца) удаляется, включая последний пустой абзац
        # титульного листа: новая страница начинается разрывом перед «Лабораторная работа №…»
        body = d.element.body
        start = P[43]._p
        remove, found = [], False
        for el in list(body):
            if el is start:
                found = True
            if found and el.tag != qn("w:sectPr"):
                remove.append(el)
        for el in remove:
            body.remove(el)
        for rid, rel in list(d.part.rels.items()):          # картинки образца
            if rel.reltype.endswith("/image"):
                d.part.drop_rel(rid)
        self.sect = body.find(qn("w:sectPr"))

    # ---------------------------------------------------------- абзацы
    def _append(self, el):
        self.sect.addprevious(el)
        return el

    @staticmethod
    def _run(p, text, size=14, bold=False):
        r = p.add_run(text)
        r.font.size = Pt(size)
        r.bold = bold or None
        r.font.name = FONT
        _tnr(r._r.get_or_add_rPr())
        return r

    def para(self, text="", indent=True, align=None, size=14, bold=False, keep_next=False, page_break=False,
             space_before=0, space_after=0):
        p = self.d.add_paragraph()
        self._append(p._p)
        pf = p.paragraph_format
        if indent:
            pf.first_line_indent = Pt(35.45)          # 1,25 см, как в образце (w:firstLine=709)
        if align == "center":
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        elif align == "justify":
            p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        pf.keep_with_next = keep_next or None
        pf.page_break_before = page_break or None
        pf.space_before = Pt(space_before)
        pf.space_after = Pt(space_after)
        if text:
            # `код` в тексте — тем же шрифтом (только Times New Roman), обратные кавычки убираются
            for part in re.split(r"`", text):
                if part:
                    self._run(p, part, size=size, bold=bold)
        return p

    def h(self, text):
        self.para(text, bold=True, keep_next=True, space_before=6)

    def bullets(self, items):
        for it in items:
            p = self.para(it, align="justify")
            ppr = p._p.get_or_add_pPr()
            numpr = OxmlElement("w:numPr")
            for tag, val in (("w:ilvl", "0"), ("w:numId", "1")):   # маркированный список образца
                e = OxmlElement(tag)
                e.set(qn("w:val"), val)
                numpr.append(e)
            ppr.insert(0, numpr)

    def header(self, goal, task, requirements):
        """Шапка как в образце: номер и тема, цель, задание, требования, «Ход работы»."""
        self.para(f"Лабораторная работа №{self.lab}", indent=False, align="center", page_break=True)
        self.para(f"«{self.topic}»", indent=False, align="center")
        self.para("", indent=False)
        self.para(f"Цель работы: {goal}", align="justify")
        self.para("")
        self.para("Задание", indent=False, align="center")
        self.para("")
        self.para(task, align="justify")
        self.para("")
        self.para("Требования к выполняемой работе")
        self.bullets(requirements)
        self.para("")
        self.para("Ход работы", indent=False, align="center")
        self.para("")

    # ---------------------------------------------------------- подписи
    def nxt(self, kind, k=1):
        """Номер k-го следующего объекта вида kind (ссылка в тексте ставится до самого объекта)."""
        return f"{self.lab}.{self.count[kind] + k}"

    def caption(self, kind, text):
        self.count[kind] += 1
        self.para(f"{kind} {self.lab}.{self.count[kind]} – {text}", indent=False, keep_next=True, space_before=6)

    # ---------------------------------------------------------- таблицы
    @staticmethod
    def _tblpr(tbl, widths, center=False, size=4):
        """Ширина, рамка, фиксированная раскладка — элементы tblPr в порядке схемы WordprocessingML."""
        tblpr = tbl._tbl.tblPr
        for tag in ("tblW", "jc", "tblBorders", "tblLayout"):
            for e in tblpr.findall(qn("w:" + tag)):
                tblpr.remove(e)
        tw = OxmlElement("w:tblW")
        tw.set(qn("w:w"), str(sum(widths)))
        tw.set(qn("w:type"), "dxa")
        tblpr.append(tw)
        if center:
            jc = OxmlElement("w:jc")
            jc.set(qn("w:val"), "center")
            tblpr.append(jc)
        b = OxmlElement("w:tblBorders")
        for side in ("top", "left", "bottom", "right", "insideH", "insideV"):
            e = OxmlElement(f"w:{side}")
            e.set(qn("w:val"), "single")
            e.set(qn("w:sz"), str(size))
            e.set(qn("w:space"), "0")
            e.set(qn("w:color"), "000000")
            b.append(e)
        tblpr.append(b)
        lay = OxmlElement("w:tblLayout")
        lay.set(qn("w:type"), "fixed")
        tblpr.append(lay)
        kids = sorted(list(tblpr), key=lambda e: TBLPR_ORDER.index(e.tag.split("}")[1])
                      if e.tag.split("}")[1] in TBLPR_ORDER else 99)
        for e in kids:
            tblpr.remove(e)
        for e in kids:
            tblpr.append(e)
        grid = tbl._tbl.tblGrid
        for gc, w in zip(grid.findall(qn("w:gridCol")), widths):
            gc.set(qn("w:w"), str(w))
        for row in tbl.rows:
            for cell, w in zip(row.cells, widths):
                cell.width = Twips(w)

    def _cell_text(self, cell, text, size=10, bold=False, align=None):
        p = cell.paragraphs[0]
        p.paragraph_format.space_after = Pt(0)
        if align == "center":
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        self._run(p, text, size=size, bold=bold)

    @staticmethod
    def _is_mono(v, j, mono_cols):
        """«Машинное» значение (JSON, путь): мельче кеглем, колонка делит остаток ширины."""
        return j in mono_cols or v[:1] in "{[" or v.startswith('"')

    def auto_widths(self, cols, rows, mono_cols=()):
        """Ширины колонок: короткие значения (даты, числа, телефоны — до 18 знаков) не переносятся и получают
        ширину по самому длинному значению; длинный текст и JSON делят остаток ширины."""
        n = len(cols)
        per_char = 95                                    # dxa на знак: Times New Roman 9–10 пт
        fixed, weight = {}, {}
        for j in range(n):
            vals = [r[j] if j < len(r) else "" for r in rows]
            mono = any(self._is_mono(v, j, mono_cols) for v in vals)
            longest = max([len(w) for w in cols[j].split()]
                          + [len(v) for v in vals if not self._is_mono(v, j, mono_cols)] + [3])
            if not mono and longest <= 18:
                fixed[j] = longest * per_char + 200
            else:
                weight[j] = 40 if mono else min(longest, 40)
        rest = TEXT_WIDTH - sum(fixed.values())
        if weight and rest < 1500 * len(weight):          # не помещается — все колонки пропорционально
            need = [fixed.get(j, weight.get(j, 0) * per_char) for j in range(n)]
            total = sum(need)
            return [int(TEXT_WIDTH * w / total) for w in need]
        if not weight:                                     # только короткие колонки — растянуть на ширину
            total = sum(fixed.values())
            return [int(TEXT_WIDTH * fixed[j] / total) for j in range(n)]
        wsum = sum(weight.values())
        return [fixed[j] if j in fixed else int(rest * weight[j] / wsum) for j in range(n)]

    def table(self, cols, rows, widths=None, size=10, mono_cols=(), max_rows=None):
        if max_rows is not None:
            rows = rows[:max_rows]
        n = len(cols)
        if widths is None:
            widths = self.auto_widths(cols, rows, mono_cols)
        tbl = self.d.add_table(rows=1 + len(rows), cols=n)
        self._append(tbl._tbl)
        self._tblpr(tbl, widths, center=True)
        for j, c in enumerate(cols):
            self._cell_text(tbl.cell(0, j), c, size=size, bold=True, align="center")
        trpr = tbl.rows[0]._tr.get_or_add_trPr()          # шапка повторяется на следующей странице
        trpr.append(OxmlElement("w:tblHeader"))
        for i, r in enumerate(rows, start=1):
            for j in range(n):
                v = r[j] if j < len(r) else ""
                self._cell_text(tbl.cell(i, j), v, size=9 if self._is_mono(v, j, mono_cols) else size)
        self.para("", indent=False)

    def result(self, lines, title, max_rows=5):
        """Результат запроса — таблица psql из вывода (первые строки)."""
        cols, rows = parse_psql(lines)
        self.caption("Таблица", title)
        self.table(cols, rows, max_rows=max_rows, size=9)

    # ---------------------------------------------------------- листинги и рисунки
    @staticmethod
    def _listing_height(lines, size):
        """Оценка высоты листинга, пт: строки с переносами (Times New Roman — ~0,45 кегля на знак)."""
        per_line = int(TEXT_WIDTH / 20 / (size * 0.45))       # знаков в строке
        n = sum(max(1, -(-len(ln.rstrip()) // per_line)) for ln in lines)
        return n * size * 1.16 + 8

    def code(self, lines, size=10):
        """Листинг: рамка из одной ячейки, Times New Roman, строки как есть. Листинг, как рисунок, целиком
        на одной странице: строка таблицы не разрывается (cantSplit), подпись держится с ним (keep_with_next);
        если листинг выше страницы — кегль уменьшается до 7 пт."""
        while size > 7 and self._listing_height(lines, size) > PAGE_TEXT_HEIGHT:
            size -= 0.5
        if self._listing_height(lines, size) > PAGE_TEXT_HEIGHT:
            print(f"ВНИМАНИЕ: листинг {self.lab}.{self.count['Листинг']} не помещается на страницу")
        tbl = self.d.add_table(rows=1, cols=1)
        self._append(tbl._tbl)
        self._tblpr(tbl, [TEXT_WIDTH])
        tbl.rows[0]._tr.get_or_add_trPr().append(OxmlElement("w:cantSplit"))
        cell = tbl.cell(0, 0)
        for k, ln in enumerate(lines):
            p = cell.paragraphs[0] if k == 0 else cell.add_paragraph()
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.0
            p.paragraph_format.keep_with_next = k < len(lines) - 1 or None
            p.paragraph_format.keep_together = True
            self._run(p, ln.rstrip() if ln.strip() else " ", size=size)
        self.listings.append((f"{self.lab}.{self.count['Листинг']}",
                              next((ln.strip() for ln in reversed(lines) if ln.strip()), "")))
        self.para("", indent=False)

    def figure(self, path, title, width_cm=16.5, max_height_cm=21.0):
        """Рисунок по центру и подпись под ним — как «Рисунок 1.1» образца; высота ограничена страницей."""
        from PIL import Image
        if not os.path.exists(path):                      # снимка ещё нет — видимая заглушка
            print("ВНИМАНИЕ: нет снимка", path)
            self.para(f"[ВСТАВИТЬ СНИМОК {os.path.basename(path)}]", indent=False, align="center", keep_next=True,
                      space_before=6)
            self.count["Рисунок"] += 1
            self.para(f"Рисунок {self.lab}.{self.count['Рисунок']} – {title}", indent=False, align="center",
                      space_after=6)
            return
        w, h = Image.open(path).size
        width_cm = min(width_cm, max_height_cm * w / h)
        p = self.para("", indent=False, align="center", keep_next=True, space_before=6)
        p.add_run().add_picture(path, width=Cm(width_cm))
        self.count["Рисунок"] += 1
        self.para(f"Рисунок {self.lab}.{self.count['Рисунок']} – {title}", indent=False, align="center",
                  space_after=6)

    # ---------------------------------------------------------- сохранение
    def save(self, out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        self.d.save(out)
        if os.environ.get("LISTINGS_TXT"):      # «номер листинга — последняя строка» для проверки разрывов по PDF
            with open(os.environ["LISTINGS_TXT"], "w", encoding="utf-8") as f:
                for no, last in self.listings:
                    f.write(f"{no}\t{last}\n")
        print("Готово:", out)
        print("Таблиц:", self.count["Таблица"], "листингов:", self.count["Листинг"], "рисунков:", self.count["Рисунок"])
