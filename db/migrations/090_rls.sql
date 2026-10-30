-- 090. Защита на уровне строк (ТЗ п. 8; requirements.md, раздел 3; D5, D6, D25, D30).
-- Второй рубеж после условий видимости в функциях api: даже запрос владельца объектов (app_owner — от его имени
-- работают функции SECURITY DEFINER) видит только строки, разрешённые текущему пользователю.
--   * ENABLE + FORCE на core.provider, core.subscriber, core.contract, core.session: FORCE обязателен — без него
--     владелец таблиц, а значит и все функции api, политики обходит (D6).
--   * Политики TO PUBLIC, условия — функции sec.* по session_user: внутри SECURITY DEFINER current_user = app_owner,
--     а session_user — пользователь, вошедший в систему. Политика «TO grp_operator» к app_owner не применилась бы.
--   * Секции (D30) — ENABLE + FORCE без политик: строки видны только через родителя, прямое чтение секции не даёт
--     ничего (запрет по умолчанию).
--   * Политика обслуживания — администратор БД и суперпользователь: функции секций (042) переносят строки через
--     родителя от их имени. Свои резервные копии (pg_dump) администратор БД делает с атрибутом BYPASSRLS (seed 030).
--   * Функции, которым по назначению нужны строки всех провайдеров, принадлежат роли app_rls_bypass (BYPASSRLS, 010):
--     поиск абонента в общем реестре и признак «общий абонент» (D25), счётчики договоров у администратора (запросы 10
--     и 13), проверка удаления провайдера (D9), проверка секции по умолчанию (D30). Доступ в них ограничивает их
--     собственное условие (группа, область видимости), результат — не больше, чем нужно экрану.
-- Внешние ключи и каскадное удаление политики не проверяют (PostgreSQL выполняет их от имени владельца таблицы без FORCE).

-- ============================================================================ функции политик
SET ROLE app_owner;

-- Обслуживание базы: администратор БД (D26) или суперпользователь (сборка, тесты) как session_user.
CREATE OR REPLACE FUNCTION sec.is_maintainer()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sec.current_group() IS NOT DISTINCT FROM 'grp_dba'
        OR EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = session_user AND r.rolsuper)
$$;
COMMENT ON FUNCTION sec.is_maintainer() IS
    'Обслуживает ли базу текущий пользователь: администратор БД или суперпользователь (политики обслуживания, 090)';

-- Есть ли договоры провайдера в секции договоров по умолчанию (sec.contract_partition_ensure, 042). Секция по умолчанию —
-- с защитой без политик, договоры администратору не видны: владелец — app_rls_bypass.
CREATE OR REPLACE FUNCTION sec.contract_default_has(p_provider_id integer)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (SELECT 1 FROM core.contract_default d WHERE d.provider_id = p_provider_id)
$$;
COMMENT ON FUNCTION sec.contract_default_has(integer) IS
    'Есть ли договоры провайдера в секции договоров по умолчанию (D30); видит все строки (владелец app_rls_bypass)';

-- Включить защиту на всех секциях сеансов и договоров (новые секции включают её сами — 042).
CREATE OR REPLACE FUNCTION sec.partitions_rls_ensure()
RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    r record;
    n integer := 0;
BEGIN
    FOR r IN SELECT t.relid
             FROM unnest(ARRAY['core.session'::regclass, 'core.contract'::regclass]) AS root(rel)
             CROSS JOIN LATERAL pg_catalog.pg_partition_tree(root.rel) t
             JOIN pg_catalog.pg_class c ON c.oid = t.relid
             WHERE t.level > 0 AND NOT (c.relrowsecurity AND c.relforcerowsecurity) LOOP
        EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY, FORCE ROW LEVEL SECURITY', r.relid::regclass);
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;
COMMENT ON FUNCTION sec.partitions_rls_ensure() IS
    'Включает ENABLE + FORCE ROW LEVEL SECURITY на секциях сеансов и договоров, где их ещё нет (D30); возвращает число секций';

REVOKE ALL ON FUNCTION sec.is_maintainer(), sec.contract_default_has(integer), sec.partitions_rls_ensure() FROM PUBLIC;
-- функции в условиях политик выполняются от имени того, кто читает таблицу: у групп прав на таблицы нет, но
-- представления и прямое чтение (тест 17.3 с временным GRANT) вычисляют эти условия от имени пользователя
GRANT EXECUTE ON FUNCTION sec.is_maintainer(), sec.sees_all_data(), sec.sees_all_providers(), sec.current_provider_id(),
    sec.current_group(), sec.group_of(name) TO grp_admin, grp_dba, grp_operator, grp_manager, grp_chief;
GRANT EXECUTE ON FUNCTION sec.subscriber_shared(integer, integer) TO grp_admin;
GRANT USAGE ON SCHEMA sec TO grp_dba;

RESET ROLE;

