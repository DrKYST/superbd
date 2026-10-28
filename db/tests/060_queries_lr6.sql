-- Тест 060. Запросы ЛР 6 и запросы 20, 22 ТЗ курсового проекта (db/migrations/061_queries_aggregate.sql, запрос 16 — в 060; D31): результат совпадает с
-- независимым расчётом суперпользователя, счётчики «Текущих дел» — со списками и отчётами, права — по ролям.
-- Как в 020 и 050: проверки от имени пользователя (SET SESSION AUTHORIZATION), значения — через \gset и test.*.

-- Выполнить оператор от имени текущего пользователя и записать в test.<p_key> 'ok' или код ошибки (как в 050).
CREATE OR REPLACE FUNCTION pg_temp.try(p_key text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    PERFORM set_config('test.' || p_key, 'ok', false);
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('test.' || p_key, SQLSTATE || ' ' || SQLERRM, false);
END $$;

-- Какие запросы ЛР 6 доступны текущему пользователю: строка из 1 (выполнен), 0 (отказ 42501), x (другая ошибка).
-- Порядок: 11 v_user_groups, 20 v_revenue_items, 12, 13, 14, 15, 22, «Крупнейшие абоненты».
CREATE OR REPLACE FUNCTION pg_temp.lr6_rights()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_sql text;
    v_res text := '';
BEGIN
    FOREACH v_sql IN ARRAY ARRAY[
        'SELECT * FROM api.v_user_groups',
        'SELECT * FROM api.v_revenue_items LIMIT 1',
        'SELECT * FROM api.report_new_contracts(current_date - 30, current_date)',
        'SELECT * FROM api.q_shared_subscribers()',
        'SELECT * FROM api.q_idle_contracts()',
        'SELECT * FROM api.report_revenue(current_date - 30, current_date)',
        'SELECT * FROM api.report_provider_shares(current_date - 30, current_date)',
        'SELECT * FROM api.report_top_subscribers(current_date - 30, current_date)']
    LOOP
        BEGIN
            EXECUTE v_sql;
            v_res := v_res || '1';
        EXCEPTION WHEN insufficient_privilege THEN
            v_res := v_res || '0';
        WHEN OTHERS THEN
            v_res := v_res || 'x';
        END;
    END LOOP;
    RETURN v_res;
END $$;

-- ============================================================================ эталоны (суперпользователь)
SELECT id AS donnet_id FROM core.provider WHERE name = 'ДонНет' \gset
SELECT count(*) AS providers_all FROM core.provider \gset
-- 12: договоры «ДонНет» за III квартал 2026
SELECT count(*) AS e12_q3 FROM core.contract
WHERE provider_id = :donnet_id AND connected_on BETWEEN '2026-07-01' AND '2026-09-30' \gset
-- 13: общие абоненты (договоры не меньше чем с двумя провайдерами) — список кодов и те, что обслуживает «ДонНет»
SELECT count(*) FILTER (WHERE n >= 3) AS e13_three FROM (SELECT count(DISTINCT provider_id) AS n FROM core.contract GROUP BY subscriber_id) x \gset
SELECT count(*) AS e13_total, md5(string_agg(subscriber_id::text, ',' ORDER BY subscriber_id)) AS e13_md5,
       count(*) FILTER (WHERE donnet) AS e13_donnet
FROM (SELECT subscriber_id, bool_or(provider_id = :donnet_id) AS donnet FROM core.contract
      GROUP BY subscriber_id HAVING count(DISTINCT provider_id) > 1) x \gset
-- 14: действующие договоры «ДонНет», заключённые раньше границы, без сеансов с границы (через NOT EXISTS)
SELECT count(*) AS e14_idle FROM core.contract c
WHERE c.provider_id = :donnet_id AND c.closed_on IS NULL AND c.connected_on < current_date - 30
  AND NOT EXISTS (SELECT 1 FROM core.session s WHERE s.contract_id = c.id
                    AND s.started_at >= (current_date - 30)::timestamptz) \gset
-- 15: выручка «ДонНет» за текущий месяц — плата за подключение + оплата сеансов
SELECT coalesce((SELECT sum(connection_fee) FROM core.contract
                 WHERE provider_id = :donnet_id AND connected_on BETWEEN date_trunc('month', current_date)::date AND current_date), 0)
     + coalesce((SELECT sum(s.cost) FROM core.session s JOIN core.contract c ON c.id = s.contract_id
                 WHERE c.provider_id = :donnet_id AND s.started_at >= date_trunc('month', current_date)
                   AND s.started_at < current_date + 1), 0) AS e15_month \gset
SELECT (SELECT count(*) FROM core.contract) + (SELECT count(*) FROM core.session) AS e15_items \gset
-- 16: провайдеры без сотрудников (NOT EXISTS) и та же разность через NOT IN без отсечения NULL
SELECT count(*) AS e16_free FROM core.provider p WHERE NOT EXISTS (SELECT 1 FROM sec.app_user u WHERE u.provider_id = p.id) \gset
SELECT count(*) AS e16_null_trap FROM core.provider p WHERE p.id NOT IN (SELECT u.provider_id FROM sec.app_user u) \gset
-- 22: договоры, действующие на конец периода, у всех провайдеров
SELECT count(*) AS e17_contracts FROM core.contract
WHERE connected_on <= '2026-09-30' AND (closed_on IS NULL OR closed_on > '2026-09-30') \gset
-- «Крупнейшие абоненты»: наибольшая выручка абонента «ДонНет» за 2026 год до сентября
SELECT max(v) AS e_top1 FROM (
    SELECT c.subscriber_id, sum(x.amount) AS v
    FROM (SELECT c.id, c.connection_fee AS amount FROM core.contract c
          WHERE c.provider_id = :donnet_id AND c.connected_on BETWEEN '2026-01-01' AND '2026-09-30'
          UNION ALL
          SELECT s.contract_id, s.cost FROM core.session s
          WHERE s.started_at >= '2026-01-01' AND s.started_at < '2026-10-01') x
    JOIN core.contract c ON c.id = x.id AND c.provider_id = :donnet_id
    GROUP BY c.subscriber_id) t \gset

-- ============================================================================ оператор
SET SESSION AUTHORIZATION op_donnet;
SELECT pg_temp.lr6_rights() AS r_op \gset
SELECT max(total_count) AS q14_total, count(*) AS q14_rows,
       count(*) FILTER (WHERE coalesce(last_session, '-infinity') >= (current_date - 30)::timestamptz
                           OR connected_on >= current_date - 30) AS q14_wrong
FROM api.q_idle_contracts(30, 200) \gset
SELECT value AS t14_op FROM api.home_todo() WHERE caption = 'Договоры без сеансов более 30 дней' \gset
SELECT count(*) FILTER (WHERE NOT can_edit) AS op_locked FROM api.v_subscribers \gset

-- ============================================================================ руководитель
SET SESSION AUTHORIZATION mgr_donnet;
SELECT pg_temp.lr6_rights() AS r_mgr \gset
SELECT value AS t14_mgr FROM api.home_todo() WHERE caption = 'Договоры без сеансов более 30 дней' \gset
SELECT max(total_count) AS q14_mgr FROM api.q_idle_contracts(30, 1) \gset
SELECT coalesce(sum(contracts), 0) AS q12_mgr FROM api.report_new_contracts('2026-07-01', '2026-09-30', 'quarter') \gset
SELECT count(DISTINCT period) AS q12_months FROM api.report_new_contracts('2026-07-01', '2026-09-30', 'month') \gset
SELECT coalesce(sum(contracts), 0) AS q12_foreign FROM api.report_new_contracts('2026-07-01', '2026-09-30', 'quarter', :donnet_id + 1) \gset
SELECT revenue AS q15_month FROM api.report_revenue(date_trunc('month', current_date)::date, current_date) WHERE period IS NULL \gset
SELECT value AS t15_mgr FROM api.home_todo() WHERE caption LIKE 'Выручка за %' \gset
-- «Итого» = сумма периодов по каждой колонке; оплата трафика = выручка − подключения
SELECT bool_and(t.new_contracts = s.nc AND t.volume_mb = s.mb AND t.connection_fees = s.cf
                AND t.traffic_fees = s.tf AND t.revenue = s.rv AND t.revenue = t.connection_fees + t.traffic_fees) AS q15_rollup,
       max(s.n) AS q15_periods
FROM (SELECT * FROM api.report_revenue('2026-01-01', '2026-09-30') WHERE period IS NULL) t,
     (SELECT count(*) AS n, sum(new_contracts) AS nc, sum(volume_mb) AS mb, sum(connection_fees) AS cf,
             sum(traffic_fees) AS tf, sum(revenue) AS rv
      FROM api.report_revenue('2026-01-01', '2026-09-30') WHERE period IS NOT NULL) s \gset
SELECT count(*) AS top_rows, max(revenue) FILTER (WHERE ord = 1) AS top1,
       bool_and(revenue >= coalesce(next_rev, 0)) AS top_sorted
FROM (SELECT ord, revenue, lead(revenue) OVER (ORDER BY ord) AS next_rev
      FROM api.report_top_subscribers('2026-01-01', '2026-09-30', 5)) t \gset
DO $$
BEGIN
    PERFORM pg_temp.try('bad_grain', 'SELECT * FROM api.report_revenue(''2026-01-01'', ''2026-03-31'', ''week'')');
    PERFORM pg_temp.try('bad_period', 'SELECT * FROM api.report_new_contracts(''2026-03-31'', ''2026-01-01'')');
END $$;

-- ============================================================================ главный аналитик
SET SESSION AUTHORIZATION chief_main;
SELECT pg_temp.lr6_rights() AS r_chief \gset
SELECT coalesce(sum(contracts), 0) AS q12_chief FROM api.report_new_contracts('2026-07-01', '2026-09-30', 'quarter', :donnet_id) \gset
SELECT count(*) AS q15_items FROM api.v_revenue_items \gset
SELECT count(*) AS q15_items_union FROM (SELECT * FROM api.v_revenue_items UNION SELECT * FROM api.v_revenue_items) u \gset
-- 22: таблица
SELECT count(*) FILTER (WHERE NOT is_total) AS q17_groups,
       sum(providers) FILTER (WHERE NOT is_total) AS q17_providers,
       sum(contracts) FILTER (WHERE NOT is_total) AS q17_contracts,
       sum(revenue) FILTER (WHERE NOT is_total) AS q17_rev_groups,
       max(revenue) FILTER (WHERE is_total) AS q17_rev_total,
       max(share_pct) FILTER (WHERE is_total) AS q17_share_total,
       sum(share_pct) FILTER (WHERE NOT is_total) AS q17_share_sum,
       max(provider_group) FILTER (WHERE ord = 5) AS q17_other
FROM api.report_provider_shares('2026-01-01', '2026-09-30', 4, NULL) \gset
-- 22: точки диаграммы — те же группы, сумма по точкам = «Итого»
SELECT count(DISTINCT provider_group) AS q17_series, count(DISTINCT period) AS q17_months, sum(revenue) AS q17_rev_points
FROM api.report_provider_shares('2026-01-01', '2026-09-30', 4, 'month') WHERE period IS NOT NULL \gset
-- 22 с отбором «Тип абонента»: выручка «Итого» = отчёт 15 аналитика по всем провайдерам с тем же отбором
SELECT max(revenue) FILTER (WHERE is_total) AS q17_type_total
FROM api.report_provider_shares('2026-01-01', '2026-09-30', 4, NULL, 5) \gset
SELECT revenue AS q15_type_total FROM api.report_revenue('2026-01-01', '2026-09-30', 'month', NULL, 5) WHERE period IS NULL \gset
SELECT value AS t15_chief FROM api.home_todo() WHERE caption LIKE 'Выручка за %' \gset
SELECT revenue AS q15_chief_month FROM api.report_revenue(date_trunc('month', current_date)::date, current_date) WHERE period IS NULL \gset

-- ============================================================================ администратор приложения
SET SESSION AUTHORIZATION adm_main;
SELECT pg_temp.lr6_rights() AS r_adm \gset
SELECT max(users) FILTER (WHERE group_name IS NULL) AS q11_all,
       sum(users) FILTER (WHERE group_name IS NOT NULL) AS q11_sum,
       (array_agg(title ORDER BY ord))[1] AS q11_first
FROM api.v_user_groups g \gset
SELECT max(total_count) AS q11_users FROM api.q_users(p_limit => 1) \gset
SELECT max(total_count) AS q13_total, md5(string_agg(id::text, ',' ORDER BY id)) AS q13_md5,
       bool_and(providers >= 2) AS q13_ge2
FROM (SELECT * FROM api.q_shared_subscribers(p_limit => 200, p_offset => 0)
      UNION ALL SELECT * FROM api.q_shared_subscribers(p_limit => 200, p_offset => 200)
      UNION ALL SELECT * FROM api.q_shared_subscribers(p_limit => 200, p_offset => 400)
      UNION ALL SELECT * FROM api.q_shared_subscribers(p_limit => 200, p_offset => 600)) q \gset
SELECT coalesce(max(total_count), 0) AS q13_three, bool_and(providers >= 3) AS q13_three_ok
FROM api.q_shared_subscribers(3, 200) \gset
SELECT pg_temp.try('q13_bad', 'SELECT * FROM api.q_shared_subscribers(1)');
SELECT max(total_count) AS q16_total, count(*) AS q16_rows FROM api.q_providers(p_without_staff => true, p_limit => 200) \gset
SELECT max(total_count) AS q16_off FROM api.q_providers(p_limit => 1) \gset
SELECT value AS t16_adm FROM api.home_todo() WHERE caption = 'Провайдеры без сотрудников' \gset

-- ============================================================================ администратор БД
SET SESSION AUTHORIZATION dba_main;
SELECT pg_temp.lr6_rights() AS r_dba \gset
SELECT max(users) FILTER (WHERE group_name IS NULL) AS q11_dba_all,
       sum(users) FILTER (WHERE group_name IS NOT NULL) AS q11_dba_sum,
       string_agg(group_name, ',' ORDER BY group_name) AS q11_dba_groups
FROM api.v_user_groups \gset
SELECT max(total_count) AS q11_dba_users FROM api.q_users(p_limit => 1) \gset
RESET SESSION AUTHORIZATION;

-- ============================================================================ проверки
SELECT pg_temp.check('12.1 запрос 11 (ROLLUP): «Все пользователи» первой строкой = сумма групп = total_count списка q_users',
    :q11_all = :q11_sum AND :q11_all = :q11_users AND :'q11_first' = 'Все пользователи'
    AND :q11_dba_all = :q11_dba_sum AND :q11_dba_all = :q11_dba_users AND :'q11_dba_groups' = 'grp_admin,grp_dba',
    format('администратор приложения %s = %s = %s; администратор БД %s = %s = %s (%s)', :q11_all, :q11_sum, :q11_users,
           :q11_dba_all, :q11_dba_sum, :q11_dba_users, :'q11_dba_groups'));
SELECT pg_temp.check('12.2 запрос 12 (WHERE): договоры по типам за квартал = договоры провайдера; аналитик с отбором = руководитель; чужой провайдер — пусто',
    :q12_mgr = :e12_q3 AND :q12_chief = :e12_q3 AND :q12_foreign = 0 AND :q12_months = 3,
    format('руководитель %s, аналитик %s, эталон %s, чужой %s, месяцев %s', :q12_mgr, :q12_chief, :e12_q3, :q12_foreign, :q12_months));
SELECT pg_temp.check('12.3 запрос 13 (HAVING): общие абоненты — те, у кого договоры не меньше чем с двумя провайдерами',
    :q13_total = :e13_total AND :'q13_md5' = :'e13_md5' AND :'q13_ge2' = 't' AND :e13_total > 0,
    format('%s из %s', :q13_total, :e13_total));
SELECT pg_temp.check('12.3а запрос 13: порог — параметр: «не меньше 3 провайдеров» = эталон; порог меньше 2 — понятная ошибка',
    :q13_three = :e13_three AND coalesce(:'q13_three_ok', 't') = 't' AND current_setting('test.q13_bad') LIKE 'P0001 Общий абонент%',
    format('%s из %s; %s', :q13_three, :e13_three, current_setting('test.q13_bad')));
SELECT pg_temp.check('12.4 запрос 13 = правило D25: оператору закрыты для изменения ровно общие абоненты его провайдера',
    :op_locked = :e13_donnet, format('закрыто %s, общих у «ДонНет» %s', :op_locked, :e13_donnet));
SELECT pg_temp.check('12.5 запрос 14 (WHERE + HAVING): список = расчёт через NOT EXISTS, в списке нет свежих договоров и договоров с сеансами после границы',
    :q14_total = :e14_idle AND :q14_rows = least(:e14_idle, 200) AND :q14_wrong = 0,
    format('список %s, эталон %s, лишних %s', :q14_total, :e14_idle, :q14_wrong));
SELECT pg_temp.check('12.6 счётчик «Договоры без сеансов более 30 дней» = список 14 (оператор и руководитель)',
    :t14_op = :q14_total AND :t14_mgr = :q14_mgr AND :q14_mgr = :q14_total,
    format('оператор %s, руководитель %s, список %s', :t14_op, :t14_mgr, :q14_total));
SELECT pg_temp.check('12.7 запрос 15: выручка за месяц = независимый расчёт = счётчик «Выручка за …» (тыс. руб.)',
    :q15_month = :e15_month AND :t15_mgr = round(:q15_month / 1000) AND :t15_chief = round(:q15_chief_month / 1000),
    format('отчёт %s, эталон %s, счётчик %s', :q15_month, :e15_month, :t15_mgr));
SELECT pg_temp.check('12.8 запрос 15 (ROLLUP): «Итого» = сумма периодов по каждой колонке, выручка = подключения + трафик',
    :'q15_rollup' = 't' AND :q15_periods = 9, :q15_periods || ' периодов');
SELECT pg_temp.check('12.9 запрос 20 (UNION ALL): строк столько же, сколько договоров и сеансов (ни одна операция не потеряна)',
    :q15_items = :e15_items AND :q15_items_union <= :q15_items,
    format('UNION ALL %s, эталон %s, UNION %s', :q15_items, :e15_items, :q15_items_union));
SELECT pg_temp.check('12.10 запрос 16 (NOT IN): провайдеры без сотрудников = расчёт через NOT EXISTS = счётчик; без флажка — все',
    :q16_total = :e16_free AND :q16_rows = :e16_free AND :t16_adm = :e16_free AND :q16_off = :providers_all AND :e16_free > 0,
    format('список %s, эталон %s, счётчик %s, без отбора %s', :q16_total, :e16_free, :t16_adm, :q16_off));
SELECT pg_temp.check('12.11 ловушка NOT IN: без «provider_id IS NOT NULL» в подзапросе разность пуста (NULL у администраторов)',
    :e16_null_trap = 0 AND :e16_free > 0, format('без отсечения NULL %s, с отсечением %s', :e16_null_trap, :e16_free));
SELECT pg_temp.check('12.12 запрос 22: 4 провайдера и «Прочие», в группах все провайдеры, договоры = действующие на конец периода',
    :q17_groups = 5 AND :q17_providers = :providers_all AND :q17_contracts = :e17_contracts
    AND :'q17_other' = format('Прочие (%s провайдеров)', :providers_all - 4),
    format('групп %s, провайдеров %s, договоров %s из %s, «%s»', :q17_groups, :q17_providers, :q17_contracts, :e17_contracts, :'q17_other'));
SELECT pg_temp.check('12.13 запрос 22: выручка групп = «Итого», доля «Итого» 100 %, доли после округления — 100 ± 0,3',
    :q17_rev_groups = :q17_rev_total AND :q17_share_total = 100 AND abs(:q17_share_sum - 100) <= 0.3,
    format('сумма долей %s', :q17_share_sum));
SELECT pg_temp.check('12.14 запрос 22: ряды диаграммы — те же 5 групп по 9 месяцам, сумма точек = «Итого»',
    :q17_series = 5 AND :q17_months = 9 AND :q17_rev_points = :q17_rev_total,
    format('рядов %s, месяцев %s', :q17_series, :q17_months));
SELECT pg_temp.check('12.14а запрос 22 с отбором «Тип абонента» (вуз): «Итого» = выручка отчёта 15 с тем же отбором',
    :q17_type_total = :q15_type_total AND :q17_type_total > 0, format('%s и %s', :q17_type_total, :q15_type_total));
SELECT pg_temp.check('12.15 «Крупнейшие абоненты»: первые 5 по убыванию выручки, первый = независимый расчёт по провайдеру',
    :top_rows = 5 AND :'top_sorted' = 't' AND :top1 = :e_top1, format('%s и %s', :top1, :e_top1));
SELECT pg_temp.check('12.16 параметры отчёта: неверная периодичность и перевёрнутый период — понятные ошибки',
    current_setting('test.bad_grain') LIKE 'P0001 Периодичность%' AND current_setting('test.bad_period') LIKE 'P0001 Дата окончания%',
    current_setting('test.bad_grain') || '; ' || current_setting('test.bad_period'));
SELECT pg_temp.check('12.17 права: каждой роли — только запросы её экранов (11, 20, 12, 13, 14, 15, 22, крупнейшие)',
    :'r_op' = '00001000' AND :'r_mgr' = '01101101' AND :'r_chief' = '01100111'
    AND :'r_adm' = '10010000' AND :'r_dba' = '10000000',
    format('оператор %s, руководитель %s, аналитик %s, администратор %s, администратор БД %s',
           :'r_op', :'r_mgr', :'r_chief', :'r_adm', :'r_dba'));

-- 12.18 Период без операций: ROLLUP всё равно даёт строку «Итого» — в ней нули, а не NULL (coalesce у сумм 15).
SET SESSION AUTHORIZATION mgr_donnet;
SELECT count(*) AS q15_empty_rows,
       coalesce(bool_and(period IS NULL AND period_title = 'Итого' AND new_contracts = 0 AND volume_mb = 0
                         AND connection_fees = 0 AND traffic_fees = 0 AND revenue = 0), false) AS q15_empty_ok
FROM api.report_revenue('2030-01-01', '2030-01-31') \gset
RESET SESSION AUTHORIZATION;
SELECT pg_temp.check('12.18 запрос 15 за период без операций: одна строка «Итого» с нулями',
    :q15_empty_rows = 1 AND :'q15_empty_ok' = 't', format('строк %s', :q15_empty_rows));
