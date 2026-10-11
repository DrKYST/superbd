-- ЛР 7: все шаги подряд на чистой схеме lab7 (схема пересоздаётся шагом 01).
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/run_all.sql
-- Планы до и после индексов и материалы для отчёта — python labs/lab07/run_lab7.py (выполняет те же файлы по одному).
\set ON_ERROR_STOP on
\ir 01_create.sql
\ir 02_generate.sql
\ir 03_select_operators.sql
\ir 04_jsonpath.sql
\ir 05_functions.sql
\ir 06_update.sql
\ir 07_delete.sql
\ir 08_indexes.sql
\ir 09_optimize.sql
\echo 'ЛР 7: все шаги выполнены'
