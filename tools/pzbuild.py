"""
Сборка пояснительной записки курсового проекта: coursework/pz/*.md -> coursework/out/pz.docx (+ PDF и проверки).

    python tools/pzbuild.py              # .docx, PDF, оглавление с номерами страниц, проверки
    python tools/pzbuild.py --no-pdf     # только .docx (оглавление без номеров страниц)

Оформление — по образцу tools/labreport.py и шаблону tools/md2docx/templates/pz-template.docx (стили, поля,
номер страницы вверху справа) и обязательным требованиям студента (.claude/rules/reports.md):
  * только Times New Roman — в тексте, таблицах, коде, подписях, титульном листе, ТЗ, колонтитулах;
  * код в основной части — рисунок: в рамке только код (целиком на одной странице), под рамкой — «Рисунок N.k – …»;
  * весь документ ≤ TOTAL_LIMIT страниц (курсовой целиком около 100 с. с учётом недописанного), бюджет — BUDGET;
  * в тексте нет ссылок на ТЗ, источников ≤ 4, ссылка — на один источник [N];
  * код в приложениях — только текст кода (без подписей), сплошь в три колонки, 11 пт, ключевые объекты в сокращении;
  * «Таблица N.k – …» над таблицей; ссылка на каждый объект в тексте до него; нумерация внутри раздела,
    в приложениях — с буквой.
Код в рисунки и листинги вырезается из реальных файлов проекта (db/, client/) — вручную не переписывается.

Синтаксис исходников (порядок файлов — coursework/pz/_order.txt):
  # 1 Название раздела            раздел (с новой страницы, прописными); # ВВЕДЕНИЕ — структурный заголовок по центру
  # ПРИЛОЖЕНИЕ А // Название        приложение (две строки по центру)
  ## 1.1 Подраздел / ### 1.1.1 Пункт
  обычные абзацы (строки подряд склеиваются), «- пункт» — список с тире, «1. пункт» — нумерованный «1)»
  Таблица: Название {#tab:key}     перед pipe-таблицей; {#tab:key widths=20,30,50} — ширины колонок в процентах
  ![Название](путь.png){#fig:key width=16}            рисунок (нет файла — видимая заглушка);
      crop=form|main|x0,y0,x1,y1 — обрезка снимка клиента, trim — пустой низ, squeeze — пустые полосы внутри;
      ph=<см> — высота места под ещё не снятый снимок (заглушка занимает столько же, сколько снимок)
  ![А](a.png){#fig:a} ![Б](b.png){#fig:b}             два снимка в одной строке — рядом, у каждого своя подпись
  !code[Название](путь#селектор){#fig:key}            код-рисунок основной части
  !listing[Название](путь#селектор){#lst:key}         код приложения: без подписи, сплошь в три колонки (название — для сборщика)
  !stub[текст || подробности]      видимая заглушка «[ЗАГЛУШКА: текст]» + запись в coursework/out/pz_todo.md
  !tz  !toc  !pagebreak            ТЗ (coursework/tz/tz.docx), содержание, разрыв страницы
  [@fig:key] [@tab:key] [@lst:key] номер объекта; {{PAGES}} {{FIGURES}} {{TABLES}} {{SOURCES}} {{APPENDICES}} — для реферата
Селекторы кода: #view:api.v_x  #func:api.f  #query:api.f (выборка RETURN QUERY)  #table:core.t  #stmt:<начало>
  #lines:10-40  #class:Name (C++ .h)  #method:Class::method (C++ .cpp)  #file (весь файл); суффикс «;full» — без сокращения.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

import yaml
from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls, qn
from docx.shared import Cm, Pt, Twips

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PZ = os.path.join(ROOT, "coursework", "pz")
OUT = os.path.join(ROOT, "coursework", "out")
TEMPLATE = os.path.join(ROOT, "tools", "md2docx", "templates", "pz-template.docx")
TZ_DOCX = os.path.join(ROOT, "coursework", "tz", "tz.docx")
FONT = "Times New Roman"
TEXT_WIDTH = 9638          # dxa: A4, поля шаблона 3 см и 1 см
TEXT_HEIGHT_PT = 714       # высота текста страницы (поля 2 и 2,5 см)
DASH = "–"
TOTAL_LIMIT = 92           # страниц всего сейчас; весь курсовой ≤ ~100 с. вместе с недописанными частями
# бюджет по разделам на 28.10.2026 (сумма 90); недописанное (4.3, 4.5, 4.6, 4.8, формы раздела 5, тесты) —
# из резерва ~10 с., при дописывании сокращать другие части, чтобы весь документ оставался около 100 с.
# 30.10: запросы 17–23 и 4.6 (+3 с. в разделе 4, +1 с. в 6) — за счёт листингов приложений сплошь в три колонки (−4 с.)
# 30.10 вечер: вставлены все снимки (схема данных, pgAdmin 17–23, секции, группы) — раздел 4 +2 с.; заглушки
# снимков больше нет, резерв — только под ненаписанное (триггеры, RLS, модифицируемое представление, формы ≈ 6–8 с.)
BUDGET = {"front": 12, "1": 3, "2": 3, "3": 5, "4": 38, "5": 8, "6": 4, "tail": 3,
          "А": 2, "Б": 4, "В": 3, "Г": 3, "Д": 2, "Е": 2}


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read().replace("\r\n", "\n").replace("\r", "")


# ====================================================================== вырезка кода из файлов проекта
def _sql_statement_end(lines, start):
    """Индекс последней строки SQL-оператора, начатого в start (учитываются $$-тела функций)."""
    dollar = None
    for i in range(start, len(lines)):
        s = lines[i]
        for m in re.finditer(r"\$[A-Za-z_]*\$", s):
            tag = m.group(0)
            if dollar is None:
                dollar = tag
            elif tag == dollar:
                dollar = None
        code = re.sub(r"--.*$", "", s) if "'" not in s else s
        if dollar is None and code.rstrip().endswith(";"):
            return i
    return len(lines) - 1


def _find(lines, pattern, path):
    rx = re.compile(pattern)
    for i, s in enumerate(lines):
        if rx.search(s):
            return i
    raise SystemExit(f"pzbuild: в {path} не найдено: {pattern}")


def _brace_end(lines, start):
    depth, seen = 0, False
    for i in range(start, len(lines)):
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', lines[i].split("//")[0])
        depth += code.count("{") - code.count("}")
        seen = seen or "{" in code
        if seen and depth <= 0:
            return i
    return len(lines) - 1


def extract(spec, md_dir):
    """Строки кода по селектору «путь#вид:имя». Путь — от корня репозитория (или от .md, если начинается с ../)."""
    path, _, sel = spec.partition("#")
    full = os.path.normpath(os.path.join(md_dir if path.startswith("..") else ROOT, path))
    lines = read(full).split("\n")
    kind, _, name = sel.partition(":")
    kind = kind.split(";")[0]
    name = name.split(";")[0]
    if kind in ("", "file"):
        out = lines
    elif kind == "lines":                       # lines:10-20 или lines:10-12,30-35 (пропуск — «…»)
        out = []
        for k, rng in enumerate(name.split(",")):
            a, b = (int(x) for x in rng.split("-"))
            part = lines[a - 1:b]
            if k:
                ind = len(part[0]) - len(part[0].lstrip()) if part else 0
                out.append(" " * ind + "…")
            out += part
    elif kind in ("view", "func", "table", "stmt"):
        pat = {"view": rf"CREATE (OR REPLACE )?VIEW {re.escape(name)}\b",
               "func": rf"CREATE (OR REPLACE )?FUNCTION {re.escape(name)}\(",
               "table": rf"CREATE TABLE (IF NOT EXISTS )?{re.escape(name)}\b",
               "stmt": re.escape(name)}[kind]
        i = _find(lines, pat, path)
        out = lines[i:_sql_statement_end(lines, i) + 1]
    elif kind == "query":
        i = _find(lines, rf"CREATE (OR REPLACE )?FUNCTION {re.escape(name)}\(", path)
        j = next(k for k in range(i, len(lines)) if "RETURN QUERY" in lines[k])
        body = "\n".join(lines[j:])
        body = body[body.index("RETURN QUERY") + len("RETURN QUERY"):].lstrip(" \n")
        start = len(lines[j]) - len(lines[j].lstrip())
        out = []
        for s in body.split("\n"):
            out.append(s)
            if re.sub(r"\s+--\s.*$", "", s).rstrip().endswith(";"):
                break
        out[0] = " " * start + out[0]
    elif kind == "class":
        i = _find(lines, rf"^(class|struct) {re.escape(name)}\b(?!;)", path)
        j = next(k for k in range(i, len(lines)) if lines[k].startswith("};"))
        out = lines[i:j + 1]
    elif kind == "method":
        i = _find(lines, rf"^[\w:<>,\s\*&]*\b{re.escape(name)}\(", path)
        out = lines[i:_brace_end(lines, i) + 1]
    else:
        raise SystemExit(f"pzbuild: неизвестный селектор {sel}")
    return out


