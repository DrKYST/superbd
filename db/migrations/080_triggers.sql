-- 080. Триггеры бизнес-правил и журнала изменений (requirements.md, раздел 5).
--   BEFORE INSERT  core.session  — сеанс в периоде действия договора и не в будущем; тариф по времени и типу дня,
--                                  если не задан (D2, D13); снимок скидки и расчёт стоимости (D3);
--   BEFORE UPDATE  core.contract — стороны договора не меняются (D14); версия строки: проверка конфликта и + 1 (D8);
--                                  сеансы не выходят за новый период действия;
--   BEFORE DELETE  core.provider — запрет, если у провайдера есть сеансы за последние 12 месяцев (D9);
--   AFTER INSERT / UPDATE / DELETE core.contract (и остальные таблицы данных) — запись в audit.change_log (D10).
-- Вместе с 045 (BEFORE INSERT/UPDATE sec.app_user) и 042 (AFTER INSERT core.provider) — все шесть типов событий.
-- Секционированные таблицы (D30): триггеры объявлены на родителе, PostgreSQL копирует их в каждую секцию, в том числе
-- в секции, созданные позже (sec.session_partitions_ensure, sec.contract_partition_ensure) — тест 15.10.
SET ROLE app_owner;

-- ============================================================================ сеанс: период, тариф, стоимость
-- Время сеанса переводится в местное явно (AT TIME ZONE, D19), а не SET TimeZone у функции: функция вызывается
-- для каждой строки (500 000 при сборке), а SET у функции сохраняет и восстанавливает параметр при каждом вызове.
-- Договор ищется по полному ключу (id, provider_id) — читается одна секция; нет такого договора — та же ошибка, что у
-- внешнего ключа (23503). Явно заданный тариф с окном времени должен подходить по времени и типу дня; тариф без окна
-- (праздничный, образовательный, акционный, служебный) назначается только явно (D13).
CREATE OR REPLACE FUNCTION sec.trg_session_bi_tariff_cost()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_local timestamp := NEW.started_at AT TIME ZONE 'Europe/Moscow';     -- местное время сеанса (D19)
    v_weekend boolean := extract(isodow FROM v_local) IN (6, 7);
    v_time time := v_local::time;
    v_connected date;
    v_closed date;
    v_price numeric;
    v_tariff record;
BEGIN
    SELECT c.connected_on, c.closed_on, c.price_per_mb INTO v_connected, v_closed, v_price
    FROM core.contract c
    WHERE c.id = NEW.contract_id AND c.provider_id = NEW.provider_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Договор не найден' USING ERRCODE = '23503';
    END IF;
    IF NEW.started_at > now() THEN
        RAISE EXCEPTION 'Время сеанса % ещё не наступило', to_char(v_local, 'DD.MM.YYYY HH24:MI') USING ERRCODE = 'P0001';
    END IF;
    IF v_local::date < v_connected THEN
        RAISE EXCEPTION 'Сеанс % раньше даты подключения договора (%)',
            to_char(v_local, 'DD.MM.YYYY HH24:MI'), to_char(v_connected, 'DD.MM.YYYY') USING ERRCODE = 'P0001';
    END IF;
    IF v_local::date > v_closed THEN
        RAISE EXCEPTION 'Сеанс % после расторжения договора (%)',
            to_char(v_local, 'DD.MM.YYYY HH24:MI'), to_char(v_closed, 'DD.MM.YYYY') USING ERRCODE = 'P0001';
    END IF;

    IF NEW.tariff_id IS NULL THEN
        -- окно через полночь (ночной 23:00–09:00) задано как time_from > time_to (D2); тариф «любой день»
        -- (is_weekend IS NULL) — после тарифа своего типа дня
        SELECT t.id, t.discount_pct INTO v_tariff
        FROM ref.tariff t
        WHERE t.time_from IS NOT NULL
          AND (t.is_weekend = v_weekend OR t.is_weekend IS NULL)
          AND CASE WHEN t.time_from < t.time_to THEN v_time >= t.time_from AND v_time < t.time_to
                   ELSE v_time >= t.time_from OR v_time < t.time_to END
        ORDER BY t.is_weekend IS NULL
        LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Нет тарифа для времени сеанса %: укажите тариф', to_char(v_local, 'DD.MM.YYYY HH24:MI')
                USING ERRCODE = 'P0001';
        END IF;
        NEW.tariff_id := v_tariff.id;
    ELSE
        SELECT t.id, t.name, t.discount_pct, t.time_from, t.time_to, t.is_weekend INTO v_tariff
        FROM ref.tariff t
        WHERE t.id = NEW.tariff_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Тариф не найден' USING ERRCODE = '23503';
        END IF;
        IF v_tariff.time_from IS NOT NULL
           AND (v_tariff.is_weekend IS DISTINCT FROM v_weekend AND v_tariff.is_weekend IS NOT NULL
                OR NOT CASE WHEN v_tariff.time_from < v_tariff.time_to
                            THEN v_time >= v_tariff.time_from AND v_time < v_tariff.time_to
                            ELSE v_time >= v_tariff.time_from OR v_time < v_tariff.time_to END) THEN
            RAISE EXCEPTION 'Тариф «%» действует % с % до %: время сеанса % не подходит', v_tariff.name,
                CASE v_tariff.is_weekend WHEN true THEN 'в выходные' WHEN false THEN 'в будни' ELSE 'ежедневно' END,
                to_char(v_tariff.time_from, 'HH24:MI'), to_char(v_tariff.time_to, 'HH24:MI'),
                to_char(v_local, 'DD.MM.YYYY HH24:MI') USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- снимок на момент сеанса (D3): изменение тарифа или цены договора не меняет выставленных сумм
    NEW.discount_pct := v_tariff.discount_pct;
    NEW.cost := round(NEW.volume_mb * v_price * (1 - v_tariff.discount_pct / 100), 2);
    RETURN NEW;
