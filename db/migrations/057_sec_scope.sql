-- 057. Область видимости данных по провайдеру и экранирование шаблонов поиска.
-- Используются в представлениях и функциях api (ЛР 5 и далее) до появления RLS; RLS станет вторым
-- рубежом с теми же правилами. В представлениях вызываются как (SELECT sec.…())::integer[] — один раз на запрос,
-- в функциях api — при объявлении переменной.
--   оператор, руководитель — только свой провайдер;
--   главный аналитик       — все провайдеры (данные и справочник провайдеров);
--   администратор          — справочник провайдеров и сотрудники, оперативных данных не видит.
SET ROLE app_owner;

CREATE OR REPLACE FUNCTION sec.sees_all_data()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sec.current_group() IS NOT DISTINCT FROM 'grp_chief'
$$;
COMMENT ON FUNCTION sec.sees_all_data() IS
    'Видит ли пользователь абонентов, договоры и сеансы всех провайдеров (главный аналитик)';

CREATE OR REPLACE FUNCTION sec.sees_all_providers()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sec.current_group() IN ('grp_admin', 'grp_chief')
$$;
COMMENT ON FUNCTION sec.sees_all_providers() IS
    'Видит ли пользователь карточки всех провайдеров (администратор, главный аналитик)';

-- Область видимости как массив кодов провайдеров. В запросах — одно условие «столбец = ANY (массив)»:
-- каноническая форма «столбец ОС константа» (массив вычисляется один раз до выполнения запроса), по которой
-- работает индекс на provider_id. Условие вида (видит_всех OR provider_id = свой) индекс не использует —
-- это дизъюнкция с переменной, и планировщик читает таблицу целиком.
-- p_provider_id — отбор по провайдеру из формы: пересекается с областью видимости (чужой — пустой массив).
-- Группа и провайдер пользователя определяются один раз; таблица провайдеров читается, только когда
-- пользователь видит всех (иначе ответ — его провайдер или пустой массив).
-- Внутренняя: вызывается только из scope_data / scope_providers (они SECURITY DEFINER), группам не выдаётся —
-- иначе пользователь мог бы передать p_sees_all = true.
CREATE OR REPLACE FUNCTION sec.provider_scope(p_sees_all boolean, p_provider_id integer)
RETURNS integer[]
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_own integer;
BEGIN
    PERFORM sec.assert_password_changed();      -- представления api не работают, пока не сменён временный пароль (D27)
    IF p_sees_all THEN
        IF p_provider_id IS NOT NULL THEN
            RETURN ARRAY[p_provider_id];
        END IF;
        RETURN ARRAY(SELECT p.id FROM core.provider p ORDER BY p.id);
    END IF;
    v_own := sec.current_provider_id();
    IF v_own IS NULL OR v_own <> coalesce(p_provider_id, v_own) THEN
        RETURN '{}';
    END IF;
    RETURN ARRAY[v_own];
END $$;
COMMENT ON FUNCTION sec.provider_scope(boolean, integer) IS
    'Коды видимых провайдеров: все (или выбранный), если p_sees_all, иначе провайдер пользователя, если он совпадает с выбранным; пустой массив — ничего';

CREATE OR REPLACE FUNCTION sec.scope_data(p_provider_id integer DEFAULT NULL)
RETURNS integer[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sec.provider_scope(sec.sees_all_data(), p_provider_id)
$$;
COMMENT ON FUNCTION sec.scope_data(integer) IS
    'Коды провайдеров, чьих абонентов, договоры и сеансы видит пользователь (оператор и руководитель — свой, главный аналитик — все, администратор — никого), с учётом отбора по провайдеру';

CREATE OR REPLACE FUNCTION sec.scope_providers(p_provider_id integer DEFAULT NULL)
RETURNS integer[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sec.provider_scope(sec.sees_all_providers(), p_provider_id)
$$;
COMMENT ON FUNCTION sec.scope_providers(integer) IS
    'Коды провайдеров, чьи карточки и сотрудников видит пользователь (администратор и главный аналитик — все, оператор и руководитель — свой), с учётом отбора по провайдеру';

-- Шаблон LIKE «начинается с»: служебные символы ввода экранируются, регистр не учитывается.
CREATE OR REPLACE FUNCTION sec.like_prefix(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE WHEN nullif(btrim(p_text), '') IS NULL THEN NULL
                ELSE replace(replace(replace(lower(btrim(p_text)), '\', '\\'), '%', '\%'), '_', '\_') || '%' END
$$;
COMMENT ON FUNCTION sec.like_prefix(text) IS
    'Шаблон поиска «начинается с» для LIKE: экранирует \, %, _ во вводе пользователя, переводит в нижний регистр';

-- Представления api вызывают функции от имени пользователя: группам нужен EXECUTE на то, что используется
-- в представлениях. Функции сообщают только сведения о самом пользователе; sec.group_of (через current_group) —
-- членство в группах, которое и так видно любому пользователю в системном каталоге pg_auth_members.
REVOKE ALL ON FUNCTION sec.sees_all_data(), sec.sees_all_providers(), sec.current_provider_id(),
                       sec.current_group(), sec.group_of(name), sec.like_prefix(text),
                       sec.scope_data(integer), sec.scope_providers(integer), sec.provider_scope(boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.sees_all_data(), sec.sees_all_providers(), sec.current_provider_id(),
                          sec.current_group(), sec.group_of(name), sec.like_prefix(text),
                          sec.scope_data(integer), sec.scope_providers(integer)
    TO grp_admin, grp_operator, grp_manager, grp_chief;
GRANT USAGE ON SCHEMA sec TO grp_admin, grp_operator, grp_manager, grp_chief;
-- Проверка временного пароля (D27) — в представлениях без области видимости (v_user_groups, v_manageable_groups).
GRANT EXECUTE ON FUNCTION sec.assert_password_changed() TO grp_admin, grp_dba;

RESET ROLE;
