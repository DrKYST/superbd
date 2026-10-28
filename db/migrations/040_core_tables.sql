-- 040. Базовые таблицы (core), сотрудники (sec), журнал изменений (audit).
-- Порядок создания: сначала сторона «один» (провайдер, абонент), затем подчинённые (договор, сеанс).
-- Порядок колонок — как на концептуальной схеме docs/diagrams/concept_model.drawio.
-- Проверки с текущей датой и с другими таблицами — триггеры следующего этапа (labs/lab03/spec.md, §3).
SET ROLE app_owner;

CREATE TABLE IF NOT EXISTS core.provider (
    id                integer       GENERATED ALWAYS AS IDENTITY,
    name              ref.d_name    NOT NULL,
    ownership_type_id smallint      NOT NULL,
    city_id           integer       NOT NULL,
    address           ref.d_address NOT NULL,
    phone             ref.d_phone   NOT NULL,
    founded_year      ref.d_year    NOT NULL,
    CONSTRAINT pk_provider PRIMARY KEY (id),
    CONSTRAINT uq_provider_name UNIQUE (name),
    CONSTRAINT fk_provider_ownership_type_id FOREIGN KEY (ownership_type_id)
        REFERENCES ref.ownership_type (id) ON DELETE RESTRICT,
    CONSTRAINT fk_provider_city_id FOREIGN KEY (city_id)
        REFERENCES ref.city (id) ON DELETE RESTRICT
);
COMMENT ON TABLE  core.provider                   IS 'Провайдер — базовая таблица';
COMMENT ON COLUMN core.provider.id                IS 'Код провайдера';
COMMENT ON COLUMN core.provider.name              IS 'Название';
COMMENT ON COLUMN core.provider.ownership_type_id IS 'Код типа собственности';
COMMENT ON COLUMN core.provider.city_id           IS 'Код города';
COMMENT ON COLUMN core.provider.address           IS 'Адрес';
COMMENT ON COLUMN core.provider.phone             IS 'Телефон';
COMMENT ON COLUMN core.provider.founded_year      IS 'Год начала работы';

-- Абонент — общий реестр объединения (D25, вместо D17): один человек или организация — одна запись,
-- сколько бы провайдеров его ни обслуживали. Здесь только то, что не зависит от провайдера:
-- наименование, тип, город, физический (юридический) адрес, основной телефон.
-- Всё, что у разных провайдеров разное (адрес подключения, контактный телефон и лицо, IP, цены), — в договоре.
-- Провайдер видит абонента, пока у него есть договор с этим абонентом (api.*, позже RLS).
-- Дубли отсекает уникальный индекс по наименованию без учёта регистра и цифрам телефона (050).
CREATE TABLE IF NOT EXISTS core.subscriber (
    id                 integer       GENERATED ALWAYS AS IDENTITY,
    name               ref.d_name    NOT NULL,
    city_id            integer       NOT NULL,
    subscriber_type_id smallint      NOT NULL,
    address            ref.d_address NOT NULL,
    phone              ref.d_phone   NOT NULL,
    row_version        integer       NOT NULL DEFAULT 1,
    CONSTRAINT pk_subscriber PRIMARY KEY (id),
    CONSTRAINT fk_subscriber_city_id FOREIGN KEY (city_id)
        REFERENCES ref.city (id) ON DELETE RESTRICT,
    CONSTRAINT fk_subscriber_subscriber_type_id FOREIGN KEY (subscriber_type_id)
        REFERENCES ref.subscriber_type (id) ON DELETE RESTRICT,
    CONSTRAINT ck_subscriber_row_version CHECK (row_version > 0)
);
COMMENT ON TABLE  core.subscriber                    IS 'Абонент — базовая таблица (общий реестр абонентов всех провайдеров, D25)';
COMMENT ON COLUMN core.subscriber.id                 IS 'Код абонента';
COMMENT ON COLUMN core.subscriber.name               IS 'ФИО или название предприятия';
COMMENT ON COLUMN core.subscriber.city_id            IS 'Код города';
COMMENT ON COLUMN core.subscriber.subscriber_type_id IS 'Код типа абонента';
COMMENT ON COLUMN core.subscriber.address            IS 'Физический адрес';
COMMENT ON COLUMN core.subscriber.phone              IS 'Телефон';
COMMENT ON COLUMN core.subscriber.row_version        IS 'Версия строки';

-- Номер договора по умолчанию: «Д-<год>-<6 цифр>» из явной последовательности (D12).
CREATE SEQUENCE IF NOT EXISTS core.contract_no_seq AS integer START 1;
COMMENT ON SEQUENCE core.contract_no_seq IS 'Последовательность номеров договоров (D12)';