def strip_comments(lines, lang):
    """Убрать строки-комментарии и комментарии в конце строки; общий отступ снять; пустые строки подряд — одну."""
    out = []
    in_block = False
    for s in lines:
        t = s.strip()
        if lang == "cpp":
            if in_block:
                if "*/" in t:
                    in_block = False
                continue
            if t.startswith("/*"):
                in_block = "*/" not in t
                continue
            if t.startswith("//"):
                continue
            s = re.sub(r"\s+//\s.*$", "", s)
        else:
            if t.startswith("--"):
                continue
            s = re.sub(r"\s+--\s.*$", "", s)
        s = s.rstrip()
        if not s and (not out or not out[-1]):
            continue
        out.append(s)
    while out and not out[-1]:
        out.pop()
    ind = min((len(s) - len(s.lstrip()) for s in out if s.strip()), default=0)
    return [s[ind:] for s in out]


KEY_SQL = re.compile(r"^\s*(CREATE|RETURNS|RETURN|SELECT|FROM|JOIN|LEFT JOIN|RIGHT JOIN|WHERE|GROUP BY|HAVING|UNION|"
                     r"WINDOW|ORDER BY|INSERT|UPDATE|DELETE|GRANT|REVOKE|ALTER|IF |PERFORM|RAISE|CASE|WITH|"
                     r"SECURITY|LANGUAGE|SET |CONSTRAINT|FOR EACH|BEFORE|AFTER|EXECUTE)", re.I)
KEY_CPP = re.compile(r"^\s*(class|struct|public|private|signals|slots|Q_OBJECT|[\w:<>\*&\s]+\w+\(.*\)\s*(const)?\s*[;{]?$|"
                     r"return|if \(|for \(|while \(|connect\(|emit|ApiCall::|m_\w+\s*=)")


def abbreviate(lines, lang, limit=34):
    """Ключевой фрагмент объекта, по которому понятно, что это за код; пропуски — «…».
    SQL-функция: первая строка заголовка, RETURNS / LANGUAGE / SECURITY, затем главный оператор тела.
    Прочий SQL и C++: начало объекта, строки с ключевыми конструкциями, конец."""
    if len(lines) <= limit:
        return lines
    n = len(lines)
    keep = set()
    if lang == "sql" and re.match(r"\s*CREATE (OR REPLACE )?FUNCTION", lines[0], re.I):
        hdr = next((i for i, s in enumerate(lines) if re.search(r"(^|\s)AS\s+\$[A-Za-z_]*\$\s*$", s)
                    or re.fullmatch(r"\s*\$[A-Za-z_]*\$\s*", s)), 0)
        keep.update({0, 1, hdr})
        keep.update(i for i in range(1, hdr) if re.match(r"\s*(RETURNS|LANGUAGE|SECURITY|SET )", lines[i], re.I))
        body = next((i for i in range(hdr + 1, n) if re.match(
            r"\s*(RETURN QUERY|RETURN \(|INSERT|UPDATE|DELETE|WITH|SELECT|EXECUTE|CREATE ROLE|GRANT)", lines[i], re.I)),
            hdr + 1)
        budget = max(6, limit - len(keep) - 2)
        keep.update(range(body, min(n - 2, body + budget)))
        keep.update({n - 2, n - 1})
    else:
        rx = KEY_SQL if lang == "sql" else KEY_CPP
        keep.update(range(min(4, n)))
        keep.update({n - 1})
        for i, s in enumerate(lines):
            if len(keep) >= limit:
                break
            if rx.search(s):
                keep.add(i)
    out, prev = [], -1
    for i in sorted(keep):
        if i != prev + 1:
            ind = len(lines[i]) - len(lines[i].lstrip())
            out.append(" " * ind + "…")
        out.append(lines[i])
        prev = i
    return out


GROUPS = {"grp_operator": "О", "grp_manager": "Р", "grp_chief": "ГА", "grp_admin": "АП", "grp_dba": "АБД"}


def api_table():
    """Таблица объектов схемы api по миграциям: вид, назначение (COMMENT ON), группы (GRANT)."""
    import glob
    objs = {}
    for f in sorted(glob.glob(os.path.join(ROOT, "db", "migrations", "*.sql"))):
        text = read(f)
        for m in re.finditer(r"CREATE (?:OR REPLACE )?(FUNCTION|VIEW) api\.(\w+)", text):
            objs.setdefault(m.group(2), {"kind": "функция" if m.group(1) == "FUNCTION" else "представление",
                                         "comment": "", "groups": set()})
        for m in re.finditer(r"COMMENT ON (?:FUNCTION|VIEW) api\.(\w+)(?:\([^)]*\))?\s+IS\s+((?:'(?:[^']|'')*'\s*\|*\s*)+)",
                             text, re.S):
            parts = re.findall(r"'((?:[^']|'')*)'", m.group(2))
            if m.group(1) in objs:
                objs[m.group(1)]["comment"] = "".join(parts).replace("''", "'")
        for m in re.finditer(r"GRANT\s+(?:EXECUTE ON FUNCTION|SELECT ON)\s+(.*?)\s+TO\s+([^;]+);", text, re.S):
            groups = re.findall(r"grp_\w+", m.group(2))
            for name in re.findall(r"api\.(\w+)", m.group(1)):
                if name in objs:
                    objs[name]["groups"].update(groups)
    rows = [["Объект", "Вид", "Назначение", "Группы"]]
    order = ["grp_operator", "grp_manager", "grp_chief", "grp_admin", "grp_dba"]
    for name in sorted(objs, key=lambda n: (objs[n]["kind"] != "представление", n)):
        o = objs[name]
        if re.match(r"^(Запрос \d+|Отчёт «)", o["comment"]):
            continue                               # запросы описаны в подразделе 4.7 (объём ПЗ)
        c = re.sub(r"\s*\(D\d+\)", "", o["comment"])
        src = r"\((?:ЛР \d|ТЗ курсового проекта)\)"          # источник вида запроса — не для ПЗ
        m = re.match(rf"^(Запрос \d+[а-я]?) {src}\.\s*(.*)$", c) or re.match(rf"^(Отчёт «[^»]+») {src}:\s*(.*)$", c)
        prefix = (m.group(1) + ". ") if m else ""
        c = m.group(2) if m else c
        short = re.split(r";\s|\s—\s|:\s|\s\(|,\s+у\s", c)[0].strip().rstrip(".")
        if len(short) < 15:
            short = re.sub(r"\s*\((true|false)\)", "", re.split(r";\s", c)[0]).strip().rstrip(".")
        c = prefix + short[:1].upper() + short[1:]
        g = ", ".join(GROUPS[x] for x in order if x in o["groups"])
        rows.append([f"api.{name}", o["kind"], c, g])
    return ("Представления и функции схемы api, кроме запросов", "tab:api-objects", {"widths": "28,18,40,14", "size": "10"}, rows)


