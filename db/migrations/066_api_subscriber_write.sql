-- 066. Общий реестр абонентов (D25): поиск без дублей, договор с новым или существующим абонентом,
-- изменение и удаление абонента, изменение данных подключения в договоре.
-- Договоры — только оператор своего провайдера; сведения реестра — оператор (свой не общий абонент) или администратор.
--
-- Правила:
--   * абонент в реестре один (уникальный индекс: наименование без учёта регистра + цифры телефона);
--   * абонент появляется вместе с первым договором (api.contract_create): отдельно «пустого» абонента оператор не создаёт —
--     иначе запись никому не видна (провайдер видит абонента, пока у него есть договор с ним);
--   * договор с абонентом, которого обслуживает другой провайдер, заключается по точному совпадению наименования
--     и телефона (как в api.subscriber_find_exact) — перебором кодов чужих абонентов увидеть нельзя;
--   * сведения реестра (наименование, тип, город, адрес, телефон) меняет и удаляет оператор, только пока абонента
--     не обслуживает никакой другой провайдер; сведения общего абонента меняет администратор (решение студента) —
--     различающиеся у провайдеров данные (адрес подключения, контактный телефон и лицо) хранятся в договоре и меняются там;
--   * удалить общего абонента нельзя никому: каскадом ушли бы договоры и сеансы других провайдеров;
--   * оптимистическая блокировка по row_version: изменение чужой версии отклоняется.
-- Ошибки: 42501 — нет прав (в том числе общий абонент), 40001 — запись изменена другим пользователем,
-- 23505 — такой абонент или IP-адрес уже есть, 22023 — неверное значение параметра.
SET ROLE app_owner;

-- Внутренняя: текст в IP-адрес с понятной ошибкой.
CREATE OR REPLACE FUNCTION sec.to_inet(p_text text)
RETURNS inet
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_text IS NULL OR btrim(p_text) = '' THEN
        RETURN NULL;
    END IF;
    RETURN btrim(p_text)::inet;
EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Неверный IP-адрес: %', p_text USING ERRCODE = '22023';
END $$;
COMMENT ON FUNCTION sec.to_inet(text) IS 'IP-адрес из текста; неверный адрес — ошибка 22023 с понятным сообщением';

-- Найти абонента реестра по точному наименованию и телефону (форма «Договор (создание)», кнопка выбора абонента).
-- Возвращает не больше одной строки и только то, что оператор и так ввёл, плюс тип и город — чтобы убедиться,
-- что это тот же абонент. Адрес, договоры и провайдеры чужого абонента не раскрываются.
DROP FUNCTION IF EXISTS api.subscriber_find_exact(text, text);
CREATE OR REPLACE FUNCTION api.subscriber_find_exact(p_name text, p_phone text)
RETURNS TABLE (id integer, name text, subscriber_type text, city text, has_own_contract boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_provider integer := sec.current_provider_id();
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator']);
    RETURN QUERY
    SELECT s.id, s.name::text, st.name::text, ci.name::text,
           EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = v_provider)
    FROM core.subscriber s
    JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
    JOIN ref.city ci ON ci.id = s.city_id
    WHERE lower(s.name) = lower(btrim(p_name))
      AND translate(s.phone, '+ ()-', '') = translate(btrim(p_phone), '+ ()-', '');
END $$;
COMMENT ON FUNCTION api.subscriber_find_exact(text, text) IS
    'Абонент реестра с точно таким наименованием (без учёта регистра) и телефоном (по цифрам); has_own_contract — есть ли договор со своим провайдером (D25)';

-- Новый договор своего провайдера.
--   p_subscriber_id задан  — второй и следующие договоры абонента, которого провайдер уже обслуживает;
--   p_subscriber_id = NULL — абонент ищется в реестре по наименованию и телефону: найден — договор заключается
--                            с ним (сведения реестра не меняются), нет — абонент создаётся из p_name … p_phone.
-- Адрес подключения по умолчанию — p_address (адрес, введённый в форме), иначе адрес абонента из реестра.
DROP FUNCTION IF EXISTS api.contract_create(integer, text, integer, integer, text, text, numeric, numeric, text,
                                            text, text, text, date, text);
