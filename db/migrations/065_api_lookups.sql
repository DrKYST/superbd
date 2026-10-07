-- 065. Списки выбора для полей клиента (выпадающие списки «Тип абонента:», «Тариф:»).
-- Справочники в схеме ref группам не выданы, поэтому значения — через функции api.
SET ROLE app_owner;

DROP FUNCTION IF EXISTS api.lookup_subscriber_types();
CREATE OR REPLACE FUNCTION api.lookup_subscriber_types()
RETURNS TABLE (id integer, name text, is_legal boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_operator', 'grp_manager', 'grp_chief']);
    RETURN QUERY SELECT t.id::integer, t.name::text, t.is_legal FROM ref.subscriber_type t ORDER BY t.name;
END $$;
COMMENT ON FUNCTION api.lookup_subscriber_types() IS 'Список выбора «Тип абонента» (отбор абонентов, карточка абонента)';

DROP FUNCTION IF EXISTS api.lookup_tariffs();
CREATE OR REPLACE FUNCTION api.lookup_tariffs()
RETURNS TABLE (id integer, code text, name text, discount_pct numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_operator', 'grp_manager', 'grp_chief']);
    RETURN QUERY SELECT t.id::integer, t.code::text, t.name::text, t.discount_pct::numeric FROM ref.tariff t ORDER BY t.id;
END $$;
COMMENT ON FUNCTION api.lookup_tariffs() IS 'Список выбора «Тариф» (отбор журнала сеансов, регистрация сеанса)';

REVOKE ALL ON FUNCTION api.lookup_subscriber_types(), api.lookup_tariffs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.lookup_subscriber_types(), api.lookup_tariffs()
    TO grp_admin, grp_operator, grp_manager, grp_chief;

RESET ROLE;