def file_list(lang):
    """Состав файлов приложения: файл, строк, объекты — для приложений Б и В (что не вошло в листинги)."""
    import glob
    rows = [["Файл", "Строк", "Объекты"]]
    if lang == "sql":
        files = (["db/create_db.sql", "db/build.sql"] + sorted(glob.glob("db/migrations/*.sql", root_dir=ROOT))
                 + sorted(glob.glob("db/seed/*.sql", root_dir=ROOT)) + sorted(glob.glob("db/tests/*.sql", root_dir=ROOT)))
        for f in files:
            text = read(os.path.join(ROOT, f))
            n = text.count("\n")
            names = []
            for m in re.finditer(r"CREATE (?:OR REPLACE )?(TABLE|VIEW|FUNCTION|TRIGGER|SEQUENCE|SCHEMA)"
                                 r"(?: IF NOT EXISTS)? ([\w.]+)", text):
                if m.group(2) not in names and not m.group(2).startswith("pg_temp"):
                    names.append(m.group(2))
            doms = re.findall(r"COMMENT ON DOMAIN ([\w.]+)", text)
            idx = len(re.findall(r"CREATE (?:UNIQUE )?INDEX", text))
            tests = re.findall(r"pg_temp\.check\('(\d+\.\d+[а-я]?)", text)
            parts = []
            if names:
                parts.append(", ".join(names))
            if doms:
                parts.append("домены " + ", ".join(d.split(".")[-1] for d in doms))
            if idx:
                parts.append(f"индексов: {idx}")
            if tests:
                parts.append(f"тесты {tests[0]}–{tests[-1]} ({len(tests)})")
            if not parts:
                first = next((l.strip("- ").strip() for l in text.split("\n") if l.startswith("--")), "")
                first = re.sub(r"^(Seed )?\d+\.\s*", "", first).rstrip(".")
                # ссылки на ТЗ и задания ЛР из комментариев в записку не переносятся
                first = re.sub(r"\((?:ТЗ|задание)[^:()]*:\s*", "(", first)
                first = re.sub(r"\s*\((?:ТЗ|задание)[^()]*\)", "", first)
                parts.append("запуск всех тестов и итог прогона" if f.endswith("run_all.sql") else first)
            rows.append([f, str(n), "; ".join(parts)])
        return ("Состав сценариев серверной части", "tab:files-sql", {"widths": "30,8,62", "size": "10"}, rows)
    base = os.path.join(ROOT, "client", "src")
    for h in sorted(glob.glob("**/*.h", root_dir=base, recursive=True)):
        if "compat" in h:
            continue
        cpp = h[:-2] + ".cpp"
        n = read(os.path.join(base, h)).count("\n")
        if os.path.exists(os.path.join(base, cpp)):
            n += read(os.path.join(base, cpp)).count("\n")
        classes = re.findall(r"^(?:class|struct|namespace) (\w+)(?![^\n]*;)", read(os.path.join(base, h)), flags=re.M)
        rows.append([h[:-2] + (".h/.cpp" if os.path.exists(os.path.join(base, cpp)) else ".h"), str(n), ", ".join(classes)])
    n = read(os.path.join(base, "main.cpp")).count("\n")
    rows.append(["main.cpp", str(n), "функция main"])
    return ("Состав исходного кода клиента (каталог client/src)", "tab:files-cpp", {"widths": "40,8,52", "size": "10"}, rows)


# ====================================================================== разбор исходников
class Block:
    def __init__(self, kind, **kw):
        self.kind = kind
        self.__dict__.update(kw)


ATTR = re.compile(r"\{#((?:fig|tab|lst):[\w.-]+)([^}]*)\}")


def attrs(s):
    m = ATTR.search(s)
    if not m:
        return s, None, {}
    kv = dict(re.findall(r"(\w+)=([^\s}]+)", m.group(2)))
    return (s[:m.start()] + s[m.end():]).strip(), m.group(1), kv


def parse(text, md_dir):
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    lines = text.split("\n")
    blocks, para, i = [], [], 0

    def flush():
        if para:
            blocks.append(Block("p", text=" ".join(s.strip() for s in para)))
            para.clear()

    while i < len(lines):
        s = lines[i].rstrip()
        st = s.strip()
        if not st:
            flush(); i += 1; continue
        m = re.match(r"^(#{1,3})\s+(.*)$", st)
        if m:
            flush(); blocks.append(Block("h", level=len(m.group(1)), text=m.group(2).strip())); i += 1; continue
        if st in ("!filelist:sql", "!filelist:cpp"):
            flush(); blocks.append(Block("filelist", lang=st.split(":")[1])); i += 1; continue
        if st in ("!tz", "!toc", "!pagebreak", "!apitable"):
            flush(); blocks.append(Block(st[1:])); i += 1; continue
        m = re.match(r"^!stub\[(.*)\]$", st)
        if m:
            flush(); blocks.append(Block("stub", text=m.group(1))); i += 1; continue
        m = re.match(r"^!(code|listing)\[(.*?)\]\((.*?)\)(.*)$", st)
        if m:
            flush()
            _, key, kv = attrs(m.group(4))
            blocks.append(Block(m.group(1), title=m.group(2), spec=m.group(3), key=key, kv=kv, md_dir=md_dir))
            i += 1; continue
        specs = re.findall(r"!\[(.*?)\]\((.*?)\)(\{[^}]*\})?", st)
        if st.startswith("![") and len(specs) == 2:
            flush()
            imgs = []
            for title, p, at in specs:
                _, key, kv = attrs(at)
                full = os.path.normpath(os.path.join(md_dir if p.startswith("..") else ROOT, p))
                imgs.append(Block("img", title=title, path=full, key=key, kv=kv))
            blocks.append(Block("imgpair", imgs=imgs))
            i += 1; continue
        m = re.match(r"^!\[(.*?)\]\((.*?)\)(.*)$", st)
        if m:
            flush()
            _, key, kv = attrs(m.group(3))
            p = m.group(2)
            full = os.path.normpath(os.path.join(md_dir if p.startswith("..") else ROOT, p))
            blocks.append(Block("img", title=m.group(1), path=full, key=key, kv=kv))
            i += 1; continue
        m = re.match(r"^Таблица:\s*(.*)$", st)
        if m:
            flush()
            title, key, kv = attrs(m.group(1))
            i += 1
            while i < len(lines) and not lines[i].strip():
                i += 1
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in re.split(r"(?<!\\)\|", lines[i].strip().strip("|"))]
                cells = [c.replace("\\|", "|") for c in cells]
                if not all(re.fullmatch(r":?-{3,}:?", c) for c in cells):
                    rows.append(cells)
                i += 1
            blocks.append(Block("table", title=title, key=key, kv=kv, rows=rows))
            continue
        m = re.match(r"^(-|\d+\.)\s+(.*)$", st)
        if m:
            flush()
            items, numbered = [], m.group(1) != "-"
            while i < len(lines):
                mm = re.match(r"^(-|\d+\.)\s+(.*)$", lines[i].strip())
                if mm:
                    items.append(mm.group(2).strip())
                elif lines[i].strip() and items and lines[i].startswith("  "):
                    items[-1] += " " + lines[i].strip()
                else:
                    break
                i += 1
            blocks.append(Block("list", items=items, numbered=numbered))
            continue
        para.append(s)
        i += 1
    flush()
    return blocks


# ====================================================================== документ
def _tnr(rpr):
    rf = rpr.find(qn("w:rFonts"))
    if rf is None:
        rf = OxmlElement("w:rFonts")
        rpr.insert(0, rf)
    for a in list(rf.attrib):
        del rf.attrib[a]
    for a in ("w:ascii", "w:hAnsi", "w:cs", "w:eastAsia"):
        rf.set(qn(a), FONT)


TBLPR_ORDER = ["tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblStyleRowBandSize", "tblStyleColBandSize",
               "tblW", "jc", "tblCellSpacing", "tblInd", "tblBorders", "shd", "tblLayout", "tblCellMar", "tblLook"]


