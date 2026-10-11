-- ЛР 7, шаг 4. Запросы с языком путей SQL/JSON (jsonpath).
-- @? — есть ли по пути хотя бы один элемент (с фильтром ? (…)); @@ — истинен ли предикат пути;
-- jsonb_path_query / _array / _first — элементы по пути (строками, массивом, первый); vars — переменные пути ($mb).
-- Регулярных выражений нет (D24): like_regex не используется.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/04_jsonpath.sql
\set ON_ERROR_STOP on
\ir 00_params.sql

-- @q 4.1_huawei_night | jsonpath: предикат @@ (два условия) | Аналитик проверяет жалобы на тарификацию: сколько сеансов на узлах Huawei в 2026 году прошло по тарифу «Выходной ночной» — по месяцам (всплеск означал бы, что NAS передаёт неверное время)
SELECT date_trunc('month', (doc #>> '{session,started_at}')::timestamptz)::date AS month,
       count(*)                                      AS sessions,
       sum((doc #>> '{billing,cost}')::numeric)      AS cost
FROM lab7.session_record
WHERE doc @@ '$.source.nas.vendor == "Huawei" && $.billing.tariff.code == "ВН"'
  AND (doc #>> '{session,started_at}')::timestamptz >= :'q_year_from'
GROUP BY 1
ORDER BY 1;

-- @q 4.2_nas_reboot | jsonpath: @? с фильтром по элементам массива | Инженер оценивает аварии: сеансы, оборванные перезагрузкой узла доступа (событие stop с причиной nas_reboot), — по узлам: сколько сеансов задело и когда последний раз
SELECT doc #>> '{source,nas,name}'           AS nas,
       doc #>> '{source,nas,vendor}'         AS vendor,
       count(*)                              AS sessions,
       max((doc #>> '{session,stopped_at}')::timestamptz) AS last_reboot
FROM lab7.session_record
WHERE doc @? '$.events[*] ? (@.type == "stop" && @.cause == "nas_reboot")'
GROUP BY 1, 2
ORDER BY 3 DESC, 1
LIMIT 10;

-- @q 4.3_interim_over | jsonpath: jsonb_path_query с переменной $mb (vars) | Оператор отвечает абоненту, жалующемуся на перерасход трафика: промежуточные обновления его сеансов, в которых накопленный входящий трафик превысил порог (порог — переменная пути)
SELECT doc #>> '{session,started_at}'        AS session_started,
       jsonb_path_query(doc, '$.events[*] ? (@.type == "interim" && @.in_mb > $mb)',
                        jsonb_build_object('mb', 200)) AS interim_update
FROM lab7.session_record
WHERE doc @> :'q_contract_doc'
ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
LIMIT 10;

-- @q 4.4_lost_interim | jsonpath: @? с фильтром от корня, jsonb_path_query_array, jsonb_path_query_first | Инженер ищет узлы, теряющие пакеты учёта: сеансы дольше часа без промежуточных обновлений — последовательность событий (массив) и время события stop
-- @note условие-диапазон (> 3600) и отрицание (NOT @?) индекс GIN не ищет — читаются все записи
SELECT doc #>> '{source,nas,name}'                                        AS nas,
       doc #>> '{source,nas,vendor}'                                      AS vendor,
       (doc #>> '{session,duration_s}')::int / 60                         AS minutes,
       jsonb_path_query_array(doc, '$.events[*].type')                    AS event_types,
       jsonb_path_query_first(doc, '$.events[*] ? (@.type == "stop").at') #>> '{}' AS stop_at
FROM lab7.session_record
WHERE doc @? '$ ? (@.session.duration_s > 3600)'
  AND NOT doc @? '$.events[*] ? (@.type == "interim")'
ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
LIMIT 10;
