-- Создание базы данных проекта и роли-владельца (выполняется один раз, из базы postgres).
-- psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f db/create_db.sql
-- Идемпотентно: существующие база и роль не пересоздаются.
\set ON_ERROR_STOP on

-- Владелец всех объектов проекта: не входит в систему, не суперпользователь, может создавать роли
-- (пользователей системы создаёт администратор через функции, принадлежащие app_owner).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'app_owner') THEN
        CREATE ROLE app_owner NOLOGIN NOSUPERUSER NOCREATEDB CREATEROLE NOINHERIT;
    END IF;
END $$;
COMMENT ON ROLE app_owner IS 'Владелец объектов БД superbd (схемы, таблицы, функции); входа в систему не имеет';

SELECT 'CREATE DATABASE superbd ENCODING ''UTF8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = 'superbd')
\gexec

COMMENT ON DATABASE superbd IS 'Учёт услуг связи интернет-провайдеров (курсовой проект, вариант Б-16)';
