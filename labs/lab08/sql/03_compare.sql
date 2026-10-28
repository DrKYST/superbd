-- ЛР 8, шаг 3. Сравнение секционированных таблиц с обычными копиями на запросах системы.
-- Блок «-- @cmp имя | что показывает | откуда запрос»: под «-- @part» — запрос к секционированным core.session и
-- core.contract, под «-- @plain» — тот же запрос к копиям lab8.session_plain и lab8.contract_plain;
-- «-- @setup» — подготовка (выполняется перед обоими). Запросы — SELECT из функций api.* (формы условий те же).
-- Планы снимает labs/lab08/run_lab8.py (explain/<имя>.txt, сводка — explain/INDEX.md): ANALYZE, прогрев, второй прогон.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab08/sql/03_compare.sql      -- выполнить обе формы
\set ON_ERROR_STOP on
\ir 00_params.sql

-- @cmp 3.1_operator_month | отсечение по времени: квартал сеансов, по списку: секция договоров провайдера | Журнал «Сеансы связи» оператора за месяц (запрос 3 ЛР 5, api.q_sessions): соединение по коду договора, отбор по провайдеру договора
-- @part
SELECT count(*) AS sessions, sum(s.cost) AS cost
FROM core.session s
JOIN core.contract c ON c.id = s.contract_id
WHERE c.provider_id = :q_provider
  AND s.started_at >= '2026-09-01' AND s.started_at < '2026-10-01';
-- @plain
SELECT count(*) AS sessions, sum(s.cost) AS cost
FROM lab8.session_plain s
JOIN lab8.contract_plain c ON c.id = s.contract_id
WHERE c.provider_id = :q_provider
  AND s.started_at >= '2026-09-01' AND s.started_at < '2026-10-01';

-- @cmp 3.2_two_levels | отсечение на двух уровнях и провайдер сеанса: соединение по составному ключу | Тот же журнал оператора, соединение по обоим столбцам внешнего ключа (contract_id, provider_id): условие на провайдера переходит на сеансы — читаются только строки своего провайдера
-- @part
SELECT count(*) AS sessions, sum(s.cost) AS cost
FROM core.session s
JOIN core.contract c ON c.id = s.contract_id AND c.provider_id = s.provider_id
WHERE c.provider_id = :q_provider
  AND s.started_at >= '2026-09-01' AND s.started_at < '2026-10-01';
-- @plain
SELECT count(*) AS sessions, sum(s.cost) AS cost
FROM lab8.session_plain s
JOIN lab8.contract_plain c ON c.id = s.contract_id AND c.provider_id = s.provider_id
WHERE c.provider_id = :q_provider
  AND s.started_at >= '2026-09-01' AND s.started_at < '2026-10-01';

-- @cmp 3.3_chief_quarter | отсечение по времени: аналитик, все провайдеры, квартал | Выручка по провайдерам за III квартал 2026 года (ветвь сеансов api.v_revenue_items, отчёты «Выручка по периодам», «Доли провайдеров»)
-- @part
SELECT count(DISTINCT c.provider_id) AS providers, count(*) AS sessions, sum(s.cost) AS cost
FROM core.session s
JOIN core.contract c ON c.id = s.contract_id
WHERE s.started_at >= '2026-07-01' AND s.started_at < '2026-10-01';
-- @plain
SELECT count(DISTINCT c.provider_id) AS providers, count(*) AS sessions, sum(s.cost) AS cost
FROM lab8.session_plain s
JOIN lab8.contract_plain c ON c.id = s.contract_id
WHERE s.started_at >= '2026-07-01' AND s.started_at < '2026-10-01';

-- @cmp 3.4_chief_all_time | отсечения нет: условие на всё время данных | Выручка по кварталам за всё время (отчёт аналитика за 2024–2026 годы): читаются все секции — секционирование не помогает
-- @part
SELECT to_char(date_trunc('quarter', s.started_at), 'YYYY-"Q"Q') AS quarter, count(*) AS sessions, sum(s.cost) AS cost
FROM core.session s
GROUP BY 1
ORDER BY 1;
-- @plain
SELECT to_char(date_trunc('quarter', s.started_at), 'YYYY-"Q"Q') AS quarter, count(*) AS sessions, sum(s.cost) AS cost
FROM lab8.session_plain s
GROUP BY 1
ORDER BY 1;

