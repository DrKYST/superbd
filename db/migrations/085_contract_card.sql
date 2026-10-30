-- 085. Модифицируемое представление «абонент + договор» (ТЗ: не меньше одного представления, изменяемого через
-- триггеры INSTEAD OF; requirements.md, раздел 5). Источник данных формы «Договор» (создание и изменение).
--   SELECT — договор своего провайдера (оператор, руководитель) или любой (главный аналитик) со сведениями абонента;
--   INSERT — новый договор своего провайдера: абонент из реестра присоединяется, а не копируется (D25), или создаётся;
--   UPDATE — данные договора и (если изменены) сведения абонента в реестре: общего абонента меняет только
--            администратор приложения (D25); оптимистическая блокировка по row_version договора и абонента (D8);
--   DELETE — договор без сеансов (ошибочно введённый); договор с сеансами расторгается, а не удаляется.
-- Права проверяются внутри триггерной функции (группа, свой провайдер) — права на представление (GRANT) лишь первый
-- рубеж. Правила общие с api.contract_create и api.subscriber_update (sec.contract_insert, sec.subscriber_save — 066).
SET ROLE app_owner;

CREATE OR REPLACE VIEW api.v_contract_card WITH (security_barrier = true) AS
SELECT c.id,
       c.contract_no::text AS contract_no,
       c.provider_id,
       CASE WHEN ot.name = upper(ot.name) THEN ot.name || ' «' || p.name || '»'
            ELSE '«' || p.name || '»' END AS provider_name,
       c.subscriber_id,
       s.name::text AS subscriber_name,
       s.subscriber_type_id::integer AS subscriber_type_id,
       st.name::text AS subscriber_type,
       s.city_id,
       ci.name::text AS city,
       s.address::text AS subscriber_address,
       s.phone::text AS subscriber_phone,
       s.row_version AS subscriber_row_version,
       sec.subscriber_shared(s.id, c.provider_id) AS subscriber_shared,
       c.connected_on,
       c.connection_fee::numeric AS connection_fee,
       c.price_per_mb::numeric AS price_per_mb,
       host(c.ip_address) AS ip_address,
       c.connection_address::text AS connection_address,
       c.contact_phone::text AS contact_phone,
       c.contact_person::text AS contact_person,
       c.closed_on,
       CASE WHEN c.closed_on IS NULL THEN 'Действует'
            ELSE 'Расторгнут ' || to_char(c.closed_on, 'DD.MM.YYYY') END AS state,
       c.note,
       c.row_version
FROM core.contract c
JOIN core.subscriber s ON s.id = c.subscriber_id
JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
JOIN ref.city ci ON ci.id = s.city_id
JOIN core.provider p ON p.id = c.provider_id
JOIN ref.ownership_type ot ON ot.id = p.ownership_type_id
-- разграничение доступа: договоры своего провайдера (главному аналитику — все), как в api.v_contracts
WHERE c.provider_id = ANY ((SELECT sec.scope_data())::integer[]);
COMMENT ON VIEW api.v_contract_card IS
    'Модифицируемое представление «абонент + договор» (INSTEAD OF): карточка договора своего провайдера со сведениями абонента; добавление, изменение и удаление — триггерами с проверкой прав и версии строки';