-- ============================================================================ функции с доступом ко всем строкам
-- Смена владельца — от имени суперпользователя (у app_rls_bypass нет права CREATE в схемах). При пересборке
-- (db/build.sql) схемы создаются заново, функции снова создаёт app_owner — и эта миграция снова передаёт их.
GRANT USAGE ON SCHEMA core, ref, sec, api TO app_rls_bypass;
GRANT SELECT ON core.provider, core.subscriber, core.contract, core.session, core.contract_default,
    ref.ownership_type, ref.city, ref.subscriber_type, sec.app_user TO app_rls_bypass;
GRANT SELECT ON api.v_providers TO app_rls_bypass;
GRANT EXECUTE ON FUNCTION sec.require_group(text[]), sec.check_group(text[]), sec.assert_password_changed(),
    sec.current_group(), sec.group_of(name), sec.current_provider_id(), sec.sees_all_providers(), sec.sees_all_data(),
    sec.provider_scope(boolean, integer), sec.scope_providers(integer), sec.scope_data(integer), sec.like_prefix(text)
    TO app_rls_bypass;

ALTER FUNCTION sec.subscriber_find(text, text) OWNER TO app_rls_bypass;
ALTER FUNCTION sec.subscriber_shared(integer, integer) OWNER TO app_rls_bypass;
ALTER FUNCTION sec.contract_default_has(integer) OWNER TO app_rls_bypass;
ALTER FUNCTION sec.trg_provider_bd_check_sessions() OWNER TO app_rls_bypass;
ALTER FUNCTION sec.trg_provider_bd_check_sessions() SECURITY DEFINER;
ALTER FUNCTION api.subscriber_find_exact(text, text) OWNER TO app_rls_bypass;
ALTER FUNCTION api.q_providers(date, date, text, boolean, boolean, integer, integer) OWNER TO app_rls_bypass;
ALTER FUNCTION api.q_shared_subscribers(integer, integer, integer) OWNER TO app_rls_bypass;
-- функциям app_owner, которые вызывают эти функции, нужен EXECUTE (по умолчанию у PUBLIC его нет)
GRANT EXECUTE ON FUNCTION sec.subscriber_find(text, text), sec.subscriber_shared(integer, integer),
    sec.contract_default_has(integer), api.q_providers(date, date, text, boolean, boolean, integer, integer)
    TO app_owner;

-- ============================================================================ защита таблиц и секций
ALTER TABLE core.provider   ENABLE ROW LEVEL SECURITY, FORCE ROW LEVEL SECURITY;
ALTER TABLE core.subscriber ENABLE ROW LEVEL SECURITY, FORCE ROW LEVEL SECURITY;
ALTER TABLE core.contract   ENABLE ROW LEVEL SECURITY, FORCE ROW LEVEL SECURITY;
ALTER TABLE core.session    ENABLE ROW LEVEL SECURITY, FORCE ROW LEVEL SECURITY;
SELECT sec.partitions_rls_ensure() AS partitions_protected \gset

-- ============================================================================ политики
-- Условия — в скалярных подзапросах (SELECT sec.…()): вычисляются один раз на запрос (InitPlan), а не для каждой строки.
-- Чтение и изменение — разными политиками: руководитель и аналитик только читают; несколько разрешающих политик
-- одной команды объединяются по ИЛИ.
SET ROLE app_owner;

-- Провайдер: администратор и аналитик — все карточки, оператор и руководитель — своего провайдера (как api.v_providers);
-- изменяет — администратор приложения.
DROP POLICY IF EXISTS provider_read ON core.provider;
CREATE POLICY provider_read ON core.provider FOR SELECT TO PUBLIC
    USING ((SELECT sec.sees_all_providers()) OR id = (SELECT sec.current_provider_id()));
DROP POLICY IF EXISTS provider_write ON core.provider;
CREATE POLICY provider_write ON core.provider FOR ALL TO PUBLIC
    USING ((SELECT sec.current_group()) = 'grp_admin')
    WITH CHECK ((SELECT sec.current_group()) = 'grp_admin');

-- Абонент (общий реестр, D25): администратор и аналитик — весь реестр; оператор и руководитель — абоненты, с которыми
-- у их провайдера есть договор. Добавляет — оператор (абонент появляется вместе с первым договором и до записи
-- договора ещё ни с кем не связан); изменяет — администратор (любого) и оператор (своего; запрет на общего абонента —
-- в api, sec.check_subscriber_edit); удаляет — оператор своего (каскадом — его договоры и сеансы).
DROP POLICY IF EXISTS subscriber_read ON core.subscriber;
CREATE POLICY subscriber_read ON core.subscriber FOR SELECT TO PUBLIC
    USING ((SELECT sec.current_group()) IN ('grp_admin', 'grp_chief')
           OR id IN (SELECT c.subscriber_id FROM core.contract c WHERE c.provider_id = (SELECT sec.current_provider_id())));
DROP POLICY IF EXISTS subscriber_insert ON core.subscriber;
CREATE POLICY subscriber_insert ON core.subscriber FOR INSERT TO PUBLIC
    WITH CHECK ((SELECT sec.current_group()) = 'grp_operator');
