-- Seed 040. Записи, согласованные с запросами ЛР 5 (задание ЛР 5, п. 3) и счётчиками начальной страницы.
-- Генератор 020 заканчивает период вчерашним днём, у всех его провайдеров есть договоры —
-- здесь добавляется то, без чего часть запросов вернула бы пусто:
--   провайдер без договоров и сотрудников      → запрос 10 (0 договоров), «Провайдеры без сотрудников»;
--   два договора «ДонНет», заключённых сегодня  → запрос 4 за неделю, «Договоров заключено на этой неделе»;
--   сеансы «ДонНет» за сегодня                 → запрос 3 за сегодня, «Сеансов зарегистрировано сегодня».
-- Тарифы без сеансов (запрос 9) и абоненты без договоров (запрос 8, у главного аналитика) уже есть в данных генератора.
-- Повторный запуск не дублирует записи.

-- Новый провайдер без договоров.
INSERT INTO core.provider (name, ownership_type_id, city_id, address, phone, founded_year)
SELECT 'Горизонт-Нет', ot.id, c.id, 'ул. Артёма, д. 120, оф. 3', '+7 856 300-45-17',
       extract(year FROM current_date)::smallint
FROM ref.ownership_type ot, ref.city c
WHERE ot.name = 'ООО' AND c.name = 'Донецк'
ON CONFLICT (name) DO NOTHING;

-- Два договора «ДонНет», заключённых сегодня, с абонентами реестра, у которых ещё нет договоров ни с кем.
INSERT INTO core.contract (provider_id, contract_no, subscriber_id, connected_on, connection_fee, price_per_mb,
                           ip_address, connection_address, note)
SELECT p.id,
       'Д-' || to_char(current_date, 'YYYY') || '-' || lpad(nextval('core.contract_no_seq')::text, 6, '0'),
       s.id, current_date, 500, 0.0450,
       ('10.200.0.' || row_number() OVER (ORDER BY s.id))::inet,
       s.address,
       'Подключение по заявке с сайта'
FROM core.subscriber s
JOIN core.provider p ON p.name = 'ДонНет'
WHERE NOT EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM core.contract c WHERE c.provider_id = p.id AND c.connected_on = current_date)
ORDER BY s.id
LIMIT 2;

-- Сеансы за сегодня по действующим договорам «ДонНет»: с начала дня до текущего момента,
-- тариф — по окну времени и типу дня (D2/D13), стоимость — по формуле D3.
-- Время считается в часовом поясе предметной области (D19).
SET TimeZone = 'Europe/Moscow';
INSERT INTO core.session (started_at, contract_id, tariff_id, volume_mb, discount_pct, cost)
SELECT x.started_at, x.contract_id, tr.id, x.volume_mb, tr.discount_pct,
       round(x.volume_mb * x.price_per_mb * (1 - tr.discount_pct / 100), 2)
FROM (
    SELECT c.id AS contract_id, c.price_per_mb,
           date_trunc('day', now()) + (now() - date_trunc('day', now())) * (g::numeric / 26) AS started_at,
           round((50 + (g * 137) % 2400)::numeric, 3) AS volume_mb
    FROM generate_series(1, 25) g
    JOIN LATERAL (
        SELECT c.id, c.price_per_mb
        FROM core.contract c JOIN core.provider p ON p.id = c.provider_id
        WHERE p.name = 'ДонНет' AND c.closed_on IS NULL AND c.connected_on < current_date
        ORDER BY c.id
        OFFSET (g % 10) LIMIT 1) c ON true
) x
JOIN ref.tariff tr
  ON tr.time_from IS NOT NULL
 AND tr.is_weekend = (extract(isodow FROM x.started_at) IN (6, 7))
 AND CASE WHEN tr.time_from < tr.time_to
          THEN x.started_at::time >= tr.time_from AND x.started_at::time < tr.time_to
          ELSE x.started_at::time >= tr.time_from OR x.started_at::time < tr.time_to END
WHERE NOT EXISTS (SELECT 1 FROM core.session s JOIN core.contract c ON c.id = s.contract_id
                  JOIN core.provider p ON p.id = c.provider_id
                  WHERE p.name = 'ДонНет' AND s.started_at >= date_trunc('day', now()));
RESET TimeZone;
