"""Таблицы для пояснительной записки из фактической схемы БД (COMMENT ON, pg_catalog).

    python tools/schema2md.py                                   # напечатать Markdown
    python tools/schema2md.py --update coursework/pz/40-bd.md   # заменить блок между метками

Метки в файле:
    <!-- BEGIN schema2md -->
    ...
    <!-- END schema2md -->
Синтаксис подписей и ссылок — tools/md2docx/README.md. Подключение — psql + pgpass
(PSQL, PGHOST, PGPORT, PGUSER, PGDATABASE можно переопределить переменными окружения).
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
SCHEMAS = "('ref', 'core', 'sec', 'audit')"
BEGIN, END = "<!-- BEGIN schema2md -->", "<!-- END schema2md -->"
DETAIL = ["core.provider", "core.subscriber", "core.session"]   # подробная структура
SKIP = ["core.contract"]   # структура показана рисунком с CREATE TABLE в тексте раздела 4.2
TABLE_ORDER = ["ref.ownership_type", "ref.city", "ref.subscriber_type", "ref.tariff",
               "core.provider", "core.subscriber", "core.contract", "core.session",
               "sec.app_user", "audit.change_log"]
CASTS = re.compile(r"::(text|numeric|character varying|date|timestamp with time zone|integer)")
PARENS = re.compile(r"(?<![a-z])\((VALUE|\d+|name)\)")


def query(sql: str) -> list[list[str]]:
    # SQL передаётся через stdin в UTF-8: аргументы командной строки Windows перекодирует в cp1251.
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    res = subprocess.run(
        [PSQL, "-h", os.environ.get("PGHOST", "127.0.0.1"), "-p", os.environ.get("PGPORT", "5432"),
         "-U", os.environ.get("PGUSER", "postgres"), "-w", "-d", os.environ.get("PGDATABASE", "superbd"),
         "-AtX", "-v", "ON_ERROR_STOP=1", "-F", "\x1f", "-f", "-"],
        input=sql.encode("utf-8"), capture_output=True, env=env,
    )
    if res.returncode != 0:
        sys.exit("Ошибка psql:\n" + res.stderr.decode("utf-8", "replace"))
    return [line.split("\x1f") for line in res.stdout.decode("utf-8").splitlines() if line]


DREF = re.compile(r"\s*\(D\d+(?:, D\d+)*\)|,\s*D\d+(?=\))")   # номера решений docs/decisions.md — не для ПЗ


def cell(s: str) -> str:
    return DREF.sub("", s).replace("|", "\\|").replace("\n", " ")


def tidy(expr: str) -> str:
    """Убирает из выражений системного каталога служебные приведения типов и лишние скобки."""
    expr = CASTS.sub("", expr).replace("character varying", "varchar")
    return PARENS.sub(lambda m: m.group(1), expr)


def code(s: str) -> str:
    return f"`{s}`" if s else ""


def domains() -> list[str]:
    rows = query(f"""
        SELECT t.typname, format_type(t.typbasetype, t.typtypmod),
               regexp_replace(pg_get_constraintdef(c.oid), '^CHECK \\((.*)\\)$', '\\1'),
               coalesce(obj_description(t.oid, 'pg_type'), '')
        FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        LEFT JOIN pg_constraint c ON c.contypid = t.oid
        WHERE t.typtype = 'd' AND n.nspname IN {SCHEMAS}
        ORDER BY t.typname""")
    out = ["Таблица: Домены {#tab:pz-domains size=10}", "",
           "| Домен | Базовый тип | Ограничение | Описание |", "|---|---|---|---|"]
    for name, base, chk, comment in rows:
        out.append(f"| {code(name)} | {tidy(base)} | {code(cell(tidy(chk)))} | {cell(comment)} |")
    return out


def tables() -> list[str]:
    cols = query(f"""
        SELECT n.nspname || '.' || c.relname, coalesce(obj_description(c.oid, 'pg_class'), ''),
               a.attname,
               CASE WHEN tn.nspname IN {SCHEMAS} THEN ty.typname ELSE format_type(a.atttypid, a.atttypmod) END,
               CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE 'NULL' END,
               CASE WHEN a.attidentity <> '' THEN 'identity'
                    ELSE coalesce(pg_get_expr(d.adbin, d.adrelid), '') END,
               coalesce((SELECT string_agg(CASE k.contype WHEN 'p' THEN 'PK' WHEN 'f' THEN 'FK' ELSE 'AK' END,
                                           ', ' ORDER BY k.contype DESC)
                         FROM pg_constraint k
                         WHERE k.conrelid = c.oid AND k.contype IN ('p', 'f', 'u') AND a.attnum = ANY (k.conkey)
                           AND k.conparentid = 0), ''),   -- без копий ключа по секциям
               coalesce(col_description(c.oid, a.attnum), '')
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_type ty ON ty.oid = a.atttypid
        JOIN pg_namespace tn ON tn.oid = ty.typnamespace
        LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
        WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname IN {SCHEMAS}   -- секции — в 4.6
        ORDER BY 1, a.attnum""")
    by_table: dict[str, tuple[str, list]] = {}
    for t, tcomment, *rest in cols:
        by_table.setdefault(t, (tcomment, []))[1].append(rest)
    order = [t for t in TABLE_ORDER if t in by_table] + sorted(set(by_table) - set(TABLE_ORDER))
    out: list[str] = []
    others = [t for t in order if t not in DETAIL and t not in SKIP]
    if others:
        # справочники и служебные таблицы — одной сводной таблицей (объём ПЗ: весь курсовой ≤ ~100 с.)
        out += ["", "Таблица: Справочники и служебные таблицы {#tab:pz-other-tables size=10 widths=24,30,46}", "",
                "| Таблица | Назначение | Колонки (ключи) |", "|---|---|---|"]
        for t in others:
            tcomment, rows = by_table[t]
            colsdesc = ", ".join(f"{name}" + (f" ({keys})" if keys else "") for name, _, _, _, keys, _ in rows)
            out.append(f"| {code(t)} | {cell(tcomment)} | {cell(colsdesc)} |")
    for t in [t for t in order if t in DETAIL]:
        tcomment, rows = by_table[t]
        key = "tab:pz-" + t.split(".")[1].replace("_", "-")
        title = tcomment.split(" — ")[0]
        out += ["", f"Таблица: Структура таблицы «{title}» ({t}) {{#{key} size=10}}", "",
                "| Колонка | Тип | NULL | Ключ | По умолчанию | Описание |", "|---|---|---|---|---|---|"]
        for name, typ, null, default, keys, comment in rows:
            out.append(f"| {code(name)} | {code(tidy(typ))} | {null} | {keys} | "
                       f"{code(cell(tidy(default)))} | {cell(comment)} |")
    return out


def indexes() -> list[str]:
    rows = query(f"""
        SELECT i.relname, n.nspname || '.' || t.relname,
               regexp_replace(pg_get_indexdef(i.oid), '^.* USING btree ', ''),
               CASE WHEN x.indisprimary THEN 'первичный ключ'
                    WHEN x.indisunique THEN 'уникальный' ELSE '' END,
               coalesce(obj_description(i.oid, 'pg_class'), '')
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname IN {SCHEMAS} AND NOT t.relispartition          -- индексы секций — копии индексов таблицы
          AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.oid)
        ORDER BY n.nspname, t.relname, x.indisprimary DESC, x.indisunique DESC, i.relname""")
    out = ["Таблица: Индексы, созданные явно (без индексов первичных ключей и ограничений уникальности) "
           "{#tab:pz-indexes size=10}", "",
           "| Индекс | Таблица | Колонки и условие | Вид | Назначение |", "|---|---|---|---|---|"]
    for name, table, cols, kind, comment in rows:
        if not comment and not kind and name.endswith("_id"):
            comment = "Индекс внешнего ключа"
        out.append(f"| {code(name)} | {code(table)} | {code(cell(tidy(cols)))} | {kind} | {cell(comment)} |")
    return out


def sequences() -> list[str]:
    rows = query(f"""
        SELECT n.nspname || '.' || s.relname, format_type(q.seqtypid, NULL),
               coalesce(d.refobjid::regclass::text || '.' || a.attname, ''),
               CASE d.deptype WHEN 'i' THEN 'identity' WHEN 'a' THEN 'явная (OWNED BY)' ELSE 'явная' END,
               coalesce(obj_description(s.oid, 'pg_class'), '')
        FROM pg_class s
        JOIN pg_namespace n ON n.oid = s.relnamespace
        JOIN pg_sequence q ON q.seqrelid = s.oid
        LEFT JOIN pg_depend d ON d.objid = s.oid AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
        LEFT JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE s.relkind = 'S' AND n.nspname IN {SCHEMAS}
        ORDER BY d.deptype, 1""")
    out = ["Таблица: Последовательности {#tab:pz-sequences size=10}", "",
           "| Последовательность | Тип | Колонка | Вид | Назначение |", "|---|---|---|---|---|"]
    for name, typ, col, kind, comment in rows:
        if not comment and kind == "identity":
            comment = "Значения суррогатного первичного ключа"
        out.append(f"| {code(name)} | {typ} | {code(col)} | {kind} | {cell(comment)} |")
    return out


def build() -> str:
    parts = [
        "Домены приведены в таблице [@tab:pz-domains], справочники и служебные таблицы — в таблице "
        "[@tab:pz-other-tables], структура основных таблиц — в таблицах [@tab:pz-provider] – [@tab:pz-session] "
        "(таблицы «Договор» — на рисунке [@fig:create-contract]), "
        "индексы — в таблице [@tab:pz-indexes]. Таблицы "
        "сформированы по фактической схеме базы данных (комментарии COMMENT ON и системный каталог) сценарием "
        "`tools/schema2md.py`; тексты сценариев создания основных объектов — в приложении Б.",
        "",
        # последовательности — абзацем в тексте 4.2 (явная одна, остальные — identity): таблица не нужна (объём ПЗ)
        *domains(), *tables(), "", *indexes(), *(sequences() if "--sequences" in sys.argv else []),
    ]
    return "\n".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--update", type=Path, help="файл Markdown с метками BEGIN/END schema2md")
    args = ap.parse_args()
    md = build()
    if not args.update:
        sys.stdout.reconfigure(encoding="utf-8")
        print(md)
        return 0
    text = args.update.read_text(encoding="utf-8")
    if BEGIN not in text or END not in text:
        print(f"В {args.update} нет меток {BEGIN} / {END}", file=sys.stderr)
        return 1
    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    args.update.write_text(f"{head}{BEGIN}\n{md}\n{END}{tail}", encoding="utf-8")
    print(f"Обновлён: {args.update}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
