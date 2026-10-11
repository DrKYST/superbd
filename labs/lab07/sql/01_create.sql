-- ЛР 7, шаг 1. Схема lab7 и таблица учётных записей сеансов (документ JSONB).
-- Документ — учётная запись сеанса связи, выгруженная из биллинга провайдера (D29): её присылает сервер
-- доступа (NAS) провайдера, у разных производителей оборудования набор атрибутов разный, поэтому запись
-- хранится целиком, как пришла, а в строку core.session разбирается запросом (05_functions.sql, запрос 5.4).
-- Структура документа — labs/lab07/structure.md, пример — labs/lab07/sample_document.json.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/01_create.sql
-- Идемпотентно: схема lab7 пересоздаётся пустой. Основную базу (core, ref, …) скрипт не меняет.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP SCHEMA IF EXISTS lab7 CASCADE;
-- Владелец — app_owner, как у всех схем проекта (D11); в схеме api функций над lab7 нет:
-- это песочница лабораторной, пользователям приложения она не видна (прав на схему у групп нет).
CREATE SCHEMA lab7 AUTHORIZATION app_owner;
COMMENT ON SCHEMA lab7 IS 'ЛР 7: документно-ориентированное хранение учётных записей сеансов из биллинга (jsonb)';

SET ROLE app_owner;

-- Индексов, кроме первичного ключа, при создании нет: документы загружаются пачкой (02_generate.sql),
-- индексы строятся после загрузки (08_indexes.sql) — так быстрее, и планы «до» и «после» видны отдельно.
CREATE TABLE lab7.session_record (
    id          bigint      GENERATED ALWAYS AS IDENTITY,
    received_at timestamptz NOT NULL DEFAULT now(),
    doc         jsonb       NOT NULL,
    CONSTRAINT pk_session_record PRIMARY KEY (id),
    -- Минимальная проверка структуры: документ — объект с обязательными разделами верхнего уровня.
    -- Значение раздела может быть null (у служебных сеансов наладки NAS договора нет: "contract": null).
    CONSTRAINT ck_session_record_doc CHECK (
        jsonb_typeof(doc) = 'object'
        AND doc ?& ARRAY['source', 'contract', 'session', 'billing', 'attributes', 'events'])
);
COMMENT ON TABLE  lab7.session_record             IS 'Учётная запись сеанса из биллинга провайдера — документ JSONB (ЛР 7, D29)';
COMMENT ON COLUMN lab7.session_record.id          IS 'Код записи';
COMMENT ON COLUMN lab7.session_record.received_at IS 'Когда запись получена из биллинга';
COMMENT ON COLUMN lab7.session_record.doc         IS 'Учётная запись сеанса как пришла: источник (провайдер, NAS), договор, сеанс, тарификация, атрибуты производителя, журнал событий';

RESET ROLE;
RESET client_min_messages;
\echo 'lab7: схема и таблица session_record созданы'
