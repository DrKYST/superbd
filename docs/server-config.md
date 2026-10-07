# Конфигурация сервера (ЛР 1 → раздел 2 ПЗ)

Выполнено 30.09.2026 на компьютере студента (Claude через управление компьютером + pgAdmin 4).

| Параметр | Значение | Обоснование |
|---|---|---|
| Версия PostgreSQL | 18, служба `postgresql-x64-18`, порт 5432, data: `C:\Program Files\PostgreSQL\18\data` | PG 16 (порт 5433) не используется |
| ОС | Windows 11 Pro 64-бит, сборка 26200 | |
| ЦП | Intel Core i5-14600KF, 14 ядер / 20 потоков | |
| ОЗУ | 32 ГБ (свободно при обычной нагрузке ≈ 10 ГБ) | ПК не выделенный сервер |
| shared_buffers | 512MB (было 128MB) | Windows: рекомендовано 64–512 МБ + кэш ОС; ПК не выделенный, второй экземпляр СУБД |
| work_mem | 64MB (было 4MB) | (10 ГБ/2 − 0,5 ГБ) / (35 запросов × 2 операции) ≈ 66 МБ → 64 МБ |
| temp_buffers | 32MB (было 8MB) | верхняя граница 16–32 МБ |
| max_prepared_transactions | 5 (было 0) | рекомендация методички; требует перезапуска |
| max_files_per_process | 1000 (по умолчанию, задано явно) | ошибок «Too many open files» нет; пересмотреть в ЛР 8 |
| track_counts | on | нужен autovacuum и pg_stat_* |

Способ: `ALTER SYSTEM SET …` (пишет `postgresql.auto.conf`, т. к. запись в `postgresql.conf` в Program Files требует прав администратора) → `SELECT pg_reload_conf();` → перезапуск службы. Проверка: запрос к `pg_settings`, `pending_restart = false` у всех шести.

## Журнал сервера и пароли (D27, добавлено 07.10.2026)

Сброс пароля (`api.user_reset_password`, `api.user_create`) и смена пароля (`api.change_own_password`) передают пароль серверу открытым текстом внутри функции; хранится он только хешем SCRAM (`password_encryption = scram-sha-256`, по умолчанию). Чтобы пароль не попал в журнал сервера (`logging_collector = on`, файлы в `data\log`):

| Параметр | Значение | Сейчас (07.10, `pg_settings`) | Почему |
|---|---|---|---|
| log_parameter_max_length | **0** | -1 (по умолчанию: значения параметров пишутся целиком) | Клиент передаёт новый пароль параметром запроса (`prepare` + `bindValue`). Значения параметров пишутся в журнал вместе с текстом запроса, когда запрос попадает в журнал по `log_min_duration_statement` или `log_statement`; 0 — не писать никогда |
| log_parameter_max_length_on_error | 0 | 0 (по умолчанию) | То же для запросов, завершившихся ошибкой (например, «Пароль должен быть не короче 8 символов») |
| log_statement | none (или ddl, mod) | none | Вызов `SELECT * FROM api.change_own_password(...)` не пишется при `none`, `ddl`, `mod`. `ALTER ROLE … PASSWORD` выполняется внутри функции (`EXECUTE`) — вложенные операторы `log_statement` не пишет. При `all` текст вызова попадёт в журнал (значение параметра — нет, если `log_parameter_max_length = 0`) |
| log_min_duration_statement | -1 | -1 | При значении ≥ 0 медленные запросы пишутся с параметрами — поэтому важен `log_parameter_max_length = 0` |
| log_min_error_statement | error | error (по умолчанию) | При ошибке пишется текст оператора верхнего уровня (вызов функции с `$1`, без значения). Ошибка внутри `EXECUTE` добавила бы в контекст текст `ALTER ROLE` с паролем, поэтому в функциях `ALTER ROLE` выполняется последним, после всех проверок |

Включить (суперпользователем, перезапуск не нужен):

```sql
ALTER SYSTEM SET log_parameter_max_length = 0;
SELECT pg_reload_conf();
```

Проверка: `SELECT name, setting FROM pg_settings WHERE name LIKE 'log_parameter_max_length%';` — оба параметра равны 0.

Пароль администратора БД и `postgres` меняется командой `\password` в psql: она отправляет на сервер уже хеш SCRAM, открытый пароль не передаётся. Команду `ALTER ROLE … PASSWORD '…'` вручную в psql не выполнять — при `log_statement = ddl` или `all` она попадёт в журнал целиком.
