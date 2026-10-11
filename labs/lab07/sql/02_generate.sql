-- ЛР 7, шаг 2. Генерация учётных записей сеансов из данных курсовой (core.*, ref.*) — не меньше 100 000 документов.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/02_generate.sql
-- Источники:
--   * каждый сеанс core.session → учётная запись: договор, провайдер, тариф, объём, скидка и стоимость — из core/ref,
--     остальное (узел доступа NAS, длительность, причина завершения, трафик по направлениям, пакеты, атрибуты
--     производителя, журнал событий) достраивается так, как его прислал бы NAS;
--   * generate_series: 400 служебных сеансов наладки NAS (без договора) и 1 200 неудачных подключений (без трафика) —
--     в учёт они не идут и удаляются в 07_delete.sql.
-- Узлы доступа (NAS) — 1–3 у провайдера, производители: MikroTik, Cisco, Juniper, Huawei, Accel-PPP (программный
-- сервер доступа на Linux). У каждого производителя свой набор атрибутов (раздел attributes) — ради этого и JSONB (D29).
-- Результат повторяем: setseed, один поток выполнения, случайные величины считаются в порядке кода сеанса.
-- Идемпотентно: таблица очищается и заполняется заново.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET TimeZone = 'Europe/Moscow';            -- D19: время в документах — местное, со смещением +03:00
SET max_parallel_workers_per_gather = 0;   -- порядок вызовов random() не зависит от параллельных процессов
DO $$ BEGIN PERFORM setseed(0.29); END $$;

TRUNCATE lab7.session_record RESTART IDENTITY;

-- ---------------------------------------------------------------- узлы доступа (NAS) провайдеров
-- Первый узел стоит в офисе провайдера (адрес провайдера), остальные — в других городах региона.
DROP TABLE IF EXISTS pg_temp.nas;
CREATE TEMP TABLE nas AS
WITH vendor(no, vendor, models) AS (VALUES
        (0, 'MikroTik',  ARRAY['CCR2116-12G-4S+', 'CCR2004-1G-12S+2XS', 'CCR1036-8G-2S+']),
        (1, 'Cisco',     ARRAY['ASR1001-X', 'ASR1002-HX']),
        (2, 'Juniper',   ARRAY['MX204', 'MX240']),
        (3, 'Huawei',    ARRAY['NetEngine 8000 M8', 'ME60-X8']),
        (4, 'Accel-PPP', ARRAY['Supermicro SYS-5019C-M', 'HPE ProLiant DL360 Gen10'])),
     city AS (SELECT array_agg(name::text ORDER BY id) AS names FROM ref.city),
     street AS (SELECT ARRAY['ул. Артёма', 'пр. Ильича', 'ул. Университетская', 'бул. Шевченко', 'ул. Постышева',
                             'пр. Мира', 'ул. Щорса', 'ул. Горького', 'ул. Садовая', 'пр. Ленинский'] AS names)
SELECT p.id AS provider_id, p.name::text AS provider_name, pc.name::text AS provider_city,
       n AS nas_no,
       format('bras%s-%s', lpad(p.id::text, 2, '0'), n) AS nas_name,
       v.vendor,
       v.models[1 + (p.id + n) % cardinality(v.models)] AS model,
       format('172.16.%s.%s', p.id, n) AS nas_ip,
       CASE WHEN n = 1 THEN pc.name::text
            ELSE city.names[1 + (p.id * 5 + n * 7) % cardinality(city.names)] END AS city,
       CASE WHEN n = 1 THEN p.address::text
            ELSE street.names[1 + (p.id * 7 + n * 3) % cardinality(street.names)] || ', д. '
                 || (10 + (p.id * 13 + n * 17) % 140) END AS address,
       1 + p.id % 3 AS nas_count
FROM core.provider p
JOIN ref.city pc ON pc.id = p.city_id
CROSS JOIN city
CROSS JOIN street
CROSS JOIN LATERAL generate_series(1, 1 + p.id % 3) n
JOIN vendor v ON v.no = (p.id * 3 + n) % 5;
CREATE UNIQUE INDEX ON nas (provider_id, nas_no);
ANALYZE nas;

-- Тариф по времени начала (D2, D13): окно времени и тип дня; окно через полночь — time_from > time_to.
CREATE OR REPLACE FUNCTION pg_temp.tariff_at(p_at timestamptz) RETURNS smallint
    LANGUAGE sql STABLE AS $f$
    SELECT tr.id FROM ref.tariff tr
    WHERE tr.time_from IS NOT NULL
      AND tr.is_weekend = (extract(isodow FROM p_at) IN (6, 7))
      AND CASE WHEN tr.time_from < tr.time_to
               THEN p_at::time >= tr.time_from AND p_at::time < tr.time_to
               ELSE p_at::time >= tr.time_from OR p_at::time < tr.time_to END $f$;

