-- 010. Схемы, группы пользователей, базовые права.
-- Роли кластерные (не удаляются вместе со схемами), поэтому создаются идемпотентно.
-- Выполняется суперпользователем; объекты следующих миграций создаются от имени app_owner.

-- Группы пользователей (NOLOGIN). Пользователь системы — LOGIN-роль, член ровно одной группы.
DO $$
DECLARE
    g text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'app_owner') THEN
        CREATE ROLE app_owner NOLOGIN NOSUPERUSER NOCREATEDB CREATEROLE NOINHERIT;
    END IF;
    -- Владелец немногих функций, которым по назначению нужны строки всех провайдеров (поиск в общем реестре абонентов,
    -- «общий ли абонент», счётчики администратора, проверка удаления провайдера): защита на уровне строк (090) на него
    -- не действует, доступ ограничивает условие самой функции. Входа нет, создать такую роль может только суперпользователь.
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'app_rls_bypass') THEN
        CREATE ROLE app_rls_bypass NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
    FOREACH g IN ARRAY ARRAY['grp_admin', 'grp_dba', 'grp_operator', 'grp_manager', 'grp_chief'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = g) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT', g);
        END IF;
    END LOOP;
END $$;

COMMENT ON ROLE app_rls_bypass IS 'Владелец функций, которым нужны строки всех провайдеров (BYPASSRLS); входа в систему не имеет';
COMMENT ON ROLE grp_admin    IS 'Группа «Администратор приложения»: пользователи (операторы, руководители, аналитики), справочники, провайдеры';
COMMENT ON ROLE grp_dba      IS 'Группа «Администратор БД»: обслуживание базы, резервные копии, журнал изменений, администраторы приложения';
COMMENT ON ROLE grp_operator IS 'Группа «Оператор»: абоненты, договоры и сеансы своего провайдера';
COMMENT ON ROLE grp_manager  IS 'Группа «Руководитель провайдера»: данные и статистика своего провайдера, только чтение';
COMMENT ON ROLE grp_chief    IS 'Группа «Главный аналитик»: сводная статистика по всем провайдерам, только чтение';

-- Доступ к базе: только группам проекта; PUBLIC не может ни подключаться, ни создавать объекты.
DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO grp_admin, grp_dba, grp_operator, grp_manager, grp_chief',
                   current_database());
    EXECUTE format('GRANT CREATE ON DATABASE %I TO app_owner', current_database());
END $$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Схемы проекта принадлежат app_owner.
CREATE SCHEMA IF NOT EXISTS ref   AUTHORIZATION app_owner;
CREATE SCHEMA IF NOT EXISTS core  AUTHORIZATION app_owner;
CREATE SCHEMA IF NOT EXISTS sec   AUTHORIZATION app_owner;
CREATE SCHEMA IF NOT EXISTS audit AUTHORIZATION app_owner;
CREATE SCHEMA IF NOT EXISTS api   AUTHORIZATION app_owner;

COMMENT ON SCHEMA ref   IS 'Справочники и домены';
COMMENT ON SCHEMA core  IS 'Основные таблицы предметной области';
COMMENT ON SCHEMA sec   IS 'Сотрудники и функции разграничения доступа';
COMMENT ON SCHEMA audit IS 'Журнал изменений';
COMMENT ON SCHEMA api   IS 'Интерфейс для клиента: функции и представления';

-- Группы не получают прав на таблицы: только схема api (функции появятся на этапе «роли + api»).
REVOKE ALL ON SCHEMA ref, core, sec, audit, api FROM PUBLIC;
GRANT USAGE ON SCHEMA api TO grp_admin, grp_dba, grp_operator, grp_manager, grp_chief;

-- Разделение администрирования (D26).
-- Администратор БД — не суперпользователь: встроенные роли PostgreSQL дают наблюдение за сервером (pg_monitor),
-- чтение всех таблиц для резервного копирования (pg_read_all_data) и обслуживание (pg_maintain, PostgreSQL 17+:
-- VACUUM, ANALYZE, REINDEX). Изменять данные он не может. Для миграций переключается на владельца объектов
-- командой SET ROLE app_owner: членство без наследования (INHERIT FALSE), поэтому права владельца действуют
-- только после явного SET ROLE, а не в обычном сеансе.
-- app_owner получает право выдавать группы (ADMIN) без членства в них (INHERIT FALSE, SET FALSE): им пользуются
-- функции api.user_create / api.user_set_login, принадлежащие app_owner (CREATEROLE).
DO $$
DECLARE
    g text;
BEGIN
    GRANT pg_monitor, pg_read_all_data TO grp_dba;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'pg_maintain') THEN
        EXECUTE 'GRANT pg_maintain TO grp_dba';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
                   WHERE m.roleid = 'app_owner'::regrole AND m.member = 'grp_dba'::regrole) THEN
        GRANT app_owner TO grp_dba WITH INHERIT FALSE, SET TRUE;
    END IF;
    FOREACH g IN ARRAY ARRAY['grp_admin', 'grp_operator', 'grp_manager', 'grp_chief'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
                       WHERE m.roleid = g::regrole AND m.member = 'app_owner'::regrole AND m.admin_option) THEN
            EXECUTE format('GRANT %I TO app_owner WITH ADMIN TRUE, INHERIT FALSE, SET FALSE', g);
        END IF;
    END LOOP;
END $$;

-- Любая новая функция app_owner по умолчанию недоступна PUBLIC — доступ выдаётся явно GRANT EXECUTE.
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
