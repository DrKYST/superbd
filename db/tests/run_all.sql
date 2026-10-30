-- Запуск всех тестов БД (структура, данные, права, RLS, триггеры).
-- psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f db/tests/run_all.sql
-- Каждая проверка печатает PASS/FAIL; при любом FAIL скрипт завершается ошибкой.
\set ON_ERROR_STOP on
\ir _helpers.sql
-- Даты и время — в часовом поясе предметной области (D19), как в функциях api и seed: «сегодня», границы
-- периода договора и окна тарифов не зависят от пояса сервера и времени запуска.
SET TimeZone = 'Europe/Moscow';

\echo '== 010 структура и данные'
\ir 010_structure.sql

\echo '== 020 whoami и доступ'
\ir 020_whoami.sql

\echo '== 030 запросы ЛР 5'
\ir 030_queries_lr5.sql

\echo '== 040 общий реестр абонентов (D25)'
\ir 040_shared_subscribers.sql

\echo '== 050 администратор приложения и администратор БД (D26)'
\ir 050_admin_split.sql

\echo '== 060 запросы ЛР 6'
\ir 060_queries_lr6.sql

\echo '== 070 сброс пароля (D27)'
\ir 070_password_reset.sql

\echo '== 080 секционирование (ЛР 8, D30)'
\ir 080_partitions.sql

\echo '== 090 запросы ТЗ курсового проекта 17–23 (D31)'
\ir 090_queries_coursework.sql

\echo '== 100 триггеры (T7, T8, журнал изменений)'
\ir 100_triggers.sql

\echo '== итог'
DO $$
DECLARE
    v_total int;
    v_failed int;
    v_list text;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE NOT ok), string_agg(name, '; ' ORDER BY n) FILTER (WHERE NOT ok)
    INTO v_total, v_failed, v_list FROM pg_temp.test_result;
    IF v_failed > 0 THEN
        RAISE EXCEPTION 'Тесты: не пройдено % из %: %', v_failed, v_total, v_list;
    END IF;
    RAISE NOTICE 'Тесты: пройдено % из %', v_total, v_total;
END $$;
