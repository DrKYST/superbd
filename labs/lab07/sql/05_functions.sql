-- ЛР 7, шаг 5. Запросы с функциями обработки JSON.
-- jsonb_array_elements (элементы массива строками), jsonb_to_record / jsonb_to_recordset (объект → строка
-- с заданными колонками), jsonb_object_keys (ключи объекта), jsonb_each_text (пары ключ — значение),
-- jsonb_populate_record (объект → строка существующего типа, здесь — строка таблицы core.session),
-- jsonb_build_object, jsonb_agg, jsonb_object_agg (сборка документа из строк), jsonb_pretty.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/05_functions.sql
\set ON_ERROR_STOP on
\ir 00_params.sql

-- @q 5.1_events_table | Функции: jsonb_array_elements WITH ORDINALITY, jsonb_to_record | Оператор разбирает жалобу на обрыв: журнал событий трёх последних сеансов договора таблицей — когда пришли старт, промежуточные обновления (накопленный трафик) и завершение с причиной
SELECT r.doc #>> '{session,acct_id}'  AS acct_id,
       a.ord,
       e.at, e.type, e.in_mb, e.out_mb, e.cause
FROM (SELECT doc FROM lab7.session_record
      WHERE doc @> :'q_contract_doc'
      ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
      LIMIT 3) r
CROSS JOIN LATERAL jsonb_array_elements(r.doc -> 'events') WITH ORDINALITY AS a(ev, ord)
CROSS JOIN LATERAL jsonb_to_record(a.ev) AS e(at timestamptz, type text, in_mb numeric, out_mb numeric, cause text)
ORDER BY e.at DESC, a.ord DESC;

-- @q 5.2_vendor_keys | Функции: jsonb_object_keys | Разработчик разборщика выгрузок: какие атрибуты присылает оборудование каждого производителя и в какой доле записей — чтобы знать, какие ключи ждать от нового NAS (набор у производителей разный — причина хранить запись в JSONB)
-- @note нужны все записи таблицы — индекс не нужен
WITH v AS (
    SELECT doc #>> '{source,nas,vendor}' AS vendor, doc -> 'attributes' AS attrs
    FROM lab7.session_record)
SELECT v.vendor, k.key AS attribute, count(*) AS records, round(100.0 * count(*) / t.total, 1) AS pct
FROM v
CROSS JOIN LATERAL jsonb_object_keys(v.attrs) AS k(key)
JOIN (SELECT vendor, count(*) AS total FROM v GROUP BY vendor) t ON t.vendor = v.vendor
GROUP BY v.vendor, k.key, t.total
ORDER BY v.vendor, records DESC, attribute;

-- @q 5.3_attr_card | Функции: jsonb_each_text, jsonb_typeof | Инженер нашёл в журнале NAS идентификатор сеанса (Acct-Session-Id) и смотрит все атрибуты этого сеанса парами «ключ — значение» с типом JSON
SELECT a.key, a.value, jsonb_typeof(r.doc -> 'attributes' -> a.key) AS json_type
FROM lab7.session_record r
CROSS JOIN LATERAL jsonb_each_text(r.doc -> 'attributes') AS a
WHERE r.doc #>> '{source,provider,name}' = :'q_provider'
  AND r.doc #>> '{session,acct_id}' = :'q_acct'
ORDER BY a.key;

-- @q 5.4_populate_session | Функции: jsonb_populate_record в тип строки core.session, || , jsonb_build_object | Загрузка выгрузки биллинга в курсовую: учётная запись разбирается в строку таблицы core.session (код договора и тарифа — по номеру договора и обозначению тарифа, объём — сумма направлений); предпросмотр для договора из жалобы
SELECT s.contract_id, s.started_at, s.tariff_id, s.volume_mb, s.discount_pct, s.cost,
       c.contract_no, t.code AS tariff_code
