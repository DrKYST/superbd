-- ЛР 7, шаг 3. Запросы с выводом полей, объектов и массивов с одним или несколькими условиями.
-- Операторы: ->  (значение по ключу или индексу массива как jsonb), ->> (то же как text),
--            #>  (значение по пути как jsonb), #>> (по пути как text),
--            @>  (документ содержит образец), ?  (есть ключ), ?| (есть хотя бы один из ключей).
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/03_select_operators.sql
-- Блок «-- @q имя | раздел задания | зачем» — один запрос; по этим блокам run_lab7.py строит explain/<имя>.txt.
\set ON_ERROR_STOP on
\ir 00_params.sql

-- @q 3.1_complaint | Поля, объекты, массивы: ->, ->>, #>, #>>, @> (несколько условий) | Оператор разбирает жалобу абонента на обрывы связи: последние сеансы договора в 2026 году — начало, длительность, причина завершения, узел доступа, трафик (объект)
SELECT doc #>> '{session,started_at}'              AS started_at,
       (doc #>> '{session,duration_s}')::int / 60  AS minutes,
       doc -> 'session' ->> 'stop_cause'           AS stop_cause,
       doc -> 'source' -> 'nas' ->> 'name'         AS nas,
       doc #> '{session,traffic}'                  AS traffic
FROM lab7.session_record
WHERE doc @> :'q_contract_doc'                                         -- провайдер и номер договора
  AND (doc #>> '{session,started_at}')::timestamptz >= :'q_year_from'
ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
LIMIT 10;

-- @q 3.2_debtors | Поля, объекты: ?|, ?, @> (несколько условий) | Колл-центр провайдера: сеансы, в которых NAS переадресовал абонента на страницу оплаты (должник) — признак у разных производителей разный: у MikroTik список адресов address_list, у остальных redirect_url
SELECT doc #>> '{contract,number}'           AS contract,
       doc #>> '{session,started_at}'        AS started_at,
       doc #>> '{source,nas,vendor}'         AS vendor,
       doc -> 'attributes'                   AS attributes
FROM lab7.session_record
WHERE doc -> 'attributes' ?| ARRAY['address_list', 'redirect_url']
  AND doc @> jsonb_build_object('source', jsonb_build_object('provider', jsonb_build_object('name', :'q_provider')))
ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
LIMIT 10;

-- @q 3.3_lost_carrier | Объекты и массивы: #>, -> (индекс массива), @> по вложенному объекту, несколько условий | Инженер ищет неисправную линию: обрывы связи (lost_carrier) на узлах доступа Макеевки в III квартале 2026 года — расположение узла (объект), число событий и последнее событие сеанса (элемент массива)
SELECT doc #>> '{source,nas,name}'           AS nas,
       doc #> '{source,nas,location}'        AS location,
       doc #>> '{contract,number}'           AS contract,
       jsonb_array_length(doc -> 'events')   AS events,
       doc -> 'events' -> -1                 AS last_event
FROM lab7.session_record
WHERE doc @> '{"session": {"stop_cause": "lost_carrier"}, "source": {"nas": {"location": {"city": "Макеевка"}}}}'
  AND (doc #>> '{session,started_at}')::timestamptz >= '2026-07-01'
  AND (doc #>> '{session,started_at}')::timestamptz <  '2026-10-01'
ORDER BY (doc #>> '{session,started_at}')::timestamptz
LIMIT 10;
