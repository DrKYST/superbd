-- Тест 090. Запросы ТЗ курсового проекта 17–23 (db/migrations/062_queries_coursework.sql; 20 и 22 — в 061, D31):
-- результат совпадает с независимым расчётом суперпользователя, права — по ролям.
-- Как в 060: проверки от имени пользователя (SET SESSION AUTHORIZATION), значения — через \gset и test.*.

-- Выполнить оператор от имени текущего пользователя и записать в test.<p_key> 'ok' или код ошибки (как в 050, 060).
CREATE OR REPLACE FUNCTION pg_temp.try(p_key text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    PERFORM set_config('test.' || p_key, 'ok', false);
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('test.' || p_key, SQLSTATE || ' ' || SQLERRM, false);
END $$;

-- Какие запросы 17–23 доступны текущему пользователю: строка из 1 (выполнен), 0 (отказ 42501), x (другая ошибка).
-- Порядок: 17 v_subscriber_type_totals, 18, 19 (договор p_contract), 20 v_revenue_items, 21, 22, 23.
CREATE OR REPLACE FUNCTION pg_temp.cw_rights(p_contract integer)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_sql text;
    v_res text := '';
BEGIN
    FOREACH v_sql IN ARRAY ARRAY[
        'SELECT * FROM api.v_subscriber_type_totals',
        'SELECT * FROM api.q_subscriber_traffic(''*'', current_date - 30, current_date)',
        format('SELECT * FROM api.report_contract_months(%s, current_date - 30, current_date)', p_contract),
        'SELECT * FROM api.v_revenue_items LIMIT 1',
        'SELECT * FROM api.q_tariff_subscribers(1, current_date - 30, current_date)',
        'SELECT * FROM api.report_provider_shares(current_date - 30, current_date)',
        'SELECT * FROM api.q_subscribers_above_avg(current_date - 30, current_date)']
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
SELECT id AS edu_tariff FROM ref.tariff WHERE name = 'Образовательный' \gset

-- 17: строки «Всего», «в том числе …» и типов — подпись, абонентов, договоров, действующих — в порядке сводки.
-- p_provider — NULL (весь реестр, все договоры) или провайдер (абоненты с его договором, только его договоры).
CREATE OR REPLACE FUNCTION pg_temp.e17(p_provider integer)
RETURNS text LANGUAGE sql AS $$
    WITH per_sub AS (
        SELECT s.id, st.id AS tid, st.name, st.is_legal,
               count(c.id) AS n, count(c.id) FILTER (WHERE c.closed_on IS NULL) AS a
        FROM core.subscriber s
        JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
        LEFT JOIN core.contract c ON c.subscriber_id = s.id AND (p_provider IS NULL OR c.provider_id = p_provider)
        GROUP BY s.id, st.id
        HAVING p_provider IS NULL OR count(c.id) > 0),
    r AS (
        SELECT 'Всего'::text AS title, count(*) AS subs, sum(n) AS n, sum(a) AS a, 0 AS o1, 0 AS o2, 0 AS o3 FROM per_sub
        UNION ALL
        SELECT CASE WHEN is_legal THEN 'в том числе юридические лица' ELSE 'в том числе физические лица' END,
               count(*), sum(n), sum(a), 1, CASE WHEN is_legal THEN 0 ELSE 1 END, 0
        FROM per_sub GROUP BY is_legal
        UNION ALL
        SELECT name, count(*), sum(n), sum(a), 1, CASE WHEN is_legal THEN 0 ELSE 1 END, tid
        FROM per_sub GROUP BY is_legal, name, tid)
    SELECT string_agg(concat_ws(':', title, subs, n, a), '; ' ORDER BY o1, o2, o3) FROM r
$$;
SELECT pg_temp.e17(NULL) AS e17_chief, pg_temp.e17(:donnet_id) AS e17_mgr \gset
SELECT count(*) AS e17_mgr_contracts FROM core.contract WHERE provider_id = :donnet_id \gset

-- 18: абоненты «ДонНет» с наименованием, содержащим «школа», — сеансы за январь–сентябрь 2026
SELECT count(DISTINCT s.id) AS e18_subs, count(*) AS e18_sessions, sum(se.volume_mb) AS e18_mb, sum(se.cost) AS e18_cost,
       md5(string_agg(DISTINCT s.id::text, ',' ORDER BY s.id::text)) AS e18_md5
FROM core.subscriber s
JOIN core.contract c ON c.subscriber_id = s.id AND c.provider_id = :donnet_id
JOIN core.session se ON se.contract_id = c.id AND se.provider_id = c.provider_id
WHERE lower(s.name) LIKE '%школа%' AND se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01' \gset
-- «?» — один символ: маска — наименование первой такой школы, последний символ заменён на «?» («Школа № 1?»)
SELECT left(min(s.name), -1) || '?' AS q18_mask, lower(left(min(s.name), -1)) || '_' AS e18_like
FROM core.subscriber s
WHERE lower(s.name) LIKE '%школа%'
  AND EXISTS (SELECT 1 FROM core.contract c JOIN core.session se ON se.contract_id = c.id AND se.provider_id = c.provider_id
              WHERE c.subscriber_id = s.id AND c.provider_id = :donnet_id
                AND se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01') \gset
SELECT count(DISTINCT s.id) AS e18_one_char
FROM core.subscriber s
JOIN core.contract c ON c.subscriber_id = s.id AND c.provider_id = :donnet_id
JOIN core.session se ON se.contract_id = c.id AND se.provider_id = c.provider_id
WHERE lower(s.name) LIKE :'e18_like' AND se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01' \gset
-- «*» — все абоненты «ДонНет» с сеансами в периоде
SELECT count(DISTINCT c.subscriber_id) AS e18_all
FROM core.contract c JOIN core.session se ON se.contract_id = c.id AND se.provider_id = c.provider_id
WHERE c.provider_id = :donnet_id AND se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01' \gset

-- 19: договор «ДонНет» с сеансами в каждом месяце января–сентября 2026 (первый по коду)
SELECT c.id AS c19
FROM core.contract c JOIN core.session se ON se.contract_id = c.id AND se.provider_id = c.provider_id
WHERE c.provider_id = :donnet_id AND se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01'
GROUP BY c.id HAVING count(DISTINCT date_trunc('month', se.started_at)) = 9
ORDER BY c.id LIMIT 1 \gset

-- 21: абоненты с сеансами по «Образовательному» за январь–сентябрь 2026 — через EXISTS (у «ДонНет» и у всех)
SELECT count(*) AS e21_mgr, md5(string_agg(s.id::text, ',' ORDER BY s.id)) AS e21_mgr_md5
FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM core.session se JOIN core.contract c ON c.id = se.contract_id AND c.provider_id = se.provider_id
              WHERE c.subscriber_id = s.id AND c.provider_id = :donnet_id AND se.tariff_id = :edu_tariff
                AND se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01') \gset
SELECT count(*) AS e21_all
FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM core.session se JOIN core.contract c ON c.id = se.contract_id AND c.provider_id = se.provider_id
              WHERE c.subscriber_id = s.id AND se.tariff_id = :edu_tariff
                AND se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01') \gset
-- договоры этих абонентов у «ДонНет»
SELECT count(*) AS e21_mgr_contracts
FROM core.contract c
WHERE c.provider_id = :donnet_id
  AND EXISTS (SELECT 1 FROM core.session se JOIN core.contract x ON x.id = se.contract_id AND x.provider_id = se.provider_id
              WHERE x.subscriber_id = c.subscriber_id AND x.provider_id = :donnet_id AND se.tariff_id = :edu_tariff
                AND se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01') \gset

-- 23: трафик абонентов «ДонНет» за III квартал 2026, среднее итогов и абоненты выше среднего
CREATE TEMP TABLE e23 AS
SELECT c.subscriber_id, sum(se.volume_mb) AS mb
FROM core.session se JOIN core.contract c ON c.id = se.contract_id AND c.provider_id = se.provider_id
WHERE c.provider_id = :donnet_id AND se.started_at >= '2026-07-01' AND se.started_at < '2026-10-01'
GROUP BY c.subscriber_id;
SELECT avg(mb) AS e23_avg FROM e23 \gset
SELECT count(*) AS e23_above, md5(string_agg(subscriber_id::text, ',' ORDER BY subscriber_id)) AS e23_md5
FROM e23 WHERE mb > :e23_avg \gset

-- ============================================================================ оператор
SET SESSION AUTHORIZATION op_donnet;
SELECT pg_temp.cw_rights(:c19) AS r_op \gset
-- 19: месяцы и «Итого»; те же итоги у запроса 2 по тому же договору и периоду
SELECT count(*) FILTER (WHERE period IS NOT NULL) AS q19_months,
       max(sessions) FILTER (WHERE period IS NULL) AS q19_sessions,
       max(volume_mb) FILTER (WHERE period IS NULL) AS q19_mb,
       max(cost) FILTER (WHERE period IS NULL) AS q19_cost,
       bool_and(full_cost = discount + cost) AS q19_parts,
       sum(sessions) FILTER (WHERE period IS NOT NULL) = max(sessions) FILTER (WHERE period IS NULL)
       AND sum(cost) FILTER (WHERE period IS NOT NULL) = max(cost) FILTER (WHERE period IS NULL) AS q19_rollup,
       md5(string_agg(concat_ws(':', period_title, sessions, volume_mb, full_cost, discount, cost), ';'
                      ORDER BY period NULLS LAST)) AS q19_md5
FROM api.report_contract_months(:c19, '2026-01-01', '2026-09-30') \gset
SELECT max(total_count) AS q2_count, max(total_volume_mb) AS q2_mb, max(total_cost) AS q2_cost
FROM api.q_contract_sessions(:c19, '2026-01-01', '2026-09-30', 1) \gset
-- тот же вызов без индексного доступа (план «без использования индекса»): результат тот же
BEGIN;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;
SELECT md5(string_agg(concat_ws(':', period_title, sessions, volume_mb, full_cost, discount, cost), ';'
                      ORDER BY period NULLS LAST)) AS q19_noindex_md5
FROM api.report_contract_months(:c19, '2026-01-01', '2026-09-30') \gset
ROLLBACK;
DO $$
BEGIN
    PERFORM pg_temp.try('q19_null', 'SELECT * FROM api.report_contract_months(NULL, ''2026-01-01'', ''2026-09-30'')');
END $$;

-- 19: оператор другого провайдера — как в запросе 2: сеансов чужого договора не видно, строки «Итого» нет
SET SESSION AUTHORIZATION op_donlink;
SELECT count(*) AS q19_foreign FROM api.report_contract_months(:c19, '2026-01-01', '2026-09-30') \gset
SELECT count(*) AS q2_foreign FROM api.q_contract_sessions(:c19, '2026-01-01', '2026-09-30') \gset

-- ============================================================================ руководитель
SET SESSION AUTHORIZATION mgr_donnet;
SELECT pg_temp.cw_rights(:c19) AS r_mgr \gset
-- 17
SELECT string_agg(concat_ws(':', title, subscribers, contracts, contracts_active), '; ' ORDER BY sort_order) AS q17_mgr,
       max(contracts) FILTER (WHERE level = 0) AS q17_mgr_contracts,
       (array_agg(title ORDER BY sort_order))[1] AS q17_first
FROM api.v_subscriber_type_totals \gset
-- 17: «всего = в том числе = сумма типов» внутри сводки, действующих не больше, чем всего
SELECT bool_and(t.ok) AS q17_sums
FROM (SELECT max(subscribers) FILTER (WHERE level = 0) = sum(subscribers) FILTER (WHERE level = 1)
             AND sum(subscribers) FILTER (WHERE level = 1) = sum(subscribers) FILTER (WHERE level = 2)
             AND max(contracts) FILTER (WHERE level = 0) = sum(contracts) FILTER (WHERE level = 1)
             AND sum(contracts) FILTER (WHERE level = 1) = sum(contracts) FILTER (WHERE level = 2)
             AND max(contracts_active) FILTER (WHERE level = 0) = sum(contracts_active) FILTER (WHERE level = 2)
             AND bool_and(contracts_active <= contracts) AS ok
      FROM api.v_subscriber_type_totals) t \gset
-- 17: у каждой строки «в том числе» — сумма типов под ней (до следующей строки «в том числе»)
SELECT bool_and(g.subs = g.type_subs AND g.n = g.type_n AND g.a = g.type_a) AS q17_groups
FROM (SELECT grp, max(subscribers) FILTER (WHERE level = 1) AS subs, sum(subscribers) FILTER (WHERE level = 2) AS type_subs,
             max(contracts) FILTER (WHERE level = 1) AS n, sum(contracts) FILTER (WHERE level = 2) AS type_n,
             max(contracts_active) FILTER (WHERE level = 1) AS a, sum(contracts_active) FILTER (WHERE level = 2) AS type_a
      FROM (SELECT v.*, count(*) FILTER (WHERE level = 1) OVER (ORDER BY sort_order) AS grp
            FROM api.v_subscriber_type_totals v) x
      WHERE level > 0
      GROUP BY grp) g \gset
-- 18
SELECT max(total_count) AS q18_subs, max(total_sessions) AS q18_sessions, max(total_volume_mb) AS q18_mb,
       max(total_cost) AS q18_cost, md5(string_agg(id::text, ',' ORDER BY id::text)) AS q18_md5,
       sum(sessions) = max(total_sessions) AND sum(volume_mb) = max(total_volume_mb) AS q18_window
FROM api.q_subscriber_traffic('*школа*', '2026-01-01', '2026-09-30', p_limit => 200) \gset
SELECT count(*) AS q18_upper FROM api.q_subscriber_traffic('*ШКОЛА*', '2026-01-01', '2026-09-30', p_limit => 200) \gset
SELECT count(*) AS q18_one_char FROM api.q_subscriber_traffic(:'q18_mask', '2026-01-01', '2026-09-30', p_limit => 200) \gset
SELECT max(total_count) AS q18_all FROM api.q_subscriber_traffic('*', '2026-01-01', '2026-09-30', p_limit => 1) \gset
SELECT count(*) AS q18_pct FROM api.q_subscriber_traffic('%', '2026-01-01', '2026-09-30', p_limit => 200) \gset
SELECT count(*) AS q18_pct_school FROM api.q_subscriber_traffic('%школа%', '2026-01-01', '2026-09-30', p_limit => 200) \gset
DO $$
BEGIN
    PERFORM pg_temp.try('q18_empty', 'SELECT * FROM api.q_subscriber_traffic(''  '', ''2026-01-01'', ''2026-09-30'')');
    PERFORM pg_temp.try('q18_null', 'SELECT * FROM api.q_subscriber_traffic(NULL, ''2026-01-01'', ''2026-09-30'')');
END $$;
-- 21
SELECT max(total_count) AS q21_mgr, count(*) AS q21_rows, count(DISTINCT id) AS q21_distinct,
       md5(string_agg(id::text, ',' ORDER BY id)) AS q21_mgr_md5, sum(contracts) AS q21_mgr_contracts
FROM api.q_tariff_subscribers(:edu_tariff, '2026-01-01', '2026-09-30', p_limit => 200) \gset
-- 23
SELECT max(total_count) AS q23_above, count(*) AS q23_rows, md5(string_agg(id::text, ',' ORDER BY id)) AS q23_md5,
       bool_and(volume_mb > :e23_avg) AS q23_all_above,
       bool_and(avg_mb = round(:e23_avg, 3)) AS q23_avg_ok,
       bool_and(above_pct = round((volume_mb / :e23_avg - 1) * 100, 1)) AS q23_pct_ok
FROM api.q_subscribers_above_avg('2026-07-01', '2026-09-30', p_limit => 200) \gset

-- ============================================================================ главный аналитик
SET SESSION AUTHORIZATION chief_main;
SELECT pg_temp.cw_rights(:c19) AS r_chief \gset
SELECT string_agg(concat_ws(':', title, subscribers, contracts, contracts_active), '; ' ORDER BY sort_order) AS q17_chief
FROM api.v_subscriber_type_totals \gset
-- 21 у всех провайдеров: абоненты не повторяются (все страницы), «Образовательный» — только у учебных заведений
SELECT max(total_count) AS q21_all, count(*) AS q21_all_rows, count(DISTINCT id) AS q21_all_distinct,
       bool_and(subscriber_type IN ('Школа', 'Колледж', 'Вуз')) AS q21_edu_only
FROM (SELECT * FROM api.q_tariff_subscribers(:edu_tariff, '2026-01-01', '2026-09-30', p_limit => 200, p_offset => 0)
      UNION ALL SELECT * FROM api.q_tariff_subscribers(:edu_tariff, '2026-01-01', '2026-09-30', p_limit => 200, p_offset => 200)
      UNION ALL SELECT * FROM api.q_tariff_subscribers(:edu_tariff, '2026-01-01', '2026-09-30', p_limit => 200, p_offset => 400)
      UNION ALL SELECT * FROM api.q_tariff_subscribers(:edu_tariff, '2026-01-01', '2026-09-30', p_limit => 200, p_offset => 600)) q \gset
-- аналитик с отбором «ДонНет» = руководитель «ДонНет»
SELECT max(total_count) AS q23_chief_donnet FROM api.q_subscribers_above_avg('2026-07-01', '2026-09-30', :donnet_id, 1) \gset
SELECT max(total_count) AS q18_chief_donnet FROM api.q_subscriber_traffic('*школа*', '2026-01-01', '2026-09-30', :donnet_id, 1) \gset

-- ============================================================================ администраторы
SET SESSION AUTHORIZATION adm_main;
SELECT pg_temp.cw_rights(:c19) AS r_adm \gset
SET SESSION AUTHORIZATION dba_main;
SELECT pg_temp.cw_rights(:c19) AS r_dba \gset
RESET SESSION AUTHORIZATION;

-- ============================================================================ проверки
SELECT pg_temp.check('14.1 запрос 17 (ROLLUP): сводка по типам = независимый расчёт (руководитель — свой провайдер, аналитик — весь реестр)',
    :'q17_mgr' = :'e17_mgr' AND :'q17_chief' = :'e17_chief' AND :'q17_first' = 'Всего',
    left(:'q17_mgr', 120) || '…');
SELECT pg_temp.check('14.2 запрос 17: сумма по типам = строка «в том числе …», сумма «в том числе» = «Всего», действующих не больше, чем всего',
    :'q17_sums' = 't' AND :'q17_groups' = 't');
SELECT pg_temp.check('14.3 запрос 17: у руководителя «Всего» договоров = договоры его провайдера',
    :q17_mgr_contracts = :e17_mgr_contracts, format('%s и %s', :q17_mgr_contracts, :e17_mgr_contracts));
SELECT pg_temp.check('14.4 запрос 18: маска «*школа*» = независимый LIKE ''%школа%'' (абоненты, сеансы, Мб, сумма), регистр не важен; итоги — по отбору',
    :q18_subs = :e18_subs AND :q18_sessions = :e18_sessions AND :q18_mb = :e18_mb AND :q18_cost = :e18_cost
    AND :'q18_md5' = :'e18_md5' AND :q18_upper = :e18_subs AND :'q18_window' = 't' AND :q18_chief_donnet = :e18_subs AND :e18_subs > 0,
    format('абонентов %s, сеансов %s, Мб %s', :q18_subs, :q18_sessions, :q18_mb));
SELECT pg_temp.check('14.5 запрос 18: «?» — один символ, «*» — любые; введённый «%» — обычный символ, а не «всё подряд»',
    :q18_one_char = :e18_one_char AND :q18_all = :e18_all AND :q18_pct = 0 AND :q18_pct_school = 0 AND :e18_one_char > 0,
    format('«%s» %s из %s, «*» %s из %s, «%%» %s', :'q18_mask', :q18_one_char, :e18_one_char, :q18_all, :e18_all, :q18_pct));
SELECT pg_temp.check('14.6 запрос 18: пустая маска — понятная ошибка',
    current_setting('test.q18_empty') LIKE 'P0001 Укажите маску%' AND current_setting('test.q18_null') LIKE 'P0001 Укажите маску%',
    current_setting('test.q18_empty'));
SELECT pg_temp.check('14.7 запрос 19 (ROLLUP): 9 месяцев, «Итого» = итоги запроса 2 по тому же договору и периоду, без скидки = скидка + к оплате',
    :q19_months = 9 AND :q19_sessions = :q2_count AND :q19_mb = :q2_mb AND :q19_cost = :q2_cost
    AND :'q19_rollup' = 't' AND :'q19_parts' = 't',
    format('договор %s: сеансов %s и %s, сумма %s и %s', :c19, :q19_sessions, :q2_count, :q19_cost, :q2_cost));
SELECT pg_temp.check('14.8 запрос 19 без индексного доступа (enable_indexscan, enable_bitmapscan = off): результат тот же',
    :'q19_md5' = :'q19_noindex_md5');
SELECT pg_temp.check('14.9 запрос 19: чужой договор — пусто, как в запросе 2; договор не выбран — понятная ошибка',
    :q19_foreign = 0 AND :q2_foreign = 0 AND current_setting('test.q19_null') LIKE 'P0001 Выберите договор%',
    format('строк %s; %s', :q19_foreign, current_setting('test.q19_null')));
SELECT pg_temp.check('14.10 запрос 21 (IN): абоненты с сеансами по тарифу = расчёт через EXISTS, абоненты не повторяются',
    :q21_mgr = :e21_mgr AND :'q21_mgr_md5' = :'e21_mgr_md5' AND :q21_rows = :q21_distinct
    AND :q21_mgr_contracts = :e21_mgr_contracts
    AND :q21_all = :e21_all AND :q21_all_rows = :e21_all AND :q21_all_rows = :q21_all_distinct AND :e21_mgr > 0,
    format('руководитель %s из %s, аналитик %s из %s (различных %s)', :q21_mgr, :e21_mgr, :q21_all, :e21_all, :q21_all_distinct));
SELECT pg_temp.check('14.11 запрос 21: «Образовательный» — только у школ, колледжей и вузов (генератор, seed 020)',
    :'q21_edu_only' = 't');
SELECT pg_temp.check('14.12 запрос 23 (подзапрос над итогами): все строки выше среднего, ни один такой абонент не пропущен, процент сходится',
    :q23_above = :e23_above AND :q23_rows = :e23_above AND :'q23_md5' = :'e23_md5' AND :'q23_all_above' = 't'
    AND :'q23_avg_ok' = 't' AND :'q23_pct_ok' = 't' AND :q23_chief_donnet = :e23_above AND :e23_above > 0,
    format('выше среднего %s из %s, среднее %s', :q23_above, :e23_above, round(:e23_avg, 3)));
SELECT pg_temp.check('14.13 права: каждой роли — только свои запросы 17–23 (оператор — 19; руководитель — все, кроме 22; аналитик — все)',
    :'r_op' = '0010000' AND :'r_mgr' = '1111101' AND :'r_chief' = '1111111'
    AND :'r_adm' = '0000000' AND :'r_dba' = '0000000',
    format('оператор %s, руководитель %s, аналитик %s, администратор %s, администратор БД %s',
           :'r_op', :'r_mgr', :'r_chief', :'r_adm', :'r_dba'));

-- 14.14 Вид запроса — по тексту объекта: у каждого запроса ТЗ (и NOT IN из ЛР 6) есть конструкция своего вида.
SELECT coalesce(string_agg(k.no, ', ' ORDER BY k.ord) FILTER (WHERE k.ok IS NOT TRUE), '') AS kinds_bad   -- \gset: NULL снял бы переменную
FROM (VALUES
    (1, '17 итоговый без условия, «всего / в том числе» — представление с GROUP BY ROLLUP',
     lower(pg_get_viewdef('api.v_subscriber_type_totals'::regclass)) LIKE '%group by rollup(%'),
    (2, '18 итоговый с условием на данные по маске — GROUP BY и LIKE по шаблону маски',
     (SELECT p.prosrc LIKE '%GROUP BY%' AND p.prosrc LIKE '%LIKE v_like%' AND p.prosrc LIKE '%sec.like_mask(p_mask)%'
      FROM pg_proc p WHERE p.oid = 'api.q_subscriber_traffic'::regproc)),
    (3, '19 итоговый с условием на данные (договор, период) — ROLLUP по месяцам',
     (SELECT p.prosrc LIKE '%GROUP BY ROLLUP%' AND p.prosrc LIKE '%se.contract_id = p_contract_id%'
      FROM pg_proc p WHERE p.oid = 'api.report_contract_months'::regproc)),
    (4, '20 объединение — UNION ALL',
     lower(pg_get_viewdef('api.v_revenue_items'::regclass)) LIKE '%union all%'),
    (5, '21 подзапрос с IN',
     (SELECT p.prosrc LIKE '%s.id IN (SELECT%' FROM pg_proc p WHERE p.oid = 'api.q_tariff_subscribers'::regproc)),
    (6, '16 подзапрос с NOT IN',
     (SELECT p.prosrc LIKE '%NOT IN (SELECT%' FROM pg_proc p WHERE p.oid = 'api.q_providers'::regproc)),
    (7, '22 подзапрос с CASE — CASE над местом провайдера из подзапроса x',
     (SELECT p.prosrc LIKE '%WITH x AS%' AND p.prosrc LIKE '%WHEN x.grp <= v_top%'
      FROM pg_proc p WHERE p.oid = 'api.report_provider_shares'::regproc)),
    (8, '23 подзапрос с операциями над итоговыми данными — сравнение с avg() итогов sum()',
     (SELECT p.prosrc LIKE '%sum(se.volume_mb)%' AND p.prosrc LIKE '%> (SELECT avg(%'
      FROM pg_proc p WHERE p.oid = 'api.q_subscribers_above_avg'::regproc))
) AS k(ord, no, ok) \gset
SELECT pg_temp.check('14.14 вид каждого запроса 17–23 (и 16) виден в его тексте: ROLLUP, LIKE по маске, UNION ALL, IN, NOT IN, CASE, avg над sum',
    :'kinds_bad' = '', CASE WHEN :'kinds_bad' = '' THEN 'все на месте' ELSE 'нет: ' || :'kinds_bad' END);