-- Договоры секционированы по провайдеру (ЛР 8, D30): у каждого провайдера своя секция — сотрудники провайдера
-- работают с ней (условие provider_id в функциях api отсекает чужие секции), аналитика — с таблицей целиком.
-- Секцию создаёт триггер при регистрации провайдера (042). Первичный ключ секционированной таблицы обязан включать
-- ключ секционирования: (id, provider_id); id по-прежнему выдаёт одна последовательность.
CREATE TABLE IF NOT EXISTS core.contract (
    id             integer           GENERATED ALWAYS AS IDENTITY,
    provider_id    integer           NOT NULL,
    contract_no    ref.d_contract_no NOT NULL
        DEFAULT ('Д-' || to_char(current_date, 'YYYY') || '-' || lpad(nextval('core.contract_no_seq')::text, 6, '0')),
    subscriber_id  integer           NOT NULL,
    connected_on   date              NOT NULL DEFAULT current_date,
    connection_fee ref.d_money       NOT NULL,
    price_per_mb   ref.d_price_mb    NOT NULL,
    ip_address     inet              NOT NULL,
    -- данные подключения у этого провайдера (D25): могут отличаться от сведений абонента в реестре
    connection_address ref.d_address NOT NULL,
    contact_phone  ref.d_phone,
    contact_person ref.d_name,
    closed_on      date,
    note           text,
    row_version    integer           NOT NULL DEFAULT 1,
    CONSTRAINT pk_contract PRIMARY KEY (id, provider_id),
    CONSTRAINT uq_contract_provider_id_contract_no UNIQUE (provider_id, contract_no),
    CONSTRAINT fk_contract_provider_id FOREIGN KEY (provider_id)
        REFERENCES core.provider (id) ON DELETE RESTRICT,
    CONSTRAINT fk_contract_subscriber_id FOREIGN KEY (subscriber_id)
        REFERENCES core.subscriber (id) ON DELETE CASCADE,
    CONSTRAINT ck_contract_closed_after_connected CHECK (closed_on >= connected_on),
    CONSTRAINT ck_contract_row_version CHECK (row_version > 0)
) PARTITION BY LIST (provider_id);
ALTER SEQUENCE core.contract_no_seq OWNED BY core.contract.contract_no;
COMMENT ON TABLE  core.contract                IS 'Договор — таблица пересечения провайдера и абонента (связь M:N) с данными подключения; секционирована по провайдеру (D30)';
COMMENT ON COLUMN core.contract.id             IS 'Код договора';
COMMENT ON COLUMN core.contract.provider_id    IS 'Код провайдера';
COMMENT ON COLUMN core.contract.contract_no    IS 'Номер договора';
COMMENT ON COLUMN core.contract.subscriber_id  IS 'Код абонента';
COMMENT ON COLUMN core.contract.connected_on   IS 'Дата подключения';
COMMENT ON COLUMN core.contract.connection_fee IS 'Стоимость подключения';
COMMENT ON COLUMN core.contract.price_per_mb   IS 'Стоимость 1 Мб';
COMMENT ON COLUMN core.contract.ip_address     IS 'IP-адрес';
COMMENT ON COLUMN core.contract.connection_address IS 'Адрес подключения';
COMMENT ON COLUMN core.contract.contact_phone  IS 'Контактный телефон';
COMMENT ON COLUMN core.contract.contact_person IS 'Контактное лицо';
COMMENT ON COLUMN core.contract.closed_on      IS 'Дата расторжения';
COMMENT ON COLUMN core.contract.note           IS 'Комментарий';
COMMENT ON COLUMN core.contract.row_version    IS 'Версия строки';

-- Сеансы секционированы по времени начала (ЛР 8, D30) в два уровня: год → квартал, плюс секция по умолчанию;
-- секции создаёт sec.session_partitions_ensure (042). PK включает дату — ключ секционирования.
-- discount_pct и cost — снимок на момент сеанса (осознанная денормализация, D3).
-- provider_id — провайдер договора: ключ договора секционирован по провайдеру и состоит из (id, provider_id),
-- поэтому внешний ключ на договор составной; провайдер договора не меняется (D14), значение согласовано ключом.
-- Вставка — только через core.session: в PostgreSQL 16 секции не наследуют identity (с 17 — наследуют).
CREATE TABLE IF NOT EXISTS core.session (
    id           bigint        GENERATED ALWAYS AS IDENTITY,
    started_at   timestamptz   NOT NULL,
    contract_id  integer       NOT NULL,
    provider_id  integer       NOT NULL,
    tariff_id    smallint      NOT NULL,
    volume_mb    ref.d_mb      NOT NULL,
    discount_pct ref.d_percent NOT NULL,
    cost         ref.d_money   NOT NULL,
    CONSTRAINT pk_session PRIMARY KEY (id, started_at),
    CONSTRAINT fk_session_contract_id_provider_id FOREIGN KEY (contract_id, provider_id)
        REFERENCES core.contract (id, provider_id) ON DELETE CASCADE,
    CONSTRAINT fk_session_tariff_id FOREIGN KEY (tariff_id)
        REFERENCES ref.tariff (id) ON DELETE RESTRICT
) PARTITION BY RANGE (started_at);
COMMENT ON TABLE  core.session              IS 'Сеанс связи — базовая таблица; секционирована по времени начала: год → квартал (D30)';
COMMENT ON COLUMN core.session.id           IS 'Код сеанса';
COMMENT ON COLUMN core.session.started_at   IS 'Дата и время сеанса';
COMMENT ON COLUMN core.session.contract_id  IS 'Код договора';
COMMENT ON COLUMN core.session.provider_id  IS 'Код провайдера (провайдер договора)';
COMMENT ON COLUMN core.session.tariff_id    IS 'Код тарифа';
COMMENT ON COLUMN core.session.volume_mb    IS 'Количество Мб';
COMMENT ON COLUMN core.session.discount_pct IS 'Скидка, %';
COMMENT ON COLUMN core.session.cost         IS 'Стоимость сеанса';

