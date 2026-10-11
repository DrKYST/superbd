# ЛР 7 — сводка запросов, планов и индексов

Создаётся `labs/lab07/run_lab7.py` — не править вручную.

```
Сервер: PostgreSQL 18.3 on x86_64-windows, compiled by msvc-19.44.35223, 64-bit
work_mem = 64MB, shared_buffers = 512MB, max_parallel_workers_per_gather = 2, random_page_cost = 4
Таблица lab7.session_record: 100025 документов, 156 MB (индексы 94 MB); снято 12.10.2026 00:39
```

«До» — без индексов (в транзакции `DROP INDEX` всех индексов, кроме первичного ключа, затем `ROLLBACK`; у оптимизированных запросов — ещё и исходная форма запроса), «после» — с индексами (у оптимизированных — переписанная форма). Каждый план — второй прогон после прогревочного, после `ANALYZE`. Стоимость — оценка верхнего узла плана, время — `Execution Time`.

| № | Раздел задания | Что делает | SQL | Вывод | cost до → после | время, мс до → после | Индекс в плане «после» |
|---|---|---|---|---|---|---|---|
| 3.1 | Поля, объекты, массивы: ->, ->>, #>, #>>, @> (несколько условий) | Оператор разбирает жалобу абонента на обрывы связи | `sql/03_select_operators.sql` | `explain/3.1_complaint.txt` | 21 906.12 → 3 340.99 | 84.640 → 0.179 | `ix_session_record_doc` |
| 3.2 | Поля, объекты: ?\|, ?, @> (несколько условий) | Колл-центр провайдера | `sql/03_select_operators.sql` | `explain/3.2_debtors.txt` | 21 966.19 → 60.76 | 70.915 → 0.785 | `ix_session_record_attributes`, `ix_session_record_doc` |
| 3.3 | Объекты и массивы: #>, -> (индекс массива), @> по вложенному объекту, несколько условий | Инженер ищет неисправную линию | `sql/03_select_operators.sql` | `explain/3.3_lost_carrier.txt` | 22 278.13 → 3 332.22 | 84.662 → 5.458 | `ix_session_record_doc` |
| 4.1 | jsonpath: предикат @@ (два условия) | Аналитик проверяет жалобы на тарификацию | `sql/04_jsonpath.sql` | `explain/4.1_huawei_night.txt` | 21 919.55 → 3 354.38 | 65.764 → 9.060 | `ix_session_record_doc` |
| 4.2 | jsonpath: @? с фильтром по элементам массива | Инженер оценивает аварии | `sql/04_jsonpath.sql` | `explain/4.2_nas_reboot.txt` | 21 284.78 → 3 371.41 | 72.297 → 9.541 | `ix_session_record_doc` |
| 4.3 | jsonpath: jsonb_path_query с переменной $mb (vars) | Оператор отвечает абоненту, жалующемуся на перерасход трафика | `sql/04_jsonpath.sql` | `explain/4.3_interim_over.txt` | 21 233.19 → 3 372.16 | 44.133 → 0.145 | `ix_session_record_doc` |
| 4.4 | jsonpath: @? с фильтром от корня, jsonb_path_query_array, jsonb_path_query_first | Инженер ищет узлы, теряющие пакеты учёта | `sql/04_jsonpath.sql` | `explain/4.4_lost_interim.txt` | 21 474.49 → 21 474.49 | 62.242 → 52.059 | нет (условие-диапазон (> 3600) и отрицание (NOT @?) индекс GIN не ищет — читаются все записи) |
| 5.1 | Функции: jsonb_array_elements WITH ORDINALITY, jsonb_to_record | Оператор разбирает жалобу на обрыв | `sql/05_functions.sql` | `explain/5.1_events_table.txt` | 21 219.63 → 3 358.59 | 39.116 → 0.158 | `ix_session_record_doc` |
| 5.2 | Функции: jsonb_object_keys | Разработчик разборщика выгрузок | `sql/05_functions.sql` | `explain/5.2_vendor_keys.txt` | 1 667 308.28 → 1 667 308.28 | 353.484 → 352.433 | нет (нужны все записи таблицы — индекс не нужен) |
| 5.3 | Функции: jsonb_each_text, jsonb_typeof | Инженер нашёл в журнале NAS идентификатор сеанса (Acct-Session-Id) и смотрит все атрибуты этого сеанса парами «ключ | `sql/05_functions.sql` | `explain/5.3_attr_card.txt` | 21 798.80 → 14.76 | 81.821 → 0.091 | `uq_session_record_provider_acct` |
| 5.4 | Функции: jsonb_populate_record в тип строки core.session, \|\| , jsonb_build_object | Загрузка выгрузки биллинга в курсовую | `sql/05_functions.sql` | `explain/5.4_populate_session.txt` | 21 575.10 → 3 735.39 | 149.211 → 0.769 | `ix_session_record_doc`, `pk_provider`, `uq_contract_provider_id_contract_no` |
| 5.5 | Функции: jsonb_populate_record (все записи), сверка с core.session | Сверка выгрузки с учётом курсовой | `sql/05_functions.sql` | `explain/5.5_reconcile.txt` | 24 975.23 → 24 989.14 | 725.816 → 648.613 | `ix_session_contract_id_started_at` (сверяются все записи — таблица читается целиком; индекс core.session — для соединения с сеансами курсовой) |
| 5.6 | Функции: jsonb_build_object, jsonb_object_agg, jsonb_agg, jsonb_pretty | Сводка за месяц по узлам доступа провайдера одним JSON-документом для системы мониторинга | `sql/05_functions.sql` | `explain/5.6_nas_summary.txt` | 22 591.26 → 3 323.00 | 78.790 → 12.888 | `ix_session_record_doc` |
| 9.1 | Оптимизация (≥ 5): ->> по цепочке ключей → @> (GIN jsonb_path_ops по документу) | Оператор открывает сеансы договора из жалобы | `sql/09_optimize.sql` | `explain/9.1_contract.txt` | 22 069.41 → 3 356.41 | 63.548 → 0.108 | `ix_session_record_doc` |
| 9.2 | Оптимизация (≥ 5): jsonb_path_exists с переменной → оператор @? с константой (GIN jsonb_path_ops) | Инженер считает сеансы, оборванные перезагрузкой узлов (запрос 4.2) | `sql/09_optimize.sql` | `explain/9.2_nas_reboot.txt` | 22 560.69 → 3 353.91 | 68.865 → 4.742 | `ix_session_record_doc` |
| 9.3 | Оптимизация (≥ 5): ?\| по атрибутам — запрос не меняется, нужен GIN jsonb_ops по attributes | Колл-центр | `sql/09_optimize.sql` | `explain/9.3_debtors.txt` | 21 966.18 → 60.76 | 48.101 → 0.615 | `ix_session_record_attributes`, `ix_session_record_doc` |
| 9.4 | Оптимизация (≥ 5): -> ->> → #>> как в выражении индекса (уникальный B-дерево провайдер + Acct-Session-Id) | Инженер нашёл в журнале NAS идентификатор сеанса и открывает учётную запись | `sql/09_optimize.sql` | `explain/9.4_acct_id.txt` | 22 069.43 → 8.45 | 56.947 → 0.029 | `uq_session_record_provider_acct` |
| 9.5 | Оптимизация (≥ 5): ::timestamptz → строка ISO 8601 с COLLATE "C" (B-дерево по времени начала) | Аналитик сверяет выгрузку с отчётом курсовой «Доли провайдеров» | `sql/09_optimize.sql` | `explain/9.5_month.txt` | 22 277.18 → 18 488.17 | 159.431 → 15.367 | `ix_session_record_started_at` |
| 9.6 | Оптимизация (≥ 5): два сравнения #>> = → предикат jsonpath @@ (GIN jsonb_path_ops) | Аналитик проверяет тарификацию Huawei (запрос 4.1) | `sql/09_optimize.sql` | `explain/9.6_huawei_night.txt` | 22 173.48 → 3 354.38 | 42.448 → 8.640 | `ix_session_record_doc` |
| 9.7 | Индекс не помог: индекс не применим: сравнение «больше» внутри jsonpath | Служба безопасности ищет заражённые компьютеры абонентов (рассылка спама) | `sql/09_optimize.sql` | `explain/9.7_range_no_index.txt` | 21 267.28 → 21 234.19 | 48.685 → 58.256 | нет — **выигрыша нет** |
| 9.8 | Индекс не помог: индекс выбран по заниженной оценке, но выигрыша нет: условию отвечает больше половины записей | Аналитик считает сеансы, завершённые самим абонентом (user_request), по производителям | `sql/09_optimize.sql` | `explain/9.8_half_table.txt` | 21 245.64 → 3 367.37 | 63.435 → 58.337 | `ix_session_record_doc` — **выигрыша нет** |

## Изменения, удаления, индексы

| Шаг | Раздел задания | SQL | Вывод |
|---|---|---|---|
| Генерация документов | заполнение ≥ 100 000, глубина ≥ 4 | `sql/02_generate.sql` | `explain/02_generate.txt` |
| 6.1–6.9 | изменение данных внутри документа (≥ 6) | `sql/06_update.sql` | `explain/06_update.txt` |
| 7.1–7.2 | удаление документов (≥ 2) | `sql/07_delete.sql` | `explain/07_delete.txt` |
| Индексы | ≥ 3: по документу целиком и по элементам ключей | `sql/08_indexes.sql` | `explain/08_indexes.txt` |

## Время шагов (последний прогон run_lab7.py)

| Шаг | Время, с |
|---|---|
| `01_create.sql` | 0.2 |
| `02_generate.sql` | 9.3 |
| `03_select_operators.sql` | 0.6 |
| `04_jsonpath.sql` | 0.7 |
| `05_functions.sql` | 1.8 |
| `06_update.sql` | 2.5 |
| `07_delete.sql` | 0.4 |
| `08_indexes.sql` | 14.9 |
| `09_optimize.sql` | 0.7 |
| всего | 31.1 |
