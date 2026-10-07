# ЛР 1. Установка и настройка сервера — выполнена 30.09.2026

- Параметры и обоснования: `docs/server-config.md`.
- Отчёт: `out/lab01.docx` — буквально как образец `reports/template_lab.docx` (2 страницы: титульник, шапка, «Ход работы», одна таблица из 6 строк postgresql.auto.conf, «Рисунок 1.1», 6 строк пояснений; без лишних разделов и вывода). Собирается `python labs/lab01/build_report.py`.
- В отчёт идут `screenshots/conf_1…conf_6*.png`; остальные (sysinfo, before, autoconf, pending, service, after) — запасные, для защиты.

## Вопросы к защите
- Почему shared_buffers не 25 % ОЗУ? — Windows (рекомендация 64–512 МБ, опора на кэш ОС), ПК не выделенный, второй экземпляр СУБД.
- Как посчитан work_mem? — (свободная память/2 − shared_buffers) / (одновременные запросы × операции в запросе) = 4608 / 70 ≈ 64 МБ.
- Почему ALTER SYSTEM, а не правка postgresql.conf? — нет прав на запись в Program Files без администратора; postgresql.auto.conf читается после postgresql.conf и имеет приоритет.
- Какие параметры требуют перезапуска? — контекст postmaster: shared_buffers, max_prepared_transactions, max_files_per_process; user/superuser применяются через pg_reload_conf().
- Зачем track_counts? — статистика для autovacuum и pg_stat_*.