CREATE OR REPLACE FUNCTION api.contract_create(
    p_subscriber_id integer,
    p_name text,
    p_subscriber_type_id integer,
    p_city_id integer,
    p_address text,
    p_phone text,
    p_connection_fee numeric,
    p_price_per_mb numeric,
    p_ip_address text,
    p_connection_address text DEFAULT NULL,
    p_contact_phone text DEFAULT NULL,
    p_contact_person text DEFAULT NULL,
    p_connected_on date DEFAULT NULL,
    p_note text DEFAULT NULL)
RETURNS TABLE (contract_id integer, contract_no text, subscriber_id integer, subscriber_created boolean)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_provider integer := sec.current_provider_id();
    v_sub integer;
    v_sub_address text;
    v_created boolean := false;
    v_ip inet := sec.to_inet(p_ip_address);
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator']);
    IF v_provider IS NULL THEN
        RAISE EXCEPTION 'Учётная запись не привязана к провайдеру' USING ERRCODE = '42501';
    END IF;
    IF v_ip IS NULL THEN
        RAISE EXCEPTION 'Не указан IP-адрес' USING ERRCODE = '22023';
    END IF;

    IF p_subscriber_id IS NOT NULL THEN
        -- только свой абонент: чужого по коду не выбрать
        SELECT s.id, s.address INTO v_sub, v_sub_address
        FROM core.subscriber s
        WHERE s.id = p_subscriber_id
          AND EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = v_provider)
        FOR KEY SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Абонент не найден среди абонентов провайдера' USING ERRCODE = '22023';
        END IF;
    ELSE
        IF coalesce(btrim(p_name), '') = '' OR coalesce(btrim(p_phone), '') = '' THEN
            RAISE EXCEPTION 'Укажите наименование и телефон абонента' USING ERRCODE = '22023';
        END IF;
        SELECT s.id, s.address INTO v_sub, v_sub_address
        FROM core.subscriber s
        WHERE lower(s.name) = lower(btrim(p_name))
          AND translate(s.phone, '+ ()-', '') = translate(btrim(p_phone), '+ ()-', '')
        FOR KEY SHARE;
        IF NOT FOUND THEN
            BEGIN
                INSERT INTO core.subscriber (name, city_id, subscriber_type_id, address, phone)
                VALUES (btrim(p_name), p_city_id, p_subscriber_type_id, p_address, btrim(p_phone))
                RETURNING id, address INTO v_sub, v_sub_address;
                v_created := true;
            EXCEPTION WHEN unique_violation THEN
                -- тот же абонент создан параллельно другим оператором — берём его
                SELECT s.id, s.address INTO STRICT v_sub, v_sub_address
                FROM core.subscriber s
                WHERE lower(s.name) = lower(btrim(p_name))
                  AND translate(s.phone, '+ ()-', '') = translate(btrim(p_phone), '+ ()-', '');
            WHEN not_null_violation THEN
                RAISE EXCEPTION 'Для нового абонента укажите тип, город и адрес' USING ERRCODE = '22023';
            END;
        END IF;
    END IF;

    BEGIN
        RETURN QUERY
        INSERT INTO core.contract AS c (provider_id, subscriber_id, connected_on, connection_fee, price_per_mb,
                                        ip_address, connection_address, contact_phone, contact_person, note)
        VALUES (v_provider, v_sub, coalesce(p_connected_on, current_date), p_connection_fee, p_price_per_mb, v_ip,
                coalesce(nullif(btrim(p_connection_address), ''), nullif(btrim(p_address), ''), v_sub_address),
                nullif(btrim(p_contact_phone), ''), nullif(btrim(p_contact_person), ''), nullif(btrim(p_note), ''))
        RETURNING c.id, c.contract_no::text, c.subscriber_id, v_created;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'IP-адрес % уже занят действующим договором провайдера', host(v_ip) USING ERRCODE = '23505';
    END;
