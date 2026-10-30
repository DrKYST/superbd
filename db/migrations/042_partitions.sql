-- 042. Секции (ЛР 8, D30).
--   * core.session — по времени начала, два уровня: год → квартал; секция по умолчанию — для года, секция которого
--     ещё не создана (вставка не падает). Годы создаёт sec.session_partitions_ensure: при сборке — 2024 … текущий + 1,
--     дальше — администратор БД раз в год (api.db_session_partitions_ensure, 070).
--   * core.contract — по провайдеру: у каждого провайдера своя секция, её создаёт триггер при регистрации провайдера;
--     секция по умолчанию — на случай, если секции нет (например, её отсоединили).
-- Без расширений (pg_partman, pg_cron): только декларативное секционирование PostgreSQL.
-- Идемпотентно: функции не пересоздают существующие секции.
SET ROLE app_owner;

-- ============================================================================ секции по умолчанию
CREATE TABLE IF NOT EXISTS core.session_default PARTITION OF core.session DEFAULT;
COMMENT ON TABLE core.session_default IS
    'Сеанс связи — секция по умолчанию (сеансы года, секция которого ещё не создана; в норме пуста)';

CREATE TABLE IF NOT EXISTS core.contract_default PARTITION OF core.contract DEFAULT;
COMMENT ON TABLE core.contract_default IS
    'Договор — секция по умолчанию (договоры провайдера без своей секции; в норме пуста)';