-- @cmp 3.5_contract_card | отсечения нет: сеансы договора без периода | Карточка договора, вкладка «Сеансы» (запрос 2 ЛР 5 без периода): по индексу (contract_id, started_at) в каждой секции и слияние — дороже, чем в обычной таблице
-- @part
SELECT s.started_at, s.volume_mb, s.cost
FROM core.session s
WHERE s.contract_id = :q_contract
ORDER BY s.started_at DESC
LIMIT 20;
-- @plain
SELECT s.started_at, s.volume_mb, s.cost
FROM lab8.session_plain s
WHERE s.contract_id = :q_contract
ORDER BY s.started_at DESC
LIMIT 20;

-- @cmp 3.6_contracts_provider | отсечение по списку: договоры провайдера | Договоры провайдера, заключённые в 2026 году (запрос 4 ЛР 5, api.q_contracts): читается только секция провайдера
-- @part
SELECT count(*) AS contracts, sum(c.connection_fee) AS fees
FROM core.contract c
WHERE c.provider_id = :q_provider AND c.connected_on >= '2026-01-01';
-- @plain
SELECT count(*) AS contracts, sum(c.connection_fee) AS fees
FROM lab8.contract_plain c
WHERE c.provider_id = :q_provider AND c.connected_on >= '2026-01-01';

-- @cmp 3.7_subscribers_visible | отсечение по списку в полусоединении | Абоненты, видимые оператору (D25, api.v_subscribers): у провайдера есть договор с абонентом — проверка только в секции своего провайдера
-- @part
SELECT count(*) AS subscribers
FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = :q_provider);
-- @plain
SELECT count(*) AS subscribers
FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM lab8.contract_plain c WHERE c.subscriber_id = s.id AND c.provider_id = :q_provider);

-- @cmp 3.8_idle_contracts | отсечения по времени нет: последний сеанс договора | «Договоры без сеансов более 30 дней» (запрос 14 ЛР 6, api.q_idle_contracts): max(started_at) по договору ищется во всех секциях
-- @part
SELECT count(*) AS idle_contracts
FROM (SELECT c.id
      FROM core.contract c
      LEFT JOIN core.session se ON se.contract_id = c.id
      WHERE c.provider_id = :q_provider AND c.closed_on IS NULL AND c.connected_on < current_date - 30
      GROUP BY c.id, c.provider_id
      HAVING max(se.started_at) IS NULL OR max(se.started_at) < (current_date - 30)::timestamptz) x;
-- @plain
SELECT count(*) AS idle_contracts
FROM (SELECT c.id
      FROM lab8.contract_plain c
      LEFT JOIN lab8.session_plain se ON se.contract_id = c.id
      WHERE c.provider_id = :q_provider AND c.closed_on IS NULL AND c.connected_on < current_date - 30
      GROUP BY c.id, c.provider_id
      HAVING max(se.started_at) IS NULL OR max(se.started_at) < (current_date - 30)::timestamptz) x;

-- @cmp 3.9_idle_rewritten | запрос под секции: условие на время вместо max — отсечение при выполнении | Тот же отбор, переписанный: «нет сеанса после границы» (NOT EXISTS с started_at ≥ граница) — читаются только секции после границы; результат тот же
-- @part
SELECT count(*) AS idle_contracts
FROM core.contract c
WHERE c.provider_id = :q_provider AND c.closed_on IS NULL AND c.connected_on < current_date - 30
  AND NOT EXISTS (SELECT 1 FROM core.session se
                  WHERE se.contract_id = c.id AND se.provider_id = c.provider_id
                    AND se.started_at >= (current_date - 30)::timestamptz);
-- @plain
SELECT count(*) AS idle_contracts
FROM lab8.contract_plain c
WHERE c.provider_id = :q_provider AND c.closed_on IS NULL AND c.connected_on < current_date - 30
  AND NOT EXISTS (SELECT 1 FROM lab8.session_plain se
                  WHERE se.contract_id = c.id AND se.provider_id = c.provider_id
                    AND se.started_at >= (current_date - 30)::timestamptz);

-- @cmp 3.10_generic_plan | отсечение при выполнении: общий план с параметрами | Функции api с параметрами периода (plpgsql готовит запрос с параметрами): общий план строится без значений, лишние секции исключаются при запуске (Subplans Removed)
-- @setup
PREPARE q_part (timestamptz, timestamptz) AS
    SELECT count(*) AS sessions, sum(cost) AS cost FROM core.session WHERE started_at >= $1 AND started_at < $2;
PREPARE q_plain (timestamptz, timestamptz) AS
    SELECT count(*) AS sessions, sum(cost) AS cost FROM lab8.session_plain WHERE started_at >= $1 AND started_at < $2;
SET plan_cache_mode = force_generic_plan;
-- @part
EXECUTE q_part('2026-07-01', '2026-10-01');
-- @plain
EXECUTE q_plain('2026-07-01', '2026-10-01');
