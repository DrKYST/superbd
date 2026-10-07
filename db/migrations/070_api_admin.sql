-- 070. Администрирование (D26): администратор приложения и администратор БД.
--   администратор приложения (grp_admin) — учётные записи операторов, руководителей и главных аналитиков;
--   администратор БД (grp_dba)           — учётные записи администраторов приложения, журнал изменений,
--                                           состояние базы (таблицы, подключения).
-- Ни один не получает доступа к абонентам, договорам и сеансам через api; права другого себе выдать нельзя.
-- Учётные записи создают функции, принадлежащие app_owner (CREATEROLE, право ADMIN на группы — миграция 010):
-- у пользователей нет права создавать роли напрямую. Пароль при создании не задаётся — его выдаёт сброс пароля
-- (временный пароль со сменой при первом входе, D27).
SET ROLE app_owner;

-- Группы, которыми управляет и которые видит администратор (sec.manageable_groups, sec.visible_groups),
-- и названия групп (sec.group_title) — в 055 рядом с sec.group_of: ими пользуется и представление 11 (061).

-- ============================================================================ пользователи

-- Список пользователей: администратор приложения видит операторов, руководителей, аналитиков и администраторов
-- приложения; администратор БД — администраторов приложения и БД. can_manage — можно ли блокировать (не себя).
DROP FUNCTION IF EXISTS api.q_users(text, text, integer, integer);
CREATE OR REPLACE FUNCTION api.q_users(
    p_group text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, login text, full_name text, group_name text, group_title text, provider_name text,
    can_login boolean, valid_until timestamptz, created_at timestamptz, can_manage boolean, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_group text := sec.current_group();
    v_visible text[] := sec.visible_groups(v_group);
    v_manage text[] := sec.manageable_groups(v_group);
    v_like text := sec.like_prefix(p_search);
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_dba']);
    RETURN QUERY
    SELECT u.id, u.login::text, u.full_name::text, g.grp, sec.group_title(g.grp),
           CASE WHEN p.id IS NULL THEN NULL
                WHEN ot.name = upper(ot.name) THEN ot.name || ' «' || p.name || '»'
                ELSE '«' || p.name || '»' END,
           r.rolcanlogin, r.rolvaliduntil, u.created_at,
           g.grp = ANY (v_manage) AND u.login <> session_user,
           count(*) OVER ()
    FROM sec.app_user u
    CROSS JOIN LATERAL (SELECT sec.group_of(u.login::name) AS grp) g
    JOIN pg_catalog.pg_roles r ON r.rolname = u.login
    LEFT JOIN core.provider p ON p.id = u.provider_id
    LEFT JOIN ref.ownership_type ot ON ot.id = p.ownership_type_id
    WHERE g.grp = ANY (v_visible)
      AND (p_group IS NULL OR g.grp = p_group)
      AND (v_like IS NULL OR lower(u.login) LIKE v_like OR lower(u.full_name) LIKE v_like)
    ORDER BY array_position(ARRAY['grp_dba', 'grp_admin', 'grp_chief', 'grp_manager', 'grp_operator'], g.grp),
             u.full_name
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_users(text, text, integer, integer) IS
    'Пользователи системы видимых групп: логин, ФИО, группа, провайдер, вход разрешён, срок пароля, дата регистрации, можно ли управлять (D26)';

-- Создать пользователя управляемой группы. Пароль не задаётся (вход до сброса пароля невозможен, D27).
DROP FUNCTION IF EXISTS api.user_create(text, text, text, integer);
CREATE OR REPLACE FUNCTION api.user_create(
    p_login text,
    p_full_name text,
    p_group text,
    p_provider_id integer DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_group text := sec.current_group();
    v_login text := btrim(p_login);
    v_id integer;
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_dba']);
    IF p_group IS NULL OR NOT p_group = ANY (sec.manageable_groups(v_group)) THEN
        RAISE EXCEPTION '%', CASE v_group
            WHEN 'grp_admin' THEN 'Администратор приложения создаёт операторов, руководителей и главных аналитиков'
            ELSE 'Администратор БД создаёт только администраторов приложения' END
            USING ERRCODE = '42501';
    END IF;
    IF p_group IN ('grp_operator', 'grp_manager') AND p_provider_id IS NULL THEN
        RAISE EXCEPTION 'Укажите провайдера: оператор и руководитель работают у провайдера' USING ERRCODE = '22023';
    END IF;
    IF p_group NOT IN ('grp_operator', 'grp_manager') AND p_provider_id IS NOT NULL THEN
        RAISE EXCEPTION 'Главный аналитик и администратор не привязываются к провайдеру' USING ERRCODE = '22023';
    END IF;
    BEGIN
        PERFORM v_login::ref.d_login;
    EXCEPTION WHEN check_violation OR string_data_right_truncation THEN
        RAISE EXCEPTION 'Логин: от 3 до 31 символа, латинские строчные буквы, цифры и «_», начинается с буквы'
            USING ERRCODE = '22023';
    END;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = v_login) THEN
        RAISE EXCEPTION 'Логин «%» уже занят', v_login USING ERRCODE = '23505';
    END IF;

    EXECUTE format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS',
                   v_login);
    EXECUTE format('GRANT %I TO %I', p_group, v_login);
    EXECUTE format('COMMENT ON ROLE %I IS %L', v_login, 'Сотрудник: ' || btrim(p_full_name));
    INSERT INTO sec.app_user (provider_id, login, full_name)
    VALUES (p_provider_id, v_login, btrim(p_full_name))
    RETURNING sec.app_user.id INTO v_id;
    RETURN v_id;
EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'Провайдер не найден' USING ERRCODE = '22023';
END $$;
COMMENT ON FUNCTION api.user_create(text, text, text, integer) IS
    'Новый пользователь: LOGIN-роль PostgreSQL без пароля, членство в группе, строка «Сотрудник»; только для управляемых групп (D26), пароль — сбросом пароля (D27)';

-- Разрешить или запретить вход пользователю управляемой группы (не себе).
DROP FUNCTION IF EXISTS api.user_set_login(text, boolean);
CREATE OR REPLACE FUNCTION api.user_set_login(p_login text, p_enabled boolean)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_group text := sec.current_group();
    v_target text := sec.group_of(p_login::name);
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_dba']);
    IF p_login = session_user THEN
        RAISE EXCEPTION 'Нельзя запретить вход собственной учётной записи' USING ERRCODE = '22023';
    END IF;
    IF v_target IS NULL OR NOT v_target = ANY (sec.manageable_groups(v_group))
       OR NOT EXISTS (SELECT 1 FROM sec.app_user u WHERE u.login = p_login) THEN
        RAISE EXCEPTION 'Нет прав на учётную запись «%»', p_login USING ERRCODE = '42501';
    END IF;
    EXECUTE format('ALTER ROLE %I %s', p_login, CASE WHEN p_enabled THEN 'LOGIN' ELSE 'NOLOGIN' END);
END $$;
COMMENT ON FUNCTION api.user_set_login(text, boolean) IS
    'Разрешить (true) или запретить (false) вход пользователю управляемой группы (D26); себе — нельзя';

-- ============================================================================ администратор БД