END $$;
COMMENT ON FUNCTION sec.trg_session_bi_tariff_cost() IS
    'Триггерная функция сеанса: время в периоде действия договора и не в будущем, тариф по окну времени и типу дня (если не задан), снимок скидки и стоимость = Мб × цена 1 Мб × (1 − скидка/100) (D2, D3, D13)';

DROP TRIGGER IF EXISTS trg_session_bi_tariff_cost ON core.session;
CREATE TRIGGER trg_session_bi_tariff_cost
    BEFORE INSERT ON core.session
    FOR EACH ROW EXECUTE FUNCTION sec.trg_session_bi_tariff_cost();
COMMENT ON TRIGGER trg_session_bi_tariff_cost ON core.session IS
    'Проверка времени сеанса, подбор тарифа, снимок скидки и расчёт стоимости (D2, D3)';

-- ============================================================================ договор: стороны, версия строки
-- Оптимистическая блокировка (D8): изменяющий запрос записывает в row_version версию, которую прочитал клиент;
-- триггер сравнивает её с версией в базе и ставит следующую. Запрос, не трогающий row_version, проходит проверку
-- (версия та же) и тоже увеличивает версию. Второй из двух одновременных изменений ждёт блокировку строки, затем
-- видит уже изменённую строку с новой версией — и получает отказ 40001.
-- Изменение сторон отклоняется до проверки версии: при смене провайдера строка перешла бы в другую секцию (D30).
CREATE OR REPLACE FUNCTION sec.trg_contract_bu_check()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NEW.provider_id IS DISTINCT FROM OLD.provider_id OR NEW.subscriber_id IS DISTINCT FROM OLD.subscriber_id THEN
        RAISE EXCEPTION 'Провайдер и абонент договора не меняются: расторгните договор и заключите новый'
            USING ERRCODE = 'P0001';
    END IF;
    IF NEW.row_version IS DISTINCT FROM OLD.row_version THEN
        RAISE EXCEPTION 'Договор % изменён другим пользователем — обновите карточку', OLD.contract_no
            USING ERRCODE = '40001';
    END IF;
    NEW.row_version := OLD.row_version + 1;

    -- сеансы остаются в периоде действия договора (индекс ix_session_contract_id_started_at)
    IF NEW.closed_on IS NOT NULL AND NEW.closed_on IS DISTINCT FROM OLD.closed_on
       AND EXISTS (SELECT 1 FROM core.session s
                   WHERE s.contract_id = OLD.id AND s.provider_id = OLD.provider_id
                     AND s.started_at >= ((NEW.closed_on + 1)::timestamp AT TIME ZONE 'Europe/Moscow')) THEN
        RAISE EXCEPTION 'По договору % есть сеансы после %: дата расторжения не может быть раньше последнего сеанса',
            OLD.contract_no, to_char(NEW.closed_on, 'DD.MM.YYYY') USING ERRCODE = 'P0001';
    END IF;
    IF NEW.connected_on > OLD.connected_on
       AND EXISTS (SELECT 1 FROM core.session s
                   WHERE s.contract_id = OLD.id AND s.provider_id = OLD.provider_id
                     AND s.started_at < (NEW.connected_on::timestamp AT TIME ZONE 'Europe/Moscow')) THEN
        RAISE EXCEPTION 'По договору % есть сеансы раньше %: дату подключения перенести нельзя',
            OLD.contract_no, to_char(NEW.connected_on, 'DD.MM.YYYY') USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END $$;
