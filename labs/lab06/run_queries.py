"""ЛР 6: результат и план выполнения каждого запроса → labs/lab06/explain/qNN.txt.

    python labs/lab06/run_queries.py

Как в ЛР 5 (labs/lab05/run_queries.py, оттуда же функции запуска): запрос выполняется от имени роли, для которой
он предназначен; план вложенного в функцию SELECT выводит auto_explain. Запрос 12 снят дважды — материал к защите
ЛР 6 (руководитель «ДонНет» за квартал — битовая карта по индексу, аналитик за 2024–2025 годы — чтение таблицы
целиком). Запросы ТЗ курсового проекта 17–23 и «Крупнейшие абоненты» — coursework/queries/run_queries.py (D31).
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lab05"))
from run_queries import SETUP, run  # noqa: E402

OUT = Path(__file__).resolve().parent / "explain"
PERIOD = "'2026-01-01', '2026-09-30'"

# файл; номер и вид; роль; формулировка; SQL (вызов от имени роли); где используется.
QUERIES = [
    ("q11", "11 (итоговый без условия)", "adm_main", "Пользователи по группам: «Все пользователи» и число в каждой группе",
     "SELECT title, group_name, users FROM api.v_user_groups",
     "«Пользователи» — панель «Группа / Кол-во»"),
    ("q12_index", "12 (итоговый с условием на данные) — с использованием индекса", "mgr_donnet",
     "Новые договоры по месяцам и типам абонентов: свой провайдер, III квартал 2026",
     "SELECT period_title, subscriber_type, contracts FROM api.report_new_contracts('2026-07-01', '2026-09-30', 'month')",
     "«Статистика» → «Новые договоры по типам абонентов»"),
    ("q12_noindex", "12 (итоговый с условием на данные) — без использования индекса", "chief_main",
     "Новые договоры по годам и типам абонентов: все провайдеры, 2024–2025 годы",
     "SELECT period_title, subscriber_type, contracts FROM api.report_new_contracts('2024-01-01', '2025-12-31', 'year')",
     "«Статистика» → «Новые договоры по типам абонентов»"),
    ("q13", "13 (итоговый с условием на группы)", "adm_main",
     "Общие абоненты — с договорами не меньше чем двух провайдеров",
     "SELECT name, subscriber_type, city, phone, providers, total_count FROM api.q_shared_subscribers(2, 10)",
     "«Справочники» → «Общие абоненты»"),
    ("q14", "14 (итоговый с условием на данные и на группы)", "op_donnet",
     "Действующие договоры без сеансов больше 30 дней",
     "SELECT contract_no, subscriber_name, connected_on, last_session, idle_days, total_count "
     "FROM api.q_idle_contracts(30, 10)",
     "счётчик «Договоры без сеансов более 30 дней» → список"),
    ("q15", "15 (запрос на запросе по принципу итогового)", "mgr_donnet",
     "Выручка по месяцам за январь–сентябрь 2026 со строкой «Итого»",
     f"SELECT period_title, new_contracts, volume_mb, connection_fees, traffic_fees, revenue FROM api.report_revenue({PERIOD})",
     "«Статистика» → «Выручка по периодам»; счётчик «Выручка за …»"),
    ("q16", "16 (запрос с подзапросом NOT IN)", "adm_main", "Провайдеры без сотрудников",
     "SELECT display_name, city, contracts_active, total_count FROM api.q_providers(p_without_staff => true, p_limit => 10)",
     "«Провайдеры», отбор «Без сотрудников»; счётчик «Провайдеры без сотрудников»"),
]


def nested_plans(log: str) -> str:
    """Планы основной выборки из вывода auto_explain (без вызова функции api.* и служебных запросов sec.*)."""
    blocks = re.split(r"(?m)^(?:psql:\S+\s+)?(?:СООБЩЕНИЕ|ЖУРНАЛ|LOG):\s+", log)
    plans = []
    for b in blocks:
        text = b.split("Query Text:", 1)[-1].split("\n\n", 1)[0] if "Query Text:" in b else ""
        if re.search(r"core\.|sec\.app_user|api\.v_", text) and not re.search(r"api\.(q|report)_", text):
            plans.append(b.rstrip())
    return "\n\n".join(plans) if plans else "(план не получен)\n" + log.strip()


def main():
    OUT.mkdir(exist_ok=True)
    for name, kind, role, title, sql, usage in QUERIES:
        out, log = run(f"{SETUP}SET SESSION AUTHORIZATION {role};\nSET TimeZone = 'Europe/Moscow';\n{sql};\n")
        text = (f"Запрос {kind}. {title}\nРоль: {role}\nГде используется: {usage}\n\n"
                f"-- SQL\n{sql};\n\n-- Результат (первые строки)\n{out.rstrip()}\n\n"
                f"-- План выполнения (auto_explain, ANALYZE, BUFFERS)\n{nested_plans(log)}\n")
        (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
        print(f"{name}.txt")


if __name__ == "__main__":
    main()