-- Время в документе — ISO 8601 с точностью до секунды и смещением (+03:00), как его передаёт NAS.
CREATE OR REPLACE FUNCTION pg_temp.iso(p_at timestamptz) RETURNS text
    LANGUAGE sql STABLE AS $f$ SELECT to_char(p_at, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM') $f$;

-- ---------------------------------------------------------------- учётные записи
WITH base AS MATERIALIZED (
    -- 1) сеансы курсовой
    SELECT 1 AS kind, se.id AS key, c.provider_id, c.id AS contract_id, c.contract_no::text AS contract_no,
           host(c.ip_address) AS ip, c.price_per_mb::numeric AS price_per_mb,
           date_trunc('second', se.started_at) AS started_at, se.volume_mb::numeric AS volume_mb,
           se.tariff_id, se.discount_pct::numeric AS discount_pct, se.cost::numeric AS cost,
           NULL::double precision AS r_kind
    FROM core.session se
    JOIN core.contract c ON c.id = se.contract_id
    UNION ALL
    -- 2) служебные сеансы наладки NAS: договора нет, тариф «Служебный» (не оплачивается)
    SELECT 2, g, 1 + g % 30, NULL, NULL, NULL, NULL,
           date_trunc('second', timestamptz '2024-01-10 00:00'
                      + random() * (current_date - date '2024-01-10' - 1) * interval '1 day'),
           round((0.5 + random() * 20)::numeric, 3),
           (SELECT id FROM ref.tariff WHERE code = 'С'), 100, 0, random()
    FROM generate_series(1, 400) g
    UNION ALL
    -- 3) неудачные подключения: договор есть, трафика нет (NAS завершил сеанс ошибкой через 0–3 с)
    SELECT 3, f.g, c.provider_id, c.id, c.contract_no::text, host(c.ip_address), c.price_per_mb::numeric,
           f.started_at, 0, pg_temp.tariff_at(f.started_at),
           (SELECT tr.discount_pct FROM ref.tariff tr WHERE tr.id = pg_temp.tariff_at(f.started_at)), 0, f.r_kind
    FROM (SELECT g, ids.ids[1 + floor(random() * cardinality(ids.ids))::int] AS contract_id,
                 random() AS r_t, random() AS r_kind
          FROM generate_series(1, 1200) g,
               (SELECT array_agg(id ORDER BY id) AS ids FROM core.contract) ids) f0
    JOIN core.contract c ON c.id = f0.contract_id
    CROSS JOIN LATERAL (SELECT f0.g, f0.r_kind,
                               date_trunc('second', c.connected_on::timestamptz
                                   + f0.r_t * (coalesce(c.closed_on + 1, current_date)::timestamptz
                                               - c.connected_on::timestamptz)) AS started_at) f
    ORDER BY 1, 2),
r AS MATERIALIZED (
    SELECT b.*,
           random() AS r_share,    -- доля входящего трафика
           random() AS r_dur,      -- секунд на мегабайт
           random() AS r_cause,    -- причина завершения
           random() AS r_debt,     -- абонент-должник: переадресация на страницу оплаты
           random() AS r_pk,       -- размер пакетов
           random() AS r_lost,     -- NAS не прислал промежуточные обновления
           random() AS r_null      -- атрибут не заполнен (null)
    FROM base b),
