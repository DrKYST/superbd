-- 055. Базовые функции разграничения доступа (sec) и api.whoami() — первое, что вызывает клиент после входа.
-- Группа пользователя определяется членством LOGIN-роли в группе PostgreSQL (pg_auth_members),
-- провайдер — по sec.app_user; в обоих случаях по session_user (D6): внутри SECURITY DEFINER
-- current_user = app_owner, а session_user остаётся реальным пользователем.
SET ROLE app_owner;

-- Группа пользователя: grp_admin / grp_dba / grp_operator / grp_manager / grp_chief или NULL.
-- Учитывается только прямое членство (строка pg_auth_members «группа — пользователь»): pg_has_role(…, 'MEMBER')
-- учитывает и косвенное, а администратор БД через SET-членство в app_owner (у которого есть право ADMIN на группы,
-- D26) формально «состоит» во всех группах. Членство только с правом ADMIN (без наследования прав группы —
-- так в группы входит app_owner) членством в группе не считается.
CREATE OR REPLACE FUNCTION sec.group_of(p_login name)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT g.rolname::text
    FROM pg_catalog.pg_auth_members m
    JOIN pg_catalog.pg_roles g ON g.oid = m.roleid
    JOIN pg_catalog.pg_roles u ON u.oid = m.member
    WHERE u.rolname = p_login
      AND m.inherit_option
      AND g.rolname IN ('grp_admin', 'grp_dba', 'grp_operator', 'grp_manager', 'grp_chief')
    ORDER BY array_position(ARRAY['grp_admin', 'grp_dba', 'grp_operator', 'grp_manager', 'grp_chief'], g.rolname::text)
    LIMIT 1
$$;
COMMENT ON FUNCTION sec.group_of(name) IS
    'Группа пользователя по прямому членству в группах проекта; NULL, если не входит ни в одну';

CREATE OR REPLACE FUNCTION sec.current_group()
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sec.group_of(session_user)
$$;
COMMENT ON FUNCTION sec.current_group() IS
    'Группа текущего пользователя (по session_user и членству в группах PostgreSQL); NULL, если пользователь не входит ни в одну группу';

CREATE OR REPLACE FUNCTION sec.in_group(p_group text)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sec.current_group() IS NOT DISTINCT FROM p_group
$$;
COMMENT ON FUNCTION sec.in_group(text) IS 'Входит ли текущий пользователь в указанную группу';

-- Какими группами управляет пользователь группы p_group (создаёт, блокирует).
CREATE OR REPLACE FUNCTION sec.manageable_groups(p_group text)
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE p_group
               WHEN 'grp_admin' THEN ARRAY['grp_operator', 'grp_manager', 'grp_chief']
               WHEN 'grp_dba'   THEN ARRAY['grp_admin']
               ELSE '{}'::text[] END
$$;
COMMENT ON FUNCTION sec.manageable_groups(text) IS
    'Группы, учётными записями которых управляет группа: администратор приложения — оператор, руководитель, главный аналитик; администратор БД — администратор приложения (D26)';

-- Какие группы видны в списке пользователей: управляемые и своя.
CREATE OR REPLACE FUNCTION sec.visible_groups(p_group text)
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE WHEN p_group IN ('grp_admin', 'grp_dba') THEN sec.manageable_groups(p_group) || p_group
                ELSE '{}'::text[] END
$$;
COMMENT ON FUNCTION sec.visible_groups(text) IS 'Группы, пользователи которых видны в списке «Пользователи»: управляемые и своя';

