-- ЛР 7, шаг 9. Оптимизация запросов под индексы (08_indexes.sql).
-- Блок «-- @opt имя | что меняется | зачем»: под «-- @before» — исходная форма запроса, под «-- @after» —
-- оптимизированная (если формы нет, запрос не меняется — помогает только индекс). Результаты обеих форм совпадают.
-- Планы снимает labs/lab07/run_lab7.py (explain/<имя>.txt):
--   «до»    — исходная форма без индексов: в транзакции индексы удаляются (DROP INDEX), план снимается,
--             транзакция откатывается — данные те же, что «после»;
--   «после» — оптимизированная форма с индексами.
-- Перед каждым снятым планом — прогон для прогрева кэша, в файл идёт второй прогон; перед всеми — ANALYZE.
-- Последние два блока — честные примеры, где индекс не помогает (диапазон в jsonpath; условие на половину таблицы).
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/09_optimize.sql      -- выполнить обе формы
-- Вручную «до» снимается так (пример для 9.1):
--   BEGIN; DROP INDEX lab7.ix_session_record_doc; EXPLAIN (ANALYZE, BUFFERS) <запрос>; ROLLBACK;
\set ON_ERROR_STOP on
\ir 00_params.sql

-- @opt 9.1_contract | ->> по цепочке ключей → @> (GIN jsonb_path_ops по документу) | Оператор открывает сеансы договора из жалобы: сравнение «ключ ->> = значение» индексом по документу не поддерживается, образец @> — поддерживается
-- @before
SELECT doc #>> '{session,started_at}'         AS started_at,
       doc -> 'session' ->> 'stop_cause'      AS stop_cause,
       (doc #>> '{billing,cost}')::numeric    AS cost
FROM lab7.session_record
WHERE doc -> 'source' -> 'provider' ->> 'name' = :'q_provider'
  AND doc -> 'contract' ->> 'number' = :'q_contract'
ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
LIMIT 10;
-- @after
SELECT doc #>> '{session,started_at}'         AS started_at,
       doc -> 'session' ->> 'stop_cause'      AS stop_cause,
       (doc #>> '{billing,cost}')::numeric    AS cost
FROM lab7.session_record
WHERE doc @> :'q_contract_doc'
ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
LIMIT 10;

-- @opt 9.2_nas_reboot | jsonb_path_exists с переменной → оператор @? с константой (GIN jsonb_path_ops) | Инженер считает сеансы, оборванные перезагрузкой узлов (запрос 4.2): функция jsonb_path_exists индексом не пользуется, оператор @? — пользуется
-- @before
SELECT doc #>> '{source,nas,name}' AS nas, count(*) AS sessions
FROM lab7.session_record
WHERE jsonb_path_exists(doc, '$.events[*] ? (@.type == "stop" && @.cause == $cause)', '{"cause": "nas_reboot"}')
GROUP BY 1
ORDER BY 2 DESC, 1
LIMIT 10;
-- @after
SELECT doc #>> '{source,nas,name}' AS nas, count(*) AS sessions
FROM lab7.session_record
WHERE doc @? '$.events[*] ? (@.type == "stop" && @.cause == "nas_reboot")'
GROUP BY 1
ORDER BY 2 DESC, 1
LIMIT 10;

-- @opt 9.3_debtors | ?| по атрибутам — запрос не меняется, нужен GIN jsonb_ops по attributes | Колл-центр: сеансы должников провайдера (запрос 3.2): наличие ключа индексом по документу (jsonb_path_ops) не ищется — для атрибутов отдельный индекс jsonb_ops
-- @after
SELECT doc #>> '{contract,number}'           AS contract,
       doc #>> '{session,started_at}'        AS started_at,
       doc #>> '{source,nas,vendor}'         AS vendor
FROM lab7.session_record
WHERE doc -> 'attributes' ?| ARRAY['address_list', 'redirect_url']
  AND doc @> jsonb_build_object('source', jsonb_build_object('provider', jsonb_build_object('name', :'q_provider')))
ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
LIMIT 10;

-- @opt 9.4_acct_id | -> ->> → #>> как в выражении индекса (уникальный B-дерево провайдер + Acct-Session-Id) | Инженер нашёл в журнале NAS идентификатор сеанса и открывает учётную запись: индекс по выражению применяется, только если в запросе записано то же выражение
-- @before
SELECT doc #>> '{contract,number}' AS contract, doc #>> '{session,started_at}' AS started_at,
       doc #>> '{session,stop_cause}' AS stop_cause, doc -> 'attributes' AS attributes
FROM lab7.session_record
WHERE doc -> 'source' -> 'provider' ->> 'name' = :'q_provider'
  AND doc -> 'session' ->> 'acct_id' = :'q_acct';
-- @after
SELECT doc #>> '{contract,number}' AS contract, doc #>> '{session,started_at}' AS started_at,
       doc #>> '{session,stop_cause}' AS stop_cause, doc -> 'attributes' AS attributes
FROM lab7.session_record
WHERE doc #>> '{source,provider,name}' = :'q_provider'
  AND doc #>> '{session,acct_id}' = :'q_acct';

-- @opt 9.5_month | ::timestamptz → строка ISO 8601 с COLLATE "C" (B-дерево по времени начала) | Аналитик сверяет выгрузку с отчётом курсовой «Доли провайдеров»: трафик и оплата трафика по провайдерам за месяц; приведение к timestamptz индексировать нельзя, строку ISO 8601 — можно
-- @before
SELECT doc #>> '{source,provider,name}'                       AS provider,
       count(*)                                               AS sessions,
       sum((doc #>> '{session,traffic,in,mb}')::numeric
           + (doc #>> '{session,traffic,out,mb}')::numeric)   AS volume_mb,
       sum((doc #>> '{billing,cost}')::numeric)               AS traffic_fees
FROM lab7.session_record
WHERE (doc #>> '{session,started_at}')::timestamptz >= :'q_from'
  AND (doc #>> '{session,started_at}')::timestamptz <  :'q_to'
GROUP BY 1
ORDER BY 4 DESC, 1
LIMIT 10;
-- @after
SELECT doc #>> '{source,provider,name}'                       AS provider,
       count(*)                                               AS sessions,
       sum((doc #>> '{session,traffic,in,mb}')::numeric
           + (doc #>> '{session,traffic,out,mb}')::numeric)   AS volume_mb,
       sum((doc #>> '{billing,cost}')::numeric)               AS traffic_fees
FROM lab7.session_record
WHERE (doc #>> '{session,started_at}') COLLATE "C" >= :'q_from'
  AND (doc #>> '{session,started_at}') COLLATE "C" <  :'q_to'
GROUP BY 1
ORDER BY 4 DESC, 1
LIMIT 10;

-- @opt 9.6_huawei_night | два сравнения #>> = → предикат jsonpath @@ (GIN jsonb_path_ops) | Аналитик проверяет тарификацию Huawei (запрос 4.1): сеансы по тарифу «Выходной ночной» на узлах Huawei в 2026 году по месяцам
-- @before
SELECT date_trunc('month', (doc #>> '{session,started_at}')::timestamptz)::date AS month,
       count(*) AS sessions, sum((doc #>> '{billing,cost}')::numeric) AS cost
FROM lab7.session_record
WHERE doc #>> '{source,nas,vendor}' = 'Huawei'
  AND doc #>> '{billing,tariff,code}' = 'ВН'
  AND (doc #>> '{session,started_at}')::timestamptz >= :'q_year_from'
GROUP BY 1
ORDER BY 1;
-- @after
SELECT date_trunc('month', (doc #>> '{session,started_at}')::timestamptz)::date AS month,
       count(*) AS sessions, sum((doc #>> '{billing,cost}')::numeric) AS cost
FROM lab7.session_record
WHERE doc @@ '$.source.nas.vendor == "Huawei" && $.billing.tariff.code == "ВН"'
  AND (doc #>> '{session,started_at}')::timestamptz >= :'q_year_from'
GROUP BY 1
ORDER BY 1;

-- @opt 9.7_range_no_index | индекс не применим: сравнение «больше» внутри jsonpath | Служба безопасности ищет заражённые компьютеры абонентов (рассылка спама): сеансы с исходящим трафиком больше 400 Мб — GIN хранит пары «путь = значение» и диапазон по ним не ищет
-- @negative
-- @after
SELECT doc #>> '{source,provider,name}' AS provider, count(*) AS sessions
FROM lab7.session_record
WHERE doc @? '$.session.traffic.out ? (@.mb > 400)'
GROUP BY 1
ORDER BY 2 DESC, 1
LIMIT 10;

-- @opt 9.8_half_table | индекс выбран по заниженной оценке, но выигрыша нет: условию отвечает больше половины записей | Аналитик считает сеансы, завершённые самим абонентом (user_request), по производителям: для @> по jsonb статистики по содержимому нет, планировщик оценивает 1 000 строк вместо ~55 000, выбирает индекс — и читает почти все страницы таблицы
-- @negative
-- @compare SET enable_bitmapscan = off
-- @after
SELECT doc #>> '{source,nas,vendor}' AS vendor, count(*) AS sessions
FROM lab7.session_record
WHERE doc @> '{"session": {"stop_cause": "user_request"}}'
GROUP BY 1
ORDER BY 1;