x AS (
    SELECT r.*, n.nas_name, n.vendor, n.model, n.nas_ip, n.city AS nas_city, n.address AS nas_address,
           n.provider_name, n.provider_city,
           t.code AS tariff_code, t.name::text AS tariff_name, t.time_from, t.time_to, t.is_weekend,
           -- скорость тарифного плана (Мбит/с), VLAN и MAC-адрес оборудования абонента — постоянны для договора
           (ARRAY[20, 50, 100, 200, 500])[1 + ((hashint4(coalesce(r.contract_id, 0))::bigint + 2147483648) % 5)::int] AS speed,
           100 + coalesce(r.contract_id, r.key) % 3900 AS vlan,
           upper(concat_ws(':', substr(m.h, 1, 2), substr(m.h, 3, 2), substr(m.h, 5, 2),
                                substr(m.h, 7, 2), substr(m.h, 9, 2), substr(m.h, 11, 2))) AS mac,
           round(r.volume_mb * (0.75 + 0.2 * r.r_share)::numeric, 3) AS in_mb,      -- входящий (к абоненту)
           CASE r.kind WHEN 1 THEN greatest(30, round(r.volume_mb * (2 + 18 * r.r_dur)::numeric))::int
                       WHEN 2 THEN (30 + 570 * r.r_dur)::int
                       ELSE (3 * r.r_dur)::int END AS duration_s,
           CASE WHEN r.kind = 2 THEN 'admin_reset'
                WHEN r.kind = 3 THEN CASE WHEN r.r_kind < 0.6 THEN 'nas_error' ELSE 'service_unavailable' END
                WHEN r.r_cause < 0.55 THEN 'user_request'
                WHEN r.r_cause < 0.72 THEN 'idle_timeout'
                WHEN r.r_cause < 0.86 THEN 'lost_carrier'
                WHEN r.r_cause < 0.93 THEN 'port_error'
                WHEN r.r_cause < 0.97 THEN 'admin_reset'
                ELSE 'nas_reboot' END AS stop_cause
    FROM r
    JOIN nas n ON n.provider_id = r.provider_id
              AND n.nas_no = 1 + ((hashint4(coalesce(r.contract_id, r.key::integer))::bigint + 2147483648) % n.nas_count)::int
    JOIN ref.tariff t ON t.id = r.tariff_id
    CROSS JOIN LATERAL (SELECT md5('mac' || coalesce(r.contract_id, -r.key)) AS h) m),
y AS (
    SELECT x.*,
           x.volume_mb - x.in_mb AS out_mb,
           x.started_at + x.duration_s * interval '1 second' AS stopped_at,
           CASE WHEN x.kind = 1 THEN 'd' || translate(lower(x.contract_no), 'д-', '')
                ELSE 'test-' || x.nas_name END AS user_name,
           -- Acct-Session-Id: уникален в пределах провайдера (у служебных и неудачных — свой диапазон)
           upper(lpad(to_hex(2175729664 + x.kind * 50000000 + x.key), 8, '0')) AS acct_id
    FROM x)
INSERT INTO lab7.session_record (received_at, doc)
SELECT date_trunc('hour', y.stopped_at) + interval '1 hour 5 minutes',      -- биллинг выгружает записи раз в час
       jsonb_build_object(
           'source', jsonb_build_object(
               'provider', jsonb_build_object('name', y.provider_name, 'city', y.provider_city),
               'nas', jsonb_build_object(
                   'name', y.nas_name, 'vendor', y.vendor, 'model', y.model, 'ip', y.nas_ip,
                   'location', jsonb_build_object('city', y.nas_city, 'address', y.nas_address))),
           'contract', CASE WHEN y.contract_id IS NULL THEN 'null'::jsonb
                            ELSE jsonb_build_object('number', y.contract_no, 'ip', y.ip) END,
           'session', jsonb_build_object(
               'acct_id', y.acct_id,
               'user_name', y.user_name,
               'started_at', pg_temp.iso(y.started_at),
               'stopped_at', pg_temp.iso(y.stopped_at),
               'duration_s', y.duration_s,
               'stop_cause', y.stop_cause,
               'traffic', jsonb_build_object(
                   'in',  jsonb_build_object('mb', y.in_mb,
                                             'packets', round(y.in_mb * (700 + 100 * y.r_pk))::bigint),
                   'out', jsonb_build_object('mb', y.out_mb,
                                             'packets', round(y.out_mb * 1500 + y.in_mb * (700 + 100 * y.r_pk) * 0.3)::bigint))),
           'billing', jsonb_build_object(
               'tariff', jsonb_build_object(
                   'code', y.tariff_code, 'name', y.tariff_name,
                   'window', CASE WHEN y.time_from IS NULL THEN 'null'::jsonb
                                  ELSE jsonb_build_object('from', to_char(y.time_from, 'HH24:MI'),
                                                          'to', to_char(y.time_to, 'HH24:MI')) END,
                   'weekend', y.is_weekend),
               'price_per_mb', y.price_per_mb,
               'discount_pct', y.discount_pct,
               'cost', y.cost),
           'attributes', a.attributes,
           'events', ev.events)
