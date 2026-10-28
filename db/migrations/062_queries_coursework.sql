-- 062. Запросы ТЗ курсового проекта — виды, которых нет в заданиях ЛР 5 и ЛР 6 (docs/analysis/queries-plan.md, D31).
-- Нумерация сквозная: 1–10 — ЛР 5 (060), 11–16 — ЛР 6 (061), 17–23 — ТЗ курсового проекта (здесь и в 061).
--   17 v_subscriber_type_totals — абоненты и договоры по типам: «Всего» и «в том числе» (итоговый без условия, ROLLUP)
--   18 q_subscriber_traffic     — трафик абонентов, наименование по маске (итоговый с условием на данные по маске)
--   19 report_contract_months   — трафик договора по месяцам (итоговый с условием на данные; планы с индексом и без)
--   20 v_revenue_items          — доходные операции, UNION ALL (061)
--   21 q_tariff_subscribers     — абоненты, пользовавшиеся тарифом (подзапрос с IN)
--   22 report_provider_shares   — доли провайдеров (подзапрос с CASE, 061)
--   23 q_subscribers_above_avg  — абоненты с трафиком выше среднего (подзапрос с операциями над итоговыми данными)
-- Оптимизация — как в 060 и 061 (D24): видимость provider_id = ANY (массив), выражения от ввода — один раз в DECLARE,
-- отбор и группировка до соединения; регулярных выражений нет.
SET ROLE app_owner;

-- ============================================================================ служебные

