"""Сверка концептуальной модели (docs/diagrams/concept_model.yaml) с фактической схемой БД.

    python tools/drawio/check_concept_vs_db.py

Для каждой несистемной таблицы схемы сравнивает по порядку поля на схеме с комментариями
колонок (COMMENT ON COLUMN) в базе superbd. Подключение — через psql и pgpass
(PSQL, PGHOST, PGPORT, PGUSER можно переопределить переменными окружения).
Код выхода 1 — есть расхождения.
"""
import os
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
SCHEMAS = ("ref", "core", "sec", "audit")

SQL = """
SELECT c.relname, a.attnum, coalesce(col_description(c.oid, a.attnum), '')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE c.relkind IN ('r', 'p') AND n.nspname IN ('ref', 'core', 'sec', 'audit')
ORDER BY c.relname, a.attnum
"""


def db_columns() -> dict[str, list[str]]:
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    out = subprocess.run(
        [PSQL, "-h", os.environ.get("PGHOST", "127.0.0.1"), "-p", os.environ.get("PGPORT", "5432"),
         "-U", os.environ.get("PGUSER", "postgres"), "-w", "-d", "superbd", "-AtX", "-F", "\t", "-c", SQL],
        capture_output=True, env=env, check=True,
    ).stdout.decode("utf-8")
    cols: dict[str, list[str]] = {}
    for line in out.splitlines():
        table, _, comment = line.split("\t", 2)
        cols.setdefault(table, []).append(comment)
    return cols


def main() -> int:
    model = yaml.safe_load((ROOT / "docs/diagrams/concept_model.yaml").read_text(encoding="utf-8"))
    db = db_columns()
    errors = 0
    expected_tables = set()
    for t in model["tables"]:
        if t.get("system"):
            continue
        expected_tables.add(t["id"])
        fields = [r[1] for r in t["rows"]]
        actual = db.get(t["id"])
        if actual is None:
            print(f"НЕТ ТАБЛИЦЫ: {t['id']} ({t['title']})")
            errors += 1
            continue
        if fields != actual:
            errors += 1
            print(f"РАСХОЖДЕНИЕ: {t['id']} ({t['title']})")
            for i in range(max(len(fields), len(actual))):
                f = fields[i] if i < len(fields) else "—"
                a = actual[i] if i < len(actual) else "—"
                print(f"   {'  ' if f == a else '≠ '}{i + 1:>2}. схема: {f:<35} БД: {a}")
        else:
            print(f"ok  {t['id']:<16} {len(fields)} полей")
    for extra in sorted(set(db) - expected_tables):
        print(f"ЛИШНЯЯ ТАБЛИЦА В БД: {extra}")
        errors += 1
    print("Расхождений нет" if not errors else f"Расхождений: {errors}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
