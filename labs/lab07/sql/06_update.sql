-- ЛР 7, шаг 6. Изменение данных внутри документов: девять изменений, у каждого — повод из работы провайдера.
-- Функции и операторы: jsonb_set (замена значения; create_missing — добавление ключа), jsonb_set_lax (null →
-- удаление ключа), jsonb_insert (вставка в массив до или после элемента), || (слияние объектов), - (удаление ключа),
-- #- (удаление по пути), jsonb_strip_nulls (удаление ключей со значением null).
-- Для каждого изменения выводится одна и та же запись до и после (её код запоминается до изменения).
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/06_update.sql   (запросы выводятся: ECHO queries)
-- Идемпотентно: повторный запуск либо записывает те же значения, либо (вставки в массив) пропускает уже изменённые
-- записи по условию.
\set ON_ERROR_STOP on
SET TimeZone = 'Europe/Moscow';            -- время в документах — со смещением +03:00 (D19)
\ir 00_params.sql
\set ECHO queries

-- ============================================================================ 6.1 jsonb_set — замена значения
\echo '6.1 jsonb_set: провайдер прислал исправление — адрес узла bras01-2 был указан с ошибкой (д. 57 вместо д. 75)'
SELECT min(id) AS u_id FROM lab7.session_record WHERE doc @> '{"source": {"nas": {"name": "bras01-2"}}}' \gset
SELECT id, doc #> '{source,nas,location}' AS before FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = jsonb_set(doc, '{source,nas,location,address}', '"бул. Шевченко, д. 75"')
WHERE doc @> '{"source": {"nas": {"name": "bras01-2"}}}';
\echo 'изменено записей:' :ROW_COUNT
SELECT id, doc #> '{source,nas,location}' AS after FROM lab7.session_record WHERE id = :u_id;