END $$;
COMMENT ON FUNCTION api.contract_create(integer, text, integer, integer, text, text, numeric, numeric, text,
                                        text, text, text, date, text) IS
    'Новый договор своего провайдера с абонентом: своим (по коду) или из реестра по наименованию и телефону; если такого нет — абонент создаётся (D25)';

-- Изменить сведения реестра. Строка абонента блокируется FOR UPDATE до проверки «нет чужих договоров»: договор
-- другого провайдера ставит на абонента FOR KEY SHARE (внешний ключ) и ждёт конца этой транзакции, а проверка
-- (отдельный оператор — новый снимок данных) видит уже зафиксированные договоры.
DROP FUNCTION IF EXISTS api.subscriber_update(integer, integer, text, integer, integer, text, text);
CREATE OR REPLACE FUNCTION api.subscriber_update(
    p_id integer,
    p_row_version integer,
    p_name text,
    p_subscriber_type_id integer,
    p_city_id integer,
    p_address text,
    p_phone text)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_version integer;
BEGIN
    PERFORM sec.check_subscriber_edit(p_id, p_row_version, false);
    UPDATE core.subscriber
    SET name = btrim(p_name), subscriber_type_id = p_subscriber_type_id, city_id = p_city_id,
        address = p_address, phone = btrim(p_phone), row_version = row_version + 1
    WHERE id = p_id
    RETURNING row_version INTO v_version;
    RETURN v_version;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'В реестре уже есть абонент с таким наименованием и телефоном' USING ERRCODE = '23505';
END $$;
COMMENT ON FUNCTION api.subscriber_update(integer, integer, text, integer, integer, text, text) IS
    'Изменение сведений абонента в реестре: администратор — любого, оператор — своего, если абонента не обслуживают другие провайдеры (D25); возвращает новую версию строки';

DROP FUNCTION IF EXISTS api.subscriber_delete(integer, integer);
CREATE OR REPLACE FUNCTION api.subscriber_delete(p_id integer, p_row_version integer)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM sec.check_subscriber_edit(p_id, p_row_version, true);
    DELETE FROM core.subscriber WHERE id = p_id;   -- договоры и сеансы — каскадно (D9), все они свои
END $$;
COMMENT ON FUNCTION api.subscriber_delete(integer, integer) IS
    'Удаление абонента вместе с его договорами и сеансами; только оператор и только если абонента не обслуживают другие провайдеры (D25)';

-- Общая проверка для изменения (p_delete = false) и удаления абонента. Блокирует строку абонента до конца транзакции.
--   администратор — изменение любого абонента реестра (удаление — нет);
--   оператор      — свой абонент (есть договор со своим провайдером), договоров других провайдеров нет;
--   у всех        — версия строки совпадает с прочитанной.
-- Вызывается только из api.subscriber_update / _delete.
CREATE OR REPLACE FUNCTION sec.check_subscriber_edit(p_id integer, p_row_version integer, p_delete boolean)
RETURNS void
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_group text := sec.current_group();
    v_provider integer := sec.current_provider_id();
    v_version integer;
