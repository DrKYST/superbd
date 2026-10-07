-- 030. Справочники (сторона «один» для базовых таблиц).
-- Состав и порядок колонок — docs/diagrams/concept_model.yaml; типы — labs/lab02/model.md, разделы 6–7.
SET ROLE app_owner;

CREATE TABLE IF NOT EXISTS ref.ownership_type (
    id   smallint   GENERATED ALWAYS AS IDENTITY,
    name ref.d_name NOT NULL,
    CONSTRAINT pk_ownership_type PRIMARY KEY (id),
    CONSTRAINT uq_ownership_type_name UNIQUE (name)
);
COMMENT ON TABLE  ref.ownership_type      IS 'Тип собственности — справочник';
COMMENT ON COLUMN ref.ownership_type.id   IS 'Код типа собственности';
COMMENT ON COLUMN ref.ownership_type.name IS 'Тип собственности';

CREATE TABLE IF NOT EXISTS ref.city (
    id   integer    GENERATED ALWAYS AS IDENTITY,
    name ref.d_name NOT NULL,
    CONSTRAINT pk_city PRIMARY KEY (id),
    CONSTRAINT uq_city_name UNIQUE (name)
);
COMMENT ON TABLE  ref.city      IS 'Город — справочник';
COMMENT ON COLUMN ref.city.id   IS 'Код города';
COMMENT ON COLUMN ref.city.name IS 'Город';

CREATE TABLE IF NOT EXISTS ref.subscriber_type (
    id       smallint   GENERATED ALWAYS AS IDENTITY,
    name     ref.d_name NOT NULL,
    is_legal boolean    NOT NULL DEFAULT false,
    CONSTRAINT pk_subscriber_type PRIMARY KEY (id),
    CONSTRAINT uq_subscriber_type_name UNIQUE (name)
);
COMMENT ON TABLE  ref.subscriber_type          IS 'Тип абонента — справочник';
COMMENT ON COLUMN ref.subscriber_type.id       IS 'Код типа абонента';
COMMENT ON COLUMN ref.subscriber_type.name     IS 'Тип абонента';
COMMENT ON COLUMN ref.subscriber_type.is_legal IS 'Юридическое лицо';

-- Тариф: окно времени и тип дня необязательны (D13). Обозначение (Б, В, Н, ВД…) — для сетки
-- «Временные зоны» и коротких подписей (D20). Тариф без окна назначается сеансу только явно;
-- окно через полночь задаётся как time_from > time_to (ночной 23:00–09:00).
CREATE TABLE IF NOT EXISTS ref.tariff (
    id           smallint      GENERATED ALWAYS AS IDENTITY,
    code         varchar(3)    NOT NULL,
    name         ref.d_name    NOT NULL,
    discount_pct ref.d_percent NOT NULL DEFAULT 0,
    time_from    time,
    time_to      time,
    is_weekend   boolean,
    description  text,
    CONSTRAINT pk_tariff PRIMARY KEY (id),
    CONSTRAINT uq_tariff_name UNIQUE (name),
    CONSTRAINT uq_tariff_code UNIQUE (code),
    CONSTRAINT ck_tariff_code CHECK (code <> '' AND translate(code, 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ', '') = ''),
    CONSTRAINT ck_tariff_window CHECK ((time_from IS NULL) = (time_to IS NULL))
);
COMMENT ON TABLE  ref.tariff              IS 'Тариф — справочник';
COMMENT ON COLUMN ref.tariff.id           IS 'Код тарифа';
COMMENT ON COLUMN ref.tariff.code         IS 'Обозначение';
COMMENT ON COLUMN ref.tariff.name         IS 'Тариф';
COMMENT ON COLUMN ref.tariff.discount_pct IS 'Скидка, %';
COMMENT ON COLUMN ref.tariff.time_from    IS 'Начало действия';
COMMENT ON COLUMN ref.tariff.time_to      IS 'Окончание действия';
COMMENT ON COLUMN ref.tariff.is_weekend   IS 'Выходные дни';
COMMENT ON COLUMN ref.tariff.description  IS 'Описание';

RESET ROLE;