-- ============================================================================ 6.2 jsonb_set, create_missing = true
\echo '6.2 jsonb_set (create_missing): выставлены счета ДонНет за сентябрь 2026 — в записи сентября добавляется номер счёта'
SELECT min(id) AS u_id FROM lab7.session_record
WHERE doc @> jsonb_build_object('source', jsonb_build_object('provider', jsonb_build_object('name', :'q_provider')))
  AND doc -> 'contract' <> 'null'
  AND (doc #>> '{session,started_at}')::timestamptz >= :'q_from'
  AND (doc #>> '{session,started_at}')::timestamptz <  :'q_to' \gset
SELECT id, doc -> 'billing' AS before FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = jsonb_set(doc, '{billing,invoice}',                      -- ключа invoice ещё нет — он создаётся
                    to_jsonb('СЧ-2026-09/' || (doc #>> '{contract,number}')), true)
WHERE doc @> jsonb_build_object('source', jsonb_build_object('provider', jsonb_build_object('name', :'q_provider')))
  AND doc -> 'contract' <> 'null'
  AND (doc #>> '{session,started_at}')::timestamptz >= :'q_from'
  AND (doc #>> '{session,started_at}')::timestamptz <  :'q_to';
\echo 'изменено записей:' :ROW_COUNT
SELECT id, doc -> 'billing' AS after FROM lab7.session_record WHERE id = :u_id;

-- ============================================================================ 6.3 jsonb_set_lax — null удаляет ключ
\echo '6.3 jsonb_set_lax: счёт договора с наибольшим числом сеансов в сентябре аннулирован (ошибка в тарифе) — номер счёта удаляется'
SELECT doc #>> '{billing,invoice}' AS u_invoice
FROM lab7.session_record
WHERE doc @? '$.billing.invoice'
GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1 \gset
SELECT min(id) AS u_id FROM lab7.session_record WHERE doc @> jsonb_build_object('billing', jsonb_build_object('invoice', :'u_invoice')) \gset
SELECT id, doc -> 'billing' AS before FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = jsonb_set_lax(doc, '{billing,invoice}', NULL, true, 'delete_key')  -- 'use_json_null' записал бы null
WHERE doc @> jsonb_build_object('billing', jsonb_build_object('invoice', :'u_invoice'));
\echo 'изменено записей:' :ROW_COUNT
SELECT id, doc -> 'billing' AS after FROM lab7.session_record WHERE id = :u_id;

-- ============================================================================ 6.4 jsonb_insert — перед элементом массива
\echo '6.4 jsonb_insert (insert_after = false): в последнем сеансе договора из жалобы абонент включил ускорение — NAS принял команду смены скорости (CoA); событие вставляется перед завершающим stop'
SELECT id AS u_id FROM lab7.session_record
WHERE doc #>> '{source,provider,name}' = :'q_provider' AND doc #>> '{session,acct_id}' = :'q_acct' \gset
SELECT id, doc -> 'events' AS before FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = jsonb_insert(doc, '{events,-1}',                        -- -1 — последний элемент (stop)
                       jsonb_build_object(
                           'at', to_char((doc #>> '{session,stopped_at}')::timestamptz - interval '1 minute',
                                         'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'),
                           'type', 'coa', 'rate_mbps', 500),
                       false)
WHERE doc #>> '{source,provider,name}' = :'q_provider' AND doc #>> '{session,acct_id}' = :'q_acct'
  AND NOT doc @? '$.events[*] ? (@.type == "coa")';               -- повторный запуск не дублирует событие
SELECT id, doc -> 'events' AS after FROM lab7.session_record WHERE id = :u_id;
\echo 'изменено записей:' :ROW_COUNT

-- ============================================================================ 6.5 jsonb_insert — после элемента массива
\echo '6.5 jsonb_insert (insert_after = true): узел bras01-1 переслал потерянные промежуточные обновления — первое вставляется сразу после события start'
SELECT min(id) AS u_id FROM lab7.session_record
WHERE doc @> '{"source": {"nas": {"name": "bras01-1"}}}'
  AND doc @? '$ ? (@.session.duration_s > 3600)'
  AND NOT doc @? '$.events[*] ? (@.type == "interim")' \gset
SELECT id, doc #>> '{session,duration_s}' AS duration_s, doc #> '{session,traffic}' AS traffic, doc -> 'events' AS before
FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = jsonb_insert(doc, '{events,0}',
                       jsonb_build_object(
                           'at', to_char((doc #>> '{session,started_at}')::timestamptz + interval '1 hour',
                                         'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'),
                           'type', 'interim',
                           'in_mb',  round((doc #>> '{session,traffic,in,mb}')::numeric * 3600
                                           / (doc #>> '{session,duration_s}')::int, 3),
                           'out_mb', round((doc #>> '{session,traffic,out,mb}')::numeric * 3600
                                           / (doc #>> '{session,duration_s}')::int, 3),
                           'resent', true),
                       true)
WHERE doc @> '{"source": {"nas": {"name": "bras01-1"}}}'
  AND doc @? '$ ? (@.session.duration_s > 3600)'
  AND NOT doc @? '$.events[*] ? (@.type == "interim")';
\echo 'изменено записей:' :ROW_COUNT
SELECT id, doc -> 'events' AS after FROM lab7.session_record WHERE id = :u_id;

-- ============================================================================ 6.6 || — слияние объектов
\echo '6.6 ||: оператор проверил по жалобе сеансы договора с обрывами связи — в запись добавляется раздел review'
SELECT min(id) AS u_id FROM lab7.session_record
WHERE doc @> :'q_contract_doc' AND doc @> '{"session": {"stop_cause": "lost_carrier"}}' \gset
SELECT id, doc ? 'review' AS has_review, doc -> 'review' AS before FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = doc || jsonb_build_object('review', jsonb_build_object(
                   'by', 'op_donnet',
                   'at', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'),
                   'result', 'обрывы на стороне абонента: неисправен роутер, рекомендована замена'))
WHERE doc @> :'q_contract_doc' AND doc @> '{"session": {"stop_cause": "lost_carrier"}}';
\echo 'изменено записей:' :ROW_COUNT
SELECT id, doc ? 'review' AS has_review, doc -> 'review' AS after FROM lab7.session_record WHERE id = :u_id;

-- ============================================================================ 6.7 - — удаление ключа
\echo '6.7 - (удаление ключа): ДонЛинк отключил выдачу служебной метки Class сервером авторизации — старые метки удаляются из атрибутов'
SELECT min(id) AS u_id FROM lab7.session_record
WHERE doc @> '{"source": {"provider": {"name": "ДонЛинк"}}}' AND doc -> 'attributes' ? 'class' \gset
SELECT id, doc -> 'attributes' AS before FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = jsonb_set(doc, '{attributes}', (doc -> 'attributes') - 'class')
WHERE doc @> '{"source": {"provider": {"name": "ДонЛинк"}}}' AND doc -> 'attributes' ? 'class';
\echo 'изменено записей:' :ROW_COUNT
SELECT id, doc -> 'attributes' AS after FROM lab7.session_record WHERE id = :u_id;

-- ============================================================================ 6.8 #- — удаление по пути
\echo '6.8 #- (удаление по пути): MAC-адрес оборудования абонента — персональные сведения, хранится не дольше года; из записей 2024 года удаляется'
SELECT min(id) AS u_id FROM lab7.session_record
WHERE (doc #>> '{session,started_at}')::timestamptz < '2025-01-01' AND doc -> 'attributes' ? 'calling_station_id' \gset
SELECT id, doc -> 'attributes' AS before FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = doc #- '{attributes,calling_station_id}'
WHERE (doc #>> '{session,started_at}')::timestamptz < '2025-01-01' AND doc -> 'attributes' ? 'calling_station_id';
\echo 'изменено записей:' :ROW_COUNT
SELECT id, doc -> 'attributes' AS after FROM lab7.session_record WHERE id = :u_id;

-- ============================================================================ 6.9 jsonb_strip_nulls
\echo '6.9 jsonb_strip_nulls: пустые (null) атрибуты — Huawei без domain_name, Accel-PPP без framed_pool — удаляются из атрибутов'
-- Только из раздела attributes: для документа целиком jsonb_strip_nulls удалил бы и обязательный раздел
-- "contract": null служебных записей — нарушение ограничения ck_session_record_doc.
SELECT min(id) AS u_id FROM lab7.session_record WHERE doc -> 'attributes' @? '$.* ? (@ == null)' \gset
SELECT id, doc -> 'attributes' AS before FROM lab7.session_record WHERE id = :u_id;
UPDATE lab7.session_record
SET doc = jsonb_set(doc, '{attributes}', jsonb_strip_nulls(doc -> 'attributes'))
WHERE doc -> 'attributes' @? '$.* ? (@ == null)';
\echo 'изменено записей:' :ROW_COUNT
SELECT id, doc -> 'attributes' AS after FROM lab7.session_record WHERE id = :u_id;

\set ECHO none
RESET TimeZone;
