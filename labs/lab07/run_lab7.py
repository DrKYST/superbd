"""ЛР 7: прогон скриптов labs/lab07/sql по порядку и материалы для отчёта → labs/lab07/explain/.

    python labs/lab07/run_lab7.py              # пересоздать схему lab7 (шаги 01–09) и снять планы
    python labs/lab07/run_lab7.py --explain    # только планы и сводка (схема lab7 уже построена)

Шаги 01–09 выполняются psql по одному файлу (ON_ERROR_STOP); вывод шагов 02, 06, 07, 08 сохраняется в explain/
(генерация, документы до и после изменений, удаления, индексы). Затем для каждого запроса — блоки «-- @q» в 03–05
и «-- @opt» в 09 — файл explain/<имя>.txt:
  * SQL и результат (первые строки);
  * план без индексов: в транзакции удаляются все индексы lab7.session_record, кроме первичного ключа
    (DROP INDEX), снимается план, транзакция откатывается — данные те же, что у плана с индексами;
  * план с индексами; у «-- @opt» с исходной формой — ещё план исходной формы с индексами (видно, применим ли
    индекс без переписывания запроса) и сравнение узлов «до» и «после».
Перед планами — ANALYZE таблицы; каждый план снимается дважды, в файл идёт второй прогон (первый прогревает кэш).
Сводка — explain/INDEX.md. Подключение — psql + pgpass (PSQL, PGHOST, PGPORT можно переопределить).
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
LAB = Path(__file__).resolve().parent
SQL = LAB / "sql"
OUT = LAB / "explain"
TABLE = "lab7.session_record"
STEPS = ["01_create.sql", "02_generate.sql", "03_select_operators.sql", "04_jsonpath.sql", "05_functions.sql",
         "06_update.sql", "07_delete.sql", "08_indexes.sql", "09_optimize.sql"]
SAVED = {"02_generate.sql": "02_generate.txt", "06_update.sql": "06_update.txt",
         "07_delete.sql": "07_delete.txt", "08_indexes.sql": "08_indexes.txt"}
QUERY_FILES = ["03_select_operators.sql", "04_jsonpath.sql", "05_functions.sql", "09_optimize.sql"]
EXPLAIN = "EXPLAIN (ANALYZE, BUFFERS)"
RESULT_LINES = 40          # результат в файле: заголовок и первые строки
NODE = re.compile(r"^(?P<indent>\s*)(?:->\s+)?(?P<name>\S.*?)\s+\(cost=(?P<c0>[\d.]+)\.\.(?P<c1>[\d.]+) "
                  r"rows=(?P<erows>\d+) width=\d+\) \(actual time=(?P<t0>[\d.]+)\.\.(?P<t1>[\d.]+) "
                  r"rows=(?P<arows>[\d.]+) loops=(?P<loops>\d+)\)")


def psql(args: list[str], stdin: str | None = None, cwd: Path = SQL) -> str:
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    cmd = [PSQL, "-h", os.environ.get("PGHOST", "127.0.0.1"), "-p", os.environ.get("PGPORT", "5432"),
           "-U", "postgres", "-w", "-d", "superbd", "-X", "-q", "-P", "pager=off", "-P", "footer=off",
           "-v", "ON_ERROR_STOP=1", *args]
    res = subprocess.run(cmd, input=stdin.encode("utf-8") if stdin is not None else None,
                         capture_output=True, env=env, cwd=cwd)
    out = res.stdout.decode("utf-8", errors="replace")
    err = res.stderr.decode("utf-8", errors="replace")
    if res.returncode != 0:
        sys.exit(f"psql завершился с ошибкой ({' '.join(args)}):\n{err}\n{out[-3000:]}")
    return out + (("\n" + err) if err.strip() else "")


def run_steps() -> dict[str, float]:
    OUT.mkdir(exist_ok=True)
    timing = {}
    for step in STEPS:
        t = time.perf_counter()
        out = psql(["-f", step])
        timing[step] = time.perf_counter() - t
        if step in SAVED:
            (OUT / SAVED[step]).write_text(f"-- Вывод labs/lab07/sql/{step} (psql -f, ON_ERROR_STOP)\n\n{out.rstrip()}\n",
                                           encoding="utf-8")
        print(f"{step}: {timing[step]:.1f} с")
    return timing


def parse_blocks(path: Path) -> list[dict]:
    blocks, cur, section = [], None, None
    for line in path.read_text(encoding="utf-8").splitlines():
        for kind in ("q", "opt"):
            tag = f"-- @{kind} "
            if line.startswith(tag):
                name, req, purpose = [x.strip() for x in line[len(tag):].split(" | ", 2)]   # «?|», «||» — не разделители
                cur = {"kind": kind, "name": name, "req": req, "purpose": purpose, "file": path.name,
                       "before": [], "after": [], "compare": None, "negative": False, "note": None}
                blocks.append(cur)
                section = "after" if kind == "q" else None
                break
        else:
            if cur is None:
                continue
            if line.startswith("-- @before"):
                section = "before"
            elif line.startswith("-- @after"):
                section = "after"
            elif line.startswith("-- @note "):
                cur["note"] = line[len("-- @note "):].strip()
            elif line.startswith("-- @negative"):
                cur["negative"] = True
            elif line.startswith("-- @compare "):
                cur["compare"] = line[len("-- @compare "):].strip()
            elif section:
                cur[section].append(line)
    for b in blocks:
        for key in ("before", "after"):
            b[key] = "\n".join(b[key]).strip()
    return blocks


def secondary_indexes() -> list[str]:
    out = psql(["-A", "-t", "-c",
                f"SELECT string_agg(c.oid::regclass::text, ',' ORDER BY c.relname) FROM pg_index i "
                f"JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = '{TABLE}'::regclass AND NOT i.indisprimary"])
    return [x for x in out.strip().split(",") if x]


def explain_twice(sql: str, marker: str, settings: str = "") -> str:
    """Прогрев (вывод отбрасывается) и снятый прогон плана."""
    return (f"\\o {os.devnull}\n{settings}\n{EXPLAIN}\n{sql}\n\\o\n"
            f"\\echo {marker}\n{EXPLAIN}\n{sql}\n")


def run_block(b: dict, indexes: list[str]) -> dict:
    before = b["before"] or b["after"]
    drop = f"DROP INDEX {', '.join(indexes)};" if indexes else ""
    script = [f"\\i '{(SQL / '00_params.sql').as_posix()}'", "SET TimeZone = 'Europe/Moscow';",
              "\\echo @@@RESULT", b["after"]]
    if b["before"]:
        script += ["\\echo @@@RESULT_BEFORE", b["before"]]
    script += ["\\pset format unaligned", "\\pset tuples_only on",
               "BEGIN;", drop, explain_twice(before, "@@@PLAN_NOIDX"), "ROLLBACK;"]
    if b["before"]:
        script.append(explain_twice(b["before"], "@@@PLAN_BEFORE_IDX"))
    script.append(explain_twice(b["after"], "@@@PLAN_IDX"))
    if b["compare"]:
        script += ["BEGIN;", explain_twice(b["after"], "@@@PLAN_COMPARE", b["compare"].rstrip(";") + ";"), "ROLLBACK;"]
    out = psql(["-f", "-"], "\n".join(script) + "\n")
    parts, key = {}, None
    for line in out.splitlines():
        if line.startswith("@@@"):
            key = line[3:].strip()
            parts[key] = []
        elif key:
            parts[key].append(line)
    return {k: "\n".join(v).strip("\n") for k, v in parts.items()}


def nodes(plan: str) -> list[dict]:
    res = []
    for line in plan.splitlines():
        m = NODE.match(line)
        if m:
            d = m.groupdict()
            res.append({"depth": len(d["indent"]), "name": d["name"], "cost": float(d["c1"]),
                        "erows": int(d["erows"]), "arows": float(d["arows"]), "time": float(d["t1"]),
                        "loops": int(d["loops"])})
    return res


def total(plan: str) -> tuple[float | None, float | None]:
    ns = nodes(plan)
    m = re.search(r"Execution Time: ([\d.]+) ms", plan)
    return (ns[0]["cost"] if ns else None), (float(m.group(1)) if m else None)


def used_indexes(plan: str) -> list[str]:
    return sorted(set(re.findall(r"(?:Index Scan|Index Only Scan|Bitmap Index Scan) (?:using |on )(\w+)", plan)))


def base_name(name: str) -> str:
    name = re.sub(r"^(Parallel|Partial|Finalize)\s+", "", name)
    name = re.sub(r"\s+(on|using)\s+.*$", "", name)
    return "Aggregate" if name in ("HashAggregate", "GroupAggregate", "MixedAggregate") else name


SCANS = {"Seq Scan", "Bitmap Heap Scan", "Index Scan", "Index Only Scan"}


def node_table(before: str, after: str) -> str:
    """Узлы плана «после» и соответствующие им узлы «до»: сканирование — с чтением таблицы целиком,
    остальные — по типу узла. Bitmap Index Scan / BitmapAnd входят в стоимость Bitmap Heap Scan над ними."""
    nb, na = nodes(before), nodes(after)
    used = set()
    rows = ["| Узел «после» | cost | время, мс | Узел «до» | cost | время, мс | Стоимость не выросла |",
            "|---|---|---|---|---|---|---|"]
    for a in na:
        ab = base_name(a["name"])
        pair = None
        if ab not in ("Bitmap Index Scan", "BitmapAnd", "BitmapOr"):
            for i, b in enumerate(nb):
                bb = base_name(b["name"])
                if i in used:
                    continue
                if (ab in SCANS and bb in SCANS) or ab == bb:
                    pair = (i, b)
                    break
        level = 0 if a["depth"] == 0 else (a["depth"] - 2) // 6 + 1
        indent = "· " * level
        left = f"| {indent}{a['name']} | {a['cost']:.2f} | {a['time']:.3f} × {a['loops']} |"
        if pair:
            used.add(pair[0])
            b = pair[1]
            ok = "да" if a["cost"] <= b["cost"] else "НЕТ"
            rows.append(f"{left} {b['name']} | {b['cost']:.2f} | {b['time']:.3f} × {b['loops']} | {ok} |")
        else:
            rows.append(f"{left} — | | | входит в узел выше |" if ab in ("Bitmap Index Scan", "BitmapAnd", "BitmapOr")
                        else f"{left} — | | | новый узел |")
    rest = [b for i, b in enumerate(nb) if i not in used]
    if rest:
        rows.append("")
        rows.append("Узлы «до», которым нет пары «после» (исчезли из плана): "
                    + "; ".join(f"{b['name']} (cost {b['cost']:.2f})" for b in rest))
    return "\n".join(rows)


def head(text: str, n: int = RESULT_LINES) -> str:
    lines = text.splitlines()
    if len(lines) <= n:
        return text
    return "\n".join(lines[:n]) + f"\n… (показаны первые {n} строк вывода из {len(lines)})"


def server_info() -> str:
    out = psql(["-A", "-t", "-F", " | ", "-c",
                "SELECT version(), current_setting('work_mem'), current_setting('shared_buffers'), "
                "current_setting('max_parallel_workers_per_gather'), current_setting('random_page_cost'), "
                f"(SELECT count(*) FROM {TABLE}), pg_size_pretty(pg_relation_size('{TABLE}')), "
                f"pg_size_pretty(pg_indexes_size('{TABLE}')), to_char(now(), 'DD.MM.YYYY HH24:MI')"])
    v = [x.strip() for x in out.strip().split(" | ")]
    return (f"Сервер: {v[0]}\nwork_mem = {v[1]}, shared_buffers = {v[2]}, max_parallel_workers_per_gather = {v[3]}, "
            f"random_page_cost = {v[4]}\nТаблица {TABLE}: {v[5]} документов, {v[6]} (индексы {v[7]}); снято {v[8]}")


class Num(str):
    """Число из JSON как есть (50.00 остаётся 50.00, а не 50.0)."""


KEY_ORDER = ["source", "contract", "session", "billing", "attributes", "events", "review",
             "provider", "nas", "number", "code", "name", "vendor", "model", "ip", "city", "location", "address",
             "acct_id", "user_name", "started_at", "stopped_at", "duration_s", "stop_cause", "traffic", "in", "out",
             "mb", "packets", "tariff", "code", "window", "from", "to", "weekend", "price_per_mb", "discount_pct",
             "cost", "invoice", "at", "type", "in_mb", "out_mb", "cause"]


def pretty(v, ind: int = 0) -> str:
    """JSON с отступами и ключами в порядке описания структуры (jsonb хранит ключи по длине и алфавиту)."""
    pad = "  " * ind
    if isinstance(v, dict):
        if not v:
            return "{}"
        keys = sorted(v, key=lambda k: KEY_ORDER.index(k) if k in KEY_ORDER else len(KEY_ORDER))
        return "{\n" + ",\n".join(f"{pad}  {json.dumps(k, ensure_ascii=False)}: {pretty(v[k], ind + 1)}"
                                  for k in keys) + f"\n{pad}}}"
    if isinstance(v, list):
        if all(not isinstance(x, (dict, list)) for x in v):
            return "[" + ", ".join(pretty(x) for x in v) + "]"
        return "[\n" + ",\n".join(f"{pad}  {pretty(x, ind + 1)}" for x in v) + f"\n{pad}]"
    if isinstance(v, Num):
        return str(v)
    return json.dumps(v, ensure_ascii=False)


# Образцы для отчёта: типичные записи двух производителей с разным набором атрибутов.
SAMPLES = [
    ("MikroTik: тариф с окном времени, промежуточные обновления, метка Class",
     """doc @> '{"source": {"nas": {"vendor": "MikroTik"}}}' AND doc -> 'attributes' ? 'class'
        AND doc @? '$.billing.tariff.window.from' AND doc @? '$.events[*] ? (@.type == "interim")'
        AND (doc #>> '{session,started_at}') COLLATE "C" >= '2026-09-01'"""),
    ("Cisco: тариф без окна времени (window = null), атрибут-массив av_pairs",
     """doc @> '{"source": {"nas": {"vendor": "Cisco"}}, "billing": {"tariff": {"window": null}}}'
        AND doc @? '$.events[*] ? (@.type == "interim")'
        AND (doc #>> '{session,started_at}') COLLATE "C" >= '2026-09-01'"""),
]


