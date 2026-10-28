-- 060. Запросы ЛР 5 — источники данных экранов клиента (docs/analysis/queries-plan.md, D22).
-- Номера запросов (docs/analysis/queries-plan.md):
--   1  сотрудники провайдера                      — внутреннее соединение, условие по внешнему ключу
--   2  сеансы договора                            — внутреннее соединение, условие по внешнему ключу
--   3  сеансы за период (журнал)                  — внутреннее соединение, условие по датам
--   4  договоры, заключённые в периоде            — внутреннее соединение, условие по датам
--   5  провайдеры с типом собственности и городом — внутреннее соединение без условия (представление)
--   6  абоненты с типом и городом                 — внутреннее соединение без условия (представление)
--   7  договоры: полные сведения                  — внутреннее соединение без условия (представление)
--   8  абоненты и договоры, включая без договоров — левое внешнее соединение
--   9  использование тарифов, включая неиспользованные — правое внешнее соединение
--   10 провайдеры с числом договоров              — запрос на запросе (представление 5 ⟕ подзапрос)
-- Списки постраничные: p_limit (до 200), p_offset, колонка total_count; итоги («Итого…») — оконные суммы
-- по всему отбору, считаются до LIMIT.
--
-- Оптимизация (D24; Карпова, гл. 9 — синтаксическая оптимизация; Лузанов — индексы):
--  * Видимость строк — одно условие provider_id = ANY (v_scope), массив считается один раз до запроса
--    (sec.scope_data / sec.scope_providers, 057): форма «столбец ОС константа», по ней работает индекс.
--  * Необязательные отборы (p_… IS NULL OR столбец = p_…) — с plan_cache_mode = force_custom_plan: план строится
--    с фактическими значениями, и планировщик сворачивает условие — для NULL оно исчезает, для значения остаётся
--    «столбец = константа» с индексом. Общий (generic) план такие условия по индексу не выполняет.
--  * Выражения от ввода пользователя (шаблоны поиска) вычисляются один раз в DECLARE, а не для каждой строки.
--  * Отбор строк — до соединения и группировки; группировка — по первичным ключам.
--  * Регулярные выражения не используются: строки разбираются translate(), left(), LIKE по шаблону-префиксу.
--  * Деньги, Мб, скидка в колонках результата — те же домены, что в таблицах (ref.d_money, ref.d_mb, …), без
--    приведения к numeric: клиент получает базовый тип домена (numeric), суммы домена и так numeric.
SET ROLE app_owner;

-- ============================================================================ представления (5, 6, 7)
-- Внутри — только соединение со справочниками; видимость — условием provider_id = ANY (…) с индексом
-- (у оператора читаются только строки его провайдера, а не вся таблица).

-- 5. Провайдеры с типом собственности и городом.
-- Экраны: «Провайдеры» (через запрос 10), «Мой провайдер», выбор провайдера в отчётах и в карточке пользователя.
CREATE OR REPLACE VIEW api.v_providers WITH (security_barrier = true) AS
SELECT p.id,
       p.name::text AS name,
       CASE WHEN ot.name = upper(ot.name) THEN ot.name || ' «' || p.name || '»'
            ELSE '«' || p.name || '»' END AS display_name,
       p.ownership_type_id,
       ot.name::text AS ownership_type,
       p.city_id,
       c.name::text AS city,
       p.address::text AS address,
       p.phone::text AS phone,
       p.founded_year::integer AS founded_year
FROM core.provider p
JOIN ref.ownership_type ot ON ot.id = p.ownership_type_id
JOIN ref.city c ON c.id = p.city_id
-- разграничение доступа (не условие запроса): администратор и аналитик — все, остальные — свой провайдер
WHERE p.id = ANY ((SELECT sec.scope_providers())::integer[]);
COMMENT ON VIEW api.v_providers IS
    'Запрос 5 (ЛР 5). Провайдеры с типом собственности и городом; оператор и руководитель видят только своего провайдера';

