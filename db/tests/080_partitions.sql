-- Тест 080. Секционирование (ЛР 8, D30): сеансы — по времени (год → квартал), договоры — по провайдеру.
-- Изменяющие проверки — в транзакциях с ROLLBACK: данные и секции базы после теста те же.

-- Код ошибки оператора ('ok' — без ошибки).
CREATE OR REPLACE FUNCTION pg_temp.try_code(p_sql text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE;
END $$;

-- Какие таблицы читает план запроса (имена из EXPLAIN (FORMAT JSON), без повторов, по алфавиту).
CREATE OR REPLACE FUNCTION pg_temp.plan_relations(p_sql text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_plan jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || p_sql INTO v_plan;
    RETURN (SELECT string_agg(DISTINCT r #>> '{}', ',' ORDER BY r #>> '{}')
            FROM jsonb_path_query(v_plan, 'lax $.**."Relation Name"') r);
END $$;

-- ============================================================================ 13.1–13.3 устройство секций
DO $$
DECLARE
    v_years int := extract(year FROM current_date)::int + 1 - 2024 + 1;    -- 2024 … следующий год
    v_y int; v_q int; v_d int; v_strat text; v_list text;
    v_prov int; v_cp int; v_cd int;
BEGIN
    SELECT count(*) FILTER (WHERE t.level = 1 AND NOT t.isleaf),
           count(*) FILTER (WHERE t.level = 2 AND t.isleaf),
           count(*) FILTER (WHERE t.level = 1 AND t.isleaf)
    INTO v_y, v_q, v_d
    FROM pg_catalog.pg_partition_tree('core.session') t;
    SELECT string_agg(DISTINCT pt.partstrat::text, ',') INTO v_strat
    FROM pg_catalog.pg_partitioned_table pt
    WHERE pt.partrelid IN (SELECT t.relid FROM pg_catalog.pg_partition_tree('core.session') t WHERE NOT t.isleaf);
    PERFORM pg_temp.check('13.1 сеансы: секции годов 2024 … следующий год, в каждой — 4 квартальные, секция по умолчанию; всё по диапазону',
        v_y = v_years AND v_q = 4 * v_years AND v_d = 1 AND v_strat = 'r',
        format('годов %s, кварталов %s, по умолчанию %s, способ %s', v_y, v_q, v_d, v_strat));

    SELECT count(*) INTO v_prov FROM core.provider;
    SELECT count(*) FILTER (WHERE t.level = 1 AND t.relid::text <> 'core.contract_default'),
           count(*) FILTER (WHERE t.relid::text = 'core.contract_default')
    INTO v_cp, v_cd
    FROM pg_catalog.pg_partition_tree('core.contract') t;
    SELECT pt.partstrat::text INTO v_strat FROM pg_catalog.pg_partitioned_table pt WHERE pt.partrelid = 'core.contract'::regclass;
    PERFORM pg_temp.check('13.2 договоры: по списку провайдеров — секция у каждого провайдера и секция по умолчанию',
        v_cp = v_prov AND v_cd = 1 AND v_strat = 'l',
        format('провайдеров %s, секций %s, по умолчанию %s, способ %s', v_prov, v_cp, v_cd, v_strat));

    -- Строка лежит в «своей» секции: сеанс — в секции года и квартала начала (по Москве, D19), договор — провайдера.
    SELECT concat_ws('; ',
               nullif((SELECT count(*) FROM core.session s
                       WHERE s.tableoid::regclass::text <> 'core.session_' || to_char(s.started_at AT TIME ZONE 'Europe/Moscow', 'YYYY')
                                                           || '_q' || to_char(s.started_at AT TIME ZONE 'Europe/Moscow', 'Q')), 0)
                   || ' сеансов не в своей секции',
               nullif((SELECT count(*) FROM core.contract c
                       WHERE c.tableoid::regclass::text <> 'core.contract_p' || c.provider_id), 0) || ' договоров не в своей секции',
               nullif((SELECT count(*) FROM core.session_default), 0) || ' сеансов в секции по умолчанию',
               nullif((SELECT count(*) FROM core.contract_default), 0) || ' договоров в секции по умолчанию')
    INTO v_list;
    PERFORM pg_temp.check('13.3 каждая строка в своей секции, секции по умолчанию пусты', v_list = '', nullif(v_list, ''));
END $$;

-- ============================================================================ 13.4 отсечение секций
SELECT id AS p_donnet FROM core.provider WHERE name = 'ДонНет' \gset
SELECT pg_temp.plan_relations($q$SELECT count(*) FROM core.session
                                WHERE started_at >= '2026-07-01' AND started_at < '2026-10-01'$q$) AS r_quarter \gset
SELECT pg_temp.plan_relations(format($q$SELECT count(*) FROM core.contract WHERE provider_id = %s$q$, :p_donnet)) AS r_provider \gset
SELECT pg_temp.plan_relations(format($q$SELECT count(*) FROM core.session s JOIN core.contract c
                                        ON c.id = s.contract_id AND c.provider_id = s.provider_id
                                        WHERE c.provider_id = %s AND s.started_at >= '2026-09-01' AND s.started_at < '2026-10-01'$q$,
                                     :p_donnet)) AS r_both \gset
SELECT pg_temp.plan_relations($q$SELECT count(*) FROM core.session WHERE started_at >= '2025-01-01' AND started_at < '2026-01-01'$q$) AS r_year \gset
SELECT pg_temp.check('13.4 отсечение секций: квартал — одна секция, провайдер — одна секция договоров, вместе — по одной на двух таблицах, год — его 4 квартала',
    :'r_quarter' = 'session_2026_q3'
    AND :'r_provider' = 'contract_p' || :p_donnet
    AND :'r_both' = 'contract_p' || :p_donnet || ',session_2026_q3'
    AND :'r_year' = 'session_2025_q1,session_2025_q2,session_2025_q3,session_2025_q4',
    format('квартал: %s; провайдер: %s; вместе: %s; год: %s', :'r_quarter', :'r_provider', :'r_both', :'r_year'));

-- Отсечение при выполнении (общий план с параметром): часть секций исключается при запуске («Subplans Removed»).
PREPARE q13 (timestamptz, timestamptz) AS SELECT count(*) FROM core.session WHERE started_at >= $1 AND started_at < $2;
SET plan_cache_mode = force_generic_plan;
DO $$
DECLARE
    v_line text;
    v_removed int := 0;
BEGIN
    FOR v_line IN EXECUTE $e$EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE q13('2026-07-01', '2026-10-01')$e$ LOOP
        IF strpos(v_line, 'Subplans Removed: ') > 0 THEN
            v_removed := substr(v_line, strpos(v_line, 'Subplans Removed: ') + 18)::int;
        END IF;
    END LOOP;
    PERFORM pg_temp.check('13.5 общий план с параметрами: лишние секции исключаются при выполнении',
        v_removed > 0, format('исключено секций: %s', v_removed));
END $$;
RESET plan_cache_mode;
DEALLOCATE q13;

-- ============================================================================ 13.6–13.8 изменения (с откатом)
BEGIN;
INSERT INTO core.provider (name, ownership_type_id, city_id, address, phone, founded_year)
SELECT 'Тест-Провайдер', ot.id, c.id, 'ул. Тестовая, д. 1', '+7 856 000-00-00', 2020
FROM ref.ownership_type ot, ref.city c WHERE ot.name = 'ООО' AND c.name = 'Донецк'
RETURNING id AS t_prov \gset
SELECT to_regclass('core.contract_p' || :t_prov) IS NOT NULL AS t_part \gset
INSERT INTO core.contract (provider_id, subscriber_id, connection_fee, price_per_mb, ip_address, connection_address)
SELECT :t_prov, s.id, 0, 0.1, '10.250.0.1', s.address FROM core.subscriber s ORDER BY s.id LIMIT 1
RETURNING tableoid::regclass::text AS t_contract_part, id AS t_contract \gset
-- сеанс с провайдером, отличным от провайдера договора, — нарушение составного внешнего ключа
SELECT pg_temp.try_code(format('INSERT INTO core.session (started_at, contract_id, provider_id, tariff_id, volume_mb, discount_pct, cost)
                                VALUES (now(), %s, %s, 1, 1, 0, 0.1)', :t_contract, :p_donnet)) AS t_fk \gset
ROLLBACK;
SELECT pg_temp.check('13.6 регистрация провайдера создаёт его секцию договоров; договор ложится в неё; сеанс с чужим провайдером отвергнут',
    :'t_part' = 't' AND :'t_contract_part' = 'core.contract_p' || :t_prov AND :'t_fk' = '23503',
    format('секция: %s; договор в %s; сеанс с чужим провайдером: %s', :'t_part', :'t_contract_part', :'t_fk'));

BEGIN;
-- Сеанс года, секции которого нет (через два года), попадает в секцию по умолчанию; функция создаёт год и переносит его.
-- Сеанс «из будущего» отклонил бы триггер сеанса (080), поэтому на время вставки он отключён: так моделируется сеанс,
-- попавший в секцию по умолчанию, когда секцию его года не создали вовремя. Стоимость 0,1 не по формуле — перенос должен
-- её сохранить (снимок D3: триггеры на время переноса отключены) и не писать в журнал.
SELECT extract(year FROM current_date)::int + 2 AS t_year \gset
SELECT count(*) AS t_log_before FROM audit.change_log \gset
ALTER TABLE core.session DISABLE TRIGGER trg_session_bi_tariff_cost;
INSERT INTO core.session (started_at, contract_id, provider_id, tariff_id, volume_mb, discount_pct, cost)
SELECT make_timestamptz(:t_year, 2, 10, 12, 0, 0, 'Europe/Moscow'), c.id, c.provider_id, 1, 1, 0, 0.1
FROM core.contract c ORDER BY c.id LIMIT 1
RETURNING tableoid::regclass::text AS t_before \gset
ALTER TABLE core.session ENABLE TRIGGER trg_session_bi_tariff_cost;
SELECT count(*) AS t_log_mid FROM audit.change_log \gset
SELECT count(*) AS t_created, coalesce(sum(moved_rows), 0) AS t_moved
FROM sec.session_partitions_ensure(make_date(:t_year, 1, 1), make_date(:t_year, 12, 31)) \gset
SELECT tableoid::regclass::text AS t_after, cost AS t_cost
FROM core.session WHERE started_at = make_timestamptz(:t_year, 2, 10, 12, 0, 0, 'Europe/Moscow') \gset
SELECT count(*) AS t_again FROM sec.session_partitions_ensure(date '2024-01-01', make_date(:t_year, 12, 31)) \gset
SELECT count(*) AS t_log_after FROM audit.change_log \gset
SELECT count(*) FILTER (WHERE t.tgenabled = 'D') AS t_disabled
FROM pg_catalog.pg_trigger t
WHERE t.tgrelid IN (SELECT r.relid FROM pg_catalog.pg_partition_tree('core.session') r) AND NOT t.tgisinternal \gset
ROLLBACK;
SELECT pg_temp.check('13.7 сеанс года без секции — в секции по умолчанию; создание секции года переносит его в квартал (снимок стоимости и журнал не меняются, триггеры снова включены); повторный вызов ничего не создаёт',
    :'t_before' = 'core.session_default' AND :t_created = 1 AND :t_moved = 1
    AND :'t_after' = 'core.session_' || :t_year || '_q1' AND :t_again = 0
    AND :t_cost = 0.1 AND :t_log_after = :t_log_mid AND :t_disabled = 0,
    format('до: %s; создано %s, перенесено %s; после: %s, стоимость %s; записей журнала при переносе +%s; отключённых триггеров %s; повторно создано %s',
           :'t_before', :t_created, :t_moved, :'t_after', :t_cost, :t_log_after - :t_log_mid, :t_disabled, :t_again));

-- ============================================================================ 13.8–13.9 администратор БД
SET SESSION AUTHORIZATION op_donnet;
SELECT pg_temp.try_code('SELECT * FROM api.db_session_partitions_ensure()') AS a_op \gset
SELECT pg_temp.try_code('SELECT count(*) FROM core.session_2026_q3') AS a_op_part \gset
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION dba_main;
SELECT count(*) AS a_dba FROM api.db_session_partitions_ensure() \gset
SELECT count(*) FILTER (WHERE table_name = 'core.session') AS a_sess,
       count(*) FILTER (WHERE table_name LIKE 'core.session\_%' OR table_name LIKE 'core.contract\_%') AS a_parts,
       max(rows_estimate) FILTER (WHERE table_name = 'core.session') AS a_rows
FROM api.db_tables() \gset
RESET SESSION AUTHORIZATION;
SELECT count(*) AS a_count FROM core.session \gset
SELECT pg_temp.check('13.8 секции на год вперёд создаёт только администратор БД; оператор не читает секцию напрямую',
    :'a_op' = '42501' AND :'a_op_part' = '42501' AND :a_dba = 0,
    format('оператор: %s, секция напрямую: %s; администратор БД создал секций: %s', :'a_op', :'a_op_part', :a_dba));
SELECT pg_temp.check('13.9 «Таблицы базы данных»: сеансы — одна строка с суммой по секциям, секций в списке нет',
    :a_sess = 1 AND :a_parts = 0 AND :a_rows BETWEEN :a_count * 0.95 AND :a_count * 1.05,
    format('строк core.session: %s; секций в списке: %s; строк по статистике %s при %s', :a_sess, :a_parts, :a_rows, :a_count));
