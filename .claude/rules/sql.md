---
paths:
  - "db/**/*.sql"
  - "labs/**/*.sql"
---

# Правила для SQL (PostgreSQL 16+)

## Файлы и порядок
- Миграции: `db/migrations/NNN_описание.sql`, номера с шагом 10 (010, 020, …), применяются по порядку из `db/build.sql` через `\ir`.
- Каждый файл идемпотентен: `CREATE OR REPLACE`, `DROP … IF EXISTS`, `CREATE … IF NOT EXISTS`. `db/build.sql` в начале делает `DROP SCHEMA … CASCADE` для своих схем.
- Сначала справочники и таблицы стороны «один», потом подчинённые.
- Генерация данных — `db/seed/`; тесты — `db/tests/` (каждый тест печатает `PASS`/`FAIL` через `RAISE NOTICE`).
- Скрипты лаб, не входящие в курсовую (например, `lab7`, `lab8`), — в `labs/labNN/sql/`, в своей схеме.

## Схемы и имена
- `ref` справочники, `core` основные таблицы, `sec` пользователи/роли, `audit` журнал, `api` интерфейс для клиента.
- `snake_case`, без кавычек; PK `id` (`GENERATED ALWAYS AS IDENTITY`); FK `<сущность>_id`; индексы `ix_<таблица>_<поля>`; триггерные функции `trg_<таблица>_<когда>_<событие>`.
- `COMMENT ON TABLE/COLUMN/FUNCTION` на русском для каждого объекта — из них строятся таблицы ПЗ.

## Типы и домены
- Деньги — домены на `numeric`, никогда `money`/`float`. Даты сеансов — `timestamptz`. IP — `inet`.
- Повторяющиеся ограничения — через `CREATE DOMAIN` (`d_phone`, `d_money`, `d_price_mb`, `d_percent`, `d_year`, `d_mb`, `d_name`).
- `ON DELETE` для каждого FK выбирать осознанно (см. `docs/decisions.md` D9).

## Функции схемы api
```sql
CREATE OR REPLACE FUNCTION api.contract_list(
    p_search text DEFAULT NULL, p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS TABLE (id int, contract_no text, subscriber text, connected_on date, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan          -- есть необязательный отбор (p_search)
AS $$
DECLARE
    v_scope integer[] := sec.scope_data();       -- видимые провайдеры, один раз
    v_like  text := sec.like_prefix(p_search);   -- шаблон «начинается с», один раз
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator','grp_manager','grp_chief']);
    RETURN QUERY
    SELECT c.id, c.contract_no::text, s.name::text, c.connected_on, count(*) OVER ()
    FROM core.contract c JOIN core.subscriber s ON s.id = c.subscriber_id
    WHERE c.provider_id = ANY (v_scope)
      AND (v_like IS NULL OR lower(s.name) LIKE v_like)
    ORDER BY c.connected_on DESC
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
REVOKE ALL ON FUNCTION api.contract_list(text,int,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.contract_list(text,int,int) TO grp_operator, grp_manager, grp_chief;
```
- Всегда: `SECURITY DEFINER`, `SET search_path = pg_catalog, pg_temp`, `SET TimeZone = 'Europe/Moscow'` (D19: драйвер QPSQL ставит сеансу UTC, а даты, время суток и дни недели считаются по местному времени; то же — в триггерных функциях), полностью квалифицированные имена, проверка группы первой строкой, явный `REVOKE … FROM PUBLIC` + `GRANT` группам.
- `ALTER DEFAULT PRIVILEGES FOR ROLE app_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;` — в миграции ролей.
- Ошибки для пользователя: `RAISE EXCEPTION 'Договор не найден' USING ERRCODE = 'P0001';` — текст на русском, без технических деталей.
- Динамический SQL только через `format('%I', …)` / `%L` / `USING`. Никакой конкатенации пользовательского ввода.
- `CREATE ROLE` из функции — только для белого списка групп; логин проверять доменом `ref.d_login` (без регулярных выражений).

## Регулярные выражения и оптимизация (D24, замечание студента)
- Регулярные выражения (`~`, `~*`, `regexp_*`, `SIMILAR TO`, `QRegularExpression`) не использовать нигде: символы — `translate()`, поиск — `LIKE` по префиксу, `strpos`, `left`. Тест 8.1 это проверяет.
- Запросы и бизнес-логику писать в оптимизированной форме (Карпова, гл. 9; Лузанов — индексы): условие «столбец ОС константа»; видимость — `provider_id = ANY (v_scope)` из `sec.scope_data()`/`sec.scope_providers()`, не `(флаг OR provider_id = …)`; выражения от параметров — один раз в `DECLARE`; выборка на каждой таблице до соединения, группировка до соединения и по PK; функции с необязательными отборами `(p IS NULL OR …)` — `SET plan_cache_mode = force_custom_plan`; индекс под каждое условие экрана.
- После изменения запроса — `python labs/lab05/run_queries.py` (или аналог лабы) и просмотр плана: нет ли чтения таблицы целиком там, где нужны строки одного провайдера.

## RLS
- `ENABLE` и `FORCE ROW LEVEL SECURITY` на всех таблицах `core`.
- Политики через функции `sec.current_provider_id()`, `sec.in_group(text)`, основанные на `session_user`.
- Проверять тестом: `SET SESSION AUTHORIZATION op_test_a; SELECT count(*) FROM api.contract_list(...);`.

## Проверка
- Прогон: `psql -v ON_ERROR_STOP=1 -f …`. Для запросов лаб 5–8 — `EXPLAIN (ANALYZE, BUFFERS)` и сохранить вывод в `labs/labNN/explain/`.