def write_samples():
    docs = []
    for title, cond in SAMPLES:
        out = psql(["-A", "-t", "-c", f"SELECT doc::text FROM {TABLE} WHERE {cond} ORDER BY id LIMIT 1"]).strip()
        docs.append((title, json.loads(out, parse_float=Num, parse_int=Num)))
    body = ",\n".join("  " + pretty(d, 1) for _, d in docs)
    (LAB / "sample_document.json").write_text("[\n" + body + "\n]\n", encoding="utf-8")
    print("sample_document.json: " + "; ".join(t for t, _ in docs))


def fmt(x: float | None, digits: int = 2) -> str:
    return "—" if x is None else f"{x:,.{digits}f}".replace(",", " ")


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")     # консоль Windows — cp1251
    timing = {} if "--explain" in sys.argv else run_steps()
    psql(["-c", f"ANALYZE {TABLE};"])
    info = server_info()
    indexes = secondary_indexes()
    params = psql(["-f", "00_params.sql"]).strip()
    summary = []
    for f in QUERY_FILES:
        for b in parse_blocks(SQL / f):
            r = run_block(b, indexes)
            no_c, no_t = total(r.get("PLAN_NOIDX", ""))
            ix_c, ix_t = total(r.get("PLAN_IDX", ""))
            idx = used_indexes(r.get("PLAN_IDX", ""))
            same = None
            if b["before"]:
                same = r.get("RESULT", "") == r.get("RESULT_BEFORE", "")
            text = [f"Запрос {b['name']} ({b['file']})", f"Раздел задания: {b['req']}", f"Зачем: {b['purpose']}",
                    info, params, ""]
            if b["before"]:
                text += ["-- SQL: исходная форма («до»)", b["before"], "",
                         "-- SQL: оптимизированная форма («после»)", b["after"], ""]
            else:
                text += ["-- SQL", b["after"], ""]
            text += ["-- Результат (первые строки)", head(r.get("RESULT", "")), ""]
            if same is not None:
                text += [f"Результаты исходной и оптимизированной форм совпадают: {'да' if same else 'НЕТ'}", ""]
            label_no = "исходная форма, " if b["before"] else ""
            text += [f"-- План «до»: {label_no}без индексов (DROP INDEX в транзакции с откатом), второй прогон",
                     r.get("PLAN_NOIDX", ""), ""]
            if b["before"]:
                text += ["-- План исходной формы при наличии индексов (применим ли индекс без переписывания)",
                         r.get("PLAN_BEFORE_IDX", ""), ""]
            label_ix = "оптимизированная форма, " if b["before"] else ""
            text += [f"-- План «после»: {label_ix}с индексами, второй прогон", r.get("PLAN_IDX", ""), ""]
            if b["compare"]:
                text += [f"-- Для сравнения: тот же запрос с индексами, но {b['compare']}", r.get("PLAN_COMPARE", ""), ""]
            if b["kind"] == "opt":
                text += ["-- Сравнение узлов: «после» (с индексами) и «до» (без индексов)",
                         node_table(r.get("PLAN_NOIDX", ""), r.get("PLAN_IDX", "")), ""]
            text += [f"Итог: стоимость верхнего узла {fmt(no_c)} → {fmt(ix_c)}; время выполнения {fmt(no_t, 3)} → "
                     f"{fmt(ix_t, 3)} мс; индексы в плане «после»: {', '.join(idx) if idx else 'не используются'}"
                     + (" — пример, где индекс не даёт выигрыша (причина — в «Зачем» и в README)" if b["negative"] else "")
                     + (f" ({b['note']})" if b["note"] else "")]
            cmp_t = total(r["PLAN_COMPARE"])[1] if b["compare"] else None
            (OUT / f"{b['name']}.txt").write_text("\n".join(text).rstrip() + "\n", encoding="utf-8")
            summary.append({**b, "no": (no_c, no_t), "ix": (ix_c, ix_t), "idx": idx, "same": same, "cmp_t": cmp_t})
            print(f"{b['name']}: {fmt(no_c)} → {fmt(ix_c)}, {fmt(no_t, 3)} → {fmt(ix_t, 3)} мс, {', '.join(idx) or '—'}")
    write_index(summary, info, timing)
    write_samples()