-- Колонки, которые меняет форма; остальное (номер, дата подключения, стоимость подключения, стороны) после записи
-- не меняется (D14).
CREATE OR REPLACE FUNCTION sec.trg_contract_card_ioiud()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_provider integer := sec.current_provider_id();
    v_id integer;
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator']);
    IF v_provider IS NULL THEN
        RAISE EXCEPTION 'Учётная запись не привязана к провайдеру' USING ERRCODE = '42501';
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- провайдер — по учётной записи оператора (поле формы только для чтения)
        IF NEW.provider_id IS DISTINCT FROM v_provider AND NEW.provider_id IS NOT NULL THEN
            RAISE EXCEPTION 'Договор заключается только от имени своего провайдера' USING ERRCODE = '42501';
        END IF;
        SELECT r.contract_id INTO v_id
        FROM sec.contract_insert(v_provider, NEW.subscriber_id, NEW.subscriber_name, NEW.subscriber_type_id, NEW.city_id,
                                 NEW.subscriber_address, NEW.subscriber_phone, NEW.contract_no, NEW.connected_on,
                                 NEW.connection_fee, NEW.price_per_mb, NEW.ip_address, NEW.connection_address,
                                 NEW.contact_phone, NEW.contact_person, NEW.note) r;
        -- RETURNING у INSERT в представление возвращает строку, которую вернул триггер: номер, коды, версии
        SELECT * INTO NEW FROM api.v_contract_card v WHERE v.id = v_id;
        RETURN NEW;
    END IF;

    IF OLD.provider_id IS DISTINCT FROM v_provider THEN
        RAISE EXCEPTION 'Договор не найден среди договоров провайдера' USING ERRCODE = '22023';
    END IF;

    IF TG_OP = 'DELETE' THEN
        IF EXISTS (SELECT 1 FROM core.session s WHERE s.contract_id = OLD.id AND s.provider_id = OLD.provider_id) THEN
            RAISE EXCEPTION 'По договору % есть сеансы связи — его нельзя удалить, только расторгнуть', OLD.contract_no
                USING ERRCODE = 'P0001';
        END IF;
        -- версия строки: изменённый с момента чтения договор не удаляется (40001)
        DELETE FROM core.contract c
        WHERE c.id = OLD.id AND c.provider_id = OLD.provider_id AND c.row_version = OLD.row_version;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Договор % изменён или удалён другим пользователем — обновите список', OLD.contract_no
                USING ERRCODE = '40001';
        END IF;
        RETURN OLD;
    END IF;

    -- UPDATE
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.provider_id IS DISTINCT FROM OLD.provider_id
       OR NEW.subscriber_id IS DISTINCT FROM OLD.subscriber_id THEN
        RAISE EXCEPTION 'Провайдер и абонент договора не меняются: расторгните договор и заключите новый'
            USING ERRCODE = 'P0001';
    END IF;
    IF NEW.contract_no IS DISTINCT FROM OLD.contract_no OR NEW.connected_on IS DISTINCT FROM OLD.connected_on
       OR NEW.connection_fee IS DISTINCT FROM OLD.connection_fee THEN
        RAISE EXCEPTION 'Номер договора, дата и стоимость подключения после записи не меняются' USING ERRCODE = 'P0001';
    END IF;

    -- сведения абонента в реестре — только если изменены (права и версия — sec.check_subscriber_edit)
    IF (NEW.subscriber_name, NEW.subscriber_type_id, NEW.city_id, NEW.subscriber_address, NEW.subscriber_phone)
       IS DISTINCT FROM (OLD.subscriber_name, OLD.subscriber_type_id, OLD.city_id, OLD.subscriber_address, OLD.subscriber_phone) THEN
        NEW.subscriber_row_version := sec.subscriber_save(OLD.subscriber_id, NEW.subscriber_row_version, NEW.subscriber_name,
                                                          NEW.subscriber_type_id, NEW.city_id, NEW.subscriber_address,
                                                          NEW.subscriber_phone);
    ELSE
        NEW.subscriber_row_version := OLD.subscriber_row_version;
    END IF;

    -- данные договора — только если изменены; версию проверяет и увеличивает триггер trg_contract_bu_check (080)
    IF (NEW.connection_address, NEW.contact_phone, NEW.contact_person, NEW.price_per_mb, NEW.ip_address,
        NEW.closed_on, NEW.note)
       IS DISTINCT FROM (OLD.connection_address, OLD.contact_phone, OLD.contact_person, OLD.price_per_mb, OLD.ip_address,
                         OLD.closed_on, OLD.note) THEN
        BEGIN
            UPDATE core.contract c
            SET connection_address = NEW.connection_address,
                contact_phone = nullif(btrim(NEW.contact_phone), ''),
                contact_person = nullif(btrim(NEW.contact_person), ''),
                price_per_mb = NEW.price_per_mb,
                ip_address = sec.to_inet(NEW.ip_address),
                closed_on = NEW.closed_on,
                note = nullif(btrim(NEW.note), ''),
                row_version = NEW.row_version
            WHERE c.id = OLD.id AND c.provider_id = OLD.provider_id
            RETURNING c.row_version INTO NEW.row_version;
        EXCEPTION WHEN unique_violation THEN
            RAISE EXCEPTION 'IP-адрес % уже занят действующим договором провайдера', NEW.ip_address USING ERRCODE = '23505';
        END;
    ELSE
        NEW.row_version := OLD.row_version;
    END IF;
    NEW.state := CASE WHEN NEW.closed_on IS NULL THEN 'Действует'
                      ELSE 'Расторгнут ' || to_char(NEW.closed_on, 'DD.MM.YYYY') END;
    RETURN NEW;
END $$;
COMMENT ON FUNCTION sec.trg_contract_card_ioiud() IS
    'Триггерная функция INSTEAD OF представления api.v_contract_card: добавление договора (с абонентом из реестра или новым), изменение договора и сведений абонента, удаление договора без сеансов; только оператор своего провайдера, версия строки (D8, D14, D25)';

DROP TRIGGER IF EXISTS trg_contract_card_ioi ON api.v_contract_card;
CREATE TRIGGER trg_contract_card_ioi INSTEAD OF INSERT ON api.v_contract_card
    FOR EACH ROW EXECUTE FUNCTION sec.trg_contract_card_ioiud();
DROP TRIGGER IF EXISTS trg_contract_card_iou ON api.v_contract_card;
CREATE TRIGGER trg_contract_card_iou INSTEAD OF UPDATE ON api.v_contract_card
    FOR EACH ROW EXECUTE FUNCTION sec.trg_contract_card_ioiud();
DROP TRIGGER IF EXISTS trg_contract_card_iod ON api.v_contract_card;
CREATE TRIGGER trg_contract_card_iod INSTEAD OF DELETE ON api.v_contract_card
    FOR EACH ROW EXECUTE FUNCTION sec.trg_contract_card_ioiud();
COMMENT ON TRIGGER trg_contract_card_ioi ON api.v_contract_card IS 'Новый договор через представление «абонент + договор»';
COMMENT ON TRIGGER trg_contract_card_iou ON api.v_contract_card IS 'Изменение договора и сведений абонента через представление';
COMMENT ON TRIGGER trg_contract_card_iod ON api.v_contract_card IS 'Удаление договора без сеансов через представление';

REVOKE ALL ON FUNCTION sec.trg_contract_card_ioiud() FROM PUBLIC;
REVOKE ALL ON api.v_contract_card FROM PUBLIC;
GRANT SELECT ON api.v_contract_card TO grp_operator, grp_manager, grp_chief;
GRANT INSERT, UPDATE, DELETE ON api.v_contract_card TO grp_operator;
-- представление вызывает функцию от имени пользователя (как v_subscribers — sec.scope_data и др., 057)
GRANT EXECUTE ON FUNCTION sec.subscriber_shared(integer, integer) TO grp_operator, grp_manager, grp_chief;

RESET ROLE;
