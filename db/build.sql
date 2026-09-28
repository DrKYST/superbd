-- Пересборка БД курсового проекта с нуля.
-- psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f db/build.sql
-- Миграции подключаются по порядку через \ir по мере выполнения лаб (начиная с ЛР 3).
\set ON_ERROR_STOP on
\echo 'Сборка БД superbd'

-- DROP SCHEMA IF EXISTS api, audit, sec, core, ref CASCADE;
-- \ir migrations/010_schemas_roles_base.sql
-- \ir migrations/020_domains.sql
-- \ir migrations/030_ref_tables.sql
-- \ir migrations/040_core_tables.sql
-- \ir migrations/050_indexes.sql
-- \ir seed/010_ref.sql
-- \ir seed/020_generate.sql
