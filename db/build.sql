-- Пересборка БД курсового проекта с нуля (суперпользователем, в базе superbd).
--   psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f db/create_db.sql   -- один раз: база и app_owner
--   psql -U postgres -d superbd  -v ON_ERROR_STOP=1 -f db/build.sql
-- Удаляет и создаёт заново схемы проекта. Роли (app_owner, grp_*, демо-пользователи) кластерные —
-- не удаляются, миграции создают их идемпотентно.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\echo 'Сборка БД superbd'

DROP SCHEMA IF EXISTS api, audit, sec, core, ref CASCADE;

\echo '  миграции'
\ir migrations/010_schemas_roles_base.sql
\ir migrations/020_domains.sql
\ir migrations/030_ref_tables.sql
\ir migrations/040_core_tables.sql
\ir migrations/042_partitions.sql
\ir migrations/045_app_user_role_check.sql
\ir migrations/050_indexes.sql
\ir migrations/055_sec_whoami.sql
\ir migrations/056_api_home.sql
\ir migrations/057_sec_scope.sql
\ir migrations/060_queries_simple.sql
\ir migrations/061_queries_aggregate.sql
\ir migrations/062_queries_coursework.sql
\ir migrations/065_api_lookups.sql
\ir migrations/066_api_subscriber_write.sql
\ir migrations/070_api_admin.sql
\ir migrations/075_password_reset.sql

\echo '  данные'
\ir seed/010_ref.sql
\ir seed/020_generate.sql
\ir seed/030_demo_users.sql
\ir seed/040_for_queries.sql

ANALYZE;
\echo 'Готово'
