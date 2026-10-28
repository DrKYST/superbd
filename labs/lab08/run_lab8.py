"""ЛР 8: стенд сравнения и материалы → labs/lab08/explain/.

    python labs/lab08/run_lab8.py              # копии lab8 (шаг 01), устройство секций, сравнение, обслуживание
    python labs/lab08/run_lab8.py --explain    # только сравнение и сводка (копии уже есть)

Секционированные таблицы — рабочие core.session и core.contract (миграции 040, 042, D30); база должна быть собрана
db/build.sql. Шаги:
  01_copies.sql      → explain/01_copies.txt      обычные копии lab8.session_plain, lab8.contract_plain;
  02_structure.sql   → explain/02_structure.txt   дерево секций, границы, строки и размеры;
  03_compare.sql     → explain/<имя>.txt          по блокам «-- @cmp»: результат и план на секциях и на копии;
  04_maintenance.sql → explain/04_maintenance.txt вставка, регистрация провайдера, DETACH/ATTACH/DROP года, каскад.
Каждый план — после ANALYZE, второй прогон (первый прогревает кэш). Сводка — explain/INDEX.md.
Подключение — psql + pgpass (PSQL, PGHOST, PGPORT можно переопределить).
"""
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
EXPLAIN = "EXPLAIN (ANALYZE, BUFFERS)"
NODE = re.compile(r"^(?P<indent>\s*)(?:->\s+)?(?P<name>\S.*?)\s+\(cost=(?P<c0>[\d.]+)\.\.(?P<c1>[\d.]+) rows=")


def psql(args: list[str], stdin: str | None = None) -> str:
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    cmd = [PSQL, "-h", os.environ.get("PGHOST", "127.0.0.1"), "-p", os.environ.get("PGPORT", "5432"),
           "-U", "postgres", "-w", "-d", "superbd", "-X", "-q", "-P", "pager=off", "-P", "footer=off",
           "-v", "ON_ERROR_STOP=1", *args]
    res = subprocess.run(cmd, input=stdin.encode("utf-8") if stdin is not None else None,
                         capture_output=True, env=env, cwd=SQL)
    out = res.stdout.decode("utf-8", errors="replace")
    err = res.stderr.decode("utf-8", errors="replace")
    if res.returncode != 0:
        sys.exit(f"psql завершился с ошибкой ({' '.join(args)}):\n{err}\n{out[-3000:]}")
    return out + (("\n" + err) if err.strip() else "")


def save(name: str, title: str, text: str):
    (OUT / name).write_text(f"-- {title}\n\n{text.rstrip()}\n", encoding="utf-8")


def parse_blocks(path: Path) -> list[dict]:
    blocks, cur, section = [], None, None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("-- @cmp "):
            name, what, why = [x.strip() for x in line[len("-- @cmp "):].split(" | ", 2)]
            cur = {"name": name, "what": what, "why": why, "setup": [], "part": [], "plain": []}
            blocks.append(cur)
            section = None
        elif cur is not None and line.strip() in ("-- @setup", "-- @part", "-- @plain"):
            section = line.strip()[4:]
        elif cur is not None and section:
            cur[section].append(line)
    for b in blocks:
        for key in ("setup", "part", "plain"):
            b[key] = "\n".join(b[key]).strip()
    return blocks


def explain_twice(sql: str, marker: str) -> str:
    return f"\\o {os.devnull}\n{EXPLAIN}\n{sql}\n\\o\n\\echo {marker}\n{EXPLAIN}\n{sql}\n"


def run_block(b: dict) -> dict:
    script = [f"\\i '{(SQL / '00_params.sql').as_posix()}'", "SET TimeZone = 'Europe/Moscow';", b["setup"],
              "\\echo @@@RES_PART", b["part"], "\\echo @@@RES_PLAIN", b["plain"],
              "\\pset format unaligned", "\\pset tuples_only on",
              explain_twice(b["part"], "@@@PLAN_PART"), explain_twice(b["plain"], "@@@PLAN_PLAIN")]
    out = psql(["-f", "-"], "\n".join(s for s in script if s) + "\n")
    parts, key = {}, None
    for line in out.splitlines():
        if line.startswith("@@@"):
            key = line[3:].strip()
            parts[key] = []
        elif key:
            parts[key].append(line)
    return {k: "\n".join(v).strip("\n") for k, v in parts.items()}


def summary(plan: str) -> dict:
    """Что прочитано: таблицы и секции (узлы Scan), исключённые при запуске секции, cost верхнего узла, время."""
    rels = sorted(set(re.findall(r"Scan(?: Backward)? (?:using \S+ )?on (\w+)", plan)))
    removed = sum(int(x) for x in re.findall(r"Subplans Removed: (\d+)", plan))
    first = next((NODE.match(l) for l in plan.splitlines() if NODE.match(l)), None)
    t = re.search(r"Execution Time: ([\d.]+) ms", plan)
    return {"rels": rels, "removed": removed, "cost": float(first.group("c1")) if first else None,
            "time": float(t.group(1)) if t else None}


def fmt(x, digits=2):
    return "—" if x is None else f"{x:,.{digits}f}".replace(",", " ")