-- Сотрудник: привязка LOGIN-роли PostgreSQL к ФИО и провайдеру (D5).
-- Не таблица пользователей: паролей и поля роли здесь нет — пользователи и группы живут
-- в системных pg_authid / pg_auth_members (CREATE ROLE, GRANT). Логин проверяет триггер из 045.
CREATE TABLE IF NOT EXISTS sec.app_user (
    id          integer     GENERATED ALWAYS AS IDENTITY,
    provider_id integer,
    login       ref.d_login NOT NULL,
    full_name   ref.d_name  NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- Сброс пароля (D27): отметка «выдан временный пароль» и кто/когда его выдал. Сам пароль — только в pg_authid.
    reset_pending boolean   NOT NULL DEFAULT false,
    reset_at    timestamptz,
    reset_by    ref.d_login,
    CONSTRAINT pk_app_user PRIMARY KEY (id),
    CONSTRAINT uq_app_user_login UNIQUE (login),
    CONSTRAINT fk_app_user_provider_id FOREIGN KEY (provider_id)
        REFERENCES core.provider (id) ON DELETE RESTRICT
);
COMMENT ON TABLE  sec.app_user             IS 'Сотрудник — служебная таблица (привязка логина PostgreSQL к провайдеру; без паролей и ролей)';
COMMENT ON COLUMN sec.app_user.id          IS 'Код сотрудника';
COMMENT ON COLUMN sec.app_user.provider_id IS 'Код провайдера';
COMMENT ON COLUMN sec.app_user.login       IS 'Логин';
COMMENT ON COLUMN sec.app_user.full_name   IS 'ФИО';
COMMENT ON COLUMN sec.app_user.created_at  IS 'Дата регистрации';
COMMENT ON COLUMN sec.app_user.reset_pending IS 'Выдан временный пароль';      -- до его смены работа недоступна (D27)
COMMENT ON COLUMN sec.app_user.reset_at    IS 'Когда выдан временный пароль';
COMMENT ON COLUMN sec.app_user.reset_by    IS 'Кто выдал временный пароль';  -- логин администратора

-- Журнал изменений (D10): без внешних ключей — записи сохраняются после удаления строк.
CREATE TABLE IF NOT EXISTS audit.change_log (
    id         bigint      GENERATED ALWAYS AS IDENTITY,
    changed_at timestamptz NOT NULL DEFAULT now(),
    db_user    varchar(63) NOT NULL DEFAULT session_user,
    table_name varchar(63) NOT NULL,
    operation  varchar(6)  NOT NULL,
    row_pk     text        NOT NULL,
    old_row    jsonb,
    new_row    jsonb,
    CONSTRAINT pk_change_log PRIMARY KEY (id),
    CONSTRAINT ck_change_log_operation CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE'))
);
COMMENT ON TABLE  audit.change_log            IS 'Журнал изменений — служебная таблица';
COMMENT ON COLUMN audit.change_log.id         IS 'Код записи';
COMMENT ON COLUMN audit.change_log.changed_at IS 'Дата и время изменения';
COMMENT ON COLUMN audit.change_log.db_user    IS 'Пользователь БД';
COMMENT ON COLUMN audit.change_log.table_name IS 'Таблица';
COMMENT ON COLUMN audit.change_log.operation  IS 'Операция';
COMMENT ON COLUMN audit.change_log.row_pk     IS 'Ключ строки';
COMMENT ON COLUMN audit.change_log.old_row    IS 'Строка до изменения';
COMMENT ON COLUMN audit.change_log.new_row    IS 'Строка после изменения';

RESET ROLE;