COMMENT ON FUNCTION sec.trg_contract_bu_check() IS
    'Триггерная функция договора: провайдер и абонент не меняются (D14); версия строки — проверка конфликта и увеличение (D8); сеансы не выходят за период действия';

DROP TRIGGER IF EXISTS trg_contract_bu_check ON core.contract;
CREATE TRIGGER trg_contract_bu_check
    BEFORE UPDATE ON core.contract
    FOR EACH ROW EXECUTE FUNCTION sec.trg_contract_bu_check();
COMMENT ON TRIGGER trg_contract_bu_check ON core.contract IS
    'Неизменность сторон договора, оптимистическая блокировка по версии строки (D8, D14)';

-- ============================================================================ провайдер: запрет удаления
-- Действующего провайдера (есть сеансы за последние 12 месяцев) удалить нельзя (D9). Провайдер с договорами без
-- недавних сеансов защищён внешним ключом договоров (RESTRICT), без договоров — удаляется.
-- Сеансы провайдера ищутся через его договоры: по каждому договору — индекс (contract_id, started_at), до первого.
CREATE OR REPLACE FUNCTION sec.trg_provider_bd_check_sessions()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM core.contract c
               WHERE c.provider_id = OLD.id
                 AND EXISTS (SELECT 1 FROM core.session s
                             WHERE s.contract_id = c.id AND s.provider_id = c.provider_id
                               AND s.started_at >= now() - interval '12 months')) THEN
        RAISE EXCEPTION 'Провайдера «%» удалить нельзя: у него есть сеансы связи за последние 12 месяцев', OLD.name
            USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
END $$;
COMMENT ON FUNCTION sec.trg_provider_bd_check_sessions() IS
    'Триггерная функция провайдера: запрет удаления при сеансах связи за последние 12 месяцев (D9)';

DROP TRIGGER IF EXISTS trg_provider_bd_check_sessions ON core.provider;
CREATE TRIGGER trg_provider_bd_check_sessions
    BEFORE DELETE ON core.provider
    FOR EACH ROW EXECUTE FUNCTION sec.trg_provider_bd_check_sessions();
COMMENT ON TRIGGER trg_provider_bd_check_sessions ON core.provider IS
    'Запрет удаления провайдера с сеансами за последние 12 месяцев (D9)';

-- ============================================================================ журнал изменений
-- Одна функция для всех таблиц: строка до и после изменения в jsonb (D10), пользователь — session_user (умолчание
-- колонки db_user), ключ строки — id. Имя таблицы — аргумент триггера: в секции (D30) TG_TABLE_NAME — имя секции.
-- SECURITY DEFINER: запись в журнал не зависит от прав того, кто меняет данные. Изменение без изменения значений
-- в журнал не попадает.
CREATE OR REPLACE FUNCTION sec.trg_audit_row()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_old jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    v_new jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
BEGIN
    IF v_old = v_new THEN
        RETURN NULL;
    END IF;
    INSERT INTO audit.change_log (table_name, operation, row_pk, old_row, new_row)
    VALUES (TG_ARGV[0], TG_OP, coalesce(v_new, v_old) ->> 'id', v_old, v_new);
    RETURN NULL;
