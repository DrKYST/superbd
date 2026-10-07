-- 061. Запросы ЛР 6 — итоговые запросы, объединение, подзапросы (docs/analysis/queries-plan.md, D28).
-- Каждый запрос — источник данных экрана, отчёта «Статистики» или счётчика «Текущих дел»; тип — самый простой,
-- которым задача решается (обоснование каждого — в плане запросов).
--   15а v_revenue_items          — доходные операции: подключения ∪ сеансы (UNION ALL)
--   11  v_user_groups            — пользователи по группам, «всего / в том числе» (итоговый без условия, ROLLUP)
--   12  report_new_contracts     — новые договоры по типам абонентов (итоговый с условием на данные)
--   13  q_shared_subscribers     — абоненты не меньше N провайдеров, их сведения меняет администратор (итоговый с условием на группы)
--   14  q_idle_contracts         — договоры без сеансов больше N дней (итоговый с условием на данные и на группы)
--   15б report_revenue           — выручка по периодам (запрос на запросе 15а, ROLLUP — строка «Итого»)
--   16  q_providers(p_without_staff) — провайдеры без сотрудников (подзапрос NOT IN); функция — в 060 (запрос 10)
--   17  report_provider_shares   — доли провайдеров: первые N и «Прочие» (подзапрос, CASE, операции над итогами)
--   —   report_top_subscribers   — крупнейшие абоненты (итоговый с условием на данные над 15а)
-- Счётчики «Текущих дел» (056) берут числа из этих же функций: «Договоры без сеансов более 30 дней» — total_count
-- запроса 14, «Провайдеры без сотрудников» — total_count запроса 16, «Выручка за месяц» — строка «Итого» запроса 15б.
-- Оптимизация — как в 060 (D24): видимость provider_id = ANY (массив), отбор до соединения, группировка до соединения.
SET ROLE app_owner;

-- ============================================================================ служебные

-- Проверка параметров отчёта: период задан и не перевёрнут, периодичность — месяц, квартал или год.
CREATE OR REPLACE FUNCTION sec.check_report_period(p_from date, p_to date, p_grain text)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'Укажите период' USING ERRCODE = 'P0001';
    END IF;
    IF p_to < p_from THEN
        RAISE EXCEPTION 'Дата окончания периода раньше даты начала' USING ERRCODE = 'P0001';
    END IF;
    IF p_grain IS NOT NULL AND p_grain NOT IN ('month', 'quarter', 'year') THEN
        RAISE EXCEPTION 'Периодичность: месяц, квартал или год' USING ERRCODE = 'P0001';
    END IF;
END $$;
COMMENT ON FUNCTION sec.check_report_period(date, date, text) IS
    'Проверка параметров отчёта: период задан, окончание не раньше начала, периодичность month / quarter / year';

-- Подпись периода отчёта: «Январь 2026», «III квартал 2026», «2026».
CREATE OR REPLACE FUNCTION sec.period_title(p_grain text, p_period date)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE p_grain
               WHEN 'month' THEN (ARRAY['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август',
                                        'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'])[extract(month FROM p_period)::int]
                                 || ' ' || extract(year FROM p_period)
               WHEN 'quarter' THEN (ARRAY['I', 'II', 'III', 'IV'])[extract(quarter FROM p_period)::int]
                                   || ' квартал ' || extract(year FROM p_period)
               ELSE extract(year FROM p_period)::text END
$$;
COMMENT ON FUNCTION sec.period_title(text, date) IS 'Подпись периода отчёта по периодичности: месяц, квартал или год';

