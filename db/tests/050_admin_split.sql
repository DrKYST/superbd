-- Тест 050. Разделение администратора (D26): администратор приложения (grp_admin) и администратор БД (grp_dba).
-- Как в 020: проверки выполняются от имени пользователя (SET SESSION AUTHORIZATION), результат передаётся
-- через настройки сеанса test.* — в таблицу результатов пользователь писать не может.
-- Учётные записи, созданные тестом (tst_*), удаляются в начале и в конце.

DO $$
DECLARE
    r text;
BEGIN
    DELETE FROM sec.app_user WHERE login LIKE 'tst\_u%';
    FOR r IN SELECT rolname FROM pg_catalog.pg_roles WHERE rolname LIKE 'tst\_u%' LOOP
        EXECUTE format('DROP ROLE %I', r);
    END LOOP;
END $$;

SELECT set_config('test.prov', (SELECT id::text FROM core.provider WHERE name = 'ДонНет'), false);

-- Выполнить оператор от имени текущего пользователя и записать в test.<p_key> 'ok' или код ошибки.
CREATE OR REPLACE FUNCTION pg_temp.try(p_key text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    PERFORM set_config('test.' || p_key, 'ok', false);
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('test.' || p_key, SQLSTATE || ' ' || SQLERRM, false);
END $$;

-- ============================================================================ 10.1–10.6 администратор БД

SET SESSION AUTHORIZATION dba_main;
SELECT group_name AS w_group, coalesce(provider_name, '<нет>') AS w_prov, role_title AS w_title,
       organization AS w_org
FROM api.whoami() \gset
SELECT pg_temp.try('dba_subscribers', 'SELECT * FROM api.q_subscribers()');
SELECT pg_temp.try('dba_providers',   'SELECT * FROM api.q_providers(NULL, NULL)');
SELECT pg_temp.try('dba_users',       'SELECT * FROM api.q_users()');
SELECT pg_temp.try('dba_log',         'SELECT * FROM api.q_change_log(current_date - 7, current_date)');
SELECT count(*) AS d_tables, count(*) FILTER (WHERE table_name = 'core.session') AS d_has_session FROM api.db_tables() \gset
SELECT count(*) FILTER (WHERE pid = pg_backend_pid()) AS d_self FROM api.db_connections() \gset
SELECT pg_temp.try('dba_read',  'SELECT count(*) FROM core.contract');
SELECT pg_temp.try('dba_write', 'UPDATE ref.city SET name = name WHERE false');
SELECT pg_temp.try('dba_setrole', 'SET ROLE app_owner');
SELECT current_user AS d_role_after_set \gset
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('10.1 whoami администратора БД: группа, без провайдера, название роли',
    :'w_group' = 'grp_dba' AND :'w_prov' = '<нет>' AND :'w_title' = 'Администратор базы данных',
    :'w_group' || ', ' || :'w_prov' || ', ' || :'w_title' || ', ' || :'w_org');
SELECT pg_temp.check('10.2 администратору БД закрыты экраны данных (абоненты, провайдеры)',
    current_setting('test.dba_subscribers') LIKE '42501%' AND current_setting('test.dba_providers') LIKE '42501%',
    current_setting('test.dba_subscribers') || ' | ' || current_setting('test.dba_providers'));
SELECT pg_temp.check('10.3 администратору БД доступны пользователи, журнал изменений, таблицы, подключения',
    current_setting('test.dba_users') = 'ok' AND current_setting('test.dba_log') = 'ok'
    AND :d_has_session = 1 AND :d_self = 1,
    current_setting('test.dba_users') || ' | ' || current_setting('test.dba_log')
    || ' | таблиц ' || :d_tables || ', свой сеанс ' || :d_self);
SELECT pg_temp.check('10.4 администратор БД читает таблицы напрямую (pg_read_all_data), но не изменяет',
    current_setting('test.dba_read') = 'ok' AND current_setting('test.dba_write') LIKE '42501%',
    current_setting('test.dba_read') || ' | ' || current_setting('test.dba_write'));
SELECT pg_temp.check('10.5 администратор БД переключается на владельца (SET ROLE app_owner), но не наследует его права',
    current_setting('test.dba_setrole') = 'ok' AND :'d_role_after_set' = 'app_owner'
    AND pg_catalog.pg_has_role('dba_main', 'app_owner', 'SET')
    AND NOT pg_catalog.pg_has_role('dba_main', 'app_owner', 'USAGE'),
    current_setting('test.dba_setrole') || ', current_user=' || :'d_role_after_set');
SELECT pg_temp.check('10.6 группа пользователя — по прямому членству: у администратора БД одна группа grp_dba',
    sec.group_of('dba_main') = 'grp_dba' AND sec.group_of('adm_main') = 'grp_admin'
    AND sec.group_of('app_owner') IS NULL,
    sec.group_of('dba_main') || ', ' || sec.group_of('adm_main'));

-- ============================================================================ 10.7–10.8 администратор приложения

SET SESSION AUTHORIZATION adm_main;
SELECT pg_temp.try('adm_log',    'SELECT * FROM api.q_change_log(current_date - 7, current_date)');
SELECT pg_temp.try('adm_tables', 'SELECT * FROM api.db_tables()');
SELECT pg_temp.try('adm_conn',   'SELECT * FROM api.db_connections()');
SELECT pg_temp.try('adm_read',   'SELECT count(*) FROM core.contract');
SELECT pg_temp.try('adm_providers', 'SELECT * FROM api.q_providers(NULL, NULL)');
SELECT string_agg(DISTINCT group_name, ',' ORDER BY group_name) AS a_groups FROM api.q_users(p_limit => 200) \gset
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('10.7 администратору приложения закрыты журнал изменений и состояние БД',
    current_setting('test.adm_log') LIKE '42501%' AND current_setting('test.adm_tables') LIKE '42501%'
    AND current_setting('test.adm_conn') LIKE '42501%' AND current_setting('test.adm_read') LIKE '42501%'
    AND current_setting('test.adm_providers') = 'ok',
    current_setting('test.adm_log') || ' | ' || current_setting('test.adm_read'));
SELECT pg_temp.check('10.8 администратор приложения видит в «Пользователях» свою группу и управляемые, без администраторов БД',
    :'a_groups' = 'grp_admin,grp_chief,grp_manager,grp_operator', :'a_groups');

-- ============================================================================ 10.9–10.13 создание учётных записей

SET SESSION AUTHORIZATION adm_main;
SELECT pg_temp.try('c_op',
    format('SELECT api.user_create(%L, %L, %L, %s)', 'tst_uop', 'Тестов Олег Петрович', 'grp_operator',
           current_setting('test.prov')));
SELECT pg_temp.try('c_chief', $q$SELECT api.user_create('tst_uchief', 'Тестова Анна Ильинична', 'grp_chief')$q$);
SELECT pg_temp.try('c_adm',   $q$SELECT api.user_create('tst_uadm', 'Тестов Иван Иванович', 'grp_admin')$q$);
SELECT pg_temp.try('c_dba',   $q$SELECT api.user_create('tst_udba', 'Тестов Иван Иванович', 'grp_dba')$q$);
SELECT pg_temp.try('c_noprov', $q$SELECT api.user_create('tst_uop2', 'Тестов Олег Петрович', 'grp_operator')$q$);
SELECT pg_temp.try('c_chiefprov',
    format('SELECT api.user_create(%L, %L, %L, %s)', 'tst_uchief2', 'Тестова Анна Ильинична', 'grp_chief',
           current_setting('test.prov')));
SELECT pg_temp.try('c_dup',   $q$SELECT api.user_create('op_donnet', 'Тестов Олег Петрович', 'grp_chief')$q$);
SELECT pg_temp.try('c_badlogin', $q$SELECT api.user_create('Tst-User', 'Тестов Олег Петрович', 'grp_chief')$q$);
SELECT pg_temp.try('c_nologin', $q$SELECT api.user_create('tst_uchief3', 'Тестова Анна Ильинична', 'grp_chief', p_can_login => false)$q$);
SELECT string_agg(group_name, ',' ORDER BY ord) AS mg_adm FROM api.v_manageable_groups \gset
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION dba_main;
SELECT string_agg(group_name, ',' ORDER BY ord) AS mg_dba FROM api.v_manageable_groups \gset
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION dba_main;
SELECT pg_temp.try('d_adm', $q$SELECT api.user_create('tst_uadm', 'Тестов Иван Иванович', 'grp_admin')$q$);
SELECT pg_temp.try('d_op',  $q$SELECT api.user_create('tst_uop3', 'Тестов Олег Петрович', 'grp_chief')$q$);
SELECT pg_temp.try('d_dba', $q$SELECT api.user_create('tst_udba', 'Тестов Иван Иванович', 'grp_dba')$q$);
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('10.9 администратор приложения создаёт оператора (с провайдером) и главного аналитика (без)',
    current_setting('test.c_op') = 'ok' AND current_setting('test.c_chief') = 'ok'
    AND sec.group_of('tst_uop') = 'grp_operator' AND sec.group_of('tst_uchief') = 'grp_chief'
    AND EXISTS (SELECT 1 FROM sec.app_user u WHERE u.login = 'tst_uop'
                AND u.provider_id = current_setting('test.prov')::int)
    AND EXISTS (SELECT 1 FROM pg_catalog.pg_authid r WHERE r.rolname = 'tst_uop' AND r.rolcanlogin
                AND NOT r.rolsuper AND NOT r.rolcreaterole AND r.rolpassword IS NULL),
    current_setting('test.c_op') || ' | ' || current_setting('test.c_chief'));
SELECT pg_temp.check('10.10 администратор приложения не создаёт администраторов (ни приложения, ни БД)',
    current_setting('test.c_adm') LIKE '42501%' AND current_setting('test.c_dba') LIKE '42501%',
    current_setting('test.c_adm') || ' | ' || current_setting('test.c_dba'));
SELECT pg_temp.check('10.11 администратор БД создаёт только администраторов приложения',
    current_setting('test.d_adm') = 'ok' AND sec.group_of('tst_uadm') = 'grp_admin'
    AND current_setting('test.d_op') LIKE '42501%' AND current_setting('test.d_dba') LIKE '42501%',
    current_setting('test.d_adm') || ' | ' || current_setting('test.d_op') || ' | ' || current_setting('test.d_dba'));
SELECT pg_temp.check('10.12 провайдер обязателен оператору и запрещён главному аналитику',
    current_setting('test.c_noprov') LIKE '22023%' AND current_setting('test.c_chiefprov') LIKE '22023%'
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname IN ('tst_uop2', 'tst_uchief2')),
    current_setting('test.c_noprov') || ' | ' || current_setting('test.c_chiefprov'));