-- ============================================================================ сеансы: год → квартал
-- Порядок для года:
--   1) сеансы этого года, попавшие в секцию по умолчанию, запоминаются и удаляются из неё — иначе секцию года не
--      присоединить (строки года не могут остаться в секции по умолчанию);
--   2) пустая таблица года (LIKE … INCLUDING DEFAULTS INCLUDING CONSTRAINTS, без identity: секция со своей identity в
--      PostgreSQL 17+ не присоединяется) присоединяется к core.session (ATTACH PARTITION) — присоединение блокирует
--      core.session слабее, чем CREATE TABLE … PARTITION OF (SHARE UPDATE EXCLUSIVE), работа с сеансами не останавливается;
--   3) кварталы создаются уже внутри присоединённой таблицы года (CREATE TABLE … PARTITION OF год): так они наследуют
--      identity родителя. Если присоединить год вместе с готовыми кварталами, PostgreSQL 18.3 передаёт identity только
--      таблице года, а не кварталам, и отсоединить год (DETACH) потом нельзя — проверено при реализации ЛР 8;
--   4) запомненные сеансы вставляются обратно через core.session (с прежними кодами) и попадают в свои кварталы.
-- Перенос — служебная операция, а не изменение данных: на время удаления и обратной вставки включённые триггеры сеансов
-- (подбор тарифа и стоимость — 080, журнал изменений) отключаются, иначе снимок скидки и стоимости (D3) был бы посчитан
-- заново, а в журнал попали бы удаление и добавление каждого сеанса. Внешние ключи (системные триггеры) действуют.
-- Отключение — после создания кварталов ещё раз: новые секции получают триггеры родителя включёнными.
-- Сеансы читаются, удаляются и вставляются через core.session (секции года ещё нет — строки года только в секции по
-- умолчанию): на самих секциях защита на уровне строк без политик (090), строки видны только через родителя — по
-- политике обслуживания (администратор БД, суперпользователь). Новым секциям защита включается сразу.
-- Индексы, внешние ключи и триггеры родителя появляются в секциях сами. Границы — полночь по Москве (D19), как периоды отчётов.
CREATE OR REPLACE FUNCTION sec.session_partitions_ensure(p_from date, p_to date)
RETURNS TABLE (partition_name text, range_from date, range_to date, moved_rows bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_year integer;
    v_q integer;
    v_name text;
    v_from date;
    v_to date;
    v_rows core.session[];
    v_triggers text[];
    v_trg text;
BEGIN
    IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
        RAISE EXCEPTION 'Неверный период для секций сеансов' USING ERRCODE = '22023';
    END IF;
    FOR v_year IN extract(year FROM p_from)::integer .. extract(year FROM p_to)::integer LOOP
        v_name := 'session_' || v_year;
        CONTINUE WHEN to_regclass('core.' || v_name) IS NOT NULL;
        v_from := make_date(v_year, 1, 1);
        v_to := make_date(v_year + 1, 1, 1);
        SELECT array_agg(d) INTO v_rows
        FROM core.session d
        WHERE d.started_at >= v_from::timestamptz AND d.started_at < v_to::timestamptz;
        IF v_rows IS NOT NULL THEN
            SELECT array_agg(t.tgname::text) INTO v_triggers
            FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid = 'core.session'::regclass AND NOT t.tgisinternal AND t.tgenabled <> 'D';
            FOREACH v_trg IN ARRAY coalesce(v_triggers, '{}') LOOP
                EXECUTE format('ALTER TABLE core.session DISABLE TRIGGER %I', v_trg);
            END LOOP;
            DELETE FROM core.session d
            WHERE d.started_at >= v_from::timestamptz AND d.started_at < v_to::timestamptz;
        END IF;
        EXECUTE format('CREATE TABLE core.%I (LIKE core.session INCLUDING DEFAULTS INCLUDING CONSTRAINTS) '
                       'PARTITION BY RANGE (started_at)', v_name);
        EXECUTE format('ALTER TABLE core.session ATTACH PARTITION core.%I FOR VALUES FROM (%L) TO (%L)',
                       v_name, v_from::timestamptz, v_to::timestamptz);
        EXECUTE format('COMMENT ON TABLE core.%I IS %L', v_name,
                       format('Сеанс связи — секция %s года (разделена по кварталам)', v_year));
        EXECUTE format('ALTER TABLE core.%I ENABLE ROW LEVEL SECURITY, FORCE ROW LEVEL SECURITY', v_name);
        FOR v_q IN 1 .. 4 LOOP
            EXECUTE format('CREATE TABLE core.%I PARTITION OF core.%I FOR VALUES FROM (%L) TO (%L)',
                           v_name || '_q' || v_q, v_name,
                           make_date(v_year, 3 * v_q - 2, 1)::timestamptz,
                           (make_date(v_year, 3 * v_q - 2, 1) + interval '3 months')::timestamptz);
            EXECUTE format('COMMENT ON TABLE core.%I IS %L', v_name || '_q' || v_q,
                           format('Сеанс связи — секция %s квартала %s года', v_q, v_year));
            EXECUTE format('ALTER TABLE core.%I ENABLE ROW LEVEL SECURITY, FORCE ROW LEVEL SECURITY', v_name || '_q' || v_q);
        END LOOP;
        IF v_rows IS NOT NULL THEN
            FOREACH v_trg IN ARRAY coalesce(v_triggers, '{}') LOOP
                EXECUTE format('ALTER TABLE core.session DISABLE TRIGGER %I', v_trg);    -- и в новых кварталах
            END LOOP;
            INSERT INTO core.session OVERRIDING SYSTEM VALUE
            SELECT (r).* FROM unnest(v_rows) AS r;
            FOREACH v_trg IN ARRAY coalesce(v_triggers, '{}') LOOP
                EXECUTE format('ALTER TABLE core.session ENABLE TRIGGER %I', v_trg);
            END LOOP;
        END IF;
        moved_rows := coalesce(cardinality(v_rows), 0);
        partition_name := 'core.' || v_name;
        range_from := v_from;
        range_to := v_to;
        RETURN NEXT;
    END LOOP;
END $$;
COMMENT ON FUNCTION sec.session_partitions_ensure(date, date) IS
    'Создаёт недостающие секции сеансов за годы периода: секция года (ATTACH PARTITION) с четырьмя квартальными, перенос сеансов года из секции по умолчанию (D30)';

-- ============================================================================ договоры: секция провайдера
-- Если договоры провайдера уже лежат в секции по умолчанию, секцию не создать: строки пришлось бы перенести удалением
-- и вставкой, а удаление договора каскадом удаляет его сеансы. Такой случай решается вручную — ошибка с объяснением.
-- Секцию по умолчанию проверяет sec.contract_default_has (090): договоры администратору, который регистрирует
-- провайдера, не видны (защита на уровне строк). Новой секции защита включается сразу.
CREATE OR REPLACE FUNCTION sec.contract_partition_ensure(p_provider_id integer)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_name text := 'contract_p' || p_provider_id;
BEGIN
    IF to_regclass('core.' || v_name) IS NOT NULL THEN
        RETURN NULL;                                   -- секция уже есть
    END IF;
    IF sec.contract_default_has(p_provider_id) THEN
        RAISE EXCEPTION 'Договоры провайдера с кодом % находятся в секции по умолчанию — перенесите их до создания секции',
            p_provider_id USING ERRCODE = 'P0001';
    END IF;
    EXECUTE format('CREATE TABLE core.%I PARTITION OF core.contract FOR VALUES IN (%s)', v_name, p_provider_id);
    EXECUTE format('COMMENT ON TABLE core.%I IS %L', v_name,
                   format('Договор — секция провайдера «%s»',
                          (SELECT p.name FROM core.provider p WHERE p.id = p_provider_id)));
    EXECUTE format('ALTER TABLE core.%I ENABLE ROW LEVEL SECURITY, FORCE ROW LEVEL SECURITY', v_name);
    RETURN 'core.' || v_name;
END $$;
COMMENT ON FUNCTION sec.contract_partition_ensure(integer) IS
    'Создаёт секцию договоров провайдера, если её нет (D30); возвращает имя созданной секции или NULL';

-- Регистрация провайдера → у него появляется своя секция договоров.
CREATE OR REPLACE FUNCTION sec.trg_provider_ai_contract_partition()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM sec.contract_partition_ensure(NEW.id);
    RETURN NULL;
END $$;
COMMENT ON FUNCTION sec.trg_provider_ai_contract_partition() IS
    'Триггерная функция: секция договоров нового провайдера (D30)';

DROP TRIGGER IF EXISTS trg_provider_ai_contract_partition ON core.provider;
CREATE TRIGGER trg_provider_ai_contract_partition
    AFTER INSERT ON core.provider
    FOR EACH ROW EXECUTE FUNCTION sec.trg_provider_ai_contract_partition();
COMMENT ON TRIGGER trg_provider_ai_contract_partition ON core.provider IS
    'У каждого провайдера — своя секция договоров (D30)';

REVOKE ALL ON FUNCTION sec.session_partitions_ensure(date, date), sec.contract_partition_ensure(integer),
    sec.trg_provider_ai_contract_partition() FROM PUBLIC;

DO $$
BEGIN
    -- Секции сеансов: с первого года данных системы (договоры заключаются с 01.01.2024) до следующего года.
    PERFORM sec.session_partitions_ensure(date '2024-01-01', (current_date + interval '1 year')::date);
    -- Секции договоров уже зарегистрированных провайдеров (при сборке с нуля провайдеров нет — секции создаст триггер).
    PERFORM sec.contract_partition_ensure(p.id) FROM core.provider p;
END $$;

RESET ROLE;
