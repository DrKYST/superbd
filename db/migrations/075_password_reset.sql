-- 075. Сброс пароля: временный пароль и смена при входе (D27, docs/analysis/password-reset.md).
-- Пароли хранит только PostgreSQL (pg_authid, хеш SCRAM): в таблицах проекта временного пароля нет, функция
-- возвращает его один раз. Пока сотрудник не сменил временный пароль (sec.app_user.reset_pending), программа ему
-- недоступна: sec.require_group и область видимости (sec.provider_scope) отказывают с кодом SB001 (055, 057);
-- работают только api.whoami (флаг must_change_password) и api.change_own_password.
-- Кто кому сбрасывает — как при управлении учётными записями (D26): администратор приложения — операторам,
-- руководителям, главным аналитикам; администратор БД — администраторам приложения; себе — нельзя.
-- Журнал сервера: ALTER ROLE выполняется из функции (EXECUTE), такие операторы log_statement не пишет; новый пароль
-- в change_own_password — параметр запроса, его значение не пишется при log_parameter_max_length = 0
-- (docs/server-config.md). ALTER ROLE — последним, после всех проверок: текст оператора с паролем не попадёт
-- в контекст сообщения об ошибке проверки.
SET ROLE app_owner;

-- Временный пароль: 12 символов из алфавита без похожих знаков (нет 0/O, 1/l/I). Источник случайности —
-- gen_random_uuid() (криптостойкий генератор PostgreSQL 13+, без расширений). В UUID версии 4 байты 6 и 8 содержат
-- служебные биты — они пропускаются. Байт берётся, только если он меньше 4 × 54 = 216: остаток от деления на 54
-- тогда распределён равномерно (без смещения в пользу первых символов алфавита).
CREATE OR REPLACE FUNCTION sec.temp_password()
RETURNS text
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_alphabet constant text := 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';   -- 54 символа
    v_bytes bytea;
    v_byte integer;
    v_result text := '';
BEGIN
    WHILE length(v_result) < 12 LOOP
        v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
        FOR i IN 0..15 LOOP
            CONTINUE WHEN i IN (6, 8);
            v_byte := get_byte(v_bytes, i);
            CONTINUE WHEN v_byte >= 216;
            v_result := v_result || substr(v_alphabet, v_byte % 54 + 1, 1);
            EXIT WHEN length(v_result) = 12;
        END LOOP;
    END LOOP;
    RETURN v_result;
END $$;
COMMENT ON FUNCTION sec.temp_password() IS
    'Случайный временный пароль: 12 символов без похожих знаков, источник — gen_random_uuid() (D27)';

-- Выдать временный пароль учётной записи: отметка в строке сотрудника и пароль со сроком сутки.
-- Внутренняя: вызывается из api.user_reset_password и api.user_create после проверки прав; группам не выдаётся.
-- Право входа не меняется: заблокированная учётная запись (NOLOGIN) остаётся заблокированной.
CREATE OR REPLACE FUNCTION sec.issue_temp_password(p_login text)
RETURNS text
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_password text := sec.temp_password();
BEGIN
    UPDATE sec.app_user u
    SET reset_pending = true, reset_at = now(), reset_by = session_user
    WHERE u.login = p_login;
    -- последним: неиспользованный временный пароль сервер перестаёт принимать через сутки
    EXECUTE format('ALTER ROLE %I PASSWORD %L VALID UNTIL %L', p_login, v_password,
                   to_char(now() + interval '1 day', 'YYYY-MM-DD HH24:MI:SSOF'));
    RETURN v_password;
END $$;
COMMENT ON FUNCTION sec.issue_temp_password(text) IS
    'Выдать учётной записи временный пароль на сутки и отметить «нужно сменить» (D27); пароль возвращается, в таблицах не хранится';

-- Сбросить пароль сотруднику управляемой группы (не себе): возвращает временный пароль — один раз — и срок его
-- действия (окно «Временный пароль», строка «Действует до»).
DROP FUNCTION IF EXISTS api.user_reset_password(text);
CREATE OR REPLACE FUNCTION api.user_reset_password(p_login text)
RETURNS TABLE (temp_password text, valid_until timestamptz)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_group text := sec.current_group();
    v_target text := sec.group_of(p_login::name);
    v_password text;
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin', 'grp_dba']);
    IF p_login = session_user THEN
        RAISE EXCEPTION 'Свой пароль меняют через «Сменить пароль»' USING ERRCODE = '22023';
    END IF;
    IF v_target IS NULL OR NOT v_target = ANY (sec.manageable_groups(v_group))
       OR NOT EXISTS (SELECT 1 FROM sec.app_user u WHERE u.login = p_login) THEN
        RAISE EXCEPTION 'Нет прав на учётную запись «%»', p_login USING ERRCODE = '42501';
    END IF;
    v_password := sec.issue_temp_password(p_login);
    RETURN QUERY SELECT v_password, r.rolvaliduntil FROM pg_catalog.pg_roles r WHERE r.rolname = p_login;
END $$;
COMMENT ON FUNCTION api.user_reset_password(text) IS
    'Сброс пароля сотрудника управляемой группы (D26): временный пароль на сутки, смена при входе (D27); пароль возвращается один раз';

-- Сменить свой пароль: после входа с временным паролем и по ссылке «Сменить пароль» начальной страницы.
-- Администратор БД меняет пароль через \password в psql: у app_owner нет права ADMIN на его роль (D26).
-- Правила пароля проверяет сервер: не короче 8 символов, не совпадает с логином.
DROP FUNCTION IF EXISTS api.change_own_password(text);
CREATE OR REPLACE FUNCTION api.change_own_password(p_new text)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- без проверки временного пароля: ради этой функции он и выдан
    PERFORM sec.check_group(ARRAY['grp_admin', 'grp_operator', 'grp_manager', 'grp_chief']);
    IF p_new IS NULL OR length(p_new) < 8 THEN
        RAISE EXCEPTION 'Пароль должен быть не короче 8 символов' USING ERRCODE = '22023';
    END IF;
    IF lower(p_new) = lower(session_user) THEN
        RAISE EXCEPTION 'Пароль не должен совпадать с логином' USING ERRCODE = '22023';
    END IF;
    UPDATE sec.app_user u SET reset_pending = false WHERE u.login = session_user;
    -- последним: после всех проверок
    EXECUTE format('ALTER ROLE %I PASSWORD %L VALID UNTIL %L', session_user, p_new, 'infinity');
END $$;
COMMENT ON FUNCTION api.change_own_password(text) IS
    'Смена своего пароля (в том числе временного, D27): не короче 8 символов, не равен логину; срок действия снимается';

REVOKE ALL ON FUNCTION sec.temp_password(), sec.issue_temp_password(text),
    api.user_reset_password(text), api.change_own_password(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.user_reset_password(text) TO grp_admin, grp_dba;
GRANT EXECUTE ON FUNCTION api.change_own_password(text) TO grp_admin, grp_operator, grp_manager, grp_chief;

RESET ROLE;