SELECT pg_temp.check('10.13 занятый и неправильный логин отклоняются',
    current_setting('test.c_dup') LIKE '23505%' AND current_setting('test.c_badlogin') LIKE '22023%',
    current_setting('test.c_dup') || ' | ' || current_setting('test.c_badlogin'));

SELECT pg_temp.check('10.13а «Вход разрешён» снят при создании — роль без права входа; список групп формы — управляемые группы',
    current_setting('test.c_nologin') = 'ok'
    AND NOT (SELECT rolcanlogin FROM pg_catalog.pg_roles WHERE rolname = 'tst_uchief3')
    AND :'mg_adm' = 'grp_operator,grp_manager,grp_chief' AND :'mg_dba' = 'grp_admin',
    current_setting('test.c_nologin') || ' | ' || :'mg_adm' || ' | ' || :'mg_dba');

-- ============================================================================ 10.14–10.15 запрет входа

SET SESSION AUTHORIZATION adm_main;
SELECT pg_temp.try('b_op',   $q$SELECT api.user_set_login('tst_uop', false)$q$);
SELECT pg_temp.try('b_self', $q$SELECT api.user_set_login('adm_main', false)$q$);
SELECT pg_temp.try('b_adm',  $q$SELECT api.user_set_login('tst_uadm', false)$q$);
SELECT pg_temp.try('b_dba',  $q$SELECT api.user_set_login('dba_main', false)$q$);
RESET SESSION AUTHORIZATION;
SELECT rolcanlogin AS b_after FROM pg_catalog.pg_roles WHERE rolname = 'tst_uop' \gset