-- Число со словом в нужной форме: 1 провайдер, 3 провайдера, 27 провайдеров, 11 провайдеров.
CREATE OR REPLACE FUNCTION sec.count_title(p_n bigint, p_one text, p_few text, p_many text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT p_n || ' ' || CASE WHEN p_n % 100 BETWEEN 11 AND 14 THEN p_many
                              WHEN p_n % 10 = 1 THEN p_one
                              WHEN p_n % 10 BETWEEN 2 AND 4 THEN p_few
                              ELSE p_many END
$$;
COMMENT ON FUNCTION sec.count_title(bigint, text, text, text) IS 'Число и существительное в согласованной форме («27 провайдеров»)';

-- ============================================================================ 15а. Доходные операции (UNION ALL)
-- Источник отчётов «Выручка по периодам» (15б), «Доли провайдеров» (17), «Крупнейшие абоненты» и счётчика
-- «Выручка за месяц». У выручки два источника с разными датами: плата за подключение — одна на договор, в день
-- заключения; оплата трафика — в моменты сеансов. Соединение договора с сеансами повторило бы плату за подключение
-- на каждом сеансе и потеряло бы договоры без сеансов, поэтому строки источников объединяются. UNION ALL, а не UNION:
-- одинаковые суммы — разные операции, удалять «дубли» нельзя; сортировка для удаления дублей тоже не нужна.
-- Условия запросов к представлению (период, провайдер, тип абонента) планировщик проталкивает в обе ветви:
-- сеансы читаются по ix_session_started_at, договоры — по ix_contract_provider_id_connected_on (первая колонка).
CREATE OR REPLACE VIEW api.v_revenue_items WITH (security_barrier = true) AS
SELECT c.provider_id,
       c.subscriber_id,
       s.subscriber_type_id,
       c.connected_on::timestamptz AS at,
       'подключение'::text AS kind,
       c.connection_fee::numeric AS amount,
       0::numeric AS volume_mb
FROM core.contract c
JOIN core.subscriber s ON s.id = c.subscriber_id
-- разграничение доступа: руководитель — свой провайдер, главный аналитик — все
WHERE c.provider_id = ANY ((SELECT sec.scope_data())::integer[])
UNION ALL
SELECT c.provider_id,
       c.subscriber_id,
       sb.subscriber_type_id,
       se.started_at,
       'трафик'::text,
       se.cost::numeric,
       se.volume_mb::numeric
FROM core.session se
JOIN core.contract c ON c.id = se.contract_id
JOIN core.subscriber sb ON sb.id = c.subscriber_id
WHERE c.provider_id = ANY ((SELECT sec.scope_data())::integer[]);
COMMENT ON VIEW api.v_revenue_items IS
    'Запрос 15а (ЛР 6). Доходные операции: плата за подключение договора (дата заключения) и оплата трафика сеанса (начало сеанса) — объединение UNION ALL; руководитель видит своего провайдера, аналитик — всех';

-- ============================================================================ 11. Пользователи по группам
-- Экран «Пользователи», панель «Группа / Кол-во» (макет Users.dc.html): «Все пользователи» и под ней — число
-- пользователей каждой группы; панель же — отбор списка api.q_users. Количества — только группировкой; строка «Все
-- пользователи» — ROLLUP: одна дополнительная группировка вместо второго запроса. Условий от пользователя нет, только
-- область видимости роли (D26): администратор приложения — свои и управляемые группы, администратор БД — администраторы.
-- Группа — прямое членство с наследованием, как в sec.group_of и q_users; пустые группы строк не дают.
CREATE OR REPLACE VIEW api.v_user_groups WITH (security_barrier = true) AS
SELECT CASE WHEN grouping(g.rolname) = 1 THEN 'Все пользователи'
            ELSE sec.group_title(g.rolname::text) END AS title,
       g.rolname::text AS group_name,                                   -- NULL у строки «Все пользователи»
       count(*) AS users,
       CASE WHEN grouping(g.rolname) = 1 THEN 0                         -- порядок строк панели: «Все пользователи» первой
            ELSE array_position(ARRAY['grp_dba', 'grp_admin', 'grp_chief', 'grp_manager', 'grp_operator']::name[],
                                g.rolname) END AS ord
FROM sec.app_user u
JOIN pg_catalog.pg_roles r        ON r.rolname = u.login
JOIN pg_catalog.pg_auth_members m ON m.member = r.oid AND m.inherit_option
JOIN pg_catalog.pg_roles g        ON g.oid = m.roleid
-- разграничение доступа: только группы, видимые роли (функция вызывается один раз)
WHERE g.rolname = ANY ((SELECT sec.visible_groups(sec.current_group()))::name[])
GROUP BY ROLLUP (g.rolname)
ORDER BY ord;
COMMENT ON VIEW api.v_user_groups IS
    'Запрос 11 (ЛР 6). Пользователи по группам: строка «Все пользователи» и число пользователей каждой видимой группы (GROUP BY ROLLUP); администраторы приложения и БД (D26)';

-- ============================================================================ 12. Новые договоры по типам абонентов
-- Отчёт «Статистика» → «Новые договоры по типам абонентов»: договоров, заключённых в каждом месяце (квартале, году),
-- по типам абонентов; ряд диаграммы — тип абонента. Количества — группировка; период и провайдер — условие на данные
-- (WHERE). Условия на группы нет: показываются все типы. Пара (период, тип) без договоров строки не даёт — на
-- диаграмме это ноль. Провайдер и период — индекс ix_contract_provider_id_connected_on: при узком отборе (руководитель,
-- квартал) — Bitmap Index Scan, при широком (аналитик, все провайдеры, год) — Seq Scan (labs/lab06/explain/).
DROP FUNCTION IF EXISTS api.report_new_contracts(date, date, text, integer);
CREATE OR REPLACE FUNCTION api.report_new_contracts(
    p_from date,
    p_to date,
    p_grain text DEFAULT 'month',
    p_provider_id integer DEFAULT NULL)
RETURNS TABLE (
    period date, period_title text, subscriber_type_id integer, subscriber_type text, contracts bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_scope integer[] := sec.scope_data(p_provider_id);    -- руководитель — свой, аналитик — все или выбранный
BEGIN
    PERFORM sec.require_group(ARRAY['grp_manager', 'grp_chief']);
    PERFORM sec.check_report_period(p_from, p_to, coalesce(p_grain, ''));
    RETURN QUERY
    SELECT k.period, sec.period_title(p_grain, k.period), st.id::integer, st.name::text, k.contracts
    FROM (SELECT date_trunc(p_grain, c.connected_on::timestamp)::date AS period, s.subscriber_type_id,
                 count(*) AS contracts
          FROM core.contract c
          JOIN core.subscriber s ON s.id = c.subscriber_id
          WHERE c.provider_id = ANY (v_scope) AND c.connected_on BETWEEN p_from AND p_to
          GROUP BY 1, s.subscriber_type_id) k
    JOIN ref.subscriber_type st ON st.id = k.subscriber_type_id
    ORDER BY k.period, st.id;
END $$;
COMMENT ON FUNCTION api.report_new_contracts(date, date, text, integer) IS
    'Запрос 12 (ЛР 6). Новые договоры по периодам (месяц, квартал, год) и типам абонентов за период; руководитель — свой провайдер, аналитик — все или выбранный';

-- ============================================================================ 13. Общие абоненты
-- «Справочники» → «Общие абоненты» (администратор приложения). Сведения реестра абонента, которого обслуживают
-- несколько провайдеров, меняет только администратор (D25, sec.check_subscriber_edit): оператор получает отказ и
-- обращается к нему. Список показывает таких абонентов; порог «провайдеров не меньше N» — параметр (по умолчанию 2 —
-- ровно правило D25; 3 и больше — абоненты, общие для многих провайдеров).
-- Вид — итоговый с условием на группы: «провайдеров не меньше N» относится к группе договоров абонента, а не к
-- отдельной строке, — WHERE его не выразит, нужен HAVING. Условий на данные нет — как и в правиле D25, учитываются и
-- расторгнутые договоры. Соединение абонента со справочниками и договорами и группировка — в одном запросе
-- (группировка по первичным ключам). Какие провайдеры — не раскрывается (договоры администратору недоступны), только их число.
DROP FUNCTION IF EXISTS api.q_shared_subscribers(integer, integer);
DROP FUNCTION IF EXISTS api.q_shared_subscribers(integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_shared_subscribers(
    p_min_providers integer DEFAULT 2,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, name text, subscriber_type text, city text, address text, phone text,
    providers bigint, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
BEGIN
    PERFORM sec.require_group(ARRAY['grp_admin']);
    IF p_min_providers IS NULL OR p_min_providers < 2 THEN
        RAISE EXCEPTION 'Общий абонент — абонент не меньше чем двух провайдеров' USING ERRCODE = 'P0001';
    END IF;
    RETURN QUERY
    SELECT s.id, s.name::text, st.name::text, ci.name::text, s.address::text, s.phone::text,
           count(DISTINCT c.provider_id), count(*) OVER ()
    FROM core.subscriber s
    JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
    JOIN ref.city ci            ON ci.id = s.city_id
    JOIN core.contract c        ON c.subscriber_id = s.id
    GROUP BY s.id, st.id, ci.id
    HAVING count(DISTINCT c.provider_id) >= p_min_providers
    ORDER BY s.name, s.id
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_shared_subscribers(integer, integer, integer) IS
    'Запрос 13 (ЛР 6). Общие абоненты — с договорами не меньше чем N провайдеров (HAVING, N ≥ 2), их сведения меняет администратор приложения (D25)';

-- ============================================================================ 14. Договоры без сеансов
-- Счётчик «Договоры без сеансов более 30 дней» (оператор, руководитель) открывает этот список. Последний сеанс —
-- max(started_at) по договору, значит группировка нужна уже для вывода; «последний сеанс раньше границы» — условие на
-- группу (HAVING); «договор действует, свой провайдер, заключён раньше границы» — условия на строки (WHERE).
-- Граница одна — current_date - p_days: договор, заключённый позже неё, ещё не простаивает. Счётчик берёт total_count.
DROP FUNCTION IF EXISTS api.q_idle_contracts(integer, integer, integer);
CREATE OR REPLACE FUNCTION api.q_idle_contracts(
    p_days integer DEFAULT 30,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0)
RETURNS TABLE (
    id integer, contract_no text, subscriber_id integer, subscriber_name text, phone text,
    connected_on date, last_session timestamptz, idle_days integer, total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
AS $$
DECLARE
    v_scope integer[] := sec.scope_data();
    v_border date := current_date - greatest(coalesce(p_days, 30), 1);
BEGIN
    PERFORM sec.require_group(ARRAY['grp_operator', 'grp_manager']);
    RETURN QUERY
    SELECT c.id, c.contract_no::text, s.id, s.name::text, coalesce(c.contact_phone, s.phone)::text,
           c.connected_on, max(se.started_at),
           current_date - coalesce(max(se.started_at)::date, c.connected_on),
           count(*) OVER ()
    FROM core.contract c
    JOIN core.subscriber s    ON s.id = c.subscriber_id
    LEFT JOIN core.session se ON se.contract_id = c.id
    WHERE c.provider_id = ANY (v_scope) AND c.closed_on IS NULL
      AND c.connected_on < v_border
    GROUP BY c.id, s.id
    HAVING coalesce(max(se.started_at), '-infinity') < v_border::timestamptz
    ORDER BY max(se.started_at) NULLS FIRST, c.connected_on, c.contract_no
    LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0);
END $$;
COMMENT ON FUNCTION api.q_idle_contracts(integer, integer, integer) IS
    'Запрос 14 (ЛР 6). Действующие договоры своего провайдера без сеансов больше N дней: последний сеанс и дней простоя (WHERE + GROUP BY + HAVING)';

-- ============================================================================ 15б. Выручка по периодам
-- Отчёт «Статистика» → «Выручка по периодам» (макет Stats.dc.html): по периодам — новых договоров, трафик, плата за
-- подключение, оплата трафика, выручка; строка «Итого»; отбор «Тип абонента». Итоги считаются по объединению 15а —
-- запрос на запросе; без него итоги каждого источника пришлось бы считать отдельно и соединять по периоду (FULL JOIN).
-- «Итого» — ROLLUP по периоду (period IS NULL). Этой же строкой считается счётчик «Выручка за месяц».
DROP FUNCTION IF EXISTS api.report_revenue(date, date, text, integer, integer);
CREATE OR REPLACE FUNCTION api.report_revenue(
    p_from date,
    p_to date,
    p_grain text DEFAULT 'month',
    p_provider_id integer DEFAULT NULL,
    p_subscriber_type_id integer DEFAULT NULL)
RETURNS TABLE (
    period date, period_title text, new_contracts bigint, volume_mb numeric,
    connection_fees numeric, traffic_fees numeric, revenue numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
BEGIN
    PERFORM sec.require_group(ARRAY['grp_manager', 'grp_chief']);
    PERFORM sec.check_report_period(p_from, p_to, coalesce(p_grain, ''));
    RETURN QUERY
    SELECT k.period, coalesce(sec.period_title(p_grain, k.period), 'Итого'),
           k.new_contracts, k.volume_mb, k.connection_fees, k.revenue - k.connection_fees, k.revenue
    FROM (SELECT date_trunc(p_grain, r.at)::date AS period,                            -- NULL — строка «Итого»
                 count(*) FILTER (WHERE r.kind = 'подключение')                    AS new_contracts,
                 coalesce(sum(r.volume_mb), 0)                                     AS volume_mb,
                 coalesce(sum(r.amount) FILTER (WHERE r.kind = 'подключение'), 0)  AS connection_fees,
                 coalesce(sum(r.amount), 0)                                        AS revenue
          FROM api.v_revenue_items r
          WHERE r.at >= p_from AND r.at < p_to + 1
            AND (p_provider_id IS NULL OR r.provider_id = p_provider_id)
            AND (p_subscriber_type_id IS NULL OR r.subscriber_type_id = p_subscriber_type_id)
          GROUP BY ROLLUP (1)) k
    ORDER BY k.period NULLS LAST;
END $$;
COMMENT ON FUNCTION api.report_revenue(date, date, text, integer, integer) IS
    'Запрос 15б (ЛР 6). Выручка по периодам: новых договоров, трафик, плата за подключение, оплата трафика, выручка и строка «Итого» — итоговый запрос к объединению 15а (запрос на запросе)';

-- ============================================================================ 17. Доли провайдеров
-- Отчёт главного аналитика «Выручка по периодам» (макет Stats_Chief): четыре крупнейших провайдера и «Прочие
-- (27 провайдеров)» — таблица «Провайдер / Договоров / Трафик / Выручка / Доля, %» с «Итого» и ряды диаграммы по
-- месяцам. Подпись группы зависит от места провайдера по выручке, а место — от его итога: внутренний запрос считает
-- итоги провайдера, место (row_number) и общий итог (sum … OVER ()) — операции над итоговыми данными; внешний —
-- CASE «первые N или Прочие» и повторную группировку. Место — по итогу за весь период (иначе первые N были бы свои в
-- каждом месяце). Провайдеры — из v_providers левым соединением: провайдер без выручки попадает в «Прочие».
-- «Договоров» — действующих на конец периода (в макете сумма столбца = счётчику «Действующих договоров»).
-- Строки с period IS NULL — таблица (последняя — «Итого», is_total), с периодом — точки рядов диаграммы
-- (p_grain IS NULL — только таблица). ord — номер группы: 1…p_top, p_top + 1 — «Прочие», p_top + 2 — «Итого».
-- Отбор «Тип абонента» (макет Stats_Chief) — по выручке и договорам абонентов этого типа.
DROP FUNCTION IF EXISTS api.report_provider_shares(date, date, integer, text);
DROP FUNCTION IF EXISTS api.report_provider_shares(date, date, integer, text, integer);
CREATE OR REPLACE FUNCTION api.report_provider_shares(
    p_from date,
    p_to date,
    p_top integer DEFAULT 4,
    p_grain text DEFAULT 'month',
    p_subscriber_type_id integer DEFAULT NULL)
RETURNS TABLE (
    ord integer, provider_group text, providers bigint, period date, period_title text,
    contracts bigint, volume_mb numeric, revenue numeric, share_pct numeric, is_total boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_top integer := least(greatest(coalesce(p_top, 4), 1), 10);
BEGIN
    PERFORM sec.require_group(ARRAY['grp_chief']);
    PERFORM sec.check_report_period(p_from, p_to, p_grain);
    RETURN QUERY
    WITH x AS (            -- провайдер: итоги за период, место по выручке, общий итог
        SELECT p.id, p.display_name,
               coalesce(k.contracts, 0)                                           AS contracts,
               coalesce(r.volume_mb, 0)                                           AS volume_mb,
               coalesce(r.revenue, 0)                                             AS revenue,
               least(row_number() OVER (ORDER BY coalesce(r.revenue, 0) DESC, p.id), v_top + 1)::integer AS grp,
               sum(coalesce(r.revenue, 0)) OVER ()                                AS total
        FROM api.v_providers p
        LEFT JOIN (SELECT i.provider_id, sum(i.volume_mb) AS volume_mb, sum(i.amount) AS revenue
                   FROM api.v_revenue_items i
                   WHERE i.at >= p_from AND i.at < p_to + 1
                     AND (p_subscriber_type_id IS NULL OR i.subscriber_type_id = p_subscriber_type_id)
                   GROUP BY i.provider_id) r ON r.provider_id = p.id
        LEFT JOIN (SELECT c.provider_id, count(*) AS contracts
                   FROM core.contract c
                   WHERE c.connected_on <= p_to AND (c.closed_on IS NULL OR c.closed_on > p_to)
                     AND (p_subscriber_type_id IS NULL
                          OR c.subscriber_id IN (SELECT s.id FROM core.subscriber s
                                                 WHERE s.subscriber_type_id = p_subscriber_type_id))
                   GROUP BY c.provider_id) k ON k.provider_id = p.id),
    t AS (                 -- группы «первые N» и «Прочие» и строка «Итого» (ROLLUP)
        SELECT coalesce(x.grp, v_top + 2) AS ord,
               CASE WHEN grouping(x.grp) = 1 THEN 'Итого'
                    WHEN x.grp <= v_top THEN min(x.display_name)
                    ELSE 'Прочие (' || sec.count_title(count(*), 'провайдер', 'провайдера', 'провайдеров') || ')'
               END AS provider_group,
               count(*) AS providers, sum(x.contracts)::bigint AS contracts,
               sum(x.volume_mb) AS volume_mb, sum(x.revenue) AS revenue,
               round(100 * sum(x.revenue) / nullif(max(x.total), 0), 1) AS share_pct,
               grouping(x.grp) = 1 AS is_total
        FROM x
        GROUP BY ROLLUP (x.grp))
    SELECT t.ord, t.provider_group, t.providers, NULL::date, NULL::text,
           t.contracts, t.volume_mb, t.revenue, t.share_pct, t.is_total
    FROM t
    UNION ALL
    SELECT x.grp, t.provider_group, t.providers, d.period, sec.period_title(p_grain, d.period),
           NULL::bigint, sum(i.volume_mb), sum(i.amount), NULL::numeric, false
    FROM x
    JOIN t ON t.ord = x.grp
    JOIN api.v_revenue_items i ON i.provider_id = x.id AND i.at >= p_from AND i.at < p_to + 1
                              AND (p_subscriber_type_id IS NULL OR i.subscriber_type_id = p_subscriber_type_id)
    CROSS JOIN LATERAL (SELECT date_trunc(p_grain, i.at)::date AS period) d
    WHERE p_grain IS NOT NULL
    GROUP BY x.grp, t.provider_group, t.providers, d.period
    ORDER BY 4 NULLS FIRST, 1;
END $$;
COMMENT ON FUNCTION api.report_provider_shares(date, date, integer, text, integer) IS
    'Запрос 17 (ЛР 6). Доли провайдеров в выручке за период: первые N по выручке и «Прочие» (CASE над местом из подзапроса), договоров, трафик, выручка, доля от общего итога, «Итого»; ряды по периодам для диаграммы; только главный аналитик';

-- ============================================================================ Крупнейшие абоненты
-- Отчёт «Статистика» → «Крупнейшие абоненты»: первые N абонентов по выручке за период — итоговый с условием на данные
-- над 15а (группировка по абоненту до соединения со справочниками). Доля — от выручки всех абонентов периода
-- (окно над итогами считается до LIMIT). Руководителю — выручка только своего провайдера.
DROP FUNCTION IF EXISTS api.report_top_subscribers(date, date, integer, integer);
CREATE OR REPLACE FUNCTION api.report_top_subscribers(
    p_from date,
    p_to date,
    p_top integer DEFAULT 10,
    p_provider_id integer DEFAULT NULL)
RETURNS TABLE (
    ord integer, subscriber_id integer, subscriber_name text, subscriber_type text,
    volume_mb numeric, revenue numeric, share_pct numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'Europe/Moscow'
SET plan_cache_mode = force_custom_plan
AS $$
BEGIN
    PERFORM sec.require_group(ARRAY['grp_manager', 'grp_chief']);
    PERFORM sec.check_report_period(p_from, p_to, NULL);
    RETURN QUERY
    SELECT k.rnk::integer, s.id, s.name::text, st.name::text, k.volume_mb, k.revenue,
           round(100 * k.revenue / nullif(k.total, 0), 1)
    FROM (SELECT r.subscriber_id, sum(r.volume_mb) AS volume_mb, sum(r.amount) AS revenue,
                 row_number() OVER (ORDER BY sum(r.amount) DESC, r.subscriber_id) AS rnk,
                 sum(sum(r.amount)) OVER () AS total
          FROM api.v_revenue_items r
          WHERE r.at >= p_from AND r.at < p_to + 1
            AND (p_provider_id IS NULL OR r.provider_id = p_provider_id)
          GROUP BY r.subscriber_id
          ORDER BY sum(r.amount) DESC, r.subscriber_id
          LIMIT least(greatest(coalesce(p_top, 10), 1), 100)) k
    JOIN core.subscriber s ON s.id = k.subscriber_id
    JOIN ref.subscriber_type st ON st.id = s.subscriber_type_id
    ORDER BY k.rnk;
END $$;
COMMENT ON FUNCTION api.report_top_subscribers(date, date, integer, integer) IS
    'Отчёт «Крупнейшие абоненты» (ЛР 6): первые N абонентов по выручке за период — трафик, выручка, доля от выручки периода; руководитель — свой провайдер, аналитик — все или выбранный';

-- ============================================================================ права
REVOKE ALL ON FUNCTION sec.check_report_period(date, date, text), sec.period_title(text, date),
    sec.count_title(bigint, text, text, text) FROM PUBLIC;
REVOKE ALL ON api.v_revenue_items, api.v_user_groups FROM PUBLIC;
REVOKE ALL ON FUNCTION
    api.report_new_contracts(date, date, text, integer),
    api.q_shared_subscribers(integer, integer, integer),
    api.q_idle_contracts(integer, integer, integer),
    api.report_revenue(date, date, text, integer, integer),
    api.report_provider_shares(date, date, integer, text, integer),
    api.report_top_subscribers(date, date, integer, integer)
FROM PUBLIC;

GRANT SELECT ON api.v_revenue_items TO grp_manager, grp_chief;
GRANT SELECT ON api.v_user_groups TO grp_admin, grp_dba;
-- функции в представлениях выполняются от имени пользователя (как в 057)
GRANT EXECUTE ON FUNCTION sec.manageable_groups(text), sec.visible_groups(text), sec.group_title(text) TO grp_admin, grp_dba;
GRANT EXECUTE ON FUNCTION
    api.report_new_contracts(date, date, text, integer),
    api.report_revenue(date, date, text, integer, integer),
    api.report_top_subscribers(date, date, integer, integer)
TO grp_manager, grp_chief;
GRANT EXECUTE ON FUNCTION api.report_provider_shares(date, date, integer, text, integer) TO grp_chief;
GRANT EXECUTE ON FUNCTION api.q_idle_contracts(integer, integer, integer) TO grp_operator, grp_manager;
GRANT EXECUTE ON FUNCTION api.q_shared_subscribers(integer, integer, integer) TO grp_admin;

RESET ROLE;