CREATE OR REPLACE FUNCTION sec.group_title(p_group text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE p_group WHEN 'grp_admin'    THEN 'Администраторы приложения'
                        WHEN 'grp_dba'      THEN 'Администраторы БД'
                        WHEN 'grp_operator' THEN 'Операторы'
                        WHEN 'grp_manager'  THEN 'Руководители'
                        WHEN 'grp_chief'    THEN 'Главные аналитики' END
$$;
COMMENT ON FUNCTION sec.group_title(text) IS 'Название группы для интерфейса';

-- Провайдер текущего пользователя (оператор, руководитель); NULL у администратора и главного аналитика.
-- SECURITY DEFINER: вызывается и из представлений api от имени пользователя, у которого нет прав
-- на sec.app_user; сообщает только провайдера самого пользователя.
CREATE OR REPLACE FUNCTION sec.current_provider_id()
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT u.provider_id FROM sec.app_user u WHERE u.login = session_user
$$;
COMMENT ON FUNCTION sec.current_provider_id() IS
    'Код провайдера текущего пользователя по sec.app_user (session_user); NULL, если пользователь не привязан к провайдеру';

-- Проверка группы — первая строка каждой функции api.
CREATE OR REPLACE FUNCTION sec.require_group(p_groups text[])
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_group text := sec.current_group();
BEGIN
    IF v_group IS NULL THEN
        RAISE EXCEPTION 'Нет доступа: учётная запись не входит ни в одну группу пользователей системы'
            USING ERRCODE = '42501';
    END IF;
    IF NOT v_group = ANY (p_groups) THEN
        RAISE EXCEPTION 'Недостаточно прав для этого действия' USING ERRCODE = '42501';
    END IF;
END $$;
COMMENT ON FUNCTION sec.require_group(text[]) IS
    'Прерывает выполнение с ошибкой 42501, если текущий пользователь не входит ни в одну из указанных групп';

-- Сведения о текущем пользователе для построения интерфейса клиента.
-- DROP: при изменении состава колонок CREATE OR REPLACE не срабатывает.
DROP FUNCTION IF EXISTS api.whoami();
CREATE OR REPLACE FUNCTION api.whoami()
RETURNS TABLE (
    login          text,
    full_name      text,
    short_name     text,
    group_name     text,
    role_title     text,
    role_short     text,
    provider_name  text,
    organization   text,
    admin_contact  text,
    database_name  text,
    server_version text,
    server_time    timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_group text := sec.current_group();
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_dba', 'grp_operator', 'grp_manager', 'grp_chief']);
    RETURN QUERY
    SELECT session_user::text,
           u.full_name::text,
           -- «Ковалёва Марина Игоревна» → «Ковалёва М. И.»
           coalesce(split_part(u.full_name, ' ', 1)
                    || coalesce(' ' || nullif(left(split_part(u.full_name, ' ', 2), 1), '') || '.', '')
                    || coalesce(' ' || nullif(left(split_part(u.full_name, ' ', 3), 1), '') || '.', ''),
                    session_user::text),
           v_group,
           CASE v_group WHEN 'grp_admin'    THEN 'Администратор приложения'
                        WHEN 'grp_dba'      THEN 'Администратор базы данных'
                        WHEN 'grp_operator' THEN 'Оператор провайдера'
                        WHEN 'grp_manager'  THEN 'Руководитель провайдера'
                        WHEN 'grp_chief'    THEN 'Главный аналитик объединения' END,
           CASE v_group WHEN 'grp_admin'    THEN 'администратор приложения'
                        WHEN 'grp_dba'      THEN 'администратор БД'
                        WHEN 'grp_operator' THEN 'оператор'
                        WHEN 'grp_manager'  THEN 'руководитель'
                        WHEN 'grp_chief'    THEN 'главный аналитик' END,
           -- Организационно-правовая форма-аббревиатура пишется перед названием: ООО «ДонНет».
           CASE WHEN p.id IS NULL THEN NULL
                WHEN ot.name = upper(ot.name) THEN ot.name || ' «' || p.name || '»'
                ELSE '«' || p.name || '»' END,
           -- «Организация» на начальной странице.
           CASE WHEN v_group IN ('grp_admin', 'grp_dba') THEN 'Объединение провайдеров'
                WHEN v_group = 'grp_chief' THEN 'Все провайдеры объединения ('
                                              || (SELECT count(*) FROM core.provider) || ')'
                ELSE CASE WHEN ot.name = upper(ot.name) THEN ot.name || ' «' || p.name || '»'
                          ELSE '«' || p.name || '»' END END,
           -- Кому обращаться по вопросам доступа: администраторы приложения; им самим — администраторы БД (D26);
           -- себя в списке нет (единственному администратору БД обращаться не к кому — NULL).
           (SELECT string_agg(a.full_name, ', ' ORDER BY a.full_name)
            FROM sec.app_user a
            WHERE sec.group_of(a.login) = CASE WHEN v_group IN ('grp_admin', 'grp_dba') THEN 'grp_dba'
                                               ELSE 'grp_admin' END
              AND a.login <> session_user),
           current_database()::text,
           'PostgreSQL ' || split_part(current_setting('server_version'), ' ', 1),
           now()
    FROM (SELECT 1) AS one
    LEFT JOIN sec.app_user u ON u.login = session_user
    LEFT JOIN core.provider p ON p.id = u.provider_id
    LEFT JOIN ref.ownership_type ot ON ot.id = p.ownership_type_id;
END $$;
COMMENT ON FUNCTION api.whoami() IS
    'Текущий пользователь: логин, ФИО, группа и название роли, провайдер, организация, к кому обращаться по доступу (администраторы приложения; им — администраторы БД), база и версия СУБД, время сервера';

REVOKE ALL ON FUNCTION sec.manageable_groups(text), sec.visible_groups(text), sec.group_title(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.whoami() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.whoami() TO grp_admin, grp_dba, grp_operator, grp_manager, grp_chief;

RESET ROLE;
