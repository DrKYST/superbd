-- Тест 070. Сброс пароля: временный пароль и смена при входе (D27, db/migrations/075_password_reset.sql).
-- Как в 050: проверки от имени пользователя (SET SESSION AUTHORIZATION), результаты — через test.*.
-- Учётные записи теста (tst_p*) удаляются в начале и в конце. Пароли здесь — тестовые значения.

DO $$
DECLARE
    r text;
BEGIN
    DELETE FROM sec.app_user WHERE login LIKE 'tst\_p%';
    FOR r IN SELECT rolname FROM pg_catalog.pg_roles WHERE rolname LIKE 'tst\_p%' LOOP
        EXECUTE format('DROP ROLE %I', r);
    END LOOP;
END $$;

SELECT id AS donnet_id FROM core.provider WHERE name = 'ДонНет' \gset

CREATE OR REPLACE FUNCTION pg_temp.try(p_key text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    PERFORM set_config('test.' || p_key, 'ok', false);
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('test.' || p_key, SQLSTATE || ' ' || SQLERRM, false);
END $$;

-- ============================================================================ создание и сброс

-- Администратор БД создаёт администратора приложения (временный пароль сразу, 11.7)
SET SESSION AUTHORIZATION dba_main;
SELECT set_config('test.pw_adm', temp_password, false) FROM api.user_create('tst_padm', 'Тестов Аркадий Петрович', 'grp_admin');
SELECT pg_temp.try('r_dba_self', $q$SELECT api.user_reset_password('dba_main')$q$);
RESET SESSION AUTHORIZATION;

-- Администратор приложения создаёт оператора и сбрасывает ему пароль
SET SESSION AUTHORIZATION adm_main;
SELECT set_config('test.pw_create', temp_password, false)
FROM api.user_create('tst_poper', 'Тестов Пётр Олегович', 'grp_operator', :donnet_id);
SELECT pg_temp.try('r_self',  $q$SELECT api.user_reset_password('adm_main')$q$);
SELECT pg_temp.try('r_admin', $q$SELECT api.user_reset_password('tst_padm')$q$);
SELECT pg_temp.try('r_dba',   $q$SELECT api.user_reset_password('dba_main')$q$);
SELECT set_config('test.pw', temp_password, false), valid_until AS pw_until FROM api.user_reset_password('tst_poper') \gset
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION dba_main;
SELECT pg_temp.try('r_dba_op',  $q$SELECT api.user_reset_password('tst_poper')$q$);
SELECT pg_temp.try('r_dba_adm', $q$SELECT api.user_reset_password('tst_padm')$q$);
SELECT pg_temp.try('c_dba_own', $q$SELECT api.change_own_password('Новый-пароль-2026')$q$);
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('11.1 сброс пароля оператору: 12 символов без похожих знаков, срок — сутки, хеш SCRAM, отметка «кто и когда»',
    length(current_setting('test.pw')) = 12
    AND translate(current_setting('test.pw'), 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789', '') = ''
    AND current_setting('test.pw') <> current_setting('test.pw_create')
    AND (SELECT r.rolvaliduntil BETWEEN now() + interval '23 hours' AND now() + interval '25 hours'
                AND r.rolpassword LIKE 'SCRAM-SHA-256$%' AND r.rolvaliduntil = :'pw_until'::timestamptz
         FROM pg_catalog.pg_authid r WHERE r.rolname = 'tst_poper')
    AND (SELECT u.reset_pending AND u.reset_by = 'adm_main' AND u.reset_at > now() - interval '1 minute'
         FROM sec.app_user u WHERE u.login = 'tst_poper'),
    (SELECT 'срок ' || r.rolvaliduntil FROM pg_catalog.pg_roles r WHERE r.rolname = 'tst_poper'));
SELECT pg_temp.check('11.2 себе сбросить нельзя; администратор приложения — не администраторам, администратор БД — только администраторам приложения',
    current_setting('test.r_self') LIKE '22023%' AND current_setting('test.r_dba_self') LIKE '22023%'
    AND current_setting('test.r_admin') LIKE '42501%' AND current_setting('test.r_dba') LIKE '42501%'
    AND current_setting('test.r_dba_op') LIKE '42501%' AND current_setting('test.r_dba_adm') = 'ok',
    current_setting('test.r_self') || ' | ' || current_setting('test.r_admin') || ' | ' || current_setting('test.r_dba_op'));

-- ============================================================================ работа с временным паролем

SET SESSION AUTHORIZATION tst_poper;
SELECT must_change_password AS w_flag, group_name AS w_group FROM api.whoami() \gset
SELECT pg_temp.try('p_contracts', 'SELECT * FROM api.q_contracts()');
SELECT pg_temp.try('p_view',      'SELECT * FROM api.v_subscribers LIMIT 1');
SELECT pg_temp.try('p_home',      'SELECT * FROM api.home_todo()');
SELECT pg_temp.try('p_short',     $q$SELECT api.change_own_password('Кор0тко')$q$);
SELECT pg_temp.try('p_login',     $q$SELECT api.change_own_password('TST_POPER')$q$);
SELECT pg_temp.try('p_ok',        $q$SELECT api.change_own_password('Новый-пароль-2026')$q$);
SELECT pg_temp.try('p_after',     'SELECT * FROM api.q_contracts()');
SELECT must_change_password AS w_flag_after FROM api.whoami() \gset
RESET SESSION AUTHORIZATION;

-- администратор приложения с временным паролем: панель групп и список групп формы тоже закрыты
SET SESSION AUTHORIZATION tst_padm;
SELECT pg_temp.try('a_groups', 'SELECT * FROM api.v_user_groups');
SELECT pg_temp.try('a_mgroups', 'SELECT * FROM api.v_manageable_groups');
SELECT must_change_password AS a_flag FROM api.whoami() \gset
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('11.3 с временным паролем работает только whoami (флаг); функции, представления и счётчики — отказ SB001',
    :'w_flag' = 't' AND :'w_group' = 'grp_operator' AND :'a_flag' = 't'
    AND current_setting('test.p_contracts') LIKE 'SB001%' AND current_setting('test.p_view') LIKE 'SB001%'
    AND current_setting('test.p_home') LIKE 'SB001%'
    AND current_setting('test.a_groups') LIKE 'SB001%' AND current_setting('test.a_mgroups') LIKE 'SB001%',
    current_setting('test.p_contracts') || ' | ' || current_setting('test.p_view') || ' | ' || current_setting('test.a_groups'));
SELECT pg_temp.check('11.4 смена пароля: короткий и равный логину — отказ 22023; правильный — флаг снят, срок бессрочный, функции работают',
    current_setting('test.p_short') LIKE '22023%' AND current_setting('test.p_login') LIKE '22023%'
    AND current_setting('test.p_ok') = 'ok' AND current_setting('test.p_after') = 'ok' AND :'w_flag_after' = 'f'
    AND (SELECT r.rolvaliduntil = 'infinity' FROM pg_catalog.pg_roles r WHERE r.rolname = 'tst_poper')
    AND NOT (SELECT u.reset_pending FROM sec.app_user u WHERE u.login = 'tst_poper'),
    current_setting('test.p_short') || ' | ' || current_setting('test.p_login') || ' | ' || current_setting('test.p_ok'));
SELECT pg_temp.check('11.5 временного пароля нет ни в одной колонке sec.app_user и audit.change_log',
    NOT EXISTS (SELECT 1 FROM sec.app_user u
                WHERE strpos(row_to_json(u)::text, current_setting('test.pw')) > 0
                   OR strpos(row_to_json(u)::text, current_setting('test.pw_create')) > 0
                   OR strpos(row_to_json(u)::text, current_setting('test.pw_adm')) > 0)
    AND NOT EXISTS (SELECT 1 FROM audit.change_log l
                    WHERE strpos(row_to_json(l)::text, current_setting('test.pw')) > 0));

-- ============================================================================ заблокированная учётная запись

SET SESSION AUTHORIZATION adm_main;
SELECT pg_temp.try('b_block', $q$SELECT api.user_set_login('tst_poper', false)$q$);
SELECT pg_temp.try('b_reset', $q$SELECT api.user_reset_password('tst_poper')$q$);
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('11.6 сброс пароля заблокированному: вход по-прежнему запрещён, флаг смены пароля стоит',
    current_setting('test.b_block') = 'ok' AND current_setting('test.b_reset') = 'ok'
    AND NOT (SELECT r.rolcanlogin FROM pg_catalog.pg_roles r WHERE r.rolname = 'tst_poper')
    AND (SELECT u.reset_pending FROM sec.app_user u WHERE u.login = 'tst_poper'),
    current_setting('test.b_block') || ' | ' || current_setting('test.b_reset'));
SELECT pg_temp.check('11.7 user_create сразу выдаёт временный пароль: 12 символов, флаг, срок — сутки',
    length(current_setting('test.pw_adm')) = 12 AND length(current_setting('test.pw_create')) = 12
    AND (SELECT u.reset_pending AND u.reset_by = 'dba_main' FROM sec.app_user u WHERE u.login = 'tst_padm')
    AND (SELECT r.rolvaliduntil BETWEEN now() + interval '23 hours' AND now() + interval '25 hours'
         FROM pg_catalog.pg_roles r WHERE r.rolname = 'tst_padm'));
SELECT pg_temp.check('11.8 администратор БД меняет свой пароль не через приложение (\password в psql)',
    current_setting('test.c_dba_own') LIKE '42501%', current_setting('test.c_dba_own'));

-- Уборка
DO $$
DECLARE
    r text;
BEGIN
    DELETE FROM sec.app_user WHERE login LIKE 'tst\_p%';
    FOR r IN SELECT rolname FROM pg_catalog.pg_roles WHERE rolname LIKE 'tst\_p%' LOOP
        EXECUTE format('DROP ROLE %I', r);
    END LOOP;
END $$;
