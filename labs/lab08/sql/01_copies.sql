-- ЛР 8, шаг 1. Стенд сравнения: обычные (несекционированные) копии рабочих таблиц курсовой.
-- Секционированные таблицы — сами рабочие (D30): core.session — по диапазону (год → квартал), core.contract — по списку
-- провайдеров; их создают миграции 040 и 042 при сборке базы. Здесь — только копии для сравнения в планах: те же
-- колонки, ограничения, индексы и данные, но одной таблицей. В курсовую копии не переносятся.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab08/sql/01_copies.sql
-- Идемпотентно: схема lab8 пересоздаётся.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP SCHEMA IF EXISTS lab8 CASCADE;
CREATE SCHEMA lab8 AUTHORIZATION app_owner;
COMMENT ON SCHEMA lab8 IS 'ЛР 8: обычные таблицы-копии сеансов и договоров для сравнения с секционированными core.session и core.contract';

SET ROLE app_owner;

-- LIKE … INCLUDING DEFAULTS INCLUDING CONSTRAINTS: колонки, NOT NULL, проверки; без identity — строки копируются
-- с теми же кодами. Первичные ключи и индексы — те же, что у секционированных таблиц (050), но обычные.
CREATE TABLE lab8.contract_plain (LIKE core.contract INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
CREATE TABLE lab8.session_plain  (LIKE core.session  INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
COMMENT ON TABLE lab8.contract_plain IS 'Договор — обычная таблица-копия core.contract (без секций)';
COMMENT ON TABLE lab8.session_plain  IS 'Сеанс связи — обычная таблица-копия core.session (без секций)';

INSERT INTO lab8.contract_plain SELECT * FROM core.contract ORDER BY id;
INSERT INTO lab8.session_plain  SELECT * FROM core.session ORDER BY started_at;   -- как при загрузке: по времени

ALTER TABLE lab8.contract_plain ADD CONSTRAINT pk_contract_plain PRIMARY KEY (id, provider_id),
    ADD CONSTRAINT uq_contract_plain_provider_id_contract_no UNIQUE (provider_id, contract_no);
CREATE INDEX ix_contract_plain_provider_id_connected_on ON lab8.contract_plain (provider_id, connected_on);
CREATE INDEX ix_contract_plain_subscriber_id_provider_id ON lab8.contract_plain (subscriber_id, provider_id);
CREATE UNIQUE INDEX uq_contract_plain_provider_id_ip_address_active
    ON lab8.contract_plain (provider_id, ip_address) WHERE closed_on IS NULL;

ALTER TABLE lab8.session_plain ADD CONSTRAINT pk_session_plain PRIMARY KEY (id, started_at),
    ADD CONSTRAINT fk_session_plain_contract FOREIGN KEY (contract_id, provider_id)
        REFERENCES lab8.contract_plain (id, provider_id) ON DELETE CASCADE;
CREATE INDEX ix_session_plain_contract_id_started_at ON lab8.session_plain (contract_id, started_at);
CREATE INDEX ix_session_plain_started_at ON lab8.session_plain (started_at);
CREATE INDEX ix_session_plain_tariff_id ON lab8.session_plain (tariff_id);

RESET ROLE;
VACUUM (ANALYZE) lab8.contract_plain;
VACUUM (ANALYZE) lab8.session_plain;
ANALYZE core.session;          -- статистика секционированной таблицы целиком (автоочистка её не собирает)
ANALYZE core.contract;
RESET client_min_messages;

SELECT 'core.session (секции)' AS table_name, count(*) AS rows FROM core.session
UNION ALL SELECT 'lab8.session_plain', count(*) FROM lab8.session_plain
UNION ALL SELECT 'core.contract (секции)', count(*) FROM core.contract
UNION ALL SELECT 'lab8.contract_plain', count(*) FROM lab8.contract_plain;