class PZDoc:
    def __init__(self, meta):
        self.meta = meta
        d = self.d = Document(TEMPLATE)
        body = d.element.body
        for el in list(body):
            if el.tag != qn("w:sectPr"):
                body.remove(el)
        self.sect = body.find(qn("w:sectPr"))
        self.sect_pristine = self.sect.xml       # для разрывов разделов листингов (три колонки)
        self.lst_open = self.lst_first = False
        self.lst_sections = 0
        # шрифт по умолчанию и во всех стилях — Times New Roman (в шаблоне по умолчанию — шрифты темы)
        for rpr in d.styles.element.iter(qn("w:rPr")):
            _tnr(rpr)
        dd = d.styles.element.find(qn("w:docDefaults"))
        _tnr(dd.find(qn("w:rPrDefault")).find(qn("w:rPr")))
        # колонтитул с номером страницы: без лишнего пустого абзаца, номер — 14 пт справа
        for rel in d.part.rels.values():
            if rel.reltype.endswith("/header"):
                hdr = rel.target_part.element
                ps = hdr.findall(qn("w:p"))
                for p in ps:
                    if not p.findall(".//" + qn("w:t")) and len(ps) > 1 and p is ps[-1]:
                        hdr.remove(p)
        self.chapter = None              # «1», «4» или «А»
        self.counters = {}
        self.numbers = {}                # key -> «4.3»
        self.objects = {"Рисунок": 0, "Таблица": 0, "Листинг": 0}
        self.headings = []               # (level, text, paragraph) — для содержания
        self.todo = []
        self.code_checks = []            # (номер, первая строка кода) — проверка неразрывности по PDF
        self.tz_anchor = None
        self.toc_anchor = None
        self.in_appendix = False

    # ---------------------------------------------------------------- абзацы
    def _append(self, el):
        self.sect.addprevious(el)
        return el

    def run(self, p, text, size=14, bold=False, italic=False, highlight=False):
        r = p.add_run(text)
        r.font.size = Pt(size)
        r.bold = bold or None
        r.italic = italic or None
        _tnr(r._r.get_or_add_rPr())
        if highlight:
            h = OxmlElement("w:highlight")
            h.set(qn("w:val"), "yellow")
            r._r.get_or_add_rPr().append(h)
        return r

    def para(self, text="", indent=True, align="justify", size=14, bold=False, keep_next=False, page_break=False,
             before=0, after=0, line=None, style="PZText"):
        p = self.d.add_paragraph(style=style)
        self._append(p._p)
        pf = p.paragraph_format
        pf.first_line_indent = Cm(1.25) if indent else Cm(0)
        p.alignment = {"justify": WD_ALIGN_PARAGRAPH.JUSTIFY, "center": WD_ALIGN_PARAGRAPH.CENTER,
                       "left": WD_ALIGN_PARAGRAPH.LEFT, "right": WD_ALIGN_PARAGRAPH.RIGHT}[align]
        pf.keep_with_next = keep_next or None
        pf.page_break_before = page_break or None
        pf.space_before = Pt(before)
        pf.space_after = Pt(after)
        if line is not None:
            pf.line_spacing = line
        if text:
            self.inline(p, text, size=size, bold=bold)
        return p

    def inline(self, p, text, size=14, bold=False):
        text = self.resolve(text)
        for part in re.split(r"(\*\*.+?\*\*)", text):
            if not part:
                continue
            b = part.startswith("**") and part.endswith("**")
            self.run(p, (part[2:-2] if b else part).replace("`", ""), size=size, bold=bold or b)

    def resolve(self, text):
        def ref(m):
            key = m.group(1)
            if key not in self.numbers:
                self.todo.append(f"Неизвестная ссылка [@{key}]")
                return f"[?{key}]"
            return self.numbers[key]
        return re.sub(r"\[@((?:fig|tab|lst):[\w.-]+)\]", ref, text)

    # ---------------------------------------------------------------- нумерация
    def number(self, kind, key):
        n = self.counters.get(kind, 0) + 1
        self.counters[kind] = n
        self.objects[kind] += 1
        no = f"{self.chapter}.{n}" if self.chapter else str(n)
        if key:
            self.numbers[key] = no
        return no

    # ---------------------------------------------------------------- заголовки
    def heading(self, level, text):
        if level == 1:
            self.counters = {}
            m = re.match(r"^ПРИЛОЖЕНИЕ\s+([А-Я])\s*//\s*(.*)$", text, flags=re.I)
            if m:
                self.chapter, self.in_appendix = m.group(1), True
                p1 = self.para(f"ПРИЛОЖЕНИЕ {m.group(1)}.", indent=False, align="center", keep_next=True,
                               page_break=True, style="Heading 1")
                p2 = self.para(m.group(2).upper(), indent=False, align="center", keep_next=True, after=14)
                self.headings.append((1, f"ПРИЛОЖЕНИЕ {m.group(1)}. {m.group(2)}", p1))
                return
            m = re.match(r"^(\d+)\s+(.*)$", text)
            if m:
                self.chapter = m.group(1)
                t = f"{m.group(1)} {m.group(2).upper()}"
                p = self.para(t, align="left", keep_next=True, page_break=True, after=14, style="Heading 1")
            else:
                self.chapter = None
                t = text.upper()
                p = self.para(t, indent=False, align="center", keep_next=True, page_break=True, after=14,
                              style="Heading 1")
            if t not in ("СОДЕРЖАНИЕ", "РЕФЕРАТ"):
                self.headings.append((1, t, p))
            return
        if self.in_appendix:
            # подразделы приложений — в содержание не входят (стиль не заголовка, полужирный)
            self.para(text, align="left", keep_next=True, before=10, after=6, bold=True)
            return
        p = self.para(text, align="left", keep_next=True, before=14 if level == 2 else 10, after=14 if level == 2 else 10,
                      style="Heading 2" if level == 2 else "Heading 3")
        self.headings.append((level, text, p))

    # ---------------------------------------------------------------- списки, заглушки
    def list(self, items, numbered):
        for k, it in enumerate(items, 1):
            mark = f"{k}) " if numbered else f"{DASH} "
            p = self.para("", align="justify")
            self.inline(p, mark + it)

    def stub(self, text):
        """!stub[видимый текст || подробности только для pz_todo.md] — в записке короткая отметка."""
        vis, _, more = text.partition("||")
        p = self.para("", align="justify")
        self.run(p, f"[ЗАГЛУШКА: {self.resolve(vis.strip())}]", highlight=True)
        self.todo.append(f"Заглушка ({self.chapter or '—'}): {vis.strip()}" + (f" — {more.strip()}" if more.strip() else ""))

    # ---------------------------------------------------------------- таблицы
    def _tblpr(self, tbl, widths, borders=True, inside_v=True, center=False):
        tblpr = tbl._tbl.tblPr
        for tag in ("tblW", "jc", "tblBorders", "tblLayout", "tblStyle", "tblLook"):
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
        sides = ["top", "left", "bottom", "right", "insideH"] + (["insideV"] if inside_v else [])
        for side in ["top", "left", "bottom", "right", "insideH", "insideV"]:
            e = OxmlElement(f"w:{side}")
            on = borders and side in sides
            e.set(qn("w:val"), "single" if on else "nil")
            if on:
                e.set(qn("w:sz"), "4")
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
        for gc, w in zip(tbl._tbl.tblGrid.findall(qn("w:gridCol")), widths):
            gc.set(qn("w:w"), str(w))
        for row in tbl.rows:
            for cell, w in zip(row.cells, widths):
                cell.width = Twips(w)

    def caption_above(self, kind, no, title):
        self.para(f"{kind} {no} {DASH} {self.resolve(title)}", indent=False, align="left", keep_next=True, before=6)

    def table(self, title, key, kv, rows):
        no = self.number("Таблица", key)
        self.caption_above("Таблица", no, title)
        ncol = max(len(r) for r in rows)
        if "widths" in kv:
            pc = [float(x) for x in kv["widths"].split(",")]
            widths = [int(TEXT_WIDTH * x / sum(pc)) for x in pc]
        else:
            # ширина колонки (dxa): короткие значения (до 18 знаков) — по самому длинному значению без переноса;
            # длинный текст делит остаток ширины пропорционально средней длине, но не уже самого длинного слова.
            # Ширина знака зависит от кегля и доли прописных (прописные Times New Roman шире строчных).
            sz = float(kv.get("size", 12 if ncol <= 4 else (11 if ncol == 5 else 10)))
            kv["size"] = str(sz)

            def cw(text):
                up = sum(1 for ch in text if ch.isupper() or ch.isdigit()) / max(1, len(text))
                return (100 + 50 * up) * sz / 11

            fixed, flex = {}, {}
            for j in range(ncol):
                cells = [re.sub(r"[`*]", "", r[j]) if j < len(r) else "" for r in rows]
                body = cells[1:] or [""]
                longest_cell = max(body, key=len)
                head = max(re.split(r"[\s,]+", cells[0]), key=len)
                words = [x for c in cells for x in re.split(r"[\s,]+", c)]
                word = max(words, key=len) if words else "abc"
                if len(longest_cell) <= 18:
                    fixed[j] = max(len(longest_cell) * cw(longest_cell), len(head) * cw(head) * 1.4, 3 * 110) + 240
                else:
                    avg = sum(len(c) for c in body) / len(body)
                    wmin = min(len(word), 24) * cw(word) + 240
                    flex[j] = (max(wmin, min(avg * 1.1, 48) * cw(longest_cell) + 240), wmin)
            rest = TEXT_WIDTH - sum(fixed.values())
            need_min = sum(m for _, m in flex.values())
            if not flex or rest < need_min:
                allw = {**fixed, **{j: v[1] if flex else v[0] for j, v in flex.items()}}
                tot = sum(allw.values())
                widths = [int(TEXT_WIDTH * allw[j] / tot) for j in range(ncol)]
            else:
                extra = rest - need_min
                tot = sum(v[0] - v[1] for v in flex.values()) or 1
                widths = [int(fixed[j]) if j in fixed else int(flex[j][1] + extra * (flex[j][0] - flex[j][1]) / tot)
                          for j in range(ncol)]
                if sum(widths) < TEXT_WIDTH and tot == 1:
                    last = max(flex)
                    widths[last] += TEXT_WIDTH - sum(widths)
        size = float(kv.get("size", 12 if ncol <= 4 else (11 if ncol == 5 else 10)))
        tbl = self.d.add_table(rows=len(rows), cols=ncol)
        self._append(tbl._tbl)
        self._tblpr(tbl, widths)
        for i, r in enumerate(rows):
            for j in range(ncol):
                cell = tbl.cell(i, j)
                p = cell.paragraphs[0]
                pf = p.paragraph_format
                pf.first_line_indent = Cm(0)
                pf.space_after = Pt(0)
                pf.line_spacing = 1.0
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER if i == 0 else WD_ALIGN_PARAGRAPH.LEFT
                self.inline(p, r[j] if j < len(r) else "", size=size, bold=(i == 0))
        tr = tbl.rows[0]._tr.get_or_add_trPr()
        tr.append(OxmlElement("w:tblHeader"))
        for row in tbl.rows:
            row._tr.get_or_add_trPr().append(OxmlElement("w:cantSplit"))
        self.para("", indent=False, line=1.0)

    # ---------------------------------------------------------------- рисунки
    def caption_below(self, no, title):
        self.para(f"Рисунок {no} {DASH} {self.resolve(title)}", indent=False, align="center", after=8)

    # обрезка снимков клиента 1440×900: «form» — без панели разделов, вкладок и строки состояния,
    # «main» — без строки состояния; явная рамка — crop=x0,y0,x1,y1 (пиксели исходного снимка)
    CROPS = {"form": (212, 93, 1440, 876), "main": (0, 0, 1440, 876)}

    def _picture(self, path, kv):
        from PIL import Image
        im = Image.open(path)
        crop = kv.get("crop")
        if crop:
            box = self.CROPS.get(crop) or tuple(int(v) for v in crop.split(","))
            w0, h0 = im.size
            box = (box[0], box[1], min(box[2], w0), min(box[3], h0))
            im = im.crop(box)
            if "trim" in kv:                       # снизу: пустые строки одного цвета
                import numpy as np
                a = np.asarray(im.convert("L")).astype(int)
                y = a.shape[0]
                while y > 40 and a[y - 1].max() - a[y - 1].min() < 6:
                    y -= 1
                im = im.crop((0, 0, im.size[0], min(im.size[1], y + 6)))
            if "squeeze" in kv:                    # пустые полосы внутри снимка (как у окна меньшей высоты)
                import numpy as np
                from PIL import Image as _I
                a = np.asarray(im.convert("L")).astype(int)
                mode = np.array([np.bincount(r).argmax() for r in a])
                blank = [(np.abs(r - m) > 6).sum() <= 6 for r, m in zip(a, mode)]   # допускаются линии рамок
                keep, run = [], 0
                for y, b in enumerate(blank):
                    run = run + 1 if b else 0
                    if not b or run <= 10:
                        keep.append(y)
                rgb = np.asarray(im.convert("RGB"))[keep]
                im = _I.fromarray(rgb)
            os.makedirs(os.path.join(OUT, ".img"), exist_ok=True)
            path = os.path.join(OUT, ".img", f"{os.path.splitext(os.path.basename(path))[0]}_{crop.replace(',', '-')}.png")
            im.save(path)
        return path, im.size

    def image(self, title, path, key, kv):
        no = self.number("Рисунок", key)
        if not os.path.exists(path):
            ph = self.para(f"[ВСТАВИТЬ СНИМОК: {os.path.relpath(path, ROOT)}]", indent=False, align="center",
                           keep_next=True, before=6)
            ph.runs[0].font.highlight_color = 7
            if "ph" in kv:                       # ph=<см> — место под будущий снимок (честный объём страниц)
                ph.paragraph_format.space_after = Cm(max(0.0, float(kv["ph"]) - 0.6))
            self.todo.append(f"Нет снимка: {os.path.relpath(path, ROOT)} (рисунок {no})")
        else:
            path, (w, h) = self._picture(path, kv)
            width = float(kv.get("width", 16.5))
            max_h = float(kv.get("maxh", 21.0))
            width = min(width, max_h * w / h)
            p = self.para("", indent=False, align="center", keep_next=True, before=6, line=1.0)
            p.add_run().add_picture(path, width=Cm(width))
        self.caption_below(no, title)

    def image_pair(self, imgs):
        """Два небольших снимка рядом: таблица без рамок 1×2, у каждого своя подпись под снимком."""
        tbl = self.d.add_table(rows=1, cols=2)
        self._append(tbl._tbl)
        half = TEXT_WIDTH // 2
        self._tblpr(tbl, [half, TEXT_WIDTH - half], borders=False, center=True)
        tbl.rows[0]._tr.get_or_add_trPr().append(OxmlElement("w:cantSplit"))
        for j, b in enumerate(imgs):
            no = self.number("Рисунок", b.key)
            cell = tbl.cell(0, j)
            va = OxmlElement("w:vAlign")          # снимки разной высоты: подписи на одной линии
            va.set(qn("w:val"), "bottom")
            cell._tc.get_or_add_tcPr().append(va)
            p = cell.paragraphs[0]
            p.paragraph_format.first_line_indent = Cm(0)
            p.paragraph_format.space_before = Pt(6)
            p.paragraph_format.keep_with_next = True
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            if not os.path.exists(b.path):
                self.run(p, f"[ВСТАВИТЬ СНИМОК: {os.path.relpath(b.path, ROOT)}]", highlight=True)
                self.todo.append(f"Нет снимка: {os.path.relpath(b.path, ROOT)} (рисунок {no})")
                if "ph" in b.kv:
                    p.paragraph_format.space_after = Cm(max(0.0, float(b.kv["ph"]) - 0.6))
            else:
                path, (w, h) = self._picture(b.path, b.kv)
                width = min(float(b.kv.get("width", 8.0)), 8.2, float(b.kv.get("maxh", 21.0)) * w / h)
                p.add_run().add_picture(path, width=Cm(width))
            cp = cell.add_paragraph()
            cp.paragraph_format.first_line_indent = Cm(0)
            cp.paragraph_format.space_before = Pt(0)
            cp.paragraph_format.space_after = Pt(8)
            cp.paragraph_format.line_spacing = 1.0
            cp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            self.inline(cp, f"Рисунок {no} {DASH} {b.title}")
        self.para("", indent=False, line=1.0)

    # ---------------------------------------------------------------- код-рисунок (основная часть)
    @staticmethod
    def _height(lines, size, width_dxa):
        per = max(10, int((width_dxa - 216) / 20 / (size * 0.47)))
        n = sum(max(1, -(-len(s) // per)) for s in lines)
        return n * size * 1.17 + 10

    def code(self, title, spec, key, kv, md_dir):
        lang = "cpp" if re.search(r"\.(h|cpp)(#|$)", spec) else "sql"
        lines = extract(spec, md_dir)
        if kv.get("strip", "1") == "1":
            lines = strip_comments(lines, lang)
        else:
            ind = min((len(x) - len(x.lstrip()) for x in lines if x.strip()), default=0)
            lines = [x[ind:].rstrip() for x in lines]
        if "head" in kv and len(lines) > int(kv["head"]) + 1:
            h = int(kv["head"])
            ind = len(lines[h]) - len(lines[h].lstrip())
            lines = lines[:h] + [" " * ind + "…"] + [lines[-1]]
        size = float(kv.get("size", 10))
        limit = TEXT_HEIGHT_PT - 40
        while size > 7 and self._height(lines, size, TEXT_WIDTH) > limit:
            size -= 0.5
        no = self.number("Рисунок", key)
        if self._height(lines, size, TEXT_WIDTH) > limit:
            self.todo.append(f"Рисунок {no} (код) выше страницы даже при 7 пт — разделить")
        # в рамке только код, подпись — отдельный абзац под рамкой (требование студента 28.10.2026).
        # Рамка — границы абзацев (w:pBdr): соседние абзацы с одинаковыми границами сливаются в один
        # прямоугольник и в Word, и в LibreOffice, а «не отрывать от следующего» у каждого абзаца кода
        # удерживает подпись на странице кода (у таблицы LibreOffice это свойство теряет).
        for k, s in enumerate(lines):
            p = self.para("", indent=False, align="left", keep_next=True, line=1.0)
            pf = p.paragraph_format
            pf.keep_together = True
            pf.left_indent = Cm(0.15)
            pf.right_indent = Cm(0.15)
            ppr = p._p.get_or_add_pPr()
            bdr = OxmlElement("w:pBdr")
            for side in ("top", "left", "bottom", "right"):
                e = OxmlElement(f"w:{side}")
                e.set(qn("w:val"), "single")
                e.set(qn("w:sz"), "4")
                e.set(qn("w:space"), "3")
                e.set(qn("w:color"), "000000")
                bdr.append(e)
            # pBdr стоит в pPr перед spacing/ind/jc (порядок схемы OOXML)
            anchor = next((ppr.find(qn(f"w:{t}")) for t in ("shd", "tabs", "suppressAutoHyphens", "spacing", "ind", "jc")
                           if ppr.find(qn(f"w:{t}")) is not None), None)
            if anchor is not None:
                anchor.addprevious(bdr)
            else:
                ppr.append(bdr)
            self.run(p, s.replace("\t", "    ") if s.strip() else " ", size=size)
        self.code_checks.append((f"Рисунок {no}", next((s.strip() for s in lines if s.strip()), "")))
        cp = self.para("", indent=False, align="center", before=4, line=1.0)
        self.inline(cp, f"Рисунок {no} {DASH} {title}")
        self.para("", indent=False, line=1.0)

    # ---------------------------------------------------------------- листинги приложений: сплошной текст в три колонки
    def section_break(self, cols, continuous):
        """Конец текущего раздела Word: абзац с w:sectPr (копия раздела документа) — cols колонок.

        continuous — раздел начинается без разрыва страницы (новая страница — у заголовка приложения)."""
        sp = parse_xml(self.sect_pristine)
        for e in sp.findall(qn("w:type")):
            sp.remove(e)
        if continuous:
            t = OxmlElement("w:type")
            t.set(qn("w:val"), "continuous")
            refs = sp.findall(qn("w:headerReference")) + sp.findall(qn("w:footerReference"))
            (refs[-1].addnext(t) if refs else sp.insert(0, t))
        c = sp.find(qn("w:cols"))
        if c is None:
            c = OxmlElement("w:cols")
            sp.find(qn("w:pgMar")).addnext(c)
        for a in list(c.attrib):
            del c.attrib[a]
        c.set(qn("w:space"), "284")
        if cols > 1:
            c.set(qn("w:num"), str(cols))
        p = self.para("", indent=False, line=1.0)
        p.paragraph_format.space_after = Pt(0)
        p.paragraph_format.space_before = Pt(0)
        self.run(p, "", size=1)
        p._p.get_or_add_pPr().append(sp)

    def listing_open(self):
        if not self.lst_open:
            # раздел до кода (заголовок приложения) — одна колонка; первый такой разрыв — как раздел документа
            self.section_break(1, continuous=self.lst_sections > 0)
            self.lst_open, self.lst_first = True, True

    def listing_close(self):
        if self.lst_open:
            self.section_break(3, continuous=True)
            self.lst_open = False
            self.lst_sections += 1

    def listing(self, title, spec, key, kv, md_dir):
        """Листинг приложения: только текст кода (без подписи), Times New Roman 11 пт, сплошь в три колонки."""
        lang = "cpp" if re.search(r"\.(h|cpp|txt)(#|$)", spec) or spec.endswith("CMakeLists.txt") else "sql"
        lines = strip_comments(extract(spec, md_dir), lang)
        if ";full" not in spec:
            lines = abbreviate(lines, lang, limit=int(kv.get("limit", 34)))
        lines = [re.sub(r"^( +)", lambda m: " " * (len(m.group(1)) // 2), s) for s in lines]   # отступ вдвое
        size = float(kv.get("size", 11))
        self.number("Листинг", key)
        self.listing_open()
        if not self.lst_first:
            lines = [""] + lines                     # фрагменты разделены пустой строкой
        self.lst_first = False
        for s in lines:
            p = self.para("", indent=False, align="left", line=1.0)
            pf = p.paragraph_format
            pf.space_after = Pt(0)
            pf.space_before = Pt(0)
            pf.keep_together = True
            self.run(p, s if s.strip() else " ", size=size)
        self.code_checks.append((f"Листинг {key}", next((s.strip() for s in lines if s.strip()), "")))

    # ---------------------------------------------------------------- титульный лист
    def title_page(self):
        m = self.meta
        c = lambda t, **k: self.para(t, indent=False, align="center", line=1.0, **k)
        c("МИНИСТЕРСТВО НАУКИ И ВЫСШЕГО ОБРАЗОВАНИЯ РОССИЙСКОЙ ФЕДЕРАЦИИ")
        c("Федеральное государственное бюджетное образовательное учреждение высшего образования")
        c(f"«{m['university'].capitalize()}»")
        c("")
        c(m["faculty"])
        c(m["department"].replace("Л. П.", "Л.П."))
        for _ in range(7):
            c("")
        c("ПОЯСНИТЕЛЬНАЯ ЗАПИСКА", size=16)
        c("")
        c("к курсовому проекту")
        c(f"по дисциплине «{m['discipline']}»")
        c("")
        c("Тема:")
        c(f"«{m['coursework_topic']}»")
        c(f"Вариант {m['variant']}: учёт услуг связи интернет-провайдеров")
        for _ in range(6):
            c("")
        tbl = self.d.add_table(rows=3, cols=2)
        self._append(tbl._tbl)
        self._tblpr(tbl, [TEXT_WIDTH // 2, TEXT_WIDTH - TEXT_WIDTH // 2], borders=False)
        left = ["Руководители:", f"ст. преп. каф. ПИ {m['teacher_senior']}", f"асс. каф. ПИ {m['teacher_lab']}"]
        right = ["Разработал:", f"ст. гр. {m['group']}", m["student"]]
        for i in range(3):
            for j, (t, al) in enumerate(((left[i], WD_ALIGN_PARAGRAPH.LEFT), (right[i], WD_ALIGN_PARAGRAPH.RIGHT))):
                p = tbl.cell(i, j).paragraphs[0]
                p.paragraph_format.first_line_indent = Cm(0)
                p.paragraph_format.line_spacing = 1.0
                p.paragraph_format.space_after = Pt(0)
                p.alignment = al
                self.run(p, t)
        for _ in range(8):
            c("")
        p = c(f"{m['city']} {DASH} {m['year']}")
        # конец раздела титульного листа: номер страницы на нём не печатается
        sp = parse_xml(self.sect.xml)
        for e in sp.findall(qn("w:headerReference")) + sp.findall(qn("w:footerReference")):
            sp.remove(e)
        default = next(e for e in self.sect.findall(qn("w:headerReference")) if e.get(qn("w:type")) == "default")
        empty = next(e for e in self.sect.findall(qn("w:headerReference")) if e.get(qn("w:type")) == "even")
        h1 = parse_xml(default.xml)
        h2 = parse_xml(empty.xml)
        h2.set(qn("w:type"), "first")
        sp.insert(0, h2)
        sp.insert(0, h1)
        tp = OxmlElement("w:titlePg")
        sp.find(qn("w:cols")).addnext(tp) if sp.find(qn("w:cols")) is not None else sp.append(tp)
        p._p.get_or_add_pPr().append(sp)

    # ---------------------------------------------------------------- сборка
    def render(self, blocks):
        for b in blocks:
            k = b.kind
            if k != "listing":
                self.listing_close()
            if k == "h":
                self.heading(b.level, b.text)
            elif k == "p":
                self.para(b.text)
            elif k == "list":
                self.list(b.items, b.numbered)
            elif k == "table":
                self.table(b.title, b.key, b.kv, b.rows)
            elif k == "img":
                self.image(b.title, b.path, b.key, b.kv)
            elif k == "imgpair":
                self.image_pair(b.imgs)
            elif k == "code":
                self.code(b.title, b.spec, b.key, b.kv, b.md_dir)
            elif k == "listing":
                self.listing(b.title, b.spec, b.key, b.kv, b.md_dir)
            elif k == "stub":
                self.stub(b.text)
            elif k == "pagebreak":
                self.para("").add_run().add_break(WD_BREAK.PAGE)
            elif k == "tz":
                self.tz_anchor = self.para("@@TZ@@", indent=False)
            elif k == "toc":
                self.toc_anchor = self.para("", indent=False)
            elif k == "apitable":
                self.table(*api_table())
            elif k == "filelist":
                self.table(*file_list(b.lang))
        self.listing_close()
        if self.lst_sections and self.sect.find(qn("w:type")) is None:
            # раздел после последних листингов начинается заголовком приложения с разрывом страницы
            t = OxmlElement("w:type")
            t.set(qn("w:val"), "continuous")
            refs = self.sect.findall(qn("w:headerReference")) + self.sect.findall(qn("w:footerReference"))
            (refs[-1].addnext(t) if refs else self.sect.insert(0, t))

    def number_pass(self, blocks):
        """Номера объектов до вывода — ссылки в тексте стоят раньше самих объектов."""
        chapter, counters = None, {}
        for b in blocks:
            if b.kind == "h" and b.level == 1:
                counters = {}
                m = re.match(r"^ПРИЛОЖЕНИЕ\s+([А-Я])", b.text, flags=re.I) or re.match(r"^(\d+)\s", b.text)
                chapter = m.group(1) if m else None
            kind = {"img": "Рисунок", "code": "Рисунок", "table": "Таблица", "listing": "Листинг",
                    "apitable": "Таблица", "filelist": "Таблица"}.get(b.kind)
            if b.kind == "apitable":
                b.key = "tab:api-objects"
            if b.kind == "filelist":
                b.key = f"tab:files-{b.lang}"
            if b.kind == "imgpair":
                for im in b.imgs:
                    counters["Рисунок"] = counters.get("Рисунок", 0) + 1
                    if im.key:
                        self.numbers[im.key] = f"{chapter}.{counters['Рисунок']}" if chapter else str(counters["Рисунок"])
            if kind:
                counters[kind] = counters.get(kind, 0) + 1
                if b.key:
                    self.numbers[b.key] = f"{chapter}.{counters[kind]}" if chapter else str(counters[kind])

    def toc(self, pages):
        """Содержание: поле TOC с готовыми строками (Word обновит по F9), номера страниц — по PDF."""
        anchor = self.toc_anchor._p
        items = [(lvl, txt) for lvl, txt, _ in self.headings]
        first = None
        for i, (lvl, txt) in enumerate(items):
            p = self.d.add_paragraph(style="PZText")
            anchor.addprevious(p._p)
            pf = p.paragraph_format
            pf.first_line_indent = Cm(0)
            pf.left_indent = Cm({1: 0, 2: 0.5, 3: 1.0}[lvl])
            pf.space_after = Pt(0)
            pf.line_spacing = 1.5
            pf.tab_stops.add_tab_stop(Twips(TEXT_WIDTH), alignment=2, leader=1)   # справа, точки
            p.alignment = WD_ALIGN_PARAGRAPH.LEFT
            if i == 0:
                for t, v in (("begin", None), ("instr", ' TOC \\o "1-3" \\h \\z '), ("separate", None)):
                    r = OxmlElement("w:r")
                    if t == "instr":
                        it = OxmlElement("w:instrText")
                        it.set(qn("xml:space"), "preserve")
                        it.text = v
                        r.append(it)
                    else:
                        fc = OxmlElement("w:fldChar")
                        fc.set(qn("w:fldCharType"), t)
                        r.append(fc)
                    p._p.append(r)
            self.run(p, f"{txt}\t{pages[i] if pages else '00'}")
            first = first or p
        last = p
        r = OxmlElement("w:r")
        fc = OxmlElement("w:fldChar")
        fc.set(qn("w:fldCharType"), "end")
        r.append(fc)
        last._p.append(r)
        anchor.getparent().remove(anchor)


ORDER = os.path.join(PZ, "_order.txt")


def build(meta, pages=None, stats=None):
    order = [s.strip() for s in read(ORDER).split("\n") if s.strip() and not s.startswith("#")]
    blocks = []
    for name in order:
        text = read(os.path.join(PZ, name))
        if stats:
            for k, v in stats.items():
                text = text.replace("{{" + k + "}}", str(v))
        blocks += parse(text, PZ)
    pz = PZDoc(meta)
    pz.number_pass(blocks)
    pz.title_page()
    pz.render(blocks)
    if pz.toc_anchor is not None:
        pz.toc(pages)
    return pz


def isolate_styles(doc, id_prefix, name_prefix):
    """Стили вставляемого документа — под своими именами, чтобы при вставке не подменились стилями шаблона
    (у шаблона «Обычный» — интервал 1,5 и отступ, у ТЗ — свои). Умолчания документа (docDefaults) ТЗ
    переносятся в корневые стили, иначе при вставке действовали бы умолчания шаблона."""
    st = doc.styles.element
    body = doc.element.body
    W = lambda t: qn("w:" + t)
    by_id = {e.get(W("styleId")): e for e in st.findall(W("style"))}
    used = set()
    for tag in ("pStyle", "rStyle", "tblStyle"):
        for e in body.iter(W(tag)):
            used.add(e.get(W("val")))
    todo = list(used)
    while todo:
        sid = todo.pop()
        e = by_id.get(sid)
        if e is None:
            continue
        for tag in ("basedOn", "next", "link"):
            r = e.find(W(tag))
            if r is not None and r.get(W("val")) not in used:
                used.add(r.get(W("val")))
                todo.append(r.get(W("val")))
    used = {u for u in used if u in by_id}
    ren = {u: id_prefix + u for u in used}
    dd = st.find(W("docDefaults"))
    d_rpr = dd.find(W("rPrDefault")).find(W("rPr")) if dd is not None and dd.find(W("rPrDefault")) is not None else None
    d_ppr = dd.find(W("pPrDefault")).find(W("pPr")) if dd is not None and dd.find(W("pPrDefault")) is not None else None
    for u in used:
        e = by_id[u]
        e.set(W("styleId"), ren[u])
        e.attrib.pop(W("default"), None)
        nm = e.find(W("name"))
        nm.set(W("val"), name_prefix + nm.get(W("val")))
        for tag in ("basedOn", "next", "link"):
            r = e.find(W(tag))
            if r is not None and r.get(W("val")) in ren:
                r.set(W("val"), ren[r.get(W("val"))])
        if e.find(W("basedOn")) is None and e.get(W("type")) == "paragraph":
            for src, tag in ((d_ppr, "pPr"), (d_rpr, "rPr")):
                if src is None:
                    continue
                dst = e.find(W(tag))
                if dst is None:
                    dst = OxmlElement("w:" + tag)
                    e.append(dst)
                have = {c.tag for c in dst}
                for c in src:
                    if c.tag not in have:
                        dst.append(parse_xml(c.xml) if False else __import__("copy").deepcopy(c))
    for tag in ("pStyle", "rStyle", "tblStyle"):
        for e in body.iter(W(tag)):
            if e.get(W("val")) in ren:
                e.set(W("val"), ren[e.get(W("val"))])
    try:
        for e in doc.part.numbering_part.element.iter(W("pStyle")):
            if e.get(W("val")) in ren:
                e.set(W("val"), ren[e.get(W("val"))])
    except Exception:
        pass


def compose_tz(docx_path):
    """ТЗ (coursework/tz/tz.docx) — сразу после титульного листа, со своими полями; страницы нумеруются."""
    from docxcompose.composer import Composer
    master = Document(docx_path)
    body = master.element.body
    idx = next(i for i, el in enumerate(body)
               if el.tag == qn("w:p") and "".join(t.text or "" for t in el.iter(qn("w:t"))) == "@@TZ@@")
    tz = Document(TZ_DOCX)
    tbody = tz.element.body
    # последний раздел ТЗ — разрывом раздела в конце, чтобы остальное шло по полям шаблона
    final = tbody.find(qn("w:sectPr"))
    p = OxmlElement("w:p")
    ppr = OxmlElement("w:pPr")
    sp = parse_xml(final.xml)
    ppr.append(sp)
    p.append(ppr)
    final.addprevious(p)
    for s in tbody.iter(qn("w:sectPr")):
        pm = s.find(qn("w:pgMar"))
        if pm is not None:
            pm.set(qn("w:header"), "567")          # номер страницы — на 1 см от края, не налезает на текст
        for e in s.findall(qn("w:titlePg")):
            s.remove(e)
    isolate_styles(tz, "TZ", "ТЗ ")
    tzp = os.path.join(tempfile.gettempdir(), "pz_tz_tmp.docx")
    tz.save(tzp)
    tz = Document(tzp)
    # пустой абзац-якорь после титульного листа удаляется, ТЗ вставляется на его место
    anchor_el = body[idx]
    Composer(master).insert(idx, tz)
    anchor_el.getparent().remove(anchor_el)
    master.save(docx_path)


def normalize_fonts(path):
    sys.path.insert(0, os.path.dirname(__file__))
    import docx_tnr
    tmp = path + ".tmp"
    docx_tnr.main(path, tmp)
    os.replace(tmp, path)


def to_pdf(docx_path):
    outdir = os.path.dirname(docx_path)
    subprocess.run(["soffice", "--headless", "--convert-to", "pdf", "--outdir", outdir, docx_path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    return os.path.splitext(docx_path)[0] + ".pdf"


def pdf_pages_text(pdf):
    n = int(re.search(r"Pages:\s+(\d+)", subprocess.run(["pdfinfo", pdf], capture_output=True, text=True).stdout).group(1))
    txt = subprocess.run(["pdftotext", "-layout", pdf, "-"], capture_output=True, text=True).stdout
    pages = txt.split("\f")
    return n, pages[:n]


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def find_heading_pages(headings, pages, start_page):
    """Номер страницы (с 1) каждого заголовка: по порядку, строка начинается с текста заголовка, без «....»."""
    out, cur = [], start_page
    for lvl, txt, _ in headings:
        key = norm(txt)[:38]
        found = None
        for pg in range(cur, len(pages)):
            for ln in pages[pg].split("\n"):
                l = norm(ln)
                if "...." in l or "…" * 3 in l:
                    continue
                if l.startswith(key) or (len(key) > 20 and key.startswith(l) and len(l) >= 12):
                    found = pg
                    break
            if found is not None:
                break
        out.append((found if found is not None else cur) + 1)
        cur = found if found is not None else cur
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-pdf", action="store_true")
    ap.add_argument("-o", "--out", default=os.path.join(OUT, "pz.docx"))
    ap.add_argument("--order", help="другой список файлов (для пробной сборки части)")
    args = ap.parse_args()
    global ORDER
    if args.order:
        ORDER = os.path.abspath(args.order)
    meta = yaml.safe_load(read(os.path.join(ROOT, "reports", "meta.yaml")))
    os.makedirs(OUT, exist_ok=True)
    out = args.out

    def make(pages, stats):
        pz = build(meta, pages, stats)
        pz.d.core_properties.author = meta["student"]
        pz.d.core_properties.title = "Пояснительная записка к курсовому проекту"
        pz.d.save(out)
        if pz.tz_anchor is not None:
            compose_tz(out)
        normalize_fonts(out)
        return pz

    stats = {"PAGES": "000", "FIGURES": "00", "TABLES": "00", "SOURCES": "00", "APPENDICES": "6"}
    pz = make(None, stats)
    if args.no_pdf:
        print("Готово (без PDF):", out)
        return
    # проход 2: номера страниц содержания и числа реферата — по PDF первого прохода
    pdf = to_pdf(out)
    n, pages = pdf_pages_text(pdf)
    toc_page = next(i for i, t in enumerate(pages) if "СОДЕРЖАНИЕ" in t and "...." in t)
    start = toc_page + 1
    while start < len(pages) and "...." in pages[start] and "ВВЕДЕНИЕ" not in norm(pages[start])[:40]:
        start += 1
    hp = find_heading_pages(pz.headings, pages, start)
    src = len(re.findall(r"^\d+\.\s", read(os.path.join(PZ, "80-literatura.md")), flags=re.M))
    stats = {"PAGES": n, "FIGURES": pz.objects["Рисунок"], "TABLES": pz.objects["Таблица"], "SOURCES": src,
             "APPENDICES": 6}
    pz = make(hp, stats)
    pdf = to_pdf(out)
    n2, pages = pdf_pages_text(pdf)
    hp2 = find_heading_pages(pz.headings, pages, start)
    report(pz, pdf, n2, pages, hp, hp2)


def report(pz, pdf, n, pages, hp, hp2):
    lines = []
    # страницы основной части: до первого приложения
    app = next((p for (lvl, t, _), p in zip(pz.headings, hp2) if t.startswith("ПРИЛОЖЕНИЕ")), n + 1)
    main_pages = app - 1
    lines.append(f"Страниц всего: {n}; основная часть (титул — список литературы): {main_pages}; приложения: {n - main_pages}")
    lines.append(f"Рисунков: {pz.objects['Рисунок']}, таблиц: {pz.objects['Таблица']}, листингов: {pz.objects['Листинг']}")
    if hp != hp2:
        diff = [(t, a, b) for (l, t, _), a, b in zip(pz.headings, hp, hp2) if a != b]
        lines.append(f"ВНИМАНИЕ: номера страниц содержания сдвинулись: {diff[:5]}")
    # шрифты
    fonts = subprocess.run(["pdffonts", pdf], capture_output=True, text=True).stdout.split("\n")[2:]
    names = sorted({re.sub(r"^[A-Z]{6}\+", "", f.split()[0]) for f in fonts if f.strip()})
    bad = [f for f in names if not f.startswith("TimesNewRoman")]
    lines.append("Шрифты PDF: " + ", ".join(names) + ("" if not bad else f"  <-- НЕ TNR: {bad}"))
    # неразрывность кода: первая строка и подпись на одной странице
    flat = [norm(p) for p in pages]
    broken = []
    for no, first in pz.code_checks:
        cap_pages = [i for i, t in enumerate(flat) if f"{no} {DASH}" in t]
        key = max(norm(first).split(" "), key=len)[:12] if first.strip() else ""
        if cap_pages and key and not any(key in flat[c] for c in cap_pages):
            broken.append(no)
    lines.append("Разрывы кода (подпись и начало на разных страницах): " + (", ".join(broken) if broken else "нет"))
    # объём по разделам: весь документ ≤ 100 с. с учётом недописанного, сейчас ≤ TOTAL_LIMIT (требование 28.10.2026)
    spans, firsts = [], [(t, p) for (lvl, t, _), p in zip(pz.headings, hp2) if lvl == 1]
    for k, (t, p) in enumerate(firsts):
        end = firsts[k + 1][1] if k + 1 < len(firsts) else n + 1
        spans.append((t, p, end - p))
    front = next((p for t, p, _ in spans if re.match(r"^1\s", t)), 1) - 1
    rows = [("Титул, ТЗ, реферат, содержание, введение", front, BUDGET["front"])]
    tail = 0
    for t, p, cnt in spans:
        m = re.match(r"^(\d+)\s", t) or re.match(r"^ПРИЛОЖЕНИЕ\s+([А-Я])", t, flags=re.I)
        if m:
            rows.append((t[:60], cnt, BUDGET.get(m.group(1))))
        elif t.upper().startswith(("ЗАКЛЮЧЕНИЕ", "СПИСОК")):
            tail += cnt
    rows.append(("Заключение и список источников", tail, BUDGET["tail"]))
    lines.append("Объём по разделам (страниц / бюджет):")
    for t, cnt, b in rows:
        lines.append(f"  {t}: {cnt}" + (f" / {b}" if b else "") + ("  <-- ПРЕВЫШЕНИЕ" if b and cnt > b else ""))
    if n > TOTAL_LIMIT:
        lines.append(f"ОШИБКА: всего {n} страниц > {TOTAL_LIMIT} (весь курсовой — около 100 с., резерв под недописанное)")
    # текст: ссылки на ТЗ, перечисления источников, число источников
    errs = []
    for name in [x.strip() for x in read(ORDER).split("\n") if x.strip() and not x.startswith("#")]:
        txt_md = re.sub(r"<!--.*?-->", "", read(os.path.join(PZ, name)), flags=re.S)
        for ln, row in enumerate(txt_md.split("\n"), 1):
            if name != "00-tz.md" and re.search(r"\bТЗ\b|техническ\w* задани", row):
                errs.append(f"ссылка на ТЗ: {name}:{ln}")
            if re.search(r"\[\d+\s*[,;–-]\s*\d+[^\]]*\]", row):
                errs.append(f"несколько источников в одной ссылке: {name}:{ln}")
    toc = next((i for i, t in enumerate(pages) if "СОДЕРЖАНИЕ" in t), 0)
    for i, t in enumerate(pages[toc + 1:], toc + 2):
        if re.search(r"\bТЗ\b|техническ\w*\s+задани", t):
            errs.append(f"«ТЗ» в тексте PDF, страница {i}")
    src = len(re.findall(r"^\d+\.\s", read(os.path.join(PZ, "80-literatura.md")), flags=re.M))
    if src > 4:
        errs.append(f"источников {src} > 4")
    lines += [f"ОШИБКА: {e}" for e in errs] or ["Ссылки на ТЗ, перечисления источников: нет; источников: " + str(src)]
    lines.append(f"Заглушек и замечаний: {len(pz.todo)}")
    txt = "\n".join(lines)
    print(txt)
    with open(os.path.join(OUT, "pz_report.txt"), "w", encoding="utf-8") as f:
        f.write(txt + "\n")
    with open(os.path.join(OUT, "pz_todo.md"), "w", encoding="utf-8") as f:
        f.write("# Недоделанное в ПЗ (генерируется tools/pzbuild.py)\n\n" + "\n".join(f"- {t}" for t in pz.todo) + "\n")


if __name__ == "__main__":
    main()
