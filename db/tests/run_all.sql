-- Запуск всех тестов БД (права, RLS, триггеры). Тесты печатают PASS/FAIL через RAISE NOTICE.
-- psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f db/tests/run_all.sql
\set ON_ERROR_STOP on
-- \ir t01_no_direct_table_access.sql