BEGIN
    IF p_delete OR v_group IS DISTINCT FROM 'grp_admin' THEN
        PERFORM sec.require_group(ARRAY['grp_operator']);
    END IF;
    SELECT s.row_version INTO v_version FROM core.subscriber s WHERE s.id = p_id FOR UPDATE;
    IF NOT FOUND
       OR v_group = 'grp_operator'
          AND NOT EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = p_id AND c.provider_id = v_provider) THEN
        RAISE EXCEPTION 'Абонент не найден' USING ERRCODE = '22023';
    END IF;
    IF v_group = 'grp_operator'
       AND EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = p_id AND c.provider_id <> v_provider) THEN
        IF p_delete THEN
            RAISE EXCEPTION 'Абонента обслуживают и другие провайдеры: удалить его нельзя' USING ERRCODE = '42501';
        END IF;
        RAISE EXCEPTION 'Абонента обслуживают и другие провайдеры: сведения реестра меняет администратор'
            USING ERRCODE = '42501',
                  HINT = 'Адрес подключения, контактный телефон и контактное лицо меняются в договоре';
    END IF;
    IF v_version IS DISTINCT FROM p_row_version THEN
        RAISE EXCEPTION 'Абонент изменён другим пользователем — обновите карточку' USING ERRCODE = '40001';
    END IF;
END $$;
COMMENT ON FUNCTION sec.check_subscriber_edit(integer, integer, boolean) IS
    'Проверка перед изменением или удалением абонента: администратор меняет любого; оператор — своего, если нет договоров других провайдеров; версия строки совпадает (D25)';

-- Изменить договор своего провайдера: данные подключения, цену, IP, расторжение, комментарий.
-- Версия строки (D8): в row_version записывается прочитанная клиентом версия — триггер trg_contract_bu_check (080)
-- сравнивает её с версией в базе (конфликт — 40001) и ставит следующую; одновременное изменение тоже отклоняется:
-- второе ждёт блокировку строки, затем триггер видит новую версию.
DROP FUNCTION IF EXISTS api.contract_update(integer, integer, text, text, text, numeric, text, date, text);
CREATE OR REPLACE FUNCTION api.contract_update(
    p_id integer,
    p_row_version integer,
    p_connection_address text,
    p_contact_phone text,
    p_contact_person text,
    p_price_per_mb numeric,
    p_ip_address text,
    p_closed_on date DEFAULT NULL,
    p_note text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_provider integer := sec.current_provider_id();
    v_ip inet := sec.to_inet(p_ip_address);
    v_version integer;
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator']);
    UPDATE core.contract
    SET connection_address = p_connection_address,
        contact_phone = nullif(btrim(p_contact_phone), ''),
        contact_person = nullif(btrim(p_contact_person), ''),
        price_per_mb = p_price_per_mb,
        ip_address = v_ip,
        closed_on = p_closed_on,
        note = nullif(btrim(p_note), ''),
        row_version = p_row_version                -- проверку и следующую версию даёт триггер (D8)
    WHERE id = p_id AND provider_id = v_provider
    RETURNING row_version INTO v_version;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Договор не найден среди договоров провайдера' USING ERRCODE = '22023';
    END IF;
    RETURN v_version;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'IP-адрес % уже занят действующим договором провайдера', host(v_ip) USING ERRCODE = '23505';
END $$;
COMMENT ON FUNCTION api.contract_update(integer, integer, text, text, text, numeric, text, date, text) IS
    'Изменение договора своего провайдера (адрес подключения, контакты, цена 1 Мб, IP, расторжение, комментарий); возвращает новую версию строки';

REVOKE ALL ON FUNCTION sec.to_inet(text), sec.check_subscriber_edit(integer, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.subscriber_find_exact(text, text),
    api.contract_create(integer, text, integer, integer, text, text, numeric, numeric, text, text, text, text, date, text),
    api.subscriber_update(integer, integer, text, integer, integer, text, text),
    api.subscriber_delete(integer, integer),
    api.contract_update(integer, integer, text, text, text, numeric, text, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.subscriber_find_exact(text, text),
    api.contract_create(integer, text, integer, integer, text, text, numeric, numeric, text, text, text, text, date, text),
    api.subscriber_update(integer, integer, text, integer, integer, text, text),
    api.subscriber_delete(integer, integer),
    api.contract_update(integer, integer, text, text, text, numeric, text, date, text) TO grp_operator;
GRANT EXECUTE ON FUNCTION api.subscriber_update(integer, integer, text, integer, integer, text, text) TO grp_admin;

RESET ROLE;