-- Шаблон LIKE из маски пользователя: * — любые символы, ? — один символ. Служебные символы LIKE во вводе
-- (\, %, _) экранируются и ищутся как обычные символы; регистр не учитывается. Символы заменяются translate().
CREATE OR REPLACE FUNCTION sec.like_mask(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE WHEN nullif(btrim(p_text), '') IS NULL THEN NULL
                ELSE translate(replace(replace(replace(lower(btrim(p_text)), '\', '\\'), '%', '\%'), '_', '\_'),
                               '*?', '%_') END
$$;
COMMENT ON FUNCTION sec.like_mask(text) IS
    'Шаблон LIKE из маски: * — любые символы, ? — один символ; \, %, _ во вводе пользователя экранируются, нижний регистр';

-- ============================================================================ 17. Абоненты и договоры по типам
-- Сводка по реестру абонентов: строка «Всего», под ней «в том числе юридические лица» и типы юридических лиц,
-- «в том числе физические лица» и типы физических лиц. Итоги «всего / в том числе» есть и в строках (два уровня
-- ROLLUP: признак юридического лица → тип), и в колонках (договоров всего, в том числе действующих). Подпись строки,
-- уровень отступа и порядок (sort_order) формирует сервер. Условий от пользователя нет — представление.
-- Видимость — как в запросах 6 и 8 (D25): главному аналитику — весь реестр, включая абонентов без договоров (левое
-- соединение: count(c.id) у такого абонента — 0), руководителю — абоненты, у которых есть договор с его провайдером,
-- и только договоры этого провайдера. Ветви видимости — UNION ALL с условием-константой (выполняется ветвь своей
-- роли, D24): у руководителя IN становится полусоединением с договорами провайдера, абоненты читаются по ключу.
-- Абонент с несколькими договорами даёт несколько строк соединения — абоненты считаются count(DISTINCT s.id).
CREATE OR REPLACE VIEW api.v_subscriber_type_totals WITH (security_barrier = true) AS
SELECT CASE WHEN grouping(st.is_legal) = 1 THEN 'Всего'
            WHEN grouping(st.name) = 1 THEN CASE WHEN st.is_legal THEN 'в том числе юридические лица'
                                                 ELSE 'в том числе физические лица' END
            ELSE st.name END                                AS title,
       2 - grouping(st.is_legal) - grouping(st.name)       AS level,        -- 0 «Всего», 1 «в том числе», 2 тип
       count(DISTINCT s.id)                                 AS subscribers,
       count(c.id)                                          AS contracts,
       count(c.id) FILTER (WHERE c.closed_on IS NULL)      AS contracts_active,
       row_number() OVER (ORDER BY grouping(st.is_legal) DESC, st.is_legal DESC,   -- «Всего», юридические, физические
                                   grouping(st.name) DESC, min(st.id)) AS sort_order
-- разграничение доступа (не условие запроса): аналитик — весь реестр, руководитель — абоненты своего провайдера
FROM (SELECT s0.id, s0.subscriber_type_id FROM core.subscriber s0
      WHERE (SELECT sec.current_group()) IS NOT DISTINCT FROM 'grp_chief'
      UNION ALL
      SELECT s0.id, s0.subscriber_type_id FROM core.subscriber s0
      WHERE (SELECT sec.current_group()) IS DISTINCT FROM 'grp_chief'
        AND s0.id IN (SELECT v.subscriber_id FROM core.contract v
                      WHERE v.provider_id = ANY ((SELECT sec.scope_data())::integer[]))) s
JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
LEFT JOIN core.contract c   ON c.subscriber_id = s.id
                           AND c.provider_id = ANY ((SELECT sec.scope_data())::integer[])
GROUP BY ROLLUP (st.is_legal, st.name)
ORDER BY sort_order;
COMMENT ON VIEW api.v_subscriber_type_totals IS
    'Запрос 17 (ТЗ курсового проекта). Абоненты и договоры по типам абонентов: «Всего», «в том числе» юридические и физические лица и их типы (GROUP BY ROLLUP), договоров всего и в том числе действующих; руководитель — абоненты и договоры своего провайдера, аналитик — весь реестр';

-- ============================================================================ 18. Трафик абонентов по маске наименования
-- По абонентам, наименование которых подходит под маску: тип, договоров с сеансами, сеансов, Мб и сумма за период;
-- «Итого» — оконные суммы по всему отбору, как в запросах 2 и 3. Маска: * — любые символы, ? — один символ
-- (sec.like_mask, шаблон строится один раз). В отличие от поиска запроса 8 («начинается с», по индексу
-- uq_subscriber_lower_name_phone_digits) подстановочный символ может стоять в начале — тогда индекс не помогает и
-- абоненты читаются целиком (8 000 строк); дальше договоры отобранных абонентов — по индексу абонента, их сеансы за
-- период — по индексу (contract_id, started_at) в секциях периода. План — с фактическим шаблоном (force_custom_plan):
-- маска без подстановочного символа в начале («Школа*») ищется по индексу, общий план шаблона не знает.
DROP FUNCTION IF EXISTS api.q_subscriber_traffic(text, date, date, integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_subscriber_traffic(
    p_mask text,
    p_from date,
    p_to date,
    p_provider_id integer DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, name text, subscriber_type text, contracts bigint, sessions bigint, volume_mb numeric, cost numeric,
    total_count bigint, total_sessions numeric, total_volume_mb numeric, total_cost numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_scope integer[] := sec.scope_data(p_provider_id);    -- руководитель — свой, аналитик — все или выбранный
    v_like text := sec.like_mask(p_mask);
BEGIN
    PERFORM sec.require_group(ARRAY['grp_manager', 'grp_chief']);
    IF v_like IS NULL THEN
        RAISE EXCEPTION 'Укажите маску наименования: * — любые символы, ? — один символ' USING ERRCODE = 'P0001';
    END IF;
    PERFORM sec.check_report_period(p_from, p_to, NULL, false);
    RETURN QUERY
    SELECT s.id, s.name::text, st.name::text,
           count(DISTINCT c.id), count(*), sum(se.volume_mb), sum(se.cost),
           count(*) OVER (), sum(count(*)) OVER (), sum(sum(se.volume_mb)) OVER (), sum(sum(se.cost)) OVER ()
    FROM core.subscriber s
    JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
    JOIN core.contract c        ON c.subscriber_id = s.id
    JOIN core.session se        ON se.contract_id = c.id AND se.provider_id = c.provider_id
    WHERE lower(s.name) LIKE v_like
      AND c.provider_id = ANY (v_scope)
      AND se.started_at >= p_from AND se.started_at < p_to + 1
    GROUP BY s.id, st.id
    ORDER BY s.name, s.id
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_subscriber_traffic(text, date, date, integer, integer, integer) IS
    'Запрос 18 (ТЗ курсового проекта). Трафик абонентов, наименование которых подходит под маску (* — любые символы, ? — один символ), за период: договоров, сеансов, Мб, сумма и итоги по отбору; руководитель — свой провайдер, аналитик — все или выбранный';

-- ============================================================================ 19. Трафик договора по месяцам
-- По месяцам периода — сеансов, Мб, стоимость без скидки (Мб × цена 1 Мб договора), скидка и сумма к оплате, строка
-- «Итого» (ROLLUP). Условие на данные — договор и период: в секциях-кварталах периода сеансы договора находятся по
-- индексу ix_session_contract_id_started_at (одно условие поиска). Тот же вызов с запретом индексного доступа
-- (SET LOCAL enable_indexscan = off, enable_bitmapscan = off) читает каждую секцию целиком — «без использования
-- индекса»: результат тот же, разные план, время и число прочитанных страниц (coursework/queries/explain/q19_*.txt).
-- Секции вне периода отсекаются при запуске запроса (в плане — Subplans Removed). План строится при каждом вызове
-- (force_custom_plan) — запрет индексного доступа действует и на повторный вызов в том же сеансе. Строку договора
-- (одну) планировщик и при запрете берёт по первичному ключу — узел помечен Disabled: true.
-- Видимость — как в запросе 2: сеансы чужого договора не видны (пустой результат, без строки «Итого»).
DROP FUNCTION IF EXISTS api.report_contract_months(integer, date, date);
CREATE OR REPLACE FUNCTION api.report_contract_months(
    p_contract_id integer,
    p_from date,
    p_to date)
RETURNS TABLE (
    period date, period_title text, sessions bigint, volume_mb numeric,
    full_cost numeric, discount numeric, cost numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_scope integer[] := sec.scope_data();
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator', 'grp_manager', 'grp_chief']);
    IF p_contract_id IS NULL THEN
        RAISE EXCEPTION 'Выберите договор' USING ERRCODE = 'P0001';
    END IF;
    PERFORM sec.check_report_period(p_from, p_to, NULL, false);
    RETURN QUERY
    SELECT k.period, CASE WHEN k.period IS NULL THEN 'Итого' ELSE sec.period_title('month', k.period) END,
           k.sessions, k.volume_mb, round(k.full_cost, 2), round(k.full_cost, 2) - k.cost, k.cost
    FROM (SELECT date_trunc('month', se.started_at)::date AS period,          -- NULL у строки «Итого»
                 count(*) AS sessions, sum(se.volume_mb) AS volume_mb,
                 sum(se.volume_mb * c.price_per_mb) AS full_cost, sum(se.cost) AS cost
          FROM core.session se
          JOIN core.contract c ON c.id = se.contract_id AND c.provider_id = se.provider_id
          WHERE se.contract_id = p_contract_id
            AND se.started_at >= p_from AND se.started_at < p_to + 1
            AND c.provider_id = ANY (v_scope)
          GROUP BY ROLLUP (date_trunc('month', se.started_at)::date)
          HAVING count(*) > 0) k                     -- без видимых сеансов ROLLUP дал бы пустую строку «Итого»
    ORDER BY k.period NULLS LAST;
END $$;
COMMENT ON FUNCTION api.report_contract_months(integer, date, date) IS
    'Запрос 19 (ТЗ курсового проекта). Трафик договора по месяцам периода: сеансов, Мб, стоимость без скидки, скидка, сумма и строка «Итого» (ROLLUP); условие на договор и период выполняется по индексу (contract_id, started_at) в секциях периода, без индекса — чтением секций целиком';

-- ============================================================================ 21. Абоненты, пользовавшиеся тарифом
-- Абоненты, у которых за период были сеансы по выбранному тарифу: наименование, тип, город, договоров у видимых
-- провайдеров. Условие — подзапрос с IN: абонент входит во множество абонентов договоров с сеансами по тарифу.
-- Соединение с сеансами повторило бы абонента столько раз, сколько у него сеансов, — нужен только факт; подзапрос
-- не зависит от строки абонента и выполняется один раз (полусоединение). Сеансы тарифа за период — по индексу
-- ix_session_tariff_id в секциях периода. Число договоров — по договорам абонента у видимых провайдеров.
DROP FUNCTION IF EXISTS api.q_tariff_subscribers(integer, date, date, integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_tariff_subscribers(
    p_tariff_id integer,
    p_from date,
    p_to date,
    p_provider_id integer DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, name text, subscriber_type text, city text, contracts bigint, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_scope integer[] := sec.scope_data(p_provider_id);    -- руководитель — свой, аналитик — все или выбранный
BEGIN
    PERFORM sec.require_group(ARRAY['grp_manager', 'grp_chief']);
    IF p_tariff_id IS NULL THEN
        RAISE EXCEPTION 'Выберите тариф' USING ERRCODE = 'P0001';
    END IF;
    PERFORM sec.check_report_period(p_from, p_to, NULL, false);
    RETURN QUERY
    SELECT s.id, s.name::text, st.name::text, ci.name::text, count(*), count(*) OVER ()
    FROM core.subscriber s
    JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
    JOIN ref.city ci            ON ci.id = s.city_id
    JOIN core.contract c        ON c.subscriber_id = s.id AND c.provider_id = ANY (v_scope)
    WHERE s.id IN (SELECT x.subscriber_id
                   FROM core.session se
                   JOIN core.contract x ON x.id = se.contract_id AND x.provider_id = se.provider_id
                   WHERE se.tariff_id = p_tariff_id
                     AND se.started_at >= p_from AND se.started_at < p_to + 1
                     AND se.provider_id = ANY (v_scope))
    GROUP BY s.id, st.id, ci.id
    ORDER BY s.name, s.id
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_tariff_subscribers(integer, date, date, integer, integer, integer) IS
    'Запрос 21 (ТЗ курсового проекта). Абоненты, у которых за период были сеансы по выбранному тарифу (подзапрос с IN): тип, город, договоров у видимых провайдеров; руководитель — свой провайдер, аналитик — все или выбранный';

-- ============================================================================ 23. Абоненты с трафиком выше среднего
-- Внутренний запрос (t) — трафик каждого абонента за период (итог по абоненту). Скалярный подзапрос — среднее этих
-- итогов (avg над sum — операция над итоговыми данными); внешний запрос — абоненты, у которых итог больше среднего,
-- и насколько: (Мб / среднее − 1) × 100. Среднее — по абонентам, у которых были сеансы у видимых провайдеров (у
-- руководителя — среднее по своему провайдеру). Итоги считаются один раз (CTE читается трижды, сеансы — один);
-- некоррелированный скалярный подзапрос вычисляется один раз (InitPlan). Окно над итогами — в запросе 22.
DROP FUNCTION IF EXISTS api.q_subscribers_above_avg(date, date, integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_subscribers_above_avg(
    p_from date,
    p_to date,
    p_provider_id integer DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, name text, subscriber_type text, volume_mb numeric, avg_mb numeric, above_pct numeric,
    total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_scope integer[] := sec.scope_data(p_provider_id);    -- руководитель — свой, аналитик — все или выбранный
BEGIN
    PERFORM sec.require_group(ARRAY['grp_manager', 'grp_chief']);
    PERFORM sec.check_report_period(p_from, p_to, NULL, false);
    RETURN QUERY
    WITH t AS (            -- итог по абоненту: трафик за период у видимых провайдеров
        SELECT c.subscriber_id, sum(se.volume_mb) AS volume_mb
        FROM core.session se
        JOIN core.contract c ON c.id = se.contract_id AND c.provider_id = se.provider_id
        WHERE se.started_at >= p_from AND se.started_at < p_to + 1
          AND c.provider_id = ANY (v_scope)
        GROUP BY c.subscriber_id)
    SELECT s.id, s.name::text, st.name::text, t.volume_mb,
           round((SELECT avg(t0.volume_mb) FROM t t0), 3),
           round((t.volume_mb / (SELECT avg(t0.volume_mb) FROM t t0) - 1) * 100, 1),
           count(*) OVER ()
    FROM t
    JOIN core.subscriber s      ON s.id = t.subscriber_id
    JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
    WHERE t.volume_mb > (SELECT avg(t0.volume_mb) FROM t t0)
    ORDER BY t.volume_mb DESC, s.id
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_subscribers_above_avg(date, date, integer, integer, integer) IS
    'Запрос 23 (ТЗ курсового проекта). Абоненты, чей трафик за период выше среднего по абонентам видимых провайдеров: Мб, среднее, на сколько процентов выше (скалярный подзапрос со средним итогов); руководитель — свой провайдер, аналитик — все или выбранный';

-- ============================================================================ права
REVOKE ALL ON FUNCTION sec.like_mask(text) FROM PUBLIC;
REVOKE ALL ON api.v_subscriber_type_totals FROM PUBLIC;
REVOKE ALL ON FUNCTION
    api.q_subscriber_traffic(text, date, date, integer, integer, integer),
    api.report_contract_months(integer, date, date),
    api.q_tariff_subscribers(integer, date, date, integer, integer, integer),
    api.q_subscribers_above_avg(date, date, integer, integer, integer)
FROM PUBLIC;

GRANT SELECT ON api.v_subscriber_type_totals TO grp_manager, grp_chief;
GRANT EXECUTE ON FUNCTION
    api.q_subscriber_traffic(text, date, date, integer, integer, integer),
    api.q_tariff_subscribers(integer, date, date, integer, integer, integer),
    api.q_subscribers_above_avg(date, date, integer, integer, integer)
TO grp_manager, grp_chief;
GRANT EXECUTE ON FUNCTION api.report_contract_months(integer, date, date) TO grp_operator, grp_manager, grp_chief;

RESET ROLE;