FROM lab7.session_record r
JOIN core.provider p ON p.name = r.doc #>> '{source,provider,name}'
JOIN core.contract c ON c.provider_id = p.id AND c.contract_no = r.doc #>> '{contract,number}'
JOIN ref.tariff t ON t.code = r.doc #>> '{billing,tariff,code}'
CROSS JOIN LATERAL jsonb_populate_record(NULL::core.session,
        (r.doc -> 'session') || (r.doc -> 'billing')                 -- started_at; discount_pct, cost
        || jsonb_build_object('contract_id', c.id, 'tariff_id', t.id,
                              'volume_mb', (r.doc #>> '{session,traffic,in,mb}')::numeric
                                         + (r.doc #>> '{session,traffic,out,mb}')::numeric)) AS s
WHERE r.doc @> :'q_contract_doc'
  AND NOT r.doc @@ '$.session.traffic.in.mb == 0 && $.session.traffic.out.mb == 0'   -- без трафика: d_mb > 0
ORDER BY s.started_at DESC
LIMIT 10;

-- @q 5.5_reconcile | Функции: jsonb_populate_record (все записи), сверка с core.session | Сверка выгрузки с учётом курсовой: каждая учётная запись с трафиком, разобранная в строку core.session, совпадает с сеансом курсовой (договор, начало, тариф, объём, стоимость); служебные (без договора) и неудачные (без трафика) в сеансы не превращаются
-- @note сверяются все записи — таблица читается целиком; индекс core.session — для соединения с сеансами курсовой
-- Объём 0 записывается как null: домен ref.d_mb требует объём > 0, null он пропускает, и строка остаётся неразобранной.
SELECT count(*)                                                          AS records,
       count(*) FILTER (WHERE r.doc -> 'contract' = 'null')              AS service_test,
       count(*) FILTER (WHERE s.contract_id IS NOT NULL AND s.volume_mb IS NULL) AS no_traffic,
       count(*) FILTER (WHERE s.contract_id IS NOT NULL AND s.volume_mb IS NOT NULL) AS parsed,
       count(cs.id)                                                      AS matched,
       count(*) FILTER (WHERE s.contract_id IS NOT NULL AND s.volume_mb IS NOT NULL) - count(cs.id) AS mismatched
FROM lab7.session_record r
LEFT JOIN core.provider p ON p.name = r.doc #>> '{source,provider,name}'
LEFT JOIN core.contract c ON c.provider_id = p.id AND c.contract_no = r.doc #>> '{contract,number}'
LEFT JOIN ref.tariff t ON t.code = r.doc #>> '{billing,tariff,code}'
CROSS JOIN LATERAL jsonb_populate_record(NULL::core.session,
        (r.doc -> 'session') || (r.doc -> 'billing')
        || jsonb_build_object('contract_id', c.id, 'tariff_id', t.id,
                              'volume_mb', nullif((r.doc #>> '{session,traffic,in,mb}')::numeric
                                                + (r.doc #>> '{session,traffic,out,mb}')::numeric, 0))) AS s
LEFT JOIN core.session cs ON cs.contract_id = s.contract_id
                         AND date_trunc('second', cs.started_at) = s.started_at
                         AND cs.tariff_id = s.tariff_id AND cs.volume_mb = s.volume_mb AND cs.cost = s.cost;

-- @q 5.6_nas_summary | Функции: jsonb_build_object, jsonb_object_agg, jsonb_agg, jsonb_pretty | Сводка за месяц по узлам доступа провайдера одним JSON-документом для системы мониторинга: сеансы, трафик по направлениям, причины завершения
WITH c AS (
    SELECT doc #>> '{source,nas,name}'     AS nas,
           doc #>> '{source,nas,vendor}'   AS vendor,
           doc #>> '{session,stop_cause}'  AS cause,
           count(*)                        AS sessions,
           sum((doc #>> '{session,traffic,in,mb}')::numeric)  AS in_mb,
           sum((doc #>> '{session,traffic,out,mb}')::numeric) AS out_mb
    FROM lab7.session_record
    WHERE doc @> jsonb_build_object('source', jsonb_build_object('provider', jsonb_build_object('name', :'q_provider')))
      AND (doc #>> '{session,started_at}')::timestamptz >= :'q_from'
      AND (doc #>> '{session,started_at}')::timestamptz <  :'q_to'
    GROUP BY 1, 2, 3),
n AS (
    SELECT c.nas,
           jsonb_build_object('nas', c.nas, 'vendor', c.vendor, 'sessions', sum(c.sessions),
                              'traffic_mb', jsonb_build_object('in', sum(c.in_mb), 'out', sum(c.out_mb)),
                              'stop_causes', jsonb_object_agg(c.cause, c.sessions)) AS item
    FROM c
    GROUP BY c.nas, c.vendor)
SELECT jsonb_pretty(jsonb_build_object('provider', :'q_provider', 'from', :'q_from', 'to', :'q_to',
                                       'nodes', jsonb_agg(n.item ORDER BY n.nas))) AS summary
FROM n;