END $$;
COMMENT ON FUNCTION sec.trg_audit_row() IS
    'Триггерная функция журнала: операция, ключ строки, строка до и после изменения (jsonb) в audit.change_log (D10); аргумент — имя таблицы';

-- Договор — три триггера, по одному на событие (ТЗ: по триггеру на каждый тип события).
DROP TRIGGER IF EXISTS trg_contract_ai_audit ON core.contract;
CREATE TRIGGER trg_contract_ai_audit AFTER INSERT ON core.contract
    FOR EACH ROW EXECUTE FUNCTION sec.trg_audit_row('core.contract');
DROP TRIGGER IF EXISTS trg_contract_au_audit ON core.contract;
CREATE TRIGGER trg_contract_au_audit AFTER UPDATE ON core.contract
    FOR EACH ROW EXECUTE FUNCTION sec.trg_audit_row('core.contract');
DROP TRIGGER IF EXISTS trg_contract_ad_audit ON core.contract;
CREATE TRIGGER trg_contract_ad_audit AFTER DELETE ON core.contract
    FOR EACH ROW EXECUTE FUNCTION sec.trg_audit_row('core.contract');
COMMENT ON TRIGGER trg_contract_ai_audit ON core.contract IS 'Журнал изменений: новый договор (D10)';
COMMENT ON TRIGGER trg_contract_au_audit ON core.contract IS 'Журнал изменений: договор до и после изменения (D10)';
COMMENT ON TRIGGER trg_contract_ad_audit ON core.contract IS 'Журнал изменений: удалённый договор (D10)';

-- Остальные таблицы данных (экран «Журнал изменений» — абоненты, сеансы, провайдеры, справочники) — по одному
-- триггеру на все три события.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['core.provider', 'core.subscriber', 'core.session',
                             'ref.ownership_type', 'ref.city', 'ref.subscriber_type', 'ref.tariff'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', 'trg_' || split_part(t, '.', 2) || '_aiud_audit', t);
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s '
                       'FOR EACH ROW EXECUTE FUNCTION sec.trg_audit_row(%L)',
                       'trg_' || split_part(t, '.', 2) || '_aiud_audit', t, t);
        EXECUTE format('COMMENT ON TRIGGER %I ON %s IS %L', 'trg_' || split_part(t, '.', 2) || '_aiud_audit', t,
                       'Журнал изменений: строка до и после изменения (D10)');
    END LOOP;
END $$;

-- Журнал на время массовой загрузки (seed при сборке) отключается: в нём — действия пользователей, а не заполнение
-- базы. Включает и отключает триггеры журнала на таблицах-родителях (секции — вместе с ними). Только для владельца
-- и суперпользователя: группам не выдаётся.
CREATE OR REPLACE FUNCTION sec.audit_set_enabled(p_enabled boolean)
RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    r record;
    n integer := 0;
BEGIN
    FOR r IN SELECT t.tgrelid::regclass AS tbl, t.tgname
             FROM pg_catalog.pg_trigger t
             JOIN pg_catalog.pg_proc p ON p.oid = t.tgfoid
             JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'sec' AND p.proname = 'trg_audit_row' AND t.tgparentid = 0
             ORDER BY 1, 2 LOOP
        EXECUTE format('ALTER TABLE %s %s TRIGGER %I', r.tbl, CASE WHEN p_enabled THEN 'ENABLE' ELSE 'DISABLE' END,
                       r.tgname);
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;
COMMENT ON FUNCTION sec.audit_set_enabled(boolean) IS
    'Включает (true) или отключает (false) триггеры журнала изменений — на время массовой загрузки данных; возвращает число триггеров';

REVOKE ALL ON FUNCTION sec.trg_session_bi_tariff_cost(), sec.trg_contract_bu_check(),
    sec.trg_provider_bd_check_sessions(), sec.trg_audit_row(), sec.audit_set_enabled(boolean) FROM PUBLIC;

RESET ROLE;