SET SESSION AUTHORIZATION dba_main;
SELECT pg_temp.try('b_by_dba', $q$SELECT api.user_set_login('tst_uadm', false)$q$);
SELECT pg_temp.try('b_op_by_dba', $q$SELECT api.user_set_login('op_donnet', false)$q$);
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('10.14 администратор приложения запрещает вход оператору, но не себе и не администраторам',
    current_setting('test.b_op') = 'ok' AND NOT :'b_after'::boolean
    AND current_setting('test.b_self') LIKE '22023%'
    AND current_setting('test.b_adm') LIKE '42501%' AND current_setting('test.b_dba') LIKE '42501%',
    current_setting('test.b_op') || ', вход=' || :'b_after' || ' | ' || current_setting('test.b_self')
    || ' | ' || current_setting('test.b_adm'));
SELECT pg_temp.check('10.15 администратор БД запрещает вход администратору приложения, но не оператору',
    current_setting('test.b_by_dba') = 'ok'
    AND NOT (SELECT rolcanlogin FROM pg_catalog.pg_roles WHERE rolname = 'tst_uadm')
    AND current_setting('test.b_op_by_dba') LIKE '42501%'
    AND (SELECT rolcanlogin FROM pg_catalog.pg_roles WHERE rolname = 'op_donnet'),
    current_setting('test.b_by_dba') || ' | ' || current_setting('test.b_op_by_dba'));

-- Уборка: учётные записи теста.
DO $$
DECLARE
    r text;
BEGIN
    DELETE FROM sec.app_user WHERE login LIKE 'tst\_u%';
    FOR r IN SELECT rolname FROM pg_catalog.pg_roles WHERE rolname LIKE 'tst\_u%' LOOP
        EXECUTE format('DROP ROLE %I', r);
    END LOOP;
END $$;