-- Журнал изменений за период с отбором по таблице, операции и пользователю.
DROP FUNCTION IF EXISTS api.q_change_log(date, date, text, text, text, integer, integer);
CREATE OR REPLACE FUNCTION api.q_change_log(
    p_from date,
    p_to date,
    p_table text DEFAULT NULL,
    p_operation text DEFAULT NULL,
    p_db_user text DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id bigint, changed_at timestamptz, db_user text, table_name text, operation text, row_pk text,
    old_row jsonb, new_row jsonb, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
BEGIN
    PERFORM sec.require_group(ARRAY['grp_dba']);
    RETURN QUERY
    SELECT l.id, l.changed_at, l.db_user::text, l.table_name::text, l.operation::text, l.row_pk,
           l.old_row, l.new_row, count(*) OVER ()
    FROM audit.change_log l
    WHERE l.changed_at >= p_from AND l.changed_at < p_to + 1
      AND (p_table IS NULL OR l.table_name = p_table)
      AND (p_operation IS NULL OR l.operation = p_operation)
      AND (p_db_user IS NULL OR l.db_user = p_db_user)
    ORDER BY l.changed_at DESC, l.id DESC
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_change_log(date, date, text, text, text, integer, integer) IS
    'Журнал изменений за период: кто, когда, какую строку какой таблицы изменил, строка до и после (jsonb); только администратор БД (D26)';

-- Таблицы проекта: оценка числа строк, размер с индексами, последняя очистка и сбор статистики, чтения.
DROP FUNCTION IF EXISTS api.db_tables();
CREATE OR REPLACE FUNCTION api.db_tables()
RETURNS TABLE (
    table_name text, table_title text, rows_estimate bigint, total_size text, total_bytes bigint,
    last_vacuum timestamptz, last_analyze timestamptz, seq_scan bigint, idx_scan bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
BEGIN
    PERFORM sec.require_group(ARRAY['grp_dba']);
    RETURN QUERY
    SELECT t.schemaname || '.' || t.relname,
           pg_catalog.obj_description(t.relid, 'pg_class'),
           t.n_live_tup,
           pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(t.relid)),
           pg_catalog.pg_total_relation_size(t.relid),
           greatest(t.last_vacuum, t.last_autovacuum),
           greatest(t.last_analyze, t.last_autoanalyze),
           t.seq_scan, coalesce(t.idx_scan, 0)
    FROM pg_catalog.pg_stat_user_tables t
    WHERE t.schemaname IN ('ref', 'core', 'sec', 'audit')
    ORDER BY pg_catalog.pg_total_relation_size(t.relid) DESC, 1;
END $$;
COMMENT ON FUNCTION api.db_tables() IS
    'Состояние таблиц проекта: строки (оценка), размер с индексами, последняя очистка и сбор статистики, последовательные и индексные чтения; только администратор БД (D26)';

-- Подключения к базе. SECURITY INVOKER: текст запросов других сеансов виден благодаря pg_monitor у администратора БД,
-- у владельца функций app_owner такого права нет.
DROP FUNCTION IF EXISTS api.db_connections();
CREATE OR REPLACE FUNCTION api.db_connections()
RETURNS TABLE (
    pid integer, user_name text, application_name text, client_addr text, backend_start timestamptz,
    state text, state_change timestamptz, wait_event text, query text)
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
BEGIN
    PERFORM sec.require_group(ARRAY['grp_dba']);
    RETURN QUERY
    SELECT a.pid, a.usename::text, a.application_name, host(a.client_addr), a.backend_start,
           a.state, a.state_change, a.wait_event_type || coalesce(': ' || a.wait_event, ''), a.query
    FROM pg_catalog.pg_stat_activity a
    WHERE a.datname = current_database() AND a.backend_type = 'client backend'
    ORDER BY a.backend_start;
END $$;
COMMENT ON FUNCTION api.db_connections() IS
    'Подключения к базе: пользователь, программа, адрес, начало сеанса, состояние, ожидание, текущий запрос; только администратор БД (D26)';

REVOKE ALL ON FUNCTION api.q_users(text, text, integer, integer), api.user_create(text, text, text, integer),
    api.user_set_login(text, boolean), api.q_change_log(date, date, text, text, text, integer, integer),
    api.db_tables(), api.db_connections() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.q_users(text, text, integer, integer), api.user_create(text, text, text, integer),
    api.user_set_login(text, boolean) TO grp_admin, grp_dba;
GRANT EXECUTE ON FUNCTION api.q_change_log(date, date, text, text, text, integer, integer),
    api.db_tables(), api.db_connections() TO grp_dba;
-- db_connections выполняется от имени пользователя: ему нужен доступ к функциям проверки группы.
GRANT USAGE ON SCHEMA sec TO grp_dba;
GRANT EXECUTE ON FUNCTION sec.require_group(text[]), sec.current_group(), sec.group_of(name) TO grp_dba;

RESET ROLE;