def write_index(summary: list[dict], info: str, timing: dict[str, float]):
    lines = ["# ЛР 7 — сводка запросов, планов и индексов", "",
             "Создаётся `labs/lab07/run_lab7.py` — не править вручную.", "", "```", info, "```", "",
             "«До» — без индексов (в транзакции `DROP INDEX` всех индексов, кроме первичного ключа, затем `ROLLBACK`; "
             "у оптимизированных запросов — ещё и исходная форма запроса), «после» — с индексами "
             "(у оптимизированных — переписанная форма). Каждый план — второй прогон после прогревочного, "
             "после `ANALYZE`. Стоимость — оценка верхнего узла плана, время — `Execution Time`.", "",
             "| № | Раздел задания | Что делает | SQL | Вывод | cost до → после | время, мс до → после | Индекс в плане «после» |",
             "|---|---|---|---|---|---|---|---|"]
    def cell(text: str) -> str:
        return text.replace("|", "\\|")

    for s in summary:
        purpose = s["purpose"].split(":")[0].split(" — ")[0]
        idx = ", ".join(f"`{x}`" for x in s["idx"]) if s["idx"] else "нет"
        if s["note"]:
            idx += f" ({s['note']})"
        if s["negative"]:
            idx += " — **выигрыша нет**"
        req = ("Оптимизация (≥ 5): " if s["kind"] == "opt" and not s["negative"] else
               "Индекс не помог: " if s["negative"] else "") + s["req"]
        lines.append(f"| {s['name'].split('_')[0]} | {cell(req)} | {cell(purpose)} | `sql/{s['file']}` | "
                     f"`explain/{s['name']}.txt` | {fmt(s['no'][0])} → {fmt(s['ix'][0])} | "
                     f"{fmt(s['no'][1], 3)} → {fmt(s['ix'][1], 3)} | {idx} |")
    lines += ["", "## Изменения, удаления, индексы", "",
              "| Шаг | Раздел задания | SQL | Вывод |", "|---|---|---|---|",
              "| Генерация документов | заполнение ≥ 100 000, глубина ≥ 4 | `sql/02_generate.sql` | `explain/02_generate.txt` |",
              "| 6.1–6.9 | изменение данных внутри документа (≥ 6) | `sql/06_update.sql` | `explain/06_update.txt` |",
              "| 7.1–7.2 | удаление документов (≥ 2) | `sql/07_delete.sql` | `explain/07_delete.txt` |",
              "| Индексы | ≥ 3: по документу целиком и по элементам ключей | `sql/08_indexes.sql` | `explain/08_indexes.txt` |"]
    if timing:
        lines += ["", "## Время шагов (последний прогон run_lab7.py)", "", "| Шаг | Время, с |", "|---|---|"]
        lines += [f"| `{k}` | {v:.1f} |" for k, v in timing.items()]
        lines += [f"| всего | {sum(timing.values()):.1f} |"]
    (OUT / "INDEX.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("INDEX.md")


if __name__ == "__main__":
    main()
