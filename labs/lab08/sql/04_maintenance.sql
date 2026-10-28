-- ЛР 8, шаг 4. Добавление и удаление данных в секционированных таблицах, обслуживание секций.
-- Всё — в транзакциях с ROLLBACK: рабочая база после скрипта та же.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab08/sql/04_maintenance.sql
\set ON_ERROR_STOP on
\ir 00_params.sql
\set ECHO queries

\echo '4.1 Вставка через родительскую таблицу: строка сама попадает в секцию квартала (сеанс) и провайдера (договор)'
BEGIN;
INSERT INTO core.session (started_at, contract_id, provider_id, tariff_id, volume_mb, discount_pct, cost)
SELECT ts, c.id, c.provider_id, t.id, 10, t.discount_pct, round(10 * c.price_per_mb * (1 - t.discount_pct / 100), 2)
FROM core.contract c, ref.tariff t,
     (VALUES (timestamptz '2024-03-15 10:00+03'), (timestamptz '2025-08-01 12:00+03'), (timestamptz '2026-09-30 23:59+03')) v(ts)
WHERE c.id = :q_contract AND c.provider_id = :q_provider AND t.code = 'А'
RETURNING tableoid::regclass AS partition, started_at;
INSERT INTO core.contract (provider_id, subscriber_id, connection_fee, price_per_mb, ip_address, connection_address)
SELECT p.id, s.id, 0, 0.1, ('10.250.0.' || p.id)::inet, s.address
FROM core.provider p CROSS JOIN LATERAL (SELECT * FROM core.subscriber ORDER BY id LIMIT 1) s
WHERE p.name IN ('ДонНет', 'ДонЛинк', 'Горизонт-Нет')
RETURNING tableoid::regclass AS partition, provider_id, contract_no;
ROLLBACK;

\echo '4.2 Регистрация провайдера: триггер создаёт его секцию договоров (D30)'
BEGIN;
INSERT INTO core.provider (name, ownership_type_id, city_id, address, phone, founded_year)
SELECT 'Новый провайдер', ot.id, ci.id, 'ул. Университетская, д. 1', '+7 856 111-22-33', 2026
FROM ref.ownership_type ot, ref.city ci WHERE ot.name = 'ООО' AND ci.name = 'Донецк'
RETURNING id AS new_provider \gset
SELECT c.relname AS partition, pg_get_expr(c.relpartbound, c.oid) AS bound, obj_description(c.oid, 'pg_class') AS comment
FROM pg_class c WHERE c.oid = to_regclass('core.contract_p' || :new_provider);
ROLLBACK;

\echo '4.3 Архивирование года: отсоединение секции 2024 года (DETACH) против удаления строк из обычной таблицы'
BEGIN;
SELECT count(*) AS sessions_2024_before FROM core.session WHERE started_at < '2025-01-01';
SELECT clock_timestamp() AS t0 \gset
ALTER TABLE core.session DETACH PARTITION core.session_2024;
SELECT round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) * 1000, 1) AS detach_ms,
       (SELECT count(*) FROM core.session WHERE started_at < '2025-01-01') AS sessions_2024_in_table,
       (SELECT count(*) FROM core.session_2024) AS rows_in_detached_table;
-- отсоединённая таблица — обычная: её можно выгрузить в архив (pg_dump -t) и удалить
SELECT clock_timestamp() AS t0 \gset
DROP TABLE core.session_2024;
SELECT round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) * 1000, 1) AS drop_ms;
ROLLBACK;
BEGIN;
SELECT clock_timestamp() AS t0 \gset
DELETE FROM lab8.session_plain WHERE started_at < '2025-01-01';
SELECT round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) * 1000, 1) AS plain_delete_ms;
ROLLBACK;

\echo '4.4 Возврат архивного года: ATTACH с готовым CHECK — без проверочного чтения таблицы'
BEGIN;
ALTER TABLE core.session DETACH PARTITION core.session_2024;
ALTER TABLE core.session_2024 ADD CONSTRAINT ck_session_2024_range
    CHECK (started_at >= '2024-01-01 00:00+03' AND started_at < '2025-01-01 00:00+03');
SELECT clock_timestamp() AS t0 \gset
ALTER TABLE core.session ATTACH PARTITION core.session_2024
    FOR VALUES FROM ('2024-01-01 00:00+03') TO ('2025-01-01 00:00+03');
SELECT round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) * 1000, 1) AS attach_ms,
       (SELECT count(*) FROM core.session WHERE started_at < '2025-01-01') AS sessions_2024_back;
ROLLBACK;

\echo '4.5 Удаление договора: каскад удаляет его сеансы во всех секциях'
BEGIN;
SELECT s.tableoid::regclass AS partition, count(*) AS sessions
FROM core.session s WHERE s.contract_id = :q_contract GROUP BY 1 ORDER BY 1;
DELETE FROM core.contract WHERE id = :q_contract AND provider_id = :q_provider;
SELECT count(*) AS sessions_left FROM core.session WHERE contract_id = :q_contract;
ROLLBACK;

\echo '4.6 Секции следующих лет: функция создаёт недостающий год (здесь — через два года) с четырьмя кварталами'
BEGIN;
SELECT * FROM sec.session_partitions_ensure(current_date, (current_date + interval '2 years')::date);
SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound
FROM pg_partition_tree('core.session') t JOIN pg_class c ON c.oid = t.relid
WHERE c.relname LIKE 'session\_' || (extract(year FROM current_date)::int + 2) || '%'
ORDER BY 1;
ROLLBACK;
\set ECHO none
