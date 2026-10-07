-- Тест 030. Запросы ЛР 5 (db/migrations/060_queries_simple.sql): результат, видимость по ролям, пагинация.
-- Значения из-под проверяемой роли передаются через \gset и test.* (см. 020_whoami.sql).

SELECT id AS donnet_id FROM core.provider WHERE name = 'ДонНет' \gset
SELECT id AS donlink_id FROM core.provider WHERE name = 'ДонЛинк' \gset
-- абоненты «ДонНет» — у кого есть договор с «ДонНет» (реестр общий, D25); всего в реестре и без договоров
SELECT count(*) AS subs_donnet FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = :donnet_id) \gset
SELECT count(*) AS subs_all, count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id)) AS subs_free
FROM core.subscriber s \gset
SELECT count(*) AS today_donnet FROM core.session s JOIN core.contract c ON c.id = s.contract_id
WHERE c.provider_id = :donnet_id AND s.started_at >= current_date \gset
SELECT c.id AS donnet_contract, (SELECT sum(cost) FROM core.session WHERE contract_id = c.id) AS donnet_contract_cost
FROM core.contract c WHERE c.provider_id = :donnet_id
  AND EXISTS (SELECT 1 FROM core.session s WHERE s.contract_id = c.id AND s.started_at >= current_date)
ORDER BY c.id LIMIT 1 \gset
SELECT c.contract_no AS donnet_contract_no FROM core.contract c WHERE c.id = :donnet_contract \gset
-- абонент «ДонНет» и хвост его телефона в том виде, как его набирают: «817-84-16»
SELECT s.id AS phone_sub, right(s.phone, 9) AS phone_tail FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = :donnet_id)
ORDER BY s.id LIMIT 1 \gset

-- Оператор «ДонНет»
SET SESSION AUTHORIZATION op_donnet;
-- две страницы по 200: у провайдера больше 200 абонентов
SELECT max(total_count) AS q8_total, count(*) FILTER (WHERE contracts_total = 0) AS q8_free
FROM (SELECT * FROM api.q_subscribers(p_limit => 200, p_offset => 0)
      UNION ALL SELECT * FROM api.q_subscribers(p_limit => 200, p_offset => 200)) q \gset
SELECT count(*) AS q8_p2_rows, max(total_count) AS q8_p2_total FROM api.q_subscribers(p_limit => 20, p_offset => 20) \gset
SELECT coalesce(max(total_count), 0) AS q3_total FROM api.q_sessions(current_date, current_date) \gset
SELECT coalesce(max(total_cost), 0) AS q2_cost FROM api.q_contract_sessions(:donnet_contract) \gset
SELECT coalesce(max(total_count), 0) AS q4_week FROM api.q_contracts(date_trunc('week', current_date)::date, current_date) \gset
SELECT count(*) AS q5_op FROM api.v_providers \gset
SELECT count(*) AS q_search_pct FROM api.q_subscribers(p_search => '%', p_limit => 200) \gset
SELECT count(*) FILTER (WHERE id = :phone_sub) AS q8_phone_found FROM api.q_subscribers(p_search => :'phone_tail', p_limit => 200) \gset
SELECT count(*) FILTER (WHERE contract_no = :'donnet_contract_no') AS q4_no_found
FROM api.q_contracts(p_search => lower(:'donnet_contract_no')) \gset
DO $$
BEGIN
    PERFORM set_config('test.scope_direct', 'allowed', false);
    BEGIN
        PERFORM sec.provider_scope(true, NULL);
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM set_config('test.scope_direct', 'denied', false);
    END;
END $$;
DO $$
BEGIN
    PERFORM set_config('test.bad_ip', 'accepted', false);
    BEGIN
        PERFORM * FROM api.q_sessions(current_date, current_date, p_ip => '10.0.999.1');
    EXCEPTION WHEN raise_exception THEN
        PERFORM set_config('test.bad_ip', SQLERRM, false);
    END;
END $$;

-- Оператор другого провайдера не видит сеансы договора «ДонНет»
SET SESSION AUTHORIZATION op_donlink;
SELECT count(*) AS q2_foreign FROM api.q_contract_sessions(:donnet_contract) \gset

-- Руководитель
SET SESSION AUTHORIZATION mgr_donnet;
SELECT count(*) AS q9_rows, count(*) FILTER (WHERE sessions_count = 0) AS q9_unused
FROM api.q_tariff_usage(date_trunc('month', current_date)::date, current_date) \gset

SELECT count(*) AS q1_mgr_own FROM api.q_provider_staff(:donnet_id) \gset
SELECT count(*) AS q1_mgr_foreign FROM api.q_provider_staff(:donlink_id) \gset
SELECT max(total_count) AS q10_mgr FROM api.q_providers() \gset

-- Главный аналитик
SET SESSION AUTHORIZATION chief_main;
SELECT count(*) AS q5_chief FROM api.v_providers \gset
SELECT max(total_count) AS q8_chief_total FROM api.q_subscribers(p_limit => 1) \gset
SELECT max(total_count) AS q8_chief_donnet FROM api.q_subscribers(p_provider_id => :donnet_id, p_limit => 1) \gset
SELECT max(total_count) AS q3_chief_filtered FROM api.q_sessions(current_date, current_date, p_provider_id => :donnet_id) \gset