-- 6. Абоненты с типом и городом.
-- Экраны: форма выбора абонента (договор), карточка абонента.
-- Реестр абонентов общий (D25): оператору и руководителю виден абонент, у которого есть договор с их провайдером
-- (общий абонент виден каждому своему провайдеру), главному аналитику и администратору — весь реестр, включая абонентов
-- без договоров (администратор ведёт сведения общих абонентов, но договоров и сеансов не видит).
-- can_edit — может ли текущий пользователь менять сведения реестра: администратор — любого абонента; оператор — только
-- если абонента не обслуживает никакой другой провайдер (иначе правка задела бы чужие договоры). Какие провайдеры —
-- не раскрывается.
-- Видимость записана двумя ветвями UNION ALL с условиями-константами (InitPlan, вычисляется один раз): выполняется
-- только ветвь своей роли. Условие «видит всех OR EXISTS (договор)» в одном WHERE планировщик не превращает в
-- полусоединение и проверяет подзапрос для каждой из 8 000 строк (D24); IN в ветви оператора становится полусоединением:
-- договоры провайдера читаются по индексу провайдера, абоненты — по первичному ключу.
CREATE OR REPLACE VIEW api.v_subscribers WITH (security_barrier = true) AS
SELECT s.id,
       s.name::text AS name,
       s.subscriber_type_id,
       st.name::text AS subscriber_type,
       st.is_legal,
       s.city_id,
       c.name::text AS city,
       s.address::text AS address,
       s.phone::text AS phone,
       s.row_version,
       (SELECT sec.current_group()) IS NOT DISTINCT FROM 'grp_admin'
           OR (SELECT sec.current_group()) IS NOT DISTINCT FROM 'grp_operator'
              AND NOT EXISTS (SELECT 1 FROM core.contract x
                              WHERE x.subscriber_id = s.id
                                AND x.provider_id IS DISTINCT FROM (SELECT sec.current_provider_id())) AS can_edit
-- разграничение доступа: аналитик и администратор — весь реестр; остальные — абоненты, с которыми у их провайдера есть договор
FROM (SELECT s0.* FROM core.subscriber s0
      WHERE (SELECT sec.current_group()) IN ('grp_chief', 'grp_admin')
      UNION ALL
      SELECT s0.* FROM core.subscriber s0
      WHERE (SELECT sec.current_group()) NOT IN ('grp_chief', 'grp_admin')
        AND s0.id IN (SELECT v.subscriber_id FROM core.contract v
                      WHERE v.provider_id = ANY ((SELECT sec.scope_data())::integer[]))) s
JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
JOIN ref.city c ON c.id = s.city_id;
COMMENT ON VIEW api.v_subscribers IS
    'Запрос 6 (ЛР 5). Абоненты с типом абонента и городом; видны абоненты, у которых есть договор со своим провайдером (аналитику и администратору — все), can_edit — можно ли менять сведения реестра (D25)';

-- 7. Договоры: полные сведения.
-- Экраны: открытие договора (форма «Договор»), форма выбора договора (сеанс, отбор журнала сеансов).
CREATE OR REPLACE VIEW api.v_contracts WITH (security_barrier = true) AS
SELECT c.id,
       c.contract_no::text AS contract_no,
       c.provider_id,
       CASE WHEN ot.name = upper(ot.name) THEN ot.name || ' «' || p.name || '»'
            ELSE '«' || p.name || '»' END AS provider_name,
       c.subscriber_id,
       s.name::text AS subscriber_name,
       st.name::text AS subscriber_type,
       s.phone::text AS subscriber_phone,
       c.connected_on,
       c.connection_fee,
       c.price_per_mb,
       host(c.ip_address) AS ip_address,
       c.closed_on,
       CASE WHEN c.closed_on IS NULL THEN 'Действует'
            ELSE 'Расторгнут ' || to_char(c.closed_on, 'DD.MM.YYYY') END AS state,
       c.note,
       c.row_version,
       c.connection_address::text AS connection_address,
       c.contact_phone::text AS contact_phone,
       c.contact_person::text AS contact_person
FROM core.contract c
JOIN core.subscriber s ON s.id = c.subscriber_id
JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
JOIN core.provider p ON p.id = c.provider_id
JOIN ref.ownership_type ot ON ot.id = p.ownership_type_id
-- видимость определяет провайдер договора: у общего абонента (D25) каждый провайдер видит только свои договоры
WHERE c.provider_id = ANY ((SELECT sec.scope_data())::integer[]);
COMMENT ON VIEW api.v_contracts IS
    'Запрос 7 (ЛР 5). Договоры с абонентом, типом абонента, провайдером и данными подключения; видны договоры своего провайдера (аналитику — все)';