DROP POLICY IF EXISTS subscriber_update ON core.subscriber;
CREATE POLICY subscriber_update ON core.subscriber FOR UPDATE TO PUBLIC
    USING ((SELECT sec.current_group()) = 'grp_admin'
           OR (SELECT sec.current_group()) = 'grp_operator'
              AND id IN (SELECT c.subscriber_id FROM core.contract c WHERE c.provider_id = (SELECT sec.current_provider_id())))
    WITH CHECK ((SELECT sec.current_group()) IN ('grp_admin', 'grp_operator'));
DROP POLICY IF EXISTS subscriber_delete ON core.subscriber;
CREATE POLICY subscriber_delete ON core.subscriber FOR DELETE TO PUBLIC
    USING ((SELECT sec.current_group()) = 'grp_operator'
           AND id IN (SELECT c.subscriber_id FROM core.contract c WHERE c.provider_id = (SELECT sec.current_provider_id())));

-- Договор и сеанс: оператор и руководитель — своего провайдера, аналитик — все, администратор — ничего (D25, D26);
-- изменяет — оператор своего провайдера. У сеанса есть провайдер договора (D30) — условие то же, без соединения.
DROP POLICY IF EXISTS contract_read ON core.contract;
CREATE POLICY contract_read ON core.contract FOR SELECT TO PUBLIC
    USING ((SELECT sec.sees_all_data()) OR provider_id = (SELECT sec.current_provider_id()));
DROP POLICY IF EXISTS contract_write ON core.contract;
CREATE POLICY contract_write ON core.contract FOR ALL TO PUBLIC
    USING ((SELECT sec.current_group()) = 'grp_operator' AND provider_id = (SELECT sec.current_provider_id()))
    WITH CHECK ((SELECT sec.current_group()) = 'grp_operator' AND provider_id = (SELECT sec.current_provider_id()));

DROP POLICY IF EXISTS session_read ON core.session;
CREATE POLICY session_read ON core.session FOR SELECT TO PUBLIC
    USING ((SELECT sec.sees_all_data()) OR provider_id = (SELECT sec.current_provider_id()));
DROP POLICY IF EXISTS session_write ON core.session;
CREATE POLICY session_write ON core.session FOR ALL TO PUBLIC
    USING ((SELECT sec.current_group()) = 'grp_operator' AND provider_id = (SELECT sec.current_provider_id()))
    WITH CHECK ((SELECT sec.current_group()) = 'grp_operator' AND provider_id = (SELECT sec.current_provider_id()));

-- Обслуживание: администратор БД и суперпользователь — все строки (перенос сеансов между секциями, 042).
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['provider', 'subscriber', 'contract', 'session'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON core.%I', t || '_maintain', t);
        EXECUTE format('CREATE POLICY %I ON core.%I FOR ALL TO PUBLIC '
                       'USING ((SELECT sec.is_maintainer())) WITH CHECK ((SELECT sec.is_maintainer()))', t || '_maintain', t);
    END LOOP;
END $$;

COMMENT ON POLICY provider_read ON core.provider IS 'Чтение: администратор и аналитик — все провайдеры, оператор и руководитель — свой';
COMMENT ON POLICY provider_write ON core.provider IS 'Изменение: администратор приложения';
COMMENT ON POLICY subscriber_read ON core.subscriber IS 'Чтение: администратор и аналитик — весь реестр, оператор и руководитель — абоненты с договором своего провайдера (D25)';
COMMENT ON POLICY subscriber_insert ON core.subscriber IS 'Добавление: оператор (абонент появляется вместе с первым договором)';
COMMENT ON POLICY subscriber_update ON core.subscriber IS 'Изменение: администратор — любого абонента, оператор — абонента своего провайдера';
COMMENT ON POLICY subscriber_delete ON core.subscriber IS 'Удаление: оператор — абонента своего провайдера';
COMMENT ON POLICY contract_read ON core.contract IS 'Чтение: аналитик — все, оператор и руководитель — договоры своего провайдера';
COMMENT ON POLICY contract_write ON core.contract IS 'Изменение: оператор — договоры своего провайдера';
COMMENT ON POLICY session_read ON core.session IS 'Чтение: аналитик — все, оператор и руководитель — сеансы своего провайдера';
COMMENT ON POLICY session_write ON core.session IS 'Изменение: оператор — сеансы своего провайдера';
COMMENT ON POLICY provider_maintain ON core.provider IS 'Обслуживание: администратор БД и суперпользователь';
COMMENT ON POLICY subscriber_maintain ON core.subscriber IS 'Обслуживание: администратор БД и суперпользователь';
COMMENT ON POLICY contract_maintain ON core.contract IS 'Обслуживание: администратор БД и суперпользователь';
COMMENT ON POLICY session_maintain ON core.session IS 'Обслуживание: администратор БД и суперпользователь (перенос сеансов между секциями)';

RESET ROLE;
