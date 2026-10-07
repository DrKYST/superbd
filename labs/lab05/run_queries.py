"""ЛР 5: результат и план выполнения каждого запроса → labs/lab05/explain/qNN.txt.

    python labs/lab05/run_queries.py

Запрос выполняется от имени роли, для которой он предназначен (SET SESSION AUTHORIZATION под postgres).
План вложенного в функцию SELECT выводит auto_explain (log_nested_statements, ANALYZE, BUFFERS):
EXPLAIN самого вызова функции показал бы только «Function Scan».
Подключение — psql + pgpass (PSQL, PGHOST, PGPORT можно переопределить переменными окружения).
"""
import os
import re
import subprocess
from pathlib import Path

PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
OUT = Path(__file__).resolve().parent / "explain"

DONNET = "(SELECT id FROM api.v_providers WHERE name = 'ДонНет')"   # как клиент: только через api
MONTH_FROM = "date_trunc('month', current_date)::date"

# № — как на экране «Запросы»; роль; формулировка; SQL (вызов от имени роли); где используется.
QUERIES = [
    (1, "adm_main", "Сотрудники провайдера «ДонНет»",
     f"SELECT login, full_name, group_title, can_login, total_count FROM api.q_provider_staff({DONNET})",
     "«Провайдеры» → «Сотрудники провайдера»"),
    (2, "op_donnet", "Сеансы выбранного договора за текущий месяц с итогом",
     "SELECT started_at, tariff_name, volume_mb, discount_pct, cost, total_count, total_volume_mb, total_cost "
     f"FROM api.q_contract_sessions((SELECT id FROM api.v_contracts WHERE state = 'Действует' ORDER BY id LIMIT 1), "
     f"{MONTH_FROM}, current_date, 10, 0)",
     "«Абоненты» → «Сеансы по договору … за …»; «Договор» → вкладка «Сеансы»"),
    (3, "op_donnet", "Журнал сеансов за текущий месяц с итогом за период",
     "SELECT started_at, contract_no, subscriber_name, ip_address, tariff_name, volume_mb, discount_pct, price_per_mb, cost, "
     f"total_count, total_volume_mb, total_cost FROM api.q_sessions({MONTH_FROM}, current_date, p_limit => 10)",
     "«Сеансы связи» (Отбор, «Итого за период»)"),
    (4, "op_donnet", "Договоры, заключённые с начала года",
     "SELECT contract_no, subscriber_name, subscriber_type, connected_on, connection_fee, price_per_mb, ip_address, state, "
     "total_count FROM api.q_contracts(date_trunc('year', current_date)::date, current_date, p_limit => 10)",
     "«Договоры»; «Договоров заключено на этой неделе»"),
    (5, "chief_main", "Провайдеры с типом собственности и городом (представление)",
     "SELECT display_name, ownership_type, city, address, phone, founded_year FROM api.v_providers ORDER BY name LIMIT 10",
     "«Провайдеры», «Мой провайдер», выбор провайдера"),
    (6, "op_donnet", "Абоненты с типом и городом (представление)",
     "SELECT name, subscriber_type, is_legal, city, address, phone FROM api.v_subscribers ORDER BY name LIMIT 10",
     "форма выбора абонента, карточка абонента"),
    (7, "op_donnet", "Договоры: полные сведения (представление)",
     "SELECT contract_no, provider_name, subscriber_name, subscriber_type, connected_on, price_per_mb, ip_address, state "
     "FROM api.v_contracts ORDER BY id LIMIT 10",
     "форма «Договор», форма выбора договора"),
    (8, "op_donnet", "Абоненты и договоры, включая абонентов без договоров",
     "SELECT name, subscriber_type, city, phone, contracts_total, contracts_active, total_count "
     "FROM api.q_subscribers(p_limit => 10) ORDER BY contracts_total, name",
     "«Абоненты» — главный список"),
    (9, "mgr_donnet", "Использование тарифов за текущий месяц, включая неиспользованные",
     f"SELECT tariff_code, tariff_name, discount_pct, sessions_count, volume_mb, revenue FROM api.q_tariff_usage({MONTH_FROM}, current_date)",
     "«Статистика» → «Трафик по тарифам»"),
    (10, "adm_main", "Провайдеры с числом действующих и новых за месяц договоров",
     "SELECT display_name, ownership_type, city, contracts_active, contracts_new, total_count "
     f"FROM api.q_providers({MONTH_FROM}, current_date, p_limit => 10)",
     "«Провайдеры», колонка «Действующих договоров»"),
]

SETUP = """\\pset pager off
\\pset footer off
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_analyze = on;
SET auto_explain.log_buffers = on;
SET auto_explain.log_timing = off;
SET auto_explain.log_nested_statements = on;
SET client_min_messages = log;
"""


def run(sql: str) -> tuple[str, str]:
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    res = subprocess.run(
        [PSQL, "-h", os.environ.get("PGHOST", "127.0.0.1"), "-p", os.environ.get("PGPORT", "5432"),
         "-U", "postgres", "-w", "-d", "superbd", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", "-"],
        input=sql.encode("utf-8"), capture_output=True, env=env)
    if res.returncode != 0:
        raise SystemExit(res.stderr.decode("utf-8", "replace"))
    return res.stdout.decode("utf-8", "replace"), res.stderr.decode("utf-8", "replace")


def nested_plans(log: str) -> str:
    """Планы вложенных запросов из вывода auto_explain (без плана самого вызова функции)."""
    blocks = re.split(r"(?m)^(?:psql:\S+\s+)?(?:СООБЩЕНИЕ|ЖУРНАЛ|LOG):\s+", log)
    plans = []
    for b in blocks:
        text = b.split("Query Text:", 1)[-1].split("\n\n", 1)[0] if "Query Text:" in b else ""
        # основная выборка: читает таблицы core / sec.app_user или представления api.v_*;
        # вызов самой функции api.q_* и служебные запросы sec.* (проверка группы) не нужны
        if re.search(r"core\.|sec\.app_user|api\.v_", text) and "api.q_" not in text:
            plans.append(b.rstrip())
    return "\n\n".join(plans) if plans else "(план не получен)\n" + log.strip()


def main():
    OUT.mkdir(exist_ok=True)
    for no, role, title, sql, usage in QUERIES:
        out, log = run(f"{SETUP}SET SESSION AUTHORIZATION {role};\n{sql};\n")
        text = (f"Запрос {no}. {title}\nРоль: {role}\nГде используется: {usage}\n\n"
                f"-- SQL\n{sql};\n\n-- Результат (первые строки)\n{out.rstrip()}\n\n"
                f"-- План выполнения (auto_explain, ANALYZE, BUFFERS)\n{nested_plans(log)}\n")
        path = OUT / f"q{no:02d}.txt"
        path.write_text(text, encoding="utf-8")
        print(f"q{no:02d}: {path.name}")


if __name__ == "__main__":
    main()