REVOKE ALL ON api.v_providers, api.v_subscribers, api.v_contracts FROM PUBLIC;
GRANT SELECT ON api.v_providers TO grp_admin, grp_operator, grp_manager, grp_chief;
GRANT SELECT ON api.v_subscribers TO grp_admin, grp_operator, grp_manager, grp_chief;
GRANT SELECT ON api.v_contracts TO grp_operator, grp_manager, grp_chief;

-- ============================================================================ функции (1–4, 8–10)

-- 1. Сотрудники провайдера: учётные записи PostgreSQL (pg_roles) и их группы (pg_auth_members).
-- Экраны: «Провайдеры» → «Сотрудники провайдера «…»» (администратор); «Мой провайдер» (руководитель — только
-- свой провайдер).
DROP FUNCTION IF EXISTS api.q_provider_staff(integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_provider_staff(
    p_provider_id integer,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, login text, full_name text, group_name text, group_title text,
    can_login boolean, valid_until timestamptz, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_scope integer[] := sec.scope_providers(p_provider_id);    -- чужой провайдер — пустой массив
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_manager', 'grp_chief']);
    RETURN QUERY
    SELECT u.id, u.login::text, u.full_name::text, g.rolname::text,
           CASE g.rolname WHEN 'grp_admin' THEN 'Администраторы' WHEN 'grp_operator' THEN 'Операторы'
                          WHEN 'grp_manager' THEN 'Руководители' WHEN 'grp_chief' THEN 'Главные аналитики' END,
           r.rolcanlogin, r.rolvaliduntil,
           count(*) OVER ()
    FROM sec.app_user u
    JOIN pg_catalog.pg_roles r ON r.rolname = u.login
    JOIN pg_catalog.pg_auth_members m ON m.member = r.oid
    JOIN pg_catalog.pg_roles g ON g.oid = m.roleid
                              AND g.rolname IN ('grp_admin', 'grp_operator', 'grp_manager', 'grp_chief')
    WHERE u.provider_id = ANY (v_scope)
    ORDER BY array_position(ARRAY['grp_manager', 'grp_operator'], g.rolname::text), u.full_name
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_provider_staff(integer, integer, integer) IS
    'Запрос 1 (ЛР 5). Сотрудники провайдера: логин, ФИО, группа, вход разрешён — соединение sec.app_user с системными pg_roles и pg_auth_members по коду провайдера';

-- 2. Сеансы договора за период с итогом.
-- Экраны: «Абоненты» → «Сеансы по договору … за …» (Итого); форма «Договор», вкладка «Сеансы».
-- Индекс ix_session_contract_id_started_at: договор и период — одно условие поиска по индексу, строки
-- приходят уже в порядке времени (сортировка не нужна).
DROP FUNCTION IF EXISTS api.q_contract_sessions(integer, date, date, integer, integer);
CREATE OR REPLACE FUNCTION api.q_contract_sessions(
    p_contract_id integer,
    p_from date DEFAULT NULL,
    p_to date DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id bigint, started_at timestamptz, tariff_code text, tariff_name text,
    volume_mb ref.d_mb, discount_pct ref.d_percent, cost ref.d_money,
    total_count bigint, total_volume_mb numeric, total_cost numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_scope integer[] := sec.scope_data();
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator', 'grp_manager', 'grp_chief']);
    RETURN QUERY
    SELECT s.id, s.started_at, t.code::text, t.name::text,
           s.volume_mb, s.discount_pct, s.cost,
           count(*) OVER (), sum(s.volume_mb) OVER (), sum(s.cost) OVER ()
    FROM core.session s
    JOIN core.contract c ON c.id = s.contract_id
    JOIN ref.tariff t ON t.id = s.tariff_id
    WHERE s.contract_id = p_contract_id
      AND c.provider_id = ANY (v_scope)
      AND (p_from IS NULL OR s.started_at >= p_from)
      AND (p_to IS NULL OR s.started_at < p_to + 1)
    ORDER BY s.started_at DESC
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_contract_sessions(integer, date, date, integer, integer) IS
    'Запрос 2 (ЛР 5). Сеансы выбранного договора за период с тарифом, скидкой, стоимостью и итогами (число, Мб, сумма)';

-- 3. Журнал сеансов за период с отбором и итогом.
-- Экраны: «Сеансы связи» (группа «Отбор», строка «Итого за период»); «Сеансов зарегистрировано сегодня».
DROP FUNCTION IF EXISTS api.q_sessions(date, date, integer, text, integer, integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_sessions(
    p_from date,
    p_to date,
    p_contract_id integer DEFAULT NULL,
    p_ip text DEFAULT NULL,
    p_tariff_id integer DEFAULT NULL,
    p_provider_id integer DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id bigint, started_at timestamptz, contract_id integer, contract_no text,
    subscriber_id integer, subscriber_name text, ip_address text,
    tariff_code text, tariff_name text, volume_mb ref.d_mb, discount_pct ref.d_percent,
    price_per_mb ref.d_price_mb, cost ref.d_money,
    total_count bigint, total_volume_mb numeric, total_cost numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_scope integer[] := sec.scope_data(p_provider_id);
    v_ip inet;
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator', 'grp_manager', 'grp_chief']);
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'Укажите период' USING ERRCODE = 'P0001';
    END IF;
    IF p_to < p_from THEN
        RAISE EXCEPTION 'Дата окончания периода раньше даты начала' USING ERRCODE = 'P0001';
    END IF;
    IF nullif(btrim(p_ip), '') IS NOT NULL THEN
        BEGIN
            v_ip := btrim(p_ip)::inet;      -- адрес или подсеть: 10.24.3.17, 10.24.3.0/24
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Неверный IP-адрес: %', p_ip USING ERRCODE = 'P0001';
        END;
    END IF;
    RETURN QUERY
    SELECT s.id, s.started_at, c.id, c.contract_no::text,
           sb.id, sb.name::text, host(c.ip_address),
           t.code::text, t.name::text, s.volume_mb, s.discount_pct,
           c.price_per_mb, s.cost,
           count(*) OVER (), sum(s.volume_mb) OVER (), sum(s.cost) OVER ()
    FROM core.session s
    JOIN core.contract c ON c.id = s.contract_id
    JOIN core.subscriber sb ON sb.id = c.subscriber_id
    JOIN ref.tariff t ON t.id = s.tariff_id
    WHERE s.started_at >= p_from AND s.started_at < p_to + 1
      AND c.provider_id = ANY (v_scope)
      AND (p_contract_id IS NULL OR s.contract_id = p_contract_id)
      AND (v_ip IS NULL OR c.ip_address <<= v_ip)
      AND (p_tariff_id IS NULL OR s.tariff_id = p_tariff_id)
    ORDER BY s.started_at DESC
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_sessions(date, date, integer, text, integer, integer, integer, integer) IS
    'Запрос 3 (ЛР 5). Сеансы за период с договором, абонентом, IP, тарифом и стоимостью; отбор по договору, IP (адрес или подсеть), тарифу; итоги за период';

-- 4. Договоры, заключённые в периоде (и договоры абонента).
-- Экраны: «Договоры» (навигация), «Договоров заключено на этой неделе», «Новых договоров за …»;
-- «Абоненты» → «Договоры абонента «…»» (p_subscriber_id, без периода).
-- Провайдер и период — индекс ix_contract_provider_id_connected_on. Поиск: номер договора хранится в верхнем
-- регистре, поэтому к верхнему регистру приводится шаблон (один раз), а не номер в каждой строке; поиск по IP
-- включается, только если ввод начинается с цифры, — иначе host() для строк не вычисляется.
DROP FUNCTION IF EXISTS api.q_contracts(date, date, integer, boolean, text, integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_contracts(
    p_from date DEFAULT NULL,
    p_to date DEFAULT NULL,
    p_subscriber_id integer DEFAULT NULL,
    p_active_only boolean DEFAULT false,
    p_search text DEFAULT NULL,
    p_provider_id integer DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, contract_no text, provider_name text, subscriber_id integer, subscriber_name text,
    subscriber_type text, connected_on date, connection_fee ref.d_money, price_per_mb ref.d_price_mb,
    ip_address text, closed_on date, state text, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_scope integer[] := sec.scope_data(p_provider_id);
    v_like text := sec.like_prefix(p_search);
    v_no_like text := upper(v_like);
    v_ip_like text := CASE WHEN left(v_like, 1) IN ('0', '1', '2', '3', '4', '5', '6', '7', '8', '9')
                           THEN v_like END;
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator', 'grp_manager', 'grp_chief']);
    RETURN QUERY
    SELECT c.id, c.contract_no::text,
           CASE WHEN ot.name = upper(ot.name) THEN ot.name || ' «' || p.name || '»'
                ELSE '«' || p.name || '»' END,
           s.id, s.name::text, st.name::text,
           c.connected_on, c.connection_fee, c.price_per_mb,
           host(c.ip_address), c.closed_on,
           CASE WHEN c.closed_on IS NULL THEN 'Действует'
                ELSE 'Расторгнут ' || to_char(c.closed_on, 'DD.MM.YYYY') END,
           count(*) OVER ()
    FROM core.contract c
    JOIN core.subscriber s ON s.id = c.subscriber_id
    JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
    JOIN core.provider p ON p.id = c.provider_id
    JOIN ref.ownership_type ot ON ot.id = p.ownership_type_id
    WHERE c.provider_id = ANY (v_scope)          -- у общего абонента (D25) — только договоры видимых провайдеров
      AND (p_from IS NULL OR c.connected_on >= p_from)
      AND (p_to IS NULL OR c.connected_on <= p_to)
      AND (p_subscriber_id IS NULL OR c.subscriber_id = p_subscriber_id)
      AND (NOT p_active_only OR c.closed_on IS NULL)
      AND (v_like IS NULL OR c.contract_no LIKE v_no_like OR lower(s.name) LIKE v_like
           OR host(c.ip_address) LIKE v_ip_like)
    ORDER BY c.connected_on DESC, c.contract_no DESC
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_contracts(date, date, integer, boolean, text, integer, integer, integer) IS
    'Запрос 4 (ЛР 5). Договоры, заключённые в периоде, с абонентом, типом абонента, провайдером и состоянием; отбор по абоненту, действующим, поиску по номеру, наименованию, IP';

-- 8. Абоненты и их договоры, включая абонентов без договоров (левое соединение с договорами).
-- Экран: «Абоненты» — главный список (колонка «Договоров», отбор «Тип абонента», «Только с действующими договорами»).
-- Реестр абонентов общий (D25): оператор и руководитель видят абонентов, у которых есть договор с их провайдером
-- (полусоединение по индексу ix_contract_subscriber_id_provider_id), главный аналитик без отбора по провайдеру — всех,
-- включая абонентов без договоров: для него левое соединение и даёт строки с нулём договоров. Договоры в счётчиках —
-- только видимых провайдеров. Поиск по началу наименования — по индексу uq_subscriber_lower_name_phone_digits.
-- Видимость — две ветви UNION ALL с условием-константой v_all (план строится по фактическим значениям,
-- force_custom_plan): выполняется одна ветвь; в ветви оператора IN становится полусоединением с договорами провайдера
-- (условие «v_all OR EXISTS …» в одном WHERE проверялось бы подзапросом для каждой строки, D24).
-- Группировка — по ключу абонента и выводимым колонкам (у подзапроса нет первичного ключа, функциональная зависимость
-- от него PostgreSQL не выводит), у справочников — по первичным ключам. Поиск по телефону — по цифрам: translate() удаляет из
-- телефона разделители, а из ввода — всё, кроме цифр; шаблон строится один раз.
DROP FUNCTION IF EXISTS api.q_subscribers(integer, boolean, text, integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_subscribers(
    p_type_id integer DEFAULT NULL,
    p_active_only boolean DEFAULT false,
    p_search text DEFAULT NULL,
    p_provider_id integer DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, name text, subscriber_type text, city text, address text, phone text,
    contracts_total bigint, contracts_active bigint, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_scope integer[] := sec.scope_data(p_provider_id);
    v_all boolean := sec.sees_all_data() AND p_provider_id IS NULL;
    v_like text := sec.like_prefix(p_search);
    -- цифры ввода: внутренний translate() даёт все «не цифры» ввода, внешний удаляет их
    v_digits text := translate(p_search, translate(p_search, '0123456789', ''), '');
    v_phone_like text := CASE WHEN length(v_digits) >= 3 THEN '%' || v_digits || '%' END;
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator', 'grp_manager', 'grp_chief']);
    RETURN QUERY
    SELECT s.id, s.name::text, st.name::text, ci.name::text, s.address::text, s.phone::text,
           count(c.id), count(c.id) FILTER (WHERE c.closed_on IS NULL),
           count(*) OVER ()
    FROM (SELECT s0.* FROM core.subscriber s0 WHERE v_all
          UNION ALL
          SELECT s0.* FROM core.subscriber s0
          WHERE NOT v_all
            AND s0.id IN (SELECT v.subscriber_id FROM core.contract v WHERE v.provider_id = ANY (v_scope))) s
    JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
    JOIN ref.city ci ON ci.id = s.city_id
    LEFT JOIN core.contract c ON c.subscriber_id = s.id
                             AND c.provider_id = ANY (v_scope)    -- договоры только видимых провайдеров, по индексу
    WHERE (p_type_id IS NULL OR s.subscriber_type_id = p_type_id)
      AND (v_like IS NULL OR lower(s.name) LIKE v_like
           OR translate(s.phone, '+ ()-', '') LIKE v_phone_like)
    GROUP BY s.id, s.name, s.address, s.phone, st.id, ci.id
    HAVING NOT p_active_only OR count(c.id) FILTER (WHERE c.closed_on IS NULL) > 0
    ORDER BY s.name, s.id
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_subscribers(integer, boolean, text, integer, integer, integer) IS
    'Запрос 8 (ЛР 5). Абоненты с типом, городом и числом договоров видимых провайдеров, у аналитика — включая абонентов без договоров (левое соединение); отбор по типу, действующим договорам, поиску по наименованию и телефону';

-- 9. Использование тарифов за период, включая неиспользованные (правое соединение сеансов с тарифами).
-- Экран: «Статистика» → «Трафик по тарифам», табличная часть (руководитель, главный аналитик).
-- Сеансы периода группируются по тарифу в подзапросе (не больше 10 строк) и только потом соединяются со
-- справочником тарифов — группировка до соединения, а не после. У неиспользованного тарифа правое соединение даёт
-- NULL вместо итогов — coalesce показывает 0 (экран и диаграмма: «0 сеансов», а не пустая ячейка).
DROP FUNCTION IF EXISTS api.q_tariff_usage(date, date, integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_tariff_usage(
    p_from date,
    p_to date,
    p_provider_id integer DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, tariff_code text, tariff_name text, discount_pct ref.d_percent,
    sessions_count bigint, volume_mb numeric, revenue numeric, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_scope integer[] := sec.scope_data(p_provider_id);
BEGIN
    PERFORM sec.require_group(ARRAY['grp_manager', 'grp_chief']);
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'Укажите период' USING ERRCODE = 'P0001';
    END IF;
    RETURN QUERY
    SELECT t.id::integer, t.code::text, t.name::text, t.discount_pct,
           coalesce(u.sessions, 0), coalesce(u.volume_mb, 0), coalesce(u.revenue, 0),
           count(*) OVER ()
    FROM (SELECT s.tariff_id, count(*) AS sessions, sum(s.volume_mb) AS volume_mb, sum(s.cost) AS revenue
          FROM core.session s
          JOIN core.contract c ON c.id = s.contract_id
          WHERE s.started_at >= p_from AND s.started_at < p_to + 1
            AND c.provider_id = ANY (v_scope)
          GROUP BY s.tariff_id) u
    RIGHT JOIN ref.tariff t ON t.id = u.tariff_id
    ORDER BY t.id
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_tariff_usage(date, date, integer, integer, integer) IS
    'Запрос 9 (ЛР 5). Использование тарифов за период: сеансов, Мб, выручка — все тарифы, включая неиспользованные (правое соединение)';

-- 10. Провайдеры с числом договоров: представление 5 ⟕ подзапрос по договорам (запрос на запросе).
-- Экраны: «Провайдеры» (администратор, главный аналитик), колонка «Действующих договоров»; «Мой провайдер»
-- (руководитель — только свой провайдер); «Провайдеры без новых договоров в …» (p_without_new).
-- Подзапрос считает договоры только видимых провайдеров (руководителю — договоры своего, а не всех).
-- Запрос 16 (ЛР 6, подзапрос с NOT IN): отбор «Без сотрудников» (p_without_staff) — провайдеры, которых нет во
-- множестве провайдеров сотрудников; счётчик администратора «Провайдеры без сотрудников» — total_count с этим отбором.
-- Подзапрос не зависит от строки провайдера и вычисляется один раз (hashed SubPlan). Левое соединение с sec.app_user
-- и IS NULL дало бы тот же отбор, но при выключенном флажке размножило бы строки — по строке на сотрудника.
-- Ловушка NOT IN: у администраторов и аналитиков provider_id IS NULL, а «x NOT IN (…, NULL)» никогда не истинно —
-- без условия IS NOT NULL в подзапросе список был бы пуст (тест 12.11).
-- У провайдера без договоров левое соединение даёт NULL вместо чисел — в колонках coalesce показывает 0; в отборе и
-- сортировке NULL разобран явно (k.provider_id IS NULL — договоров нет; NULLS LAST — такие провайдеры в конце).
DROP FUNCTION IF EXISTS api.q_providers(date, date, text, boolean, integer, integer);
DROP FUNCTION IF EXISTS api.q_providers(date, date, text, boolean, boolean, integer, integer);
CREATE OR REPLACE FUNCTION api.q_providers(
    p_from date DEFAULT NULL,
    p_to date DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_without_new boolean DEFAULT false,
    p_without_staff boolean DEFAULT false,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, display_name text, ownership_type text, city text, address text, phone text,
    founded_year integer, contracts_active bigint, contracts_new bigint, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_scope integer[] := sec.scope_providers();
    v_like text := sec.like_prefix(p_search);
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_manager', 'grp_chief']);
    RETURN QUERY
    SELECT v.id, v.display_name, v.ownership_type, v.city, v.address, v.phone, v.founded_year,
           coalesce(k.active, 0), coalesce(k.new_in_period, 0),
           count(*) OVER ()
    FROM api.v_providers v
    LEFT JOIN (
        SELECT c.provider_id,
               count(*) FILTER (WHERE c.closed_on IS NULL) AS active,
               count(*) FILTER (WHERE (p_from IS NULL OR c.connected_on >= p_from)
                                  AND (p_to IS NULL OR c.connected_on <= p_to)) AS new_in_period
        FROM core.contract c
        WHERE c.provider_id = ANY (v_scope)
        GROUP BY c.provider_id) k ON k.provider_id = v.id
    WHERE (v_like IS NULL OR lower(v.name) LIKE v_like)
      AND (NOT p_without_new OR k.provider_id IS NULL OR k.new_in_period = 0)
      AND (NOT p_without_staff
           OR v.id NOT IN (SELECT u.provider_id FROM sec.app_user u WHERE u.provider_id IS NOT NULL))
    ORDER BY k.active DESC NULLS LAST, v.name
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_providers(date, date, text, boolean, boolean, integer, integer) IS
    'Запрос 10 (ЛР 5). Провайдеры (представление v_providers) с числом действующих и новых за период договоров из подзапроса, включая провайдеров без договоров (запрос на запросе, левое соединение); запрос 16 (ЛР 6) — отбор провайдеров без сотрудников (NOT IN)';

-- Права: отзыв у PUBLIC и выдача группам, которым функция нужна на экранах.
REVOKE ALL ON FUNCTION
    api.q_provider_staff(integer, integer, integer),
    api.q_contract_sessions(integer, date, date, integer, integer),
    api.q_sessions(date, date, integer, text, integer, integer, integer, integer),
    api.q_contracts(date, date, integer, boolean, text, integer, integer, integer),
    api.q_subscribers(integer, boolean, text, integer, integer, integer),
    api.q_tariff_usage(date, date, integer, integer, integer),
    api.q_providers(date, date, text, boolean, boolean, integer, integer)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.q_provider_staff(integer, integer, integer) TO grp_admin, grp_manager, grp_chief;
GRANT EXECUTE ON FUNCTION
    api.q_contract_sessions(integer, date, date, integer, integer),
    api.q_sessions(date, date, integer, text, integer, integer, integer, integer),
    api.q_contracts(date, date, integer, boolean, text, integer, integer, integer),
    api.q_subscribers(integer, boolean, text, integer, integer, integer)
TO grp_operator, grp_manager, grp_chief;
GRANT EXECUTE ON FUNCTION api.q_tariff_usage(date, date, integer, integer, integer) TO grp_manager, grp_chief;
GRANT EXECUTE ON FUNCTION api.q_providers(date, date, text, boolean, boolean, integer, integer) TO grp_admin, grp_manager, grp_chief;

RESET ROLE;
