-- 050. Индексы.
-- PostgreSQL сам создаёт индексы только для PK и UNIQUE; внешние ключи индексируются вручную
-- (ускоряют соединения и проверку при удалении родителя).
-- core.contract.subscriber_id покрыт ix_contract_subscriber_id_provider_id, core.contract.provider_id —
-- ix_contract_provider_id_connected_on.
-- core.session.contract_id покрыт ix_session_contract_id_started_at.
SET ROLE app_owner;

CREATE INDEX IF NOT EXISTS ix_provider_ownership_type_id   ON core.provider (ownership_type_id);
CREATE INDEX IF NOT EXISTS ix_provider_city_id             ON core.provider (city_id);
CREATE INDEX IF NOT EXISTS ix_subscriber_city_id           ON core.subscriber (city_id);
CREATE INDEX IF NOT EXISTS ix_subscriber_subscriber_type_id ON core.subscriber (subscriber_type_id);
CREATE INDEX IF NOT EXISTS ix_session_tariff_id            ON core.session (tariff_id);
CREATE INDEX IF NOT EXISTS ix_app_user_provider_id         ON sec.app_user (provider_id);

-- Выборки по периоду и по договору.
CREATE INDEX IF NOT EXISTS ix_session_contract_id_started_at ON core.session (contract_id, started_at);
CREATE INDEX IF NOT EXISTS ix_session_started_at            ON core.session (started_at);
-- Договоры провайдера за период: provider_id = … AND connected_on BETWEEN …; главному аналитику (все провайдеры)
-- тот же индекс отдаёт диапазон дат пропуском по первой колонке (Skip Scan, PostgreSQL 18) — провайдеров немного.
CREATE INDEX IF NOT EXISTS ix_contract_provider_id_connected_on ON core.contract (provider_id, connected_on);
-- Журнал изменений за период (экран администратора БД, D26): записи только добавляются, читаются по дате.
CREATE INDEX IF NOT EXISTS ix_change_log_changed_at ON audit.change_log (changed_at);

-- Видимость абонента провайдеру (D25): EXISTS (договор с этим абонентом у провайдера из области видимости) —
-- проверяется только по индексу (index only scan); первая колонка индексирует внешний ключ на абонента.
CREATE INDEX IF NOT EXISTS ix_contract_subscriber_id_provider_id ON core.contract (subscriber_id, provider_id);

-- Один абонент — одна запись реестра (D25): наименование без учёта регистра + цифры телефона
-- («+7 (949) 123-45-67» и «7 949 1234567» — один телефон). Тот же индекс ищет абонента по началу
-- наименования: lower(name) LIKE 'ива%' (класс операторов text_pattern_ops).
CREATE UNIQUE INDEX IF NOT EXISTS uq_subscriber_lower_name_phone_digits
    ON core.subscriber (lower(name) text_pattern_ops, translate(phone, '+ ()-', ''));

-- IP-адрес уникален среди действующих договоров провайдера (D1).
CREATE UNIQUE INDEX IF NOT EXISTS uq_contract_provider_id_ip_address_active
    ON core.contract (provider_id, ip_address) WHERE closed_on IS NULL;

COMMENT ON INDEX core.ix_session_contract_id_started_at IS 'Сеансы договора за период';
COMMENT ON INDEX core.ix_session_started_at IS 'Сеансы за период (ключ секционирования, D30)';
COMMENT ON INDEX core.ix_contract_provider_id_connected_on IS 'Договоры провайдера, заключённые в периоде';
COMMENT ON INDEX audit.ix_change_log_changed_at IS 'Журнал изменений за период';
COMMENT ON INDEX core.ix_contract_subscriber_id_provider_id IS 'Договоры абонента; есть ли у абонента договор с провайдером (видимость абонента, D25)';
COMMENT ON INDEX core.uq_subscriber_lower_name_phone_digits IS 'Абонент в реестре один (наименование без учёта регистра + цифры телефона, D25); поиск по началу наименования';
COMMENT ON INDEX core.uq_contract_provider_id_ip_address_active IS 'IP-адрес уникален среди действующих договоров провайдера (D1)';

RESET ROLE;
