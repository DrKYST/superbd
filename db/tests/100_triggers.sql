-- Тест 100. Триггеры бизнес-правил и журнала изменений (migrations/080; requirements.md, разделы 5 и 10: T7, T8).
-- Изменяющие проверки — в транзакциях с ROLLBACK, результат снимается через \gset до отката.

-- Код и текст ошибки оператора ('ok' — без ошибки).
CREATE OR REPLACE FUNCTION pg_temp.try_msg(p_sql text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- ============================================================================ 15.1 шесть типов событий
DO $$
DECLARE
    v_kinds text;
    v_tables int;
BEGIN
    WITH t AS (
        SELECT t.tgrelid::regclass::text AS tbl, t.tgname,
               CASE WHEN t.tgtype & 2 <> 0 THEN 'BEFORE' WHEN t.tgtype & 64 <> 0 THEN 'INSTEAD OF' ELSE 'AFTER' END AS timing,
               t.tgtype
        FROM pg_catalog.pg_trigger t
        JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('core', 'ref', 'sec') AND NOT t.tgisinternal AND t.tgparentid = 0),
    k AS (
        SELECT tbl, timing || ' ' || e.event AS kind
        FROM t CROSS JOIN LATERAL (VALUES (4, 'INSERT'), (16, 'UPDATE'), (8, 'DELETE')) AS e(bit, event)
        WHERE t.tgtype & e.bit <> 0 AND timing <> 'INSTEAD OF')
    SELECT string_agg(DISTINCT kind, ', ' ORDER BY kind), count(DISTINCT tbl) INTO v_kinds, v_tables FROM k;
    PERFORM pg_temp.check('15.1 триггеры на все шесть типов событий (BEFORE/AFTER × INSERT/UPDATE/DELETE), не меньше чем на двух таблицах',
        v_kinds = 'AFTER DELETE, AFTER INSERT, AFTER UPDATE, BEFORE DELETE, BEFORE INSERT, BEFORE UPDATE' AND v_tables >= 2,
        format('%s; таблиц %s', v_kinds, v_tables));
END $$;

-- ============================================================================ данные для проверок
SELECT id AS p_donnet FROM core.provider WHERE name = 'ДонНет' \gset
-- действующий договор «ДонНет», заключённый до 2025 года
SELECT c.id AS k_id, c.provider_id AS k_prov, c.price_per_mb AS k_price, c.connected_on AS k_from, c.row_version AS k_ver,
       c.contract_no AS k_no
FROM core.contract c
WHERE c.provider_id = :p_donnet AND c.closed_on IS NULL AND c.connected_on < date '2025-01-01'
ORDER BY c.id LIMIT 1 \gset
-- расторгнутый договор с сеансами в разные дни
SELECT c.id AS r_id, c.provider_id AS r_prov, c.closed_on AS r_closed, c.connected_on AS r_from
FROM core.contract c
WHERE c.closed_on IS NOT NULL AND c.closed_on > c.connected_on + 30
  AND (SELECT count(DISTINCT (s.started_at AT TIME ZONE 'Europe/Moscow')::date) FROM core.session s
       WHERE s.contract_id = c.id AND s.provider_id = c.provider_id) >= 2
ORDER BY c.id LIMIT 1 \gset
SELECT max(s.started_at AT TIME ZONE 'Europe/Moscow')::date AS r_last FROM core.session s
WHERE s.contract_id = :r_id AND s.provider_id = :r_prov \gset
SELECT id AS t_edu FROM ref.tariff WHERE name = 'Образовательный' \gset
SELECT id AS t_night FROM ref.tariff WHERE name = 'Ночной' \gset

-- ============================================================================ 15.2–15.6 сеанс (T8)
BEGIN;
-- период действия договора и время
SELECT pg_temp.try_msg(format($q$INSERT INTO core.session (started_at, contract_id, provider_id, volume_mb)
                                VALUES (%L::date - 1, %s, %s, 10)$q$, :'k_from', :k_id, :k_prov)) AS e_before \gset
SELECT pg_temp.try_msg(format($q$INSERT INTO core.session (started_at, contract_id, provider_id, volume_mb)
                                VALUES (now() + interval '1 hour', %s, %s, 10)$q$, :k_id, :k_prov)) AS e_future \gset
SELECT pg_temp.try_msg(format($q$INSERT INTO core.session (started_at, contract_id, provider_id, volume_mb)
                                VALUES ((%L::date + 1)::timestamp AT TIME ZONE 'Europe/Moscow' + interval '10 hours', %s, %s, 10)$q$,
                              :'r_closed', :r_id, :r_prov)) AS e_after_close \gset
SELECT pg_temp.try_msg(format($q$INSERT INTO core.session (started_at, contract_id, provider_id, volume_mb)
                                VALUES (%L::timestamp AT TIME ZONE 'Europe/Moscow' + interval '10 hours', %s, %s, 10)$q$,
                              :'r_closed', :r_id, :r_prov)) AS e_close_day \gset
-- подбор тарифа по времени и типу дня: среда 20:00 — вечерний, среда 23:30 и четверг 08:59 — ночной (окно через
-- полночь), четверг 09:00 — бизнес-время, суббота 02:00 — выходной ночной, воскресенье 12:00 — выходной дневной
WITH ins AS (
    INSERT INTO core.session (started_at, contract_id, provider_id, volume_mb)
    SELECT make_timestamptz(2025, 6, d, h, m, 0, 'Europe/Moscow'), :k_id, :k_prov, 123.456
    FROM (VALUES (4, 20, 0), (4, 23, 30), (5, 8, 59), (5, 9, 0), (7, 2, 0), (8, 12, 0)) AS v(d, h, m)
    RETURNING started_at, tariff_id, discount_pct, cost)
SELECT string_agg(t.code, ',' ORDER BY i.started_at) AS auto_codes,
       bool_and(i.discount_pct = t.discount_pct
                AND i.cost = round(123.456 * :k_price * (1 - t.discount_pct / 100), 2)) AS auto_cost_ok,
       string_agg(i.cost::text, ',' ORDER BY i.started_at) AS auto_costs
FROM ins i JOIN ref.tariff t ON t.id = i.tariff_id \gset
-- явный тариф: без окна (образовательный) — принимается в любое время; с окном (ночной) — только в своё окно
SELECT pg_temp.try_msg(format($q$INSERT INTO core.session (started_at, contract_id, provider_id, tariff_id, volume_mb)
                                VALUES (make_timestamptz(2025, 6, 4, 12, 0, 0, 'Europe/Moscow'), %s, %s, %s, 10)$q$,
                              :k_id, :k_prov, :t_edu)) AS e_edu \gset
SELECT pg_temp.try_msg(format($q$INSERT INTO core.session (started_at, contract_id, provider_id, tariff_id, volume_mb)
                                VALUES (make_timestamptz(2025, 6, 4, 12, 0, 0, 'Europe/Moscow'), %s, %s, %s, 10)$q$,
                              :k_id, :k_prov, :t_night)) AS e_night_noon \gset
-- переданные скидка и стоимость не принимаются: снимок считает триггер
INSERT INTO core.session (started_at, contract_id, provider_id, volume_mb, discount_pct, cost)
VALUES (make_timestamptz(2025, 6, 4, 10, 0, 0, 'Europe/Moscow'), :k_id, :k_prov, 100, 99, 0.01)
RETURNING id AS s_id, started_at AS s_at, discount_pct AS s_disc, cost AS s_cost \gset
-- снимок (D3): изменение скидки тарифа и цены договора не меняет стоимость уже записанного сеанса
UPDATE ref.tariff SET discount_pct = discount_pct + 5 WHERE code = 'Б';
UPDATE core.contract SET price_per_mb = price_per_mb * 2 WHERE id = :k_id AND provider_id = :k_prov;
SELECT cost AS s_cost_after FROM core.session WHERE id = :s_id AND started_at = :'s_at' \gset
ROLLBACK;

SELECT pg_temp.check('15.2 T8: сеанс раньше даты подключения, в будущем и после расторжения отклоняется; в день расторжения — принимается',
    left(:'e_before', 5) = 'P0001' AND strpos(:'e_before', 'раньше даты подключения') > 0
    AND left(:'e_future', 5) = 'P0001' AND left(:'e_after_close', 5) = 'P0001' AND :'e_close_day' = 'ok',
    format('раньше: %s; в будущем: %s; после расторжения: %s; в день расторжения: %s',
           :'e_before', :'e_future', :'e_after_close', :'e_close_day'));
SELECT pg_temp.check('15.3 T8: тариф не задан — подобран по времени и типу дня (окно через полночь, будни и выходные)',
    :'auto_codes' = 'В,Н,Н,Б,ВН,ВД', :'auto_codes');
SELECT pg_temp.check('15.4 T8: скидка — из тарифа, стоимость = Мб × цена 1 Мб × (1 − скидка/100); переданные скидка и стоимость заменяются',
    :'auto_cost_ok'::boolean AND :s_disc = 0 AND :s_cost = round(100 * :k_price, 2),
    format('стоимости %s; переданные 99 %% и 0,01 → %s %% и %s', :'auto_costs', :s_disc, :s_cost));
SELECT pg_temp.check('15.5 явный тариф без окна принимается в любое время; тариф с окном вне своего окна отклоняется',
    :'e_edu' = 'ok' AND left(:'e_night_noon', 5) = 'P0001', format('образовательный: %s; ночной в полдень: %s', :'e_edu', :'e_night_noon'));
SELECT pg_temp.check('15.6 снимок (D3): изменение скидки тарифа и цены договора не меняет стоимость записанного сеанса',
    :s_cost_after = :s_cost, format('%s → %s', :s_cost, :s_cost_after));

-- ============================================================================ 15.7 провайдер (T7)
BEGIN;
SELECT pg_temp.try_msg(format('DELETE FROM core.provider WHERE id = %s', :p_donnet)) AS e_donnet \gset
-- провайдер с договором и старым (больше 12 месяцев) сеансом: триггер пропускает, удаление запрещает внешний ключ
INSERT INTO core.provider (name, ownership_type_id, city_id, address, phone, founded_year)
SELECT 'Тест-Старый', ot.id, c.id, 'ул. Тестовая, д. 2', '+7 856 000-00-02', 2020
FROM ref.ownership_type ot, ref.city c WHERE ot.name = 'ООО' AND c.name = 'Донецк'
RETURNING id AS o_prov \gset
INSERT INTO core.contract (provider_id, subscriber_id, connected_on, connection_fee, price_per_mb, ip_address, connection_address)
SELECT :o_prov, s.id, date '2024-01-10', 0, 0.1, '10.251.0.1', s.address FROM core.subscriber s ORDER BY s.id LIMIT 1
RETURNING id AS o_contract \gset
INSERT INTO core.session (started_at, contract_id, provider_id, volume_mb)
VALUES (make_timestamptz(2024, 3, 1, 12, 0, 0, 'Europe/Moscow'), :o_contract, :o_prov, 10);
SELECT pg_temp.try_msg(format('DELETE FROM core.provider WHERE id = %s', :o_prov)) AS e_old \gset
-- провайдер без договоров и сотрудников удаляется
SELECT pg_temp.try_msg($q$DELETE FROM core.provider WHERE name = 'Горизонт-Нет'$q$) AS e_empty \gset
ROLLBACK;
SELECT pg_temp.check('15.7 T7: провайдер с сеансами за 12 месяцев — отказ триггера; со старыми сеансами — отказ внешнего ключа; без договоров — удаляется',
    left(:'e_donnet', 5) = 'P0001' AND strpos(:'e_donnet', '12 месяцев') > 0
    AND left(:'e_old', 5) = '23001' AND :'e_empty' = 'ok',
    format('«ДонНет»: %s; со старыми сеансами: %s; без договоров: %s', :'e_donnet', left(:'e_old', 5), :'e_empty'));

-- ============================================================================ 15.8–15.10 договор
BEGIN;
SELECT pg_temp.try_msg(format('UPDATE core.contract SET subscriber_id = subscriber_id + 1 WHERE id = %s AND provider_id = %s',
                              :k_id, :k_prov)) AS e_sub \gset
SELECT pg_temp.try_msg(format('UPDATE core.contract SET provider_id = (SELECT min(id) FROM core.provider WHERE id <> %s) WHERE id = %s AND provider_id = %s',
                              :k_prov, :k_id, :k_prov)) AS e_prov \gset
-- версия строки: изменение без версии увеличивает её; с прочитанной (устаревшей) версией — конфликт
UPDATE core.contract SET note = 'тест версии' WHERE id = :k_id AND provider_id = :k_prov RETURNING row_version AS v1 \gset
SELECT pg_temp.try_msg(format('UPDATE core.contract SET note = ''второе'', row_version = %s WHERE id = %s AND provider_id = %s',
                              :k_ver, :k_id, :k_prov)) AS e_stale \gset
UPDATE core.contract SET note = 'с версией', row_version = :v1 WHERE id = :k_id AND provider_id = :k_prov
RETURNING row_version AS v2 \gset
SET SESSION AUTHORIZATION op_donnet;
SELECT pg_temp.try_msg(format('SELECT api.contract_update(%s, %s, ''ул. Тест, д. 1'', NULL, NULL, 0.1, ''192.0.2.90'')',
                              :k_id, :k_ver)) AS e_api_stale \gset
SELECT api.contract_update(:k_id, :v2, 'ул. Тест, д. 1', NULL, NULL, 0.1, '192.0.2.90') AS v3 \gset
RESET SESSION AUTHORIZATION;
-- период действия и сеансы: дата расторжения раньше последнего сеанса — отказ; в день последнего сеанса — можно
SELECT pg_temp.try_msg(format('UPDATE core.contract SET closed_on = %L::date - 1 WHERE id = %s AND provider_id = %s',
                              :'r_last', :r_id, :r_prov)) AS e_close_early \gset
SELECT pg_temp.try_msg(format('UPDATE core.contract SET closed_on = %L WHERE id = %s AND provider_id = %s',
                              :'r_last', :r_id, :r_prov)) AS e_close_last \gset
SELECT pg_temp.try_msg(format('UPDATE core.contract SET connected_on = %L WHERE id = %s AND provider_id = %s',
                              :'r_last', :r_id, :r_prov)) AS e_connect_late \gset
ROLLBACK;
SELECT pg_temp.check('15.8 стороны договора (абонент, провайдер) не меняются (D14)',
    left(:'e_sub', 5) = 'P0001' AND left(:'e_prov', 5) = 'P0001', format('абонент: %s; провайдер: %s', :'e_sub', :'e_prov'));
SELECT pg_temp.check('15.9 версия строки (D8): каждое изменение увеличивает её на 1; устаревшая версия — конфликт 40001, и в api.contract_update',
    :v1 = :k_ver + 1 AND left(:'e_stale', 5) = '40001' AND :v2 = :v1 + 1
    AND left(:'e_api_stale', 5) = '40001' AND :v3 = :v2 + 1,
    format('версии %s → %s → %s → %s; устаревшая: %s; api: %s', :k_ver, :v1, :v2, :v3, left(:'e_stale', 5), left(:'e_api_stale', 5)));
SELECT pg_temp.check('15.10 расторжение раньше последнего сеанса и перенос подключения позже первого сеанса отклоняются',
    left(:'e_close_early', 5) = 'P0001' AND :'e_close_last' = 'ok' AND left(:'e_connect_late', 5) = 'P0001',
    format('раньше последнего: %s; в день последнего: %s; подключение позже сеансов: %s',
           left(:'e_close_early', 5), :'e_close_last', left(:'e_connect_late', 5)));

-- ============================================================================ 15.11 журнал изменений
SELECT id AS any_type FROM ref.subscriber_type ORDER BY id LIMIT 1 \gset
SELECT id AS any_city FROM ref.city ORDER BY id LIMIT 1 \gset
BEGIN;
SELECT coalesce(max(id), 0) AS log_from FROM audit.change_log \gset
SET SESSION AUTHORIZATION op_donnet;
SELECT contract_id AS j_contract, subscriber_id AS j_sub
FROM api.contract_create(NULL, 'Тестовый Абонент Журнала', :any_type, :any_city, 'ул. Журнальная, д. 1', '+7 949 555-77-01',
                         0, 0.1, '192.0.2.77') \gset
SELECT api.contract_update(:j_contract, 1, 'ул. Журнальная, д. 2', NULL, 'Петров П. П.', 0.12, '192.0.2.77') AS j_ver \gset
SELECT api.subscriber_delete(:j_sub, 1);
RESET SESSION AUTHORIZATION;
-- записи удаления абонента и каскадного удаления договора — в одном операторе, их порядок не важен
SELECT string_agg(l.table_name || ' ' || l.operation, ', '
                  ORDER BY l.operation = 'DELETE', CASE WHEN l.operation = 'DELETE' THEN l.table_name END, l.id) AS j_ops,
       bool_and(l.db_user = 'op_donnet') AS j_user,
       bool_and(CASE l.operation WHEN 'INSERT' THEN l.old_row IS NULL AND l.new_row IS NOT NULL
                                 WHEN 'UPDATE' THEN l.old_row IS NOT NULL AND l.new_row IS NOT NULL
                                 ELSE l.old_row IS NOT NULL AND l.new_row IS NULL END) AS j_rows,
       bool_and(l.row_pk = CASE l.table_name WHEN 'core.contract' THEN :'j_contract' ELSE :'j_sub' END) AS j_pk,
       max(l.old_row ->> 'connection_address') FILTER (WHERE l.operation = 'UPDATE') AS j_old_addr,
       max(l.new_row ->> 'connection_address') FILTER (WHERE l.operation = 'UPDATE') AS j_new_addr,
       max(l.new_row ->> 'row_version') FILTER (WHERE l.operation = 'UPDATE') AS j_new_ver
FROM audit.change_log l WHERE l.id > :log_from \gset
SET SESSION AUTHORIZATION dba_main;
SELECT count(*) AS j_dba, max(changed_fields) FILTER (WHERE operation = 'UPDATE') AS j_fields
FROM api.q_change_log(current_date, current_date, 'core.contract', NULL, 'op_donnet', 200, 0)
WHERE row_pk = :'j_contract' \gset
RESET SESSION AUTHORIZATION;
ROLLBACK;
SELECT pg_temp.check('15.11 журнал: добавление, изменение, удаление договора (и каскадом) — строки до и после в jsonb, пользователь — кто изменил',
    :'j_ops' = 'core.subscriber INSERT, core.contract INSERT, core.contract UPDATE, core.contract DELETE, core.subscriber DELETE'
    AND :'j_user'::boolean AND :'j_rows'::boolean AND :'j_pk'::boolean
    AND :'j_old_addr' = 'ул. Журнальная, д. 1' AND :'j_new_addr' = 'ул. Журнальная, д. 2' AND :'j_new_ver' = '2',
    format('%s; адрес «%s» → «%s», версия %s', :'j_ops', :'j_old_addr', :'j_new_addr', :'j_new_ver'));
SELECT pg_temp.check('15.12 администратор БД видит записи в «Журнале изменений» с числом изменённых полей',
    :j_dba = 3 AND :j_fields >= 3, format('записей по договору %s, изменено полей %s', :j_dba, :j_fields));

-- ============================================================================ 15.13 триггеры в новых секциях
BEGIN;
INSERT INTO core.provider (name, ownership_type_id, city_id, address, phone, founded_year)
SELECT 'Тест-Секция', ot.id, c.id, 'ул. Тестовая, д. 3', '+7 856 000-00-03', 2020
FROM ref.ownership_type ot, ref.city c WHERE ot.name = 'ООО' AND c.name = 'Донецк'
RETURNING id AS n_prov \gset
SELECT extract(year FROM current_date)::int + 3 AS n_year \gset
SELECT count(*) AS n_parts FROM sec.session_partitions_ensure(make_date(:n_year, 1, 1), make_date(:n_year, 1, 1)) \gset
WITH want(tbl, tgname) AS (
    SELECT 'core.contract_p' || :n_prov, x FROM unnest(ARRAY['trg_contract_bu_check', 'trg_contract_ai_audit',
                                                            'trg_contract_au_audit', 'trg_contract_ad_audit']) x
    UNION ALL
    SELECT 'core.session_' || :n_year || '_q' || q, x
    FROM generate_series(1, 4) q, unnest(ARRAY['trg_session_bi_tariff_cost', 'trg_session_aiud_audit']) x)
SELECT count(*) AS n_want, count(t.oid) FILTER (WHERE t.tgparentid <> 0 AND t.tgenabled = 'O') AS n_have
FROM want w
LEFT JOIN pg_catalog.pg_trigger t ON t.tgrelid = to_regclass(w.tbl) AND t.tgname = w.tgname \gset
ROLLBACK;
SELECT pg_temp.check('15.13 секции, созданные после сборки (договоры нового провайдера, кварталы нового года), получают триггеры родителя',
    :n_parts = 1 AND :n_have = :n_want, format('ожидалось %s триггеров в новых секциях, есть %s', :n_want, :n_have));

-- ============================================================================ 15.14–15.15 данные сборки
-- Все сеансы прошли через триггер: в периоде договора, не в будущем, тариф с окном — в своём окне, снимок по формуле.
-- Снимок (D3): сеансы, записанные до изменения цены договора или скидки тарифа (по журналу), хранят прежнюю стоимость.
WITH v AS MATERIALIZED (
    SELECT c.id AS contract_id, t.id AS tariff_id,
           l.lt::date < c.connected_on OR l.lt::date > c.closed_on OR s.started_at > now()
           OR t.time_from IS NOT NULL
              AND (t.is_weekend IS DISTINCT FROM (extract(isodow FROM l.lt) IN (6, 7)) AND t.is_weekend IS NOT NULL
                   OR NOT CASE WHEN t.time_from < t.time_to THEN l.lt::time >= t.time_from AND l.lt::time < t.time_to
                               ELSE l.lt::time >= t.time_from OR l.lt::time < t.time_to END) AS rule_broken,
           s.discount_pct <> t.discount_pct
           OR s.cost <> round(s.volume_mb * c.price_per_mb * (1 - t.discount_pct / 100), 2) AS snapshot_differs
    FROM core.session s
    JOIN core.contract c ON c.id = s.contract_id AND c.provider_id = s.provider_id
    JOIN ref.tariff t ON t.id = s.tariff_id
    CROSS JOIN LATERAL (SELECT s.started_at AT TIME ZONE 'Europe/Moscow' AS lt) l)
SELECT count(*) FILTER (WHERE v.rule_broken
                           OR v.snapshot_differs
                              AND NOT EXISTS (SELECT 1 FROM audit.change_log j
                                              WHERE j.operation = 'UPDATE'
                                                AND (j.table_name = 'core.contract' AND j.row_pk = v.contract_id::text
                                                     AND j.old_row -> 'price_per_mb' IS DISTINCT FROM j.new_row -> 'price_per_mb'
                                                     OR j.table_name = 'ref.tariff' AND j.row_pk = v.tariff_id::text
                                                        AND j.old_row -> 'discount_pct' IS DISTINCT FROM j.new_row -> 'discount_pct'))) AS g_bad,
       count(*) AS g_all
FROM v \gset
SELECT pg_temp.check('15.14 все сеансы базы удовлетворяют правилам триггера (период, время тарифа, снимок скидки и стоимости)',
    :g_bad = 0 AND :g_all >= 500000, format('нарушений %s из %s', :g_bad, :g_all));
SELECT count(*) FILTER (WHERE table_name = 'core.session') AS l_sessions,
       count(*) FILTER (WHERE db_user = 'postgres') AS l_postgres
FROM audit.change_log \gset
SELECT pg_temp.check('15.15 заполнение базы при сборке в журнал не попадает: в журнале — действия пользователей',
    :l_sessions < 1000 AND :l_postgres = 0, format('записей о сеансах %s, от postgres %s', :l_sessions, :l_postgres));
