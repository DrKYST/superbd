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


def cell(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


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
    out = ["Таблица: Домены {#tab:pz-domains}", "",
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
                         WHERE k.conrelid = c.oid AND k.contype IN ('p', 'f', 'u') AND a.attnum = ANY (k.conkey)), ''),
               coalesce(col_description(c.oid, a.attnum), '')
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_type ty ON ty.oid = a.atttypid
        JOIN pg_namespace tn ON tn.oid = ty.typnamespace
        LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
        WHERE c.relkind IN ('r', 'p') AND n.nspname IN {SCHEMAS}
        ORDER BY 1, a.attnum""")
    by_table: dict[str, tuple[str, list]] = {}
    for t, tcomment, *rest in cols:
        by_table.setdefault(t, (tcomment, []))[1].append(rest)
    order = [t for t in TABLE_ORDER if t in by_table] + sorted(set(by_table) - set(TABLE_ORDER))
    out: list[str] = []
    for t in order:
        tcomment, rows = by_table[t]
        key = "tab:pz-" + t.split(".")[1].replace("_", "-")
        title = tcomment.split(" — ")[0]
        out += ["", f"Таблица: Структура таблицы «{title}» ({t}) {{#{key}}}", "",
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
        WHERE n.nspname IN {SCHEMAS}
        ORDER BY n.nspname, t.relname, x.indisprimary DESC, x.indisunique DESC, i.relname""")
    out = ["Таблица: Индексы {#tab:pz-indexes}", "",
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
    out = ["Таблица: Последовательности {#tab:pz-sequences}", "",
           "| Последовательность | Тип | Колонка | Вид | Назначение |", "|---|---|---|---|---|"]
    for name, typ, col, kind, comment in rows:
        if not comment and kind == "identity":
            comment = "Значения суррогатного первичного ключа"
        out.append(f"| {code(name)} | {typ} | {code(col)} | {kind} | {cell(comment)} |")
    return out


def build() -> str:
    parts = [
        "Домены приведены в таблице [@tab:pz-domains], структура таблиц — в таблицах "
        "[@tab:pz-ownership-type] – [@tab:pz-change-log], индексы — в таблице [@tab:pz-indexes], "
        "последовательности — в таблице [@tab:pz-sequences]. Таблицы сформированы по фактической схеме базы "
        "данных (комментарии COMMENT ON и системный каталог) сценарием `tools/schema2md.py`.",
        "",
        *domains(), *tables(), "", *indexes(), "", *sequences(),
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
