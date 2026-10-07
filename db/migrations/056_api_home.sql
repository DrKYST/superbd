-- 056. Данные начальной страницы клиента: блок «Текущие дела» (docs/ui/mockup/Home.dc.html, R.todo).
-- Счётчики считает сервер; оператор и руководитель видят только своего провайдера.
-- Счётчик, который открывает список или отчёт, берёт число из той же функции (ЛР 6, 061), чтобы они не расходились:
-- «Договоры без сеансов более 30 дней» — total_count api.q_idle_contracts, «Провайдеры без сотрудников» — total_count
-- api.q_providers с отбором p_without_staff, «Выручка за …» — строка «Итого» api.report_revenue.
-- До появления RLS отбор по провайдеру делается явно: оператору — c.provider_id = свой, руководителю и
-- аналитику — c.provider_id = ANY (sec.scope_data()) (одно условие с индексом, D24).
SET ROLE app_owner;

DROP FUNCTION IF EXISTS api.home_todo();
CREATE OR REPLACE FUNCTION api.home_todo()
RETURNS TABLE (
    ord     integer,
    caption text,
    value   numeric,
    form    text,
    as_of   timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'   -- D19: клиент QPSQL работает в UTC
AS $$
DECLARE
    v_group    text := sec.current_group();
    v_provider integer := sec.current_provider_id();
    v_scope    integer[] := sec.scope_data();     -- руководитель — свой провайдер, аналитик — все
    v_today    date := current_date;
    v_month    date := date_trunc('month', current_date)::date;
    v_month_nom text := (ARRAY['январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль', 'август',
                               'сентябрь', 'октябрь', 'ноябрь', 'декабрь'])[extract(month FROM current_date)::int]
                        || ' ' || extract(year FROM current_date);
    v_month_prep text := (ARRAY['январе', 'феврале', 'марте', 'апреле', 'мае', 'июне', 'июле', 'августе',
                                'сентябре', 'октябре', 'ноябре', 'декабре'])[extract(month FROM current_date)::int];
    v_pwd_until date := (date_trunc('month', current_date) + interval '2 months - 1 day')::date;
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_dba', 'grp_operator', 'grp_manager', 'grp_chief']);

    IF v_group = 'grp_operator' THEN
        RETURN QUERY
        SELECT 1, 'Договоры без сеансов более 30 дней'::text,
               coalesce((SELECT max(q.total_count) FROM api.q_idle_contracts(30, 1, 0) q), 0)::numeric,
               'idle_contracts'::text, now()
        UNION ALL
        SELECT 2, 'Сеансов зарегистрировано сегодня',
               (SELECT count(*) FROM core.session s JOIN core.contract c ON c.id = s.contract_id
                WHERE c.provider_id = v_provider AND s.started_at >= v_today::timestamptz)::numeric,
               'sessions', now()
        UNION ALL
        SELECT 3, 'Договоров заключено на этой неделе',
               (SELECT count(*) FROM core.contract c
                WHERE c.provider_id = v_provider AND c.connected_on >= date_trunc('week', v_today)::date)::numeric,
               'contracts', now()
        UNION ALL
        SELECT 4, 'Договоры с наступившей датой расторжения',
               (SELECT count(*) FROM core.contract c
                WHERE c.provider_id = v_provider AND c.closed_on = v_today)::numeric,
               'contracts', now();

    ELSIF v_group IN ('grp_manager', 'grp_chief') THEN
        -- Выручка месяца = плата за подключение договоров, заключённых в месяце, + оплата сеансов месяца
        -- (строка «Итого» отчёта «Выручка по периодам»).
        RETURN QUERY
        WITH revenue AS (
            SELECT coalesce((SELECT r.revenue FROM api.report_revenue(v_month, v_today) r WHERE r.period IS NULL), 0)
                   AS total)
        SELECT t.ord, t.caption, t.value, t.form, now()
        FROM (
            SELECT 1 AS ord, 'Провайдеров в объединении'::text AS caption,
                   (SELECT count(*) FROM core.provider)::numeric AS value, 'providers'::text AS form
            WHERE v_group = 'grp_chief'
            UNION ALL
            SELECT CASE WHEN v_group = 'grp_chief' THEN 2 ELSE 1 END,
                   'Выручка за ' || v_month_nom || ', тыс. руб.',
                   round((SELECT total FROM revenue) / 1000), 'report_revenue'
            UNION ALL
            SELECT 2, 'Новых договоров за ' || split_part(v_month_nom, ' ', 1),
                   (SELECT count(*) FROM core.contract c
                    WHERE c.provider_id = ANY (v_scope) AND c.connected_on >= v_month)::numeric,
                   'contracts'
            WHERE v_group = 'grp_manager'
            UNION ALL
            SELECT 3, 'Действующих договоров',
                   (SELECT count(*) FROM core.contract c
                    WHERE c.provider_id = ANY (v_scope) AND c.closed_on IS NULL)::numeric,
                   'contracts'
            UNION ALL
            SELECT 4, 'Договоры без сеансов более 30 дней',
                   coalesce((SELECT max(q.total_count) FROM api.q_idle_contracts(30, 1, 0) q), 0)::numeric,
                   'idle_contracts'
            WHERE v_group = 'grp_manager'
            UNION ALL
            SELECT 4, 'Провайдеры без новых договоров в ' || v_month_prep,
                   (SELECT count(*) FROM core.provider p
                    WHERE NOT EXISTS (SELECT 1 FROM core.contract c
                                      WHERE c.provider_id = p.id AND c.connected_on >= v_month))::numeric,
                   'providers'
            WHERE v_group = 'grp_chief'
        ) t
        ORDER BY t.ord;

    ELSIF v_group = 'grp_admin' THEN
        -- Учётные записи администраторов БД ведёт не администратор приложения (D26) — в счётчиках их нет.
        RETURN QUERY
        SELECT 1, 'Пароли истекают до ' || to_char(v_pwd_until, 'DD.MM.YYYY'),
               (SELECT count(*) FROM sec.app_user u JOIN pg_catalog.pg_roles r ON r.rolname = u.login
                WHERE r.rolvaliduntil IS NOT NULL AND r.rolvaliduntil < (v_pwd_until + 1)::timestamptz
                  AND sec.group_of(u.login) IS DISTINCT FROM 'grp_dba')::numeric,
               'users'::text, now()
        UNION ALL
        SELECT 2, 'Пользователи с запрещённым входом',
               (SELECT count(*) FROM sec.app_user u JOIN pg_catalog.pg_roles r ON r.rolname = u.login
                WHERE NOT r.rolcanlogin AND sec.group_of(u.login) IS DISTINCT FROM 'grp_dba')::numeric,
               'users', now()
        UNION ALL
        SELECT 3, 'Провайдеры без сотрудников',
               coalesce((SELECT max(q.total_count) FROM api.q_providers(p_without_staff => true, p_limit => 1) q), 0)::numeric,
               'providers_without_staff', now()
        UNION ALL
        SELECT 4, 'Пользователей системы',
               (SELECT count(*) FROM sec.app_user u WHERE sec.group_of(u.login) IS DISTINCT FROM 'grp_dba')::numeric,
               'users', now();

    ELSIF v_group = 'grp_dba' THEN
        -- Обслуживание базы (D26): размер данных проекта, подключения, журнал, свежесть статистики планировщика.
        RETURN QUERY
        SELECT 1, 'Размер данных, МБ',
               round((SELECT sum(pg_catalog.pg_total_relation_size(c.oid))
                      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                      WHERE n.nspname IN ('ref', 'core', 'sec', 'audit') AND c.relkind IN ('r', 'p')) / 1048576.0),
               'db_tables'::text, now()
        UNION ALL
        SELECT 2, 'Подключений к базе сейчас',
               -- numbackends, а не pg_stat_activity: функция выполняется от имени app_owner, которому сведения
               -- о чужих сеансах (тип процесса, запрос) не показываются; число подключений к базе видно всем.
               (SELECT d.numbackends FROM pg_catalog.pg_stat_database d WHERE d.datname = current_database())::numeric,
               'db_connections', now()
        UNION ALL
        SELECT 3, 'Изменений в журнале за сегодня',
               (SELECT count(*) FROM audit.change_log l WHERE l.changed_at >= v_today::timestamptz)::numeric,
               'change_log', now()
        UNION ALL
        SELECT 4, 'Таблиц без сбора статистики больше 7 дней',
               (SELECT count(*) FROM pg_catalog.pg_stat_user_tables t
                WHERE t.schemaname IN ('ref', 'core', 'sec', 'audit')
                  AND coalesce(greatest(t.last_analyze, t.last_autoanalyze), '-infinity')
                      < now() - interval '7 days')::numeric,
               'db_tables', now();
    END IF;
END $$;
COMMENT ON FUNCTION api.home_todo() IS
    'Начальная страница, блок «Текущие дела»: счётчики по роли текущего пользователя (оператор и руководитель — только свой провайдер)';

REVOKE ALL ON FUNCTION api.home_todo() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.home_todo() TO grp_admin, grp_dba, grp_operator, grp_manager, grp_chief;

RESET ROLE;
