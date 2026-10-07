-- Общие помощники тестов (подключаются из run_all.sql первыми).
-- Результаты копятся во временной таблице; итог в конце run_all.sql: при любом FAIL — ошибка,
-- и psql с ON_ERROR_STOP=1 завершается с ненулевым кодом.
SET client_min_messages = warning;
DROP TABLE IF EXISTS pg_temp.test_result;
SET client_min_messages = notice;
CREATE TEMP TABLE test_result (
    n      serial,
    name   text    NOT NULL,
    ok     boolean NOT NULL,
    detail text
);

CREATE OR REPLACE FUNCTION pg_temp.check(p_name text, p_ok boolean, p_detail text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO pg_temp.test_result (name, ok, detail) VALUES (p_name, coalesce(p_ok, false), p_detail);
    RAISE NOTICE '% %', CASE WHEN coalesce(p_ok, false) THEN 'PASS' ELSE 'FAIL' END,
        p_name || coalesce(' — ' || p_detail, '');
END $$;

-- Приводится ли значение к домену ref.<p_domain> (проверка ограничения домена).
CREATE OR REPLACE FUNCTION pg_temp.casts_to(p_value text, p_domain text)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('SELECT %L::ref.%I', p_value, p_domain);
    RETURN true;
EXCEPTION WHEN check_violation OR string_data_right_truncation THEN
    RETURN false;
END $$;
