-- Тест 020. api.whoami() и базовое разграничение доступа (SET SESSION AUTHORIZATION).
-- От имени проверяемой роли нельзя писать во временную таблицу результатов (её владелец — postgres),
-- поэтому значения передаются через переменные psql (\gset) и настройку сеанса test.*.

-- Роль без группы: создаётся на время теста.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'tst_nogroup') THEN
        CREATE ROLE tst_nogroup LOGIN;
    END IF;
END $$;

-- 6.1 Оператор
SET SESSION AUTHORIZATION op_donnet;
SELECT group_name AS w_group, coalesce(provider_name, '') AS w_prov, short_name AS w_short,
       role_short AS w_role, database_name AS w_db
FROM api.whoami() \gset
DO $$
BEGIN
    PERFORM set_config('test.direct_denied', 'no', false);
    BEGIN
        PERFORM 1 FROM core.contract LIMIT 1;
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM set_config('test.direct_denied', 'yes', false);
    END;
END $$;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('6.1 whoami оператора: группа, провайдер, краткое ФИО, роль',
    :'w_group' = 'grp_operator' AND :'w_prov' LIKE '%«ДонНет»' AND :'w_short' = 'Лысенко И. О.'
    AND :'w_role' = 'оператор' AND :'w_db' = current_database(),
    :'w_group' || ', ' || :'w_prov' || ', ' || :'w_short' || ', ' || :'w_role');
SELECT pg_temp.check('6.2 оператор не читает таблицы core напрямую (только через api)',
    current_setting('test.direct_denied') = 'yes');

-- 6.3 Администратор приложения: провайдера нет
SET SESSION AUTHORIZATION adm_main;
SELECT group_name AS w_group, coalesce(provider_name, '<нет>') AS w_prov, role_title AS w_title
FROM api.whoami() \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.check('6.3 whoami администратора приложения: без провайдера',
    :'w_group' = 'grp_admin' AND :'w_prov' = '<нет>' AND :'w_title' = 'Администратор приложения',
    :'w_group' || ', ' || :'w_prov');

-- 6.4 Учётная запись без группы не получает доступа даже к whoami
SET SESSION AUTHORIZATION tst_nogroup;
DO $$
BEGIN
    PERFORM set_config('test.nogroup', 'allowed', false);
    BEGIN
        PERFORM * FROM api.whoami();
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM set_config('test.nogroup', 'denied: ' || SQLERRM, false);
    END;
END $$;
RESET SESSION AUTHORIZATION;
SELECT pg_temp.check('6.4 пользователь без группы получает отказ',
    current_setting('test.nogroup') LIKE 'denied%', current_setting('test.nogroup'));

-- 6.5 Ни одна функция схем api и sec не доступна PUBLIC
SELECT pg_temp.check('6.5 функции api и sec не выполняются от имени PUBLIC',
    NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('api', 'sec') AND pg_catalog.has_function_privilege('tst_nogroup', p.oid, 'EXECUTE')),
    (SELECT string_agg(n.nspname || '.' || p.proname, ', ')
     FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('api', 'sec') AND pg_catalog.has_function_privilege('tst_nogroup', p.oid, 'EXECUTE')));

-- 6.6 Начальная страница: по 4 счётчика «Текущих дел» у каждой роли
SET SESSION AUTHORIZATION op_donnet;
SELECT count(*) AS t_op, string_agg(caption || '=' || value, '; ' ORDER BY ord) AS t_op_list FROM api.home_todo() \gset
SET SESSION AUTHORIZATION mgr_donnet;
SELECT count(*) AS t_mgr, string_agg(caption || '=' || value, '; ' ORDER BY ord) AS t_mgr_list FROM api.home_todo() \gset
SET SESSION AUTHORIZATION chief_main;
SELECT count(*) AS t_chief, string_agg(caption || '=' || value, '; ' ORDER BY ord) AS t_chief_list FROM api.home_todo() \gset
SET SESSION AUTHORIZATION adm_main;
SELECT count(*) AS t_adm, string_agg(caption || '=' || value, '; ' ORDER BY ord) AS t_adm_list FROM api.home_todo() \gset
SET SESSION AUTHORIZATION dba_main;
SELECT count(*) AS t_dba, string_agg(caption || '=' || value, '; ' ORDER BY ord) AS t_dba_list FROM api.home_todo() \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.check('6.6 «Текущие дела»: по 4 счётчика у оператора, руководителя, аналитика и обоих администраторов',
    :t_op = 4 AND :t_mgr = 4 AND :t_chief = 4 AND :t_adm = 4 AND :t_dba = 4,
    'оператор: ' || :'t_op_list' || ' | руководитель: ' || :'t_mgr_list' || ' | администратор БД: ' || :'t_dba_list');

-- 6.7 Результат не зависит от часового пояса сеанса клиента (D19: QPSQL работает в UTC)
SET SESSION AUTHORIZATION chief_main;
SET TIME ZONE 'UTC';
SELECT string_agg(caption || '=' || value, '; ' ORDER BY ord) AS tz_utc FROM api.home_todo() \gset
SET TIME ZONE 'Europe/Moscow';
SELECT string_agg(caption || '=' || value, '; ' ORDER BY ord) AS tz_msk FROM api.home_todo() \gset
-- остаётся Europe/Moscow — пояс прогона тестов (run_all.sql)
RESET SESSION AUTHORIZATION;
SELECT pg_temp.check('6.7 «Текущие дела» одинаковы при сеансе в UTC и в Europe/Moscow',
    :'tz_utc' = :'tz_msk', :'tz_utc');

DROP ROLE tst_nogroup;