def server_info() -> str:
    out = psql(["-A", "-t", "-F", " | ", "-c",
                "SELECT version(), current_setting('work_mem'), current_setting('shared_buffers'), "
                "current_setting('max_parallel_workers_per_gather'), (SELECT count(*) FROM core.session), "
                "(SELECT count(*) FROM core.contract), to_char(now(), 'DD.MM.YYYY HH24:MI')"])
    v = [x.strip() for x in out.strip().split(" | ")]
    return (f"Сервер: {v[0]}\nwork_mem = {v[1]}, shared_buffers = {v[2]}, max_parallel_workers_per_gather = {v[3]}\n"
            f"core.session: {v[4]} сеансов, core.contract: {v[5]} договоров; снято {v[6]}")


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    OUT.mkdir(exist_ok=True)
    timing = {}
    if "--explain" not in sys.argv:
        for step, title in [("01_copies.sql", "Обычные копии для сравнения"), ("02_structure.sql", "Устройство секций")]:
            t = time.perf_counter()
            save(step.replace(".sql", ".txt"), f"Вывод labs/lab08/sql/{step}: {title}", psql(["-f", step]))
            timing[step] = time.perf_counter() - t
            print(f"{step}: {timing[step]:.1f} с")
    psql(["-c", "ANALYZE core.session; ANALYZE core.contract; ANALYZE lab8.session_plain; ANALYZE lab8.contract_plain;"])
    info = server_info()
    rows = []
    for b in parse_blocks(SQL / "03_compare.sql"):
        r = run_block(b)
        sp, sl = summary(r.get("PLAN_PART", "")), summary(r.get("PLAN_PLAIN", ""))
        same = r.get("RES_PART", "") == r.get("RES_PLAIN", "")
        text = [f"Сравнение {b['name']} (03_compare.sql)", f"Что показывает: {b['what']}", f"Запрос: {b['why']}", info, ""]
        if b["setup"]:
            text += ["-- Подготовка", b["setup"], ""]
        text += ["-- SQL: секционированные таблицы (core.session, core.contract)", b["part"], "",
                 "-- SQL: обычные копии (lab8.session_plain, lab8.contract_plain)", b["plain"], "",
                 "-- Результат (секционированные таблицы)", r.get("RES_PART", ""), "",
                 f"Результаты на секциях и на копиях совпадают: {'да' if same else 'НЕТ'}", "",
                 "-- План: секционированные таблицы, второй прогон", r.get("PLAN_PART", ""), "",
                 "-- План: обычные копии, второй прогон", r.get("PLAN_PLAIN", ""), "",
                 f"Итог: секции — прочитано {len(sp['rels'])} ({', '.join(sp['rels'])})"
                 + (f", исключено при запуске {sp['removed']}" if sp["removed"] else "")
                 + f", cost {fmt(sp['cost'])}, {fmt(sp['time'], 3)} мс; копия — {', '.join(sl['rels'])}, "
                   f"cost {fmt(sl['cost'])}, {fmt(sl['time'], 3)} мс"]
        (OUT / f"{b['name']}.txt").write_text("\n".join(text).rstrip() + "\n", encoding="utf-8")
        rows.append((b, sp, sl, same))
        print(f"{b['name']}: секции {len(sp['rels'])} отн., {fmt(sp['time'], 3)} мс; копия {fmt(sl['time'], 3)} мс")
    if "--explain" not in sys.argv:
        t = time.perf_counter()
        save("04_maintenance.txt", "Вывод labs/lab08/sql/04_maintenance.sql: добавление и удаление данных, обслуживание секций",
             psql(["-f", "04_maintenance.sql"]))
        timing["04_maintenance.sql"] = time.perf_counter() - t
    write_index(rows, info, timing)


def write_index(rows, info, timing):
    lines = ["# ЛР 8 — сравнение секционированных таблиц с обычными", "",
             "Создаётся `labs/lab08/run_lab8.py` — не править вручную.", "", "```", info, "```", "",
             "Секционированные — рабочие таблицы курсовой: `core.session` (по диапазону `started_at`, год → квартал, "
             "секция по умолчанию) и `core.contract` (по списку `provider_id`, секция по умолчанию). Обычные — копии "
             "`lab8.session_plain`, `lab8.contract_plain` с теми же данными и индексами. «Прочитано» — таблицы и секции "
             "в узлах сканирования плана; «исключено» — секции, отброшенные при запуске (общий план с параметрами). "
             "Каждый план — второй прогон после прогревочного.", "",
             "| № | Что показывает | Запрос | Секции: прочитано | cost секции / копия | время, мс секции / копия | Результаты совпадают | Вывод |",
             "|---|---|---|---|---|---|---|---|"]
    for b, sp, sl, same in rows:
        read = f"{len(sp['rels'])}" + (f" (исключено {sp['removed']})" if sp["removed"] else "")
        why = b["why"].split(":")[0].split(" (")[0]
        lines.append(f"| {b['name'].split('_')[0]} | {b['what'].replace('|', chr(92) + '|')} | {why} | {read} | "
                     f"{fmt(sp['cost'])} / {fmt(sl['cost'])} | {fmt(sp['time'], 3)} / {fmt(sl['time'], 3)} | "
                     f"{'да' if same else 'НЕТ'} | `explain/{b['name']}.txt` |")
    lines += ["", "## Другие материалы", "",
              "| Файл | Содержание |", "|---|---|",
              "| `explain/01_copies.txt` | Создание обычных копий, число строк |",
              "| `explain/02_structure.txt` | Дерево секций с границами, строки и размер каждой секции, сравнение размеров, индексы секций |",
              "| `explain/04_maintenance.txt` | Вставка через родителя (в какую секцию легла строка), регистрация провайдера → секция, "
              "DETACH/DROP года против DELETE из обычной таблицы, ATTACH с CHECK, каскадное удаление договора, создание секций года |"]
    if timing:
        lines += ["", "## Время шагов (последний полный прогон)", "", "| Шаг | Время, с |", "|---|---|"]
        lines += [f"| `{k}` | {v:.1f} |" for k, v in timing.items()]
    (OUT / "INDEX.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("INDEX.md")


if __name__ == "__main__":
    main()
