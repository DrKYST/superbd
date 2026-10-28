-- Снимки результатов запросов 17–23 для подраздела 4.7 ПЗ (pgAdmin, Query Tool, база superbd).
-- pgAdmin подключён как postgres; пароли нигде не вводятся и не хранятся. Каждый блок выполняется отдельно:
-- выделить блок и нажать F5 (Query Tool показывает результат последнего запроса блока). Снимок — только панель
-- результата (Data Output), без текста запроса. Файлы — coursework/pz/img/pga_q17.png … pga_q23.png.

-- ============================================================================ pga_q17.png
-- Запрос 17: абоненты и договоры по типам — всего и в том числе (руководитель «ДонНет»)
SET SESSION AUTHORIZATION mgr_donnet;
SELECT title AS "Тип абонента", subscribers AS "Абонентов", contracts AS "Договоров",
       contracts_active AS "В т. ч. действующих"
FROM api.v_subscriber_type_totals;
RESET SESSION AUTHORIZATION;

-- ============================================================================ pga_q18.png
-- Запрос 18: трафик абонентов по маске «*школа*» за январь–сентябрь 2026 (руководитель «ДонНет»)
SET SESSION AUTHORIZATION mgr_donnet;
SELECT name AS "Абонент", subscriber_type AS "Тип абонента", contracts AS "Договоров", sessions AS "Сеансов",
       volume_mb AS "Трафик, Мб", cost AS "Сумма, руб.", total_count AS "Всего абонентов",
       total_volume_mb AS "Итого Мб", total_cost AS "Итого, руб."
FROM api.q_subscriber_traffic('*школа*', '2026-01-01', '2026-09-30');
RESET SESSION AUTHORIZATION;

-- ============================================================================ pga_q19.png
-- Запрос 19: трафик договора по месяцам за январь–сентябрь 2026 (оператор «ДонНет»).
-- Договор — первый договор «ДонНет» с сеансами в каждом месяце периода; код выбирается суперпользователем
-- и передаётся через параметр сеанса demo.c19 (оператор таблиц не читает).
SELECT set_config('demo.c19', (
    SELECT c.id::text
    FROM core.contract c
    JOIN core.provider p ON p.id = c.provider_id AND p.name = 'ДонНет'
    JOIN core.session se ON se.contract_id = c.id AND se.provider_id = c.provider_id
    WHERE se.started_at >= '2026-01-01' AND se.started_at < '2026-10-01'
    GROUP BY c.id HAVING count(DISTINCT date_trunc('month', se.started_at)) = 9
    ORDER BY c.id LIMIT 1), false);
SET SESSION AUTHORIZATION op_donnet;
SELECT period_title AS "Месяц", sessions AS "Сеансов", volume_mb AS "Трафик, Мб",
       full_cost AS "Без скидки, руб.", discount AS "Скидка, руб.", cost AS "К оплате, руб."
FROM api.report_contract_months(current_setting('demo.c19')::integer, '2026-01-01', '2026-09-30');
RESET SESSION AUTHORIZATION;

-- ============================================================================ pga_q20.png
-- Запрос 20: доходные операции своего провайдера с начала текущего месяца (руководитель «ДонНет»)
SET SESSION AUTHORIZATION mgr_donnet;
SELECT at AS "Дата и время", kind AS "Операция", amount AS "Сумма, руб.", volume_mb AS "Трафик, Мб"
FROM api.v_revenue_items
WHERE at >= date_trunc('month', current_date)
ORDER BY at DESC
LIMIT 15;
RESET SESSION AUTHORIZATION;

-- ============================================================================ pga_q21.png
-- Запрос 21: абоненты, у которых были сеансы по тарифу «Образовательный», январь–сентябрь 2026 (руководитель «ДонНет»)
SET SESSION AUTHORIZATION mgr_donnet;
SELECT name AS "Абонент", subscriber_type AS "Тип абонента", city AS "Город", contracts AS "Договоров",
       total_count AS "Всего абонентов"
FROM api.q_tariff_subscribers((SELECT id FROM api.lookup_tariffs() WHERE name = 'Образовательный'),
                              '2026-01-01', '2026-09-30');
RESET SESSION AUTHORIZATION;

-- ============================================================================ pga_q22.png
-- Запрос 22: доли провайдеров в выручке за январь–сентябрь 2026 — первые 4 и «Прочие» (главный аналитик)
SET SESSION AUTHORIZATION chief_main;
SELECT provider_group AS "Провайдер", providers AS "Провайдеров", contracts AS "Договоров",
       volume_mb AS "Трафик, Мб", revenue AS "Выручка, руб.", share_pct AS "Доля, %"
FROM api.report_provider_shares('2026-01-01', '2026-09-30')
WHERE period IS NULL;
RESET SESSION AUTHORIZATION;

-- ============================================================================ pga_q23.png
-- Запрос 23: абоненты с трафиком выше среднего за III квартал 2026 (руководитель «ДонНет»)
SET SESSION AUTHORIZATION mgr_donnet;
SELECT name AS "Абонент", subscriber_type AS "Тип абонента", volume_mb AS "Трафик, Мб",
       avg_mb AS "Среднее, Мб", above_pct AS "Выше среднего, %", total_count AS "Всего абонентов"
FROM api.q_subscribers_above_avg('2026-07-01', '2026-09-30');
RESET SESSION AUTHORIZATION;
