-- Seed 030. Демо-пользователи системы: по одному-два на группу.
-- Пользователь = LOGIN-роль PostgreSQL (строка pg_authid), группа — членство (строка pg_auth_members).
-- Роли создаются БЕЗ ПАРОЛЯ: пароль студент задаёт сам (\password <логин> в psql или в pgAdmin).
-- Идемпотентно: существующие роли не пересоздаются; каждый логин остаётся ровно в одной группе.

DO $$
DECLARE
    u record;
    g text;
BEGIN
    FOR u IN SELECT * FROM (VALUES
        ('adm_main',   'grp_admin',    'Демо-пользователь: администратор приложения'),
        ('dba_main',   'grp_dba',      'Демо-пользователь: администратор базы данных'),
        ('op_donnet',  'grp_operator', 'Демо-пользователь: оператор провайдера «ДонНет»'),
        ('op_donlink', 'grp_operator', 'Демо-пользователь: оператор провайдера «ДонЛинк»'),
        ('op_donnet2', 'grp_operator', 'Демо-пользователь: второй оператор провайдера «ДонНет»'),
        ('mgr_donnet', 'grp_manager',  'Демо-пользователь: руководитель провайдера «ДонНет»'),
        ('chief_main', 'grp_chief',    'Демо-пользователь: главный аналитик объединения')
    ) AS t(login, grp, note)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = u.login) THEN
            EXECUTE format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT', u.login);
        END IF;
        FOREACH g IN ARRAY ARRAY['grp_admin', 'grp_dba', 'grp_operator', 'grp_manager', 'grp_chief'] LOOP
            IF g <> u.grp AND EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
                                      WHERE m.roleid = g::regrole AND m.member = u.login::regrole) THEN
                EXECUTE format('REVOKE %I FROM %I', g, u.login);
            END IF;
        END LOOP;
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
                       WHERE m.roleid = u.grp::regrole AND m.member = u.login::regrole) THEN
            EXECUTE format('GRANT %I TO %I', u.grp, u.login);
        END IF;
        EXECUTE format('COMMENT ON ROLE %I IS %L', u.login, u.note);
        -- Администратор БД делает резервные копии (pg_dump, D26): таблицы с защитой на уровне строк (FORCE, 090) и их
        -- секции он читает целиком, только если обходит политики. Атрибут BYPASSRLS выдаёт только суперпользователь —
        -- как и саму учётную запись администратора БД; у остальных его нет.
        EXECUTE format('ALTER ROLE %I %s', u.login, CASE WHEN u.grp = 'grp_dba' THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END);
        -- Право управлять учётной записью (блокировка входа, сброс пароля) у функций api, принадлежащих app_owner;
        -- роли, созданные через api.user_create, получают его автоматически (CREATEROLE, PostgreSQL 16+).
        -- Администраторами БД приложение не управляет (их создаёт postgres), а выдать такое право и нельзя:
        -- администратор БД сам входит в app_owner (SET), членство стало бы циклическим.
        IF u.grp <> 'grp_dba' AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
                       WHERE m.roleid = u.login::regrole AND m.member = 'app_owner'::regrole AND m.admin_option) THEN
            EXECUTE format('GRANT %I TO app_owner WITH ADMIN TRUE, INHERIT FALSE, SET FALSE', u.login);
        END IF;
    END LOOP;
END $$;

-- Сотрудники: ФИО и провайдер (NULL — администратор и главный аналитик работают не у провайдера).
INSERT INTO sec.app_user (provider_id, login, full_name)
SELECT p.id, t.login, t.full_name
FROM (VALUES
    ('adm_main',   NULL,      'Кравец Андрей Викторович'),
    ('dba_main',   NULL,      'Тарасенко Виктор Павлович'),
    ('op_donnet',  'ДонНет',  'Лысенко Ирина Олеговна'),
    ('op_donlink', 'ДонЛинк', 'Горбунов Павел Сергеевич'),
    ('op_donnet2', 'ДонНет',  'Бойко Светлана Андреевна'),
    ('mgr_donnet', 'ДонНет',  'Руденко Олег Николаевич'),
    ('chief_main', NULL,      'Белова Наталья Юрьевна')
) AS t(login, provider, full_name)
LEFT JOIN core.provider p ON p.name = t.provider
ON CONFLICT (login) DO UPDATE SET provider_id = EXCLUDED.provider_id, full_name = EXCLUDED.full_name;