-- Администратор
SET SESSION AUTHORIZATION adm_main;
SELECT count(*) AS q1_rows, string_agg(group_title, ',' ORDER BY group_title) AS q1_groups
FROM api.q_provider_staff(:donnet_id) \gset
SELECT max(total_count) AS q10_total, count(*) FILTER (WHERE contracts_active = 0) AS q10_zero
FROM api.q_providers(p_limit => 200) \gset
DO $$
BEGIN
    PERFORM set_config('test.admin_sessions', 'allowed', false);
    BEGIN
        PERFORM * FROM api.q_sessions(current_date, current_date);
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM set_config('test.admin_sessions', 'denied', false);
    END;
END $$;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.check('7.1 запрос 8: оператор видит абонентов, у которых есть договор с его провайдером (D25)',
    :q8_total = :subs_donnet AND :q8_free = 0,
    format('абонентов %s из %s, без договоров %s', :q8_total, :subs_donnet, :q8_free));
SELECT pg_temp.check('7.1а запрос 8 (левое соединение): аналитик видит весь реестр, включая абонентов без договоров; с отбором по провайдеру — как оператор',
    :q8_chief_total = :subs_all AND :subs_free > 0 AND :q8_chief_donnet = :subs_donnet,
    format('всего %s из %s (без договоров %s), по «ДонНет» %s из %s', :q8_chief_total, :subs_all, :subs_free,
           :q8_chief_donnet, :subs_donnet));
SELECT pg_temp.check('7.2 пагинация: вторая страница — 20 строк, total_count не меняется',
    :q8_p2_rows = 20 AND :q8_p2_total = :q8_total);
SELECT pg_temp.check('7.3 запрос 3 (по датам): журнал за сегодня совпадает с данными провайдера',
    :q3_total = :today_donnet AND :today_donnet > 0, format('%s из %s', :q3_total, :today_donnet));
SELECT pg_temp.check('7.4 запрос 2 (по внешнему ключу): итог стоимости сеансов договора совпадает с суммой',
    :q2_cost = :donnet_contract_cost, format('%s и %s', :q2_cost, :donnet_contract_cost));
SELECT pg_temp.check('7.5 запрос 2: оператор другого провайдера не видит сеансы чужого договора', :q2_foreign = 0);
SELECT pg_temp.check('7.6 запрос 4 (по датам): договоры этой недели найдены', :q4_week >= 2, :q4_week || ' шт.');
SELECT pg_temp.check('7.7 запрос 5: оператор видит только своего провайдера, аналитик — всех',
    :q5_op = 1 AND :q5_chief = (SELECT count(*) FROM core.provider), format('%s и %s', :q5_op, :q5_chief));
SELECT pg_temp.check('7.8 запрос 9 (правое соединение): все 10 тарифов, включая неиспользованные',
    :q9_rows = (SELECT count(*) FROM ref.tariff) AND :q9_unused >= 1, format('тарифов %s, без сеансов %s', :q9_rows, :q9_unused));
SELECT pg_temp.check('7.9 запрос 10 (запрос на запросе): все провайдеры, включая провайдера без договоров',
    :q10_total = (SELECT count(*) FROM core.provider) AND :q10_zero >= 1, format('провайдеров %s, без договоров %s', :q10_total, :q10_zero));
SELECT pg_temp.check('7.10 запрос 1: сотрудники провайдера с группами из pg_auth_members',
    :q1_rows = 3 AND :'q1_groups' = 'Операторы,Операторы,Руководители', :'q1_groups');
SELECT pg_temp.check('7.11 аналитик с отбором по провайдеру получает те же сеансы, что оператор этого провайдера',
    :q3_chief_filtered = :q3_total);
SELECT pg_temp.check('7.12 администратору журнал сеансов недоступен', current_setting('test.admin_sessions') = 'denied');
SELECT pg_temp.check('7.13 неверный IP в отборе — понятная ошибка', current_setting('test.bad_ip') LIKE 'Неверный IP-адрес%',
    current_setting('test.bad_ip'));
SELECT pg_temp.check('7.14 символ «%» в поиске экранируется и не выбирает всех', :q_search_pct = 0, :q_search_pct || ' строк');
SELECT pg_temp.check('7.15 руководитель видит сотрудников и карточку только своего провайдера',
    :q1_mgr_own = 3 AND :q1_mgr_foreign = 0 AND :q10_mgr = 1,
    format('свои %s, чужие %s, провайдеров %s', :q1_mgr_own, :q1_mgr_foreign, :q10_mgr));
SELECT pg_temp.check('7.16 поиск абонента по цифрам телефона в любом написании («817-84-16»)', :q8_phone_found = 1,
    :'phone_tail');
SELECT pg_temp.check('7.17 поиск договора по номеру без учёта регистра', :q4_no_found = 1, lower(:'donnet_contract_no'));
SELECT pg_temp.check('7.18 оператор не может вызвать внутреннюю sec.provider_scope и получить всех провайдеров',
    current_setting('test.scope_direct') = 'denied');
