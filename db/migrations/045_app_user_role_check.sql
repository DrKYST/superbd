-- 045. Связь R10 «Пользователь — Сотрудник»: логин сотрудника должен быть LOGIN-ролью PostgreSQL.
-- Внешний ключ на системный каталог pg_authid поставить нельзя, поэтому проверка — триггером.
SET ROLE app_owner;

CREATE OR REPLACE FUNCTION sec.trg_app_user_biu_check_role()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r
                   WHERE r.rolname = NEW.login AND r.rolcanlogin) THEN
        RAISE EXCEPTION 'Учётная запись «%» не найдена: сначала создайте пользователя PostgreSQL с правом входа', NEW.login
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END $$;
COMMENT ON FUNCTION sec.trg_app_user_biu_check_role() IS
    'Триггерная функция: логин сотрудника должен существовать в pg_roles и иметь право входа (связь R10)';

DROP TRIGGER IF EXISTS trg_app_user_biu_check_role ON sec.app_user;
CREATE TRIGGER trg_app_user_biu_check_role
    BEFORE INSERT OR UPDATE OF login ON sec.app_user
    FOR EACH ROW EXECUTE FUNCTION sec.trg_app_user_biu_check_role();
COMMENT ON TRIGGER trg_app_user_biu_check_role ON sec.app_user IS
    'Проверка, что логин сотрудника — существующая LOGIN-роль PostgreSQL';

RESET ROLE;
