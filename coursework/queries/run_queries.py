"""Запросы ТЗ курсового проекта 17–23 и отчёт «Крупнейшие абоненты»: результат и план → coursework/queries/explain/.

    python coursework/queries/run_queries.py

Как в ЛР 5 и ЛР 6 (labs/lab05/run_queries.py — функции запуска, labs/lab06/run_queries.py — образец): запрос
выполняется от имени роли, для которой он предназначен; план вложенного в функцию SELECT выводит auto_explain
(ANALYZE, BUFFERS). Запрос 19 снят дважды одним и тем же вызовом: q19_index.txt — обычный план, q19_noindex.txt — в
транзакции с запретом индексного доступа (SET LOCAL enable_indexscan = off, enable_bitmapscan = off; ROLLBACK).
Договор для запроса 19 — первый договор «ДонНет» с сеансами в каждом месяце января–сентября 2026 (период данных
генератора кончается днём сборки, поэтому код договора определяется при запуске).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "labs" / "lab05"))
from run_queries import SETUP, run  # noqa: E402

OUT = Path(__file__).resolve().parent / "explain"
PERIOD = "'2026-01-01', '2026-09-30'"
Q3 = "'2026-07-01', '2026-09-30'"
EDU = "(SELECT id FROM api.lookup_tariffs() WHERE name = 'Образовательный')"   # как клиент: только через api
NO_INDEX = "BEGIN;\nSET LOCAL enable_indexscan = off;\nSET LOCAL enable_bitmapscan = off;\n{sql};\nROLLBACK"

# Договор «ДонНет» с сеансами в каждом месяце периода (суперпользователем, только для выбора примера).
C19_SQL = """\\pset tuples_only on
\\pset format unaligned
SELECT c.id
FROM core.contract c
JOIN core.provider p ON p.id = c.provider_id AND p.name = 'ДонНет'
JOIN core.session se ON se.contract_id = c.id AND se.provider_id = c.provider_id
WHERE se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01'
GROUP BY c.id HAVING count(DISTINCT date_trunc('month', se.started_at)) = 9
ORDER BY c.id LIMIT 1;
"""


def queries(c19: int):
    """файл; номер и вид; роль; формулировка; SQL (вызов от имени роли); где используется; обёртка вызова."""
    call19 = (f"SELECT period_title, sessions, volume_mb, full_cost, discount, cost "
              f"FROM api.report_contract_months({c19}, {PERIOD})")
    return [
        ("q17", "17 (итоговый без условия с итоговыми данными «всего», «в том числе»)", "mgr_donnet",
         "Абоненты и договоры своего провайдера по типам абонентов: всего и в том числе",
         "SELECT title, subscribers, contracts, contracts_active FROM api.v_subscriber_type_totals",
         "подраздел 4.7 ПЗ (экрана нет, D23)", None),
        ("q18", "18 (итоговый с условием на данные по маске)", "mgr_donnet",
         "Трафик абонентов, наименование которых подходит под маску «*школа*», за январь–сентябрь 2026",
         "SELECT name, subscriber_type, contracts, sessions, volume_mb, cost, total_count, total_sessions, "
         f"total_volume_mb, total_cost FROM api.q_subscriber_traffic('*школа*', {PERIOD})",
         "подраздел 4.7 ПЗ (экрана нет, D23)", None),
        ("q19_index", "19 (итоговый с условием на данные) — с использованием индекса", "op_donnet",
         f"Трафик договора по месяцам за январь–сентябрь 2026 (договор с кодом {c19})",
         call19, "подраздел 4.7 ПЗ (экрана нет, D23)", None),
        ("q19_noindex", "19 (итоговый с условием на данные) — без использования индекса", "op_donnet",
         f"Тот же вызов в транзакции с запретом индексного доступа (договор с кодом {c19})",
         call19, "подраздел 4.7 ПЗ (экрана нет, D23)", NO_INDEX),
        ("q20", "20 (запрос с объединением UNION ALL)", "mgr_donnet",
         "Доходные операции своего провайдера с начала текущего месяца",
         "SELECT at, kind, amount, volume_mb FROM api.v_revenue_items "
         "WHERE at >= date_trunc('month', current_date) ORDER BY at DESC LIMIT 10",
         "основа отчётов «Выручка по периодам» (15), «Доли провайдеров» (22), «Крупнейшие абоненты»", None),
        ("q21", "21 (запрос с подзапросом IN)", "mgr_donnet",
         "Абоненты своего провайдера, у которых были сеансы по тарифу «Образовательный», за январь–сентябрь 2026",
         f"SELECT name, subscriber_type, city, contracts, total_count FROM api.q_tariff_subscribers({EDU}, {PERIOD})",
         "подраздел 4.7 ПЗ (экрана нет, D23)", None),
        ("q22", "22 (запрос с подзапросом CASE, операции над итоговыми данными)", "chief_main",
         "Доли провайдеров в выручке за январь–сентябрь 2026: первые 4 и «Прочие»",
         "SELECT provider_group, providers, contracts, volume_mb, revenue, share_pct "
         f"FROM api.report_provider_shares({PERIOD}) WHERE period IS NULL",
         "«Статистика» → «Выручка по периодам» (главный аналитик)", None),
        ("q23", "23 (запрос с подзапросом и операциями над итоговыми данными)", "mgr_donnet",
         "Абоненты своего провайдера с трафиком выше среднего за III квартал 2026",
         f"SELECT name, subscriber_type, volume_mb, avg_mb, above_pct, total_count FROM api.q_subscribers_above_avg({Q3})",
         "подраздел 4.7 ПЗ (экрана нет, D23)", None),
        ("top_subscribers", "«Крупнейшие абоненты» (итоговый с условием на данные над 20; без номера, D31)", "mgr_donnet",
         "Первые 10 абонентов своего провайдера по выручке за январь–сентябрь 2026",
         "SELECT ord, subscriber_name, subscriber_type, volume_mb, revenue, share_pct "
         f"FROM api.report_top_subscribers({PERIOD}, 10)",
         "«Статистика» → «Крупнейшие абоненты»", None),
    ]


def nested_plans(log: str) -> str:
    """Планы основной выборки из вывода auto_explain: запросы к сеансам, договорам, абонентам или представлениям api;
    без вызова функции api.q_* / api.report_* и служебных запросов sec.* (группа пользователя, провайдеры)."""
    blocks = re.split(r"(?m)^(?:psql:\S+\s+)?(?:СООБЩЕНИЕ|ЖУРНАЛ|LOG):\s+", log)
    plans = []
    for b in blocks:
        text = b.split("Query Text:", 1)[-1].split("\n\n", 1)[0] if "Query Text:" in b else ""
        if re.search(r"core\.(session|contract|subscriber)|api\.v_", text) and not re.search(r"api\.(q|report)_", text):
            plans.append(b.rstrip())
    return "\n\n".join(plans) if plans else "(план не получен)\n" + log.strip()


def main():
    OUT.mkdir(exist_ok=True)
    out, _ = run(C19_SQL)
    c19 = int(out.strip().splitlines()[-1])
    for name, kind, role, title, sql, usage, wrap in queries(c19):
        body = wrap.format(sql=sql) if wrap else sql
        out, log = run(f"{SETUP}SET SESSION AUTHORIZATION {role};\nSET TimeZone = 'Europe/Moscow';\n{body};\n")
        text = (f"Запрос {kind}. {title}\nРоль: {role}\nГде используется: {usage}\n\n"
                f"-- SQL\n{body};\n\n-- Результат (первые строки)\n{out.rstrip()}\n\n"
                f"-- План выполнения (auto_explain, ANALYZE, BUFFERS)\n{nested_plans(log)}\n")
        (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
        print(f"{name}.txt")


if __name__ == "__main__":
    main()
