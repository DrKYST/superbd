#!/usr/bin/env python3
"""
Отчёт по ЛР 7 в оформлении образца reports/template_lab.docx (общая часть — tools/labreport.py).
«Ход работы» строится из материалов лабораторной — ничего не переписывается вручную:
  structure.md, sample_document.json      — структура документа;
  sql/*.sql                               — код создания таблицы, генерации, индексов;
  explain/*.txt, explain/INDEX.md         — SQL запросов, планы EXPLAIN (ANALYZE, BUFFERS), журналы изменений;
  screenshots/<запрос>.png                — результаты запросов 3.1–5.6, снимки pgAdmin (Query Tool).

  python labs/lab07/build_report.py      ->  labs/lab07/out/lab07.docx
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from labreport import (Report, all_psql_tables, num, parse_psql, plan_lines, read,  # noqa: E402
                       sql_text, trim, unmd)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "lab07.docx")
EXPL = os.path.join(HERE, "explain")
SQL = os.path.join(HERE, "sql")
LAB = 7
TOPIC = "Практическое применение документно-ориентированных баз данных"

# ------------------------------------------------------------------ разбор материалов ЛР 7
SECTION_PREFIXES = ("SQL", "Результат", "План", "Сравнение", "Для сравнения")


def explain_file(name):
    """explain/<name>.txt -> {'meta': {...}, 'sections': {заголовок: [строки]}, 'total': строка «Итог»}."""
    text = read(EXPL, name + ".txt")
    meta, sections, cur = {}, {}, None
    total = None
    for line in text.splitlines():
        if line.startswith("-- ") and line[3:].startswith(SECTION_PREFIXES):
            cur = line[3:].strip()
            sections[cur] = []
            continue
        if line.startswith("Итог:"):
            total = line[len("Итог:"):].strip()
            cur = None
            continue
        if cur is None:
            if ": " in line and not sections:
                k, v = line.split(": ", 1)
                meta[k.strip()] = v.strip()
            continue
        sections[cur].append(line)
    return {"meta": meta, "sections": sections, "total": total}


def section(ex, prefix):
    for k, v in ex["sections"].items():
        if k.startswith(prefix):
            return v
    return None


def index_md():
    """explain/INDEX.md -> {№: {cost, time, index}}."""
    res = {}
    for ln in read(EXPL, "INDEX.md").splitlines():
        m = re.match(r"\| (\d\.\d) \|", ln)
        if not m:
            continue
        # № | раздел | что делает | SQL | вывод | cost | время | индекс  (в «раздел» может быть «?\|»)
        cells = [c for c in re.split(r"(?<!\\)\|", ln.strip().strip("|"))]
        cells = [c.strip().replace("\\|", "|") for c in cells]
        res[cells[0]] = {"cost": cells[5], "time": cells[6], "index": cells[7]}
    return res


def md_table(text, heading):
    """Первая таблица Markdown после заголовка heading -> (колонки, строки)."""
    lines = text.splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip() == heading)
    rows = []
    for ln in lines[start + 1:]:
        if ln.startswith("|"):
            rows.append([c.strip() for c in ln.strip().strip("|").split(" | ")])
        elif rows:
            break
    cols, body = rows[0], [r for r in rows[2:]]
    return cols, body


# ------------------------------------------------------------------ документ
R = Report(LAB, TOPIC)
para, h, bullets, caption, code, table, nxt = R.para, R.h, R.bullets, R.caption, R.code, R.table, R.nxt
COUNT = R.count


def result(ex, title, max_rows=5):
    """Результат запроса из explain/<имя>.txt — таблица с первыми строками."""
    R.result(section(ex, "Результат"), title, max_rows=max_rows)


# ------------------------------------------------------------------ шапка лабораторной (как в образце)
para(f"Лабораторная работа №{LAB}", indent=False, align="center", page_break=True)
para(f"«{TOPIC}»", indent=False, align="center")
para("", indent=False)
para("Цель работы: изучение подходов к построению и моделированию документно-ориентированных баз данных "
     "с помощью типов JSON и JSONB в PostgreSQL (принципы NoSQL).", align="justify")
para("")
para("Задание", indent=False, align="center")
para("")
para("Для предметной области варианта 16 (учёт услуг связи интернет-провайдеров) придумать структуру "
     "JSON-документа, создать таблицу для его хранения, заполнить её псевдоданными, выполнить запросы "
     "на выборку, изменение и удаление данных в документах, создать индексы, проанализировать планы "
     "выполнения запросов и оптимизировать запросы.", align="justify")
para("")
para("Требования к выполняемой работе")
bullets([
    "придумать и написать пример структуры JSON по заданию;",
    "создать таблицу для хранения JSON;",
    "заполнить таблицу псевдоданными: не менее 100 000 записей, глубина вложенности не менее 4;",
    "запросы с выводом конкретных полей, объектов и массивов с одним или несколькими условиями — не менее 3;",
    "запросы с использованием jsonpath — не менее 3;",
    "запросы с использованием функций обработки JSON — не менее 3;",
    "обновление, добавление и удаление данных внутри документа — не менее 6;",
    "удаление документов — не менее 2;",
    "индексы — не менее 3 (один по полю с документом целиком, не менее двух по элементам ключей);",
    "анализ запросов с помощью EXPLAIN (ANALYZE);",
    "оптимизировать не менее 5 запросов так, чтобы они использовали индексы, а стоимость узлов плана не выросла.",
])
para("")
para("Ход работы", indent=False, align="center")
para("")


# ------------------------------------------------------------------ 1 структура документа
struct_md = read(HERE, "structure.md")
h("1 Пример структуры JSON")
para("В качестве документа выбрана учётная запись сеанса связи, которую биллинг интернет-провайдера "
     "выгружает по каждому завершённому сеансу абонента. Запись содержит сведения о том, откуда пришёл "
     "сеанс (провайдер и сервер доступа — NAS), по какому договору он прошёл, когда начался и закончился, "
     "сколько трафика передано в каждую сторону, как сеанс протарифицирован, какие атрибуты передало "
     "оборудование и какие события произошли за время сеанса.", align="justify")
para("Документное хранение выбрано потому, что у оборудования разных производителей (MikroTik, Cisco, "
     "Juniper, Huawei, Accel-PPP) набор атрибутов сеанса разный и меняется со сменой оборудования или "
     "прошивки: для реляционного хранения под каждый набор пришлось бы заводить колонки или таблицу "
     "«ключ — значение». Запись хранится целиком, как пришла, а нужные поля разбираются запросами; "
     "в частности, запрос 5.4 разбирает запись в строку таблицы сеансов `core.session` курсового проекта.",
     align="justify")
t1 = nxt("Таблица")
para(f"Ключи документа приведены в таблице {t1}, атрибуты, которые передаёт оборудование разных "
     f"производителей, — в таблице {LAB}.{COUNT['Таблица'] + 2}, пример документа — в листинге {nxt('Листинг')}.",
     align="justify")
cols, rows = md_table(struct_md, "## Ключи документа")
rows = [[unmd(c) for c in r] for r in rows]
caption("Таблица", "Ключи документа «Учётная запись сеанса»")
table(["Путь", "Тип", "Обязательность", "Описание", "Пример"], rows,
      widths=[2350, 1050, 1400, 2950, 1600], size=9, mono_cols=(0,))
cols, rows = md_table(struct_md, "### Атрибуты по производителям (`attributes`)")
rows = [[unmd(c) for c in r] for r in rows]
caption("Таблица", "Атрибуты сеанса по производителям оборудования")
table(cols, rows, widths=[1500, 5600, 2250], size=10)

class _Num(str):
    """Число JSON как записано в файле (50.00 остаётся 50.00)."""


def _compact(v, ind=0, width=88):
    """JSON с отступами, но короткие объекты и массивы — в одну строку: документ целиком на одной странице."""
    def flat(x):
        if isinstance(x, dict):
            return "{" + ", ".join(f'"{k}": {flat(w)}' for k, w in x.items()) + "}"
        if isinstance(x, list):
            return "[" + ", ".join(flat(w) for w in x) + "]"
        if isinstance(x, _Num):
            return str(x)
        return json.dumps(x, ensure_ascii=False)
    one = flat(v)
    if not isinstance(v, (dict, list)) or ind + len(one) <= width:
        return [" " * ind + one]
    pad = " " * ind
    out = [pad + ("{" if isinstance(v, dict) else "[")]
    items = list(v.items()) if isinstance(v, dict) else [(None, w) for w in v]
    for i, (k, w) in enumerate(items):
        sub = _compact(w, ind + 2, width)
        if k is not None:
            sub[0] = " " * (ind + 2) + f'"{k}": ' + sub[0].lstrip()
        if i < len(items) - 1:
            sub[-1] += ","
        out += sub
    out.append(pad + ("}" if isinstance(v, dict) else "]"))
    return out


docs = json.loads(read(HERE, "sample_document.json"), parse_float=_Num, object_pairs_hook=dict)
doc_lines = _compact(docs[0])
caption("Листинг", "Пример документа: учётная запись сеанса на узле доступа MikroTik")
code(doc_lines, size=10)

para("Глубина вложенности документа — 4 уровня: например, путь `session.traffic.in.mb` (сеанс → трафик → "
     "входящий → мегабайты), `source.nas.location.city` (источник → узел доступа → расположение → город) "
     "и `billing.tariff.window.from` (тарификация → тариф → окно времени → начало).", align="justify")

# ------------------------------------------------------------------ 2 таблица и заполнение
h("2 Создание таблицы и заполнение данными")
create = read(SQL, "01_create.sql")
m = re.search(r"CREATE TABLE lab7\.session_record.*?\);", create, re.S)
para(f"Документы хранятся в таблице `lab7.session_record` отдельной схемы `lab7` (листинг {nxt('Листинг')}). "
     "Ограничение-проверка требует, чтобы документ был объектом и содержал все обязательные разделы "
     "верхнего уровня (оператор `?&`).", align="justify")
caption("Листинг", "Создание таблицы для хранения документов")
code(m.group(0).splitlines())

gen = read(SQL, "02_generate.sql").splitlines()
i0 = next(i for i, ln in enumerate(gen) if ln.startswith("INSERT INTO lab7.session_record"))
i1 = next(i for i, ln in enumerate(gen) if ln.startswith("FROM y"))
para("Документы порождаются из данных курсового проекта: каждый сеанс `core.session` превращается "
     "в учётную запись (договор, провайдер, тариф, объём, скидка и стоимость берутся из таблиц `core` и `ref`), "
     "а узел доступа, длительность, причина завершения, трафик по направлениям, атрибуты производителя "
     "и журнал событий достраиваются так, как их передал бы сервер доступа. Дополнительно функцией "
     "`generate_series` создаются 400 служебных сеансов наладки узлов (без договора) и 1 200 неудачных "
     "подключений (без трафика) — они удаляются в разделе 5. Генератор повторяем: перед ним вызывается "
     f"`setseed`. Сборка документа показана в листинге {nxt('Листинг')}.", align="justify")
caption("Листинг", "Сборка документа при заполнении таблицы (фрагмент sql/02_generate.sql)")
code(gen[i0:i1])

gtab = all_psql_tables(read(EXPL, "02_generate.txt").splitlines())
(c1, r1), (c2, r2) = gtab[0], gtab[1]
v1 = dict(zip(c1, r1[0]))
v2 = dict(zip(c2, r2[0]))
para(f"Результат заполнения приведён в таблице {nxt('Таблица')}.", align="justify")
caption("Таблица", "Результат заполнения таблицы")
table(["Показатель", "Значение"], [
    ["Документов всего", v1["documents"]],
    ["в том числе служебных сеансов наладки", v1["service_test"]],
    ["в том числе неудачных подключений", v1["failed"]],
    ["Размер таблицы", v1["table_size"].replace("MB", "МБ")],
    ["Средний / наибольший размер документа, байт", f"{v1['avg_doc_bytes']} / {v1['max_doc_bytes']}"],
    ["Документов с путём source.nas.location.city (4 уровня)", v2["depth4_nas_location"]],
    ["Документов с путём session.traffic.in.mb (4 уровня)", v2["depth4_traffic"]],
    ["Документов с путём billing.tariff.window.from (4 уровня)", v2["depth4_tariff_window"]],
    ["Период сеансов", f"{v2['first_session']} – {v2['last_session']}"],
], widths=[6600, 2750])

# ------------------------------------------------------------------ 3 запросы
h("3 Запросы к документам")
para("Значения, от которых зависят запросы (провайдер «ДонНет», номер договора абонента из жалобы, "
     "идентификатор сеанса, отчётный месяц), выбираются по данным в начале каждого скрипта и подставляются "
     "в запросы как константы переменными psql (`:'q_contract_doc'`, `:'q_provider'` и др.). "
     "Для каждого запроса ниже приведены назначение, текст и снимок результата из pgAdmin (Query Tool).", align="justify")

GROUPS = [
    ("3.1 Вывод полей, объектов и массивов", ["3.1_complaint", "3.2_debtors", "3.3_lost_carrier"]),
    ("3.2 Запросы с использованием jsonpath", ["4.1_huawei_night", "4.2_nas_reboot", "4.3_interim_over",
                                                "4.4_lost_interim"]),
    ("3.3 Запросы с функциями обработки JSON", ["5.1_events_table", "5.2_vendor_keys", "5.3_attr_card",
                                                 "5.4_populate_session", "5.5_reconcile", "5.6_nas_summary"]),
]
ROWS = {"5.1_events_table": 7, "5.2_vendor_keys": 8}
WHAT = {   # что выбирает запрос — одной фразой
    "3.1": "последние сеансы договора из жалобы абонента", "3.2": "сеансы должников (признак — в атрибутах NAS)",
    "3.3": "обрывы связи на узлах Макеевки за квартал", "4.1": "сеансы Huawei по тарифу «Выходной ночной» по месяцам",
    "4.2": "сеансы, оборванные перезагрузкой узла, по узлам", "4.3": "промежуточные обновления сверх порога трафика",
    "4.4": "сеансы дольше часа без промежуточных обновлений", "5.1": "журнал событий сеансов договора таблицей",
    "5.2": "ключи атрибутов по производителям и их доля", "5.3": "атрибуты сеанса по идентификатору на NAS",
    "5.4": "разбор учётной записи в строку core.session", "5.5": "сверка всех учётных записей с core.session",
    "5.6": "сводка за месяц по узлам одним JSON-документом",
}

SHOTS = os.path.join(HERE, "screenshots")      # результаты запросов — снимки pgAdmin (Query Tool)


def shot(name, title):
    """Снимок результата из pgAdmin; узкие снимки крупнее, чтобы текст читался."""
    from PIL import Image
    path = os.path.join(SHOTS, name + ".png")
    w = Image.open(path).width if os.path.exists(path) else 1512
    R.figure(path, title, width_cm=min(16.5, 16.5 * w / 1000))


for gtitle, names in GROUPS:
    h(gtitle)
    for name in names:
        ex = explain_file(name)
        no = name.split("_")[0]
        tools = ex["meta"]["Раздел задания"].split(":", 1)[-1].strip()
        para(f"Запрос {no} — {WHAT[no]}; использовано: {tools}. Листинг {nxt('Листинг')}, "
             f"рисунок {nxt('Рисунок')}.", align="justify")
        caption("Листинг", f"Запрос {no}")
        code(sql_text(section(ex, "SQL")))
        shot(name, f"Результат запроса {no} в pgAdmin"
             + (" (документ-сводка выведен построчно функцией string_to_table)" if no == "5.6" else ""))
para("Сверка 5.5: все 100 025 записей совпали с сеансами курсового проекта.", align="justify")

# ------------------------------------------------------------------ 4 изменения внутри документов
h("4 Изменение данных внутри документов")
upd = read(EXPL, "06_update.txt").splitlines()
blocks, cur = [], None
for ln in upd:
    if re.match(r"^6\.\d ", ln):
        cur = [ln]
        blocks.append(cur)
    elif cur is not None:
        cur.append(ln)
TOOLS = {"6.1": "jsonb_set", "6.2": "jsonb_set (create_missing)", "6.3": "jsonb_set_lax", "6.4": "jsonb_insert (перед элементом)",
         "6.5": "jsonb_insert (после элемента)", "6.6": "||", "6.7": "- (удаление ключа)", "6.8": "#- (удаление по пути)",
         "6.9": "jsonb_strip_nulls"}
UPD = {   # повод изменения — одной фразой
    "6.1": "исправлен адрес узла bras01-2", "6.2": "в записи сентября добавлен номер счёта",
    "6.3": "удалён номер аннулированного счёта", "6.4": "перед завершением сеанса вставлено событие смены скорости",
    "6.5": "после начала сеанса вставлено пересланное промежуточное обновление",
    "6.6": "добавлена отметка о проверке по жалобе", "6.7": "из атрибутов удалена служебная метка class",
    "6.8": "из записей старше года удалён MAC-адрес", "6.9": "удалены пустые атрибуты",
}
summary = []
parsed = []
for b in blocks:
    no, title = b[0].split(" ", 1)
    reason = title.split(": ", 1)[1] if ": " in title else title
    u0 = next(i for i, ln in enumerate(b) if ln.startswith("UPDATE"))
    u1 = next(i for i in range(u0, len(b)) if b[i].rstrip().endswith(";"))
    count = next(ln.split(":")[1].strip() for ln in b if ln.startswith("изменено записей"))
    tabs = all_psql_tables(b)
    before = next(t for t in tabs if any(c in ("before",) for c in t[0]))
    after = next(t for t in tabs if "after" in t[0])
    summary.append([no, TOOLS[no], UPD[no][0].upper() + UPD[no][1:], count])
    parsed.append((no, reason, b[u0:u1 + 1], before, after, count))
para(f"Выполнено девять изменений данных внутри документов, у каждого — повод из работы провайдера "
     f"(таблица {nxt('Таблица')}). Для каждого изменения выводится одна и та же запись до и после изменения.",
     align="justify")
caption("Таблица", "Изменения данных внутри документов")
table(["№", "Средство", "Повод", "Записей"], summary, widths=[600, 3000, 4750, 1000])
for no, reason, upd_sql, before, after, count in parsed:
    lst, tb = nxt("Листинг"), nxt("Таблица")
    para(f"Изменение {no} ({TOOLS[no]}) — {UPD[no]}; записей: {count} (листинг {lst}, таблица {tb}).",
         align="justify")
    caption("Листинг", f"Изменение {no}")
    code(upd_sql)
    cb, rb = before
    ca, ra = after
    keep = [j for j, c in enumerate(cb) if c != "id"]
    rows = []
    for j in keep:
        name = cb[j]
        label = "до" if name == "before" else name
        rows.append([label, rb[0][j] if rb[0][j] else "(нет ключа)"])
    ja = [j for j, c in enumerate(ca) if c != "id"]
    for j in ja:
        label = "после" if ca[j] == "after" else ca[j] + " (после)"
        rows.append([label, ra[0][j]])
    caption("Таблица", f"Запись до и после изменения {no} (код записи {rb[0][0]})")
    table(["Значение", "Фрагмент документа"], rows, widths=[1500, 7850], mono_cols=(1,))

# ------------------------------------------------------------------ 5 удаление документов
h("5 Удаление документов")
dele = read(EXPL, "07_delete.txt").splitlines()
dblocks, cur = [], None
for ln in dele:
    if re.match(r"^7\.\d ", ln):
        cur = [ln]
        dblocks.append(cur)
    elif cur is not None:
        cur.append(ln)
DEL_TOOL = {"7.1": "служебные сеансы наладки без договора, по образцу @>",
            "7.2": "неудачные подключения без трафика, по условию jsonpath @?"}
for b in dblocks:
    no, title = b[0].split(" ", 1)
    d0 = next(i for i, ln in enumerate(b) if ln.startswith("DELETE"))
    d1 = next(i for i in range(d0, len(b)) if b[i].rstrip().endswith(";"))
    cnt = next(ln.split(":")[1].strip() for ln in b if ln.startswith("удалено записей"))
    tabs = all_psql_tables(b)
    lst, tb = nxt("Листинг"), nxt("Таблица")
    para(f"Удаление {no} — {DEL_TOOL[no]}; удалено {cnt} (листинг {lst}, таблица {tb}).", align="justify")
    caption("Листинг", f"Удаление {no}")
    code(b[d0:d1 + 1])
    caption("Таблица", f"Примеры документов, удаляемых запросом {no}")
    table(*tabs[0])
left = all_psql_tables(dele)[-1]
para(f"После удалений в таблице осталось {left[1][0][0]} документов: требование «не менее 100 000» "
     "выполняется и после удаления.", align="justify")

# ------------------------------------------------------------------ 6 индексы
h("6 Индексы")
idx_sql = read(SQL, "08_indexes.sql")
creates = re.findall(r"CREATE (?:UNIQUE )?INDEX IF NOT EXISTS .*?;", idx_sql, re.S)
para(f"Созданы четыре индекса (листинг {nxt('Листинг')}): один по документу целиком и три по элементам ключей.",
     align="justify")
caption("Листинг", "Создание индексов")
code("\n\n".join(creates).splitlines())
bullets([
    "`ix_session_record_doc` — GIN по документу целиком с классом операторов `jsonb_path_ops`: поиск по образцу "
    "(`@>`) и по jsonpath с условиями равенства (`@?`, `@@`) — договор, узел доступа, причина завершения, "
    "события журнала, производитель и тариф;",
    "`ix_session_record_attributes` — GIN по вложенному объекту `attributes` с классом `jsonb_ops`: проверка "
    "наличия атрибута (`?`, `?|`), которую `jsonb_path_ops` не поддерживает;",
    "`uq_session_record_provider_acct` — уникальный B-дерево по выражениям «провайдер + идентификатор сеанса "
    "на NAS»: повторная выгрузка того же сеанса отвергается, а запись находится по идентификатору из журнала NAS;",
    "`ix_session_record_started_at` — B-дерево по времени начала сеанса для отборов за период. Значение — строка "
    "ISO 8601 с одинаковым смещением +03:00, поэтому побайтовое сравнение строк (`COLLATE \"C\"`) совпадает "
    "со сравнением моментов времени; приведение к `timestamptz` в индексе невозможно, так как оно зависит "
    "от настроек сеанса (функция не IMMUTABLE).",
])
itab = all_psql_tables(read(EXPL, "08_indexes.txt").splitlines())
sizes, opcl = itab[0], itab[1]
para(f"Размеры индексов приведены в таблице {nxt('Таблица')}. Класс `jsonb_path_ops` выбран для индекса "
     "по документу потому, что элемент такого индекса — хеш пути вместе со значением "
     "(«source.nas.vendor = Huawei»), а не отдельные ключ и значение: образец из нескольких ключей "
     f"отбирается точнее, а индекс меньше (таблица {LAB}.{COUNT['Таблица'] + 2}).", align="justify")
caption("Таблица", "Размеры индексов")
ru = lambda s: s.replace("kB", "кБ").replace("MB", "МБ")
table(["Индекс", "Метод", "Размер", "Размер таблицы"],
      [[r[0], r[1], ru(r[2]), ru(r[3])] for r in sizes[1]], widths=[4200, 1300, 1700, 2150])
caption("Таблица", "Размер индекса GIN по документу при разных классах операторов")
table(["Класс операторов", "Размер"], [[r[0], ru(r[1])] for r in opcl[1]], widths=[4675, 4675])

# ------------------------------------------------------------------ 7 анализ и оптимизация
h("7 Анализ и оптимизация запросов")
ex0 = explain_file("9.1_contract")
settings = next(ln for ln in read(EXPL, "9.1_contract.txt").splitlines() if ln.startswith("work_mem"))
server = ex0["meta"]["Сервер"].split(" on ")[0]
para(f"Планы всех запросов сняты командой `EXPLAIN (ANALYZE, BUFFERS)` на сервере {server} "
     f"(Windows; {settings}) при 100 025 документах в таблице. "
     "План «до» снят без индексов: в транзакции индексы удаляются (`DROP INDEX`), план снимается, транзакция "
     "откатывается, поэтому данные «до» и «после» одни и те же. План «после» снят с индексами. Перед планами "
     "выполнена команда `ANALYZE`, каждый план — второй прогон после прогревочного. Стоимость — оценка "
     "верхнего узла плана, время — Execution Time.", align="justify")
IDX = index_md()
SHORT = {
    "3.1": "Сеансы договора из жалобы", "3.2": "Сеансы должников (атрибуты)", "3.3": "Обрывы связи в Макеевке",
    "4.1": "Huawei, тариф «Выходной ночной»", "4.2": "Обрывы из-за перезагрузки NAS", "4.3": "Обновления сверх порога ($mb)",
    "4.4": "Сеансы без промежуточных обновлений", "5.1": "Журнал событий таблицей", "5.2": "Ключи атрибутов по производителям",
    "5.3": "Атрибуты сеанса по Acct-Session-Id", "5.4": "Разбор в строку core.session", "5.5": "Сверка с core.session",
    "5.6": "Сводка по узлам в JSON",
    "9.1": "->> → @>", "9.2": "jsonb_path_exists → @?", "9.3": "индекс GIN по attributes",
    "9.4": "-> ->> → #>> (как в индексе)", "9.5": "::timestamptz → строка COLLATE \"C\"", "9.6": "два сравнения #>> → @@",
    "9.7": "диапазон в jsonpath", "9.8": "условие на половину таблицы",
}


def short_index(s):
    s = unmd(s)
    if s.startswith("нет"):
        return "нет"
    s = s.split(" (")[0].replace(" — выигрыша нет", "")
    return s


rows = []
for no in sorted(IDX, key=lambda k: (int(k.split(".")[0]), int(k.split(".")[1]))):
    v = IDX[no]
    rows.append([no, SHORT[no], num(v["cost"]), num(v["time"]), short_index(v["index"])])
para(f"Сводка по всем запросам приведена в таблице {nxt('Таблица')}: запросы 3.1–5.6 — в исходной форме, "
     "9.1–9.6 — оптимизированные, 9.7 и 9.8 — примеры, где индекс не даёт выигрыша.", align="justify")
caption("Таблица", "Стоимость и время выполнения запросов без индексов и с индексами")
table(["№", "Запрос", "Стоимость до → после", "Время, мс, до → после", "Индекс в плане «после»"], rows,
      widths=[600, 2900, 1950, 1700, 2200], size=9)
para("Запросы 4.4, 5.2 и 5.5 индексов не используют по существу: в 4.4 условие — диапазон и отрицание, "
     "которые GIN не ищет, а 5.2 и 5.5 обрабатывают все записи таблицы.", align="justify")

OPT = [
    ("9.1_contract", "условие `->>` по цепочке ключей заменено образцом @>"),
    ("9.2_nas_reboot", "функция jsonb_path_exists заменена оператором @?"),
    ("9.3_debtors", "запрос не меняется — для проверки ключей ?| создан GIN jsonb_ops по attributes"),
    ("9.4_acct_id", "выражение записано как в индексе: #>> вместо -> ->>"),
    ("9.5_month", "приведение к timestamptz заменено сравнением строк ISO 8601 с COLLATE \"C\", как в индексе"),
    ("9.6_huawei_night", "два сравнения извлечённых значений заменены предикатом jsonpath @@"),
]
h("7.1 Оптимизированные запросы")
para("В планах показаны узлы, условия и время выполнения; результаты исходной и оптимизированной форм совпадают.",
     align="justify")
for name, why in OPT:
    ex = explain_file(name)
    no = name.split("_")[0]
    before_sql = section(ex, "SQL: исходная форма")
    after_sql = section(ex, "SQL: оптимизированная форма") or section(ex, "SQL")
    l1 = nxt("Листинг")
    if before_sql:
        para(f"Запрос {no}: {why} (листинги {l1}–{nxt('Листинг', 4)}).", align="justify")
        caption("Листинг", f"Запрос {no}, исходная форма")
        code(sql_text(before_sql))
        caption("Листинг", f"Запрос {no}, оптимизированная форма")
        code(sql_text(after_sql))
    else:
        para(f"Запрос {no}: {why} (листинги {l1}–{nxt('Листинг', 3)}).", align="justify")
        caption("Листинг", f"Запрос {no}")
        code(sql_text(after_sql))
    caption("Листинг", f"План запроса {no} до оптимизации (без индексов)")
    code(plan_lines(section(ex, "План «до»")), size=9)
    caption("Листинг", f"План запроса {no} после оптимизации (с индексами)")
    code(plan_lines(section(ex, "План «после»")), size=9)
    tot = ex["total"]
    m = re.search(r"стоимость верхнего узла (.+?) → (.+?); время выполнения (.+?) → (.+?) мс", tot)
    para(f"Стоимость {num(m.group(1))} → {num(m.group(2))}, время {num(m.group(3))} → {num(m.group(4))} мс; "
         "стоимость узлов не выросла.", align="justify")

h("7.2 Запросы, которым индекс не помогает")
ex7 = explain_file("9.7_range_no_index")
para("Запрос 9.7 — сравнение «больше» внутри jsonpath: GIN хранит пары «путь = значение» и диапазон не ищет, "
     f"план остаётся последовательным чтением (листинги {nxt('Листинг')}, {nxt('Листинг', 2)}).", align="justify")
caption("Листинг", "Запрос 9.7")
code(sql_text(section(ex7, "SQL")))
caption("Листинг", "План запроса 9.7 с индексами")
code(plan_lines(section(ex7, "План «после»")), size=9)
ex8 = explain_file("9.8_half_table")
para("Запрос 9.8 — условию отвечает 55 % записей; статистики по содержимому jsonb нет, планировщик ждёт "
     "1 000 строк вместо 54 868 и выбирает индекс, но время то же, что без него "
     f"(листинги {nxt('Листинг')}, {nxt('Листинг', 2)}).", align="justify")
caption("Листинг", "План запроса 9.8 с индексом")
code(plan_lines(section(ex8, "План «после»")), size=9)
caption("Листинг", "План запроса 9.8 при запрете сканирования по битовой карте (enable_bitmapscan = off)")
code(plan_lines(section(ex8, "Для сравнения")), size=9)

# ------------------------------------------------------------------ выводы
h("Выводы")
para("В работе разработана документная модель учётной записи сеанса связи из биллинга провайдера с глубиной "
     "вложенности 4, таблица заполнена 101 625 документами, порождёнными из данных курсового проекта. "
     "Выполнены запросы с операторами извлечения и поиска по образцу, с языком путей jsonpath и с функциями "
     "обработки JSON, девять изменений внутри документов и два удаления документов. Созданы четыре индекса; "
     "шесть запросов оптимизированы так, что используют индексы, а стоимость узлов их планов не выросла, "
     "на двух запросах показано, когда индекс не помогает. Для курсового проекта показано, что выгрузка "
     "биллинга разбирается в таблицу сеансов одним запросом и полностью сверяется с учётом.", align="justify")

R.save(OUT)