FROM y
CROSS JOIN LATERAL (
    SELECT CASE y.vendor
               WHEN 'MikroTik' THEN jsonb_build_object(
                   'rate_limit', y.speed || 'M/' || y.speed || 'M',
                   'framed_pool', 'pool-' || y.nas_name,
                   'calling_station_id', y.mac)
                   || CASE WHEN y.r_debt < 0.015 THEN '{"address_list": "debtors"}'::jsonb ELSE '{}' END
               WHEN 'Cisco' THEN jsonb_build_object(
                   'av_pairs', jsonb_build_array('subscriber:sa=internet-' || y.speed || 'm', 'ip:vrf-id=INET',
                                                 'accounting-list=default'),
                   'nas_port_id', 'Gi0/0/1.' || y.vlan,
                   'calling_station_id', y.mac)
               WHEN 'Juniper' THEN jsonb_build_object(
                   'service_activate', 'internet(' || y.speed || 'm)',
                   'ingress_policy', 'in-' || y.speed || 'm',
                   'primary_dns', '172.16.0.53',
                   'calling_station_id', y.mac)
               WHEN 'Huawei' THEN jsonb_build_object(
                   'input_peak_rate_kbps', y.speed * 1024,
                   'output_peak_rate_kbps', y.speed * 1024,
                   'domain_name', CASE WHEN y.r_null < 0.3 THEN NULL ELSE 'isp' || y.provider_id END,
                   'calling_station_id', y.mac)
               ELSE jsonb_build_object(                                   -- Accel-PPP
                   'nas_port_id', 'ens1f0.' || y.vlan,
                   'framed_protocol', 'ppp',
                   'downstream_limit_kbps', y.speed * 1000,
                   'upstream_limit_kbps', y.speed * 500,
                   'framed_pool', CASE WHEN y.r_null < 0.5 THEN NULL ELSE 'pool-' || y.nas_name END,
                   'calling_station_id', y.mac)
           END
           -- должник: у MikroTik — список адресов (выше), у остальных — адрес страницы оплаты
           || CASE WHEN y.r_debt < 0.015 AND y.vendor <> 'MikroTik'
                   THEN '{"redirect_url": "http://10.255.255.1/pay"}'::jsonb ELSE '{}' END
           -- Class — служебная метка сервера авторизации (RADIUS), её возвращают NAS провайдеров с чётным кодом
           || CASE WHEN y.provider_id % 2 = 0
                   THEN jsonb_build_object('class', 'AUTH-' || upper(substr(md5('class' || y.kind || '-' || y.key), 1, 16)))
                   ELSE '{}' END AS attributes) a
CROSS JOIN LATERAL (
    -- Журнал событий: start, промежуточные обновления раз в час (не больше трёх; накопленный трафик), stop.
    SELECT jsonb_agg(e.ev ORDER BY e.ord) AS events
    FROM (SELECT 0 AS ord, jsonb_build_object('at', pg_temp.iso(y.started_at), 'type', 'start') AS ev
          UNION ALL
          SELECT k, jsonb_build_object(
                     'at', pg_temp.iso(y.started_at + k * interval '1 hour'),
                     'type', 'interim',
                     'in_mb', round(y.in_mb * k * 3600 / y.duration_s, 3),
                     'out_mb', round(y.out_mb * k * 3600 / y.duration_s, 3))
          FROM generate_series(1, least(y.duration_s / 3600, 3)) k
          WHERE y.r_lost >= 0.03                                     -- у 3 % записей обновления потеряны
          UNION ALL
          SELECT 99, jsonb_build_object('at', pg_temp.iso(y.stopped_at), 'type', 'stop', 'cause', y.stop_cause)) e
    ) ev
ORDER BY y.stopped_at, y.kind, y.key;                                -- записи приходят в порядке завершения сеансов

ANALYZE lab7.session_record;
DROP TABLE pg_temp.nas;
RESET max_parallel_workers_per_gather;
RESET TimeZone;
RESET client_min_messages;

SELECT count(*) AS documents,
       count(*) FILTER (WHERE doc -> 'contract' = 'null') AS service_test,
       count(*) FILTER (WHERE doc @> '{"session": {"traffic": {"in": {"mb": 0}, "out": {"mb": 0}}}}') AS failed,
       pg_size_pretty(pg_total_relation_size('lab7.session_record')) AS table_size,
       round(avg(pg_column_size(doc))) AS avg_doc_bytes,
       max(pg_column_size(doc)) AS max_doc_bytes
FROM lab7.session_record;

-- Глубина вложенности: пути четвёртого уровня есть в документах (у тарифов без окна времени window = null).
SELECT count(*) FILTER (WHERE doc @? '$.source.nas.location.city')  AS depth4_nas_location,
       count(*) FILTER (WHERE doc @? '$.session.traffic.in.mb')     AS depth4_traffic,
       count(*) FILTER (WHERE doc @? '$.billing.tariff.window.from') AS depth4_tariff_window,
       min((doc #>> '{session,started_at}')::timestamptz)::date     AS first_session,
       max((doc #>> '{session,started_at}')::timestamptz)::date     AS last_session
FROM lab7.session_record;
