-- Seed 020. Псевдослучайные данные: провайдеры, абоненты, договоры, сеансы (ТЗ п. 4: 10 000 – 50 000+ строк).
-- Результат повторяем: setseed(0.16) перед генерацией. Повторный запуск пересоздаёт данные
-- (TRUNCATE ... RESTART IDENTITY сбрасывает и последовательность номеров договоров).
-- Данные соблюдают ограничения, которые позже будут проверять триггеры (labs/lab03/spec.md, §5):
-- сеанс в периоде действия договора и не в будущем, тариф по окну времени и типу дня,
-- подключение не раньше года основания провайдера, стоимость сеанса по формуле D3.

TRUNCATE core.session, core.contract, core.subscriber, sec.app_user, core.provider RESTART IDENTITY;

-- Даты и время — в часовом поясе предметной области (D19): «сегодня» и окна тарифов те же, что у функций api
-- и seed 040, независимо от пояса сервера (иначе ночью по Москве генератор и 040 расходились в границе суток).
SET TimeZone = 'Europe/Moscow';

DO $$ BEGIN PERFORM setseed(0.16); END $$;

-- Вспомогательные функции генерации (временные, живут до конца сеанса psql).
CREATE OR REPLACE FUNCTION pg_temp.pick(anyarray) RETURNS anyelement
    LANGUAGE sql VOLATILE AS 'SELECT $1[1 + floor(random() * cardinality($1))::int]';
CREATE OR REPLACE FUNCTION pg_temp.rnd(lo int, hi int) RETURNS int
    LANGUAGE sql VOLATILE AS 'SELECT lo + floor(random() * (hi - lo + 1))::int';
CREATE OR REPLACE FUNCTION pg_temp.phone(code text) RETURNS text
    LANGUAGE sql VOLATILE AS $f$
    SELECT '+7 ' || code || ' ' || lpad(pg_temp.rnd(100, 999)::text, 3, '0') || '-'
           || lpad(pg_temp.rnd(0, 99)::text, 2, '0') || '-' || lpad(pg_temp.rnd(0, 99)::text, 2, '0') $f$;
CREATE OR REPLACE FUNCTION pg_temp.street() RETURNS text
    LANGUAGE sql VOLATILE AS $f$
    SELECT pg_temp.pick(ARRAY['ул. Артёма', 'пр. Ильича', 'ул. Университетская', 'бул. Шевченко',
        'ул. Постышева', 'пр. Мира', 'ул. Щорса', 'ул. Горького', 'ул. Садовая', 'пр. Ленинский',
        'ул. Кирова', 'ул. Шахтёрская', 'ул. Набережная', 'ул. Молодёжная', 'ул. Советская',
        'ул. Школьная', 'пр. Победы', 'ул. Гагарина', 'ул. Пушкина', 'ул. Комарова'])
        || ', д. ' || pg_temp.rnd(1, 150) $f$;

-- ---------------------------------------------------------------- провайдеры (30)
-- Название = префикс + окончание: 1 — «ДонНет», 2 — «ДонЛинк» (на них завязаны демо-пользователи 030).
INSERT INTO core.provider (name, ownership_type_id, city_id, address, phone, founded_year)
SELECT (ARRAY['Дон', 'Альфа', 'Вега', 'Мега', 'Сфера', 'Спектр'])[g / 5 + 1]
       || (ARRAY['Нет', 'Линк', '-Телеком', 'Сеть', 'Коннект'])[g % 5 + 1],
       pg_temp.pick(ot.ids),
       pg_temp.pick(ci.ids),
       pg_temp.street() || ', оф. ' || pg_temp.rnd(1, 40),
       pg_temp.phone('856'),
       pg_temp.rnd(1995, 2020)
FROM generate_series(0, 29) g,
     (SELECT array_agg(id ORDER BY id) AS ids FROM ref.ownership_type
       WHERE name NOT IN ('ИП', 'Кооператив', 'Некоммерческая организация')) ot,
     (SELECT array_agg(id ORDER BY id) AS ids FROM ref.city) ci
ORDER BY g;

-- ---------------------------------------------------------------- абоненты (8 000)
-- Тип абонента — по весам (частных лиц большинство); наименование зависит от типа.
WITH weights(name, weight) AS (VALUES
        ('Частное лицо', 70), ('Индивидуальный предприниматель', 5), ('Школа', 4), ('Колледж', 2),
        ('Вуз', 2), ('Предприятие', 8), ('Государственное учреждение', 3), ('Библиотека', 1),
        ('Больница', 1), ('Интернет-кафе', 2), ('Общественная организация', 2)),
     type_pool AS (
        SELECT array_agg(w.name ORDER BY w.name, n) AS names
        FROM weights w CROSS JOIN LATERAL generate_series(1, w.weight) n),
     s AS (
        SELECT g,
               pg_temp.pick(tp.names) AS tname,
               random() < 0.5 AS female,
               pg_temp.pick(ARRAY['Иванов', 'Петров', 'Сидоров', 'Кузнецов', 'Смирнов', 'Попов', 'Васильев',
                   'Соколов', 'Михайлов', 'Новиков', 'Фёдоров', 'Морозов', 'Волков', 'Алексеев', 'Лебедев',
                   'Семёнов', 'Егоров', 'Павлов', 'Козлов', 'Степанов', 'Николаев', 'Орлов', 'Андреев',
                   'Макаров', 'Никитин', 'Захаров', 'Зайцев', 'Соловьёв', 'Борисов', 'Яковлев', 'Григорьев',
                   'Романов', 'Воробьёв', 'Сергеев', 'Кравченко', 'Шевченко', 'Бондаренко', 'Ткаченко',
                   'Коваленко', 'Литвиненко']) AS surname,
               pg_temp.rnd(1, 20) AS n_first,
               pg_temp.rnd(1, 15) AS n_patr
        FROM generate_series(1, 8000) g, type_pool tp),
     named AS (
        SELECT s.g, s.tname,
               CASE WHEN s.female AND s.surname NOT LIKE '%енко' THEN s.surname || 'а' ELSE s.surname END AS surname_g,
               CASE WHEN s.female
                    THEN (ARRAY['Елена', 'Ольга', 'Наталья', 'Татьяна', 'Ирина', 'Светлана', 'Анна', 'Марина',
                          'Юлия', 'Екатерина', 'Людмила', 'Валентина', 'Оксана', 'Виктория', 'Дарья', 'Алина',
                          'Галина', 'Надежда', 'Мария', 'Анастасия'])[s.n_first]
                    ELSE (ARRAY['Александр', 'Сергей', 'Андрей', 'Дмитрий', 'Алексей', 'Николай', 'Владимир',
                          'Игорь', 'Олег', 'Виктор', 'Юрий', 'Максим', 'Артём', 'Евгений', 'Михаил', 'Павел',
                          'Роман', 'Денис', 'Иван', 'Владислав'])[s.n_first] END AS first_name,
               CASE WHEN s.female
                    THEN (ARRAY['Александровна', 'Сергеевна', 'Андреевна', 'Дмитриевна', 'Алексеевна',
                          'Николаевна', 'Владимировна', 'Игоревна', 'Олеговна', 'Викторовна', 'Юрьевна',
                          'Михайловна', 'Павловна', 'Ивановна', 'Петровна'])[s.n_patr]
                    ELSE (ARRAY['Александрович', 'Сергеевич', 'Андреевич', 'Дмитриевич', 'Алексеевич',
                          'Николаевич', 'Владимирович', 'Игоревич', 'Олегович', 'Викторович', 'Юрьевич',
                          'Михайлович', 'Павлович', 'Иванович', 'Петрович'])[s.n_patr] END AS patronymic
        FROM s)
INSERT INTO core.subscriber (name, city_id, subscriber_type_id, address, phone)
SELECT CASE n.tname
           WHEN 'Частное лицо' THEN n.surname_g || ' ' || n.first_name || ' ' || n.patronymic
           WHEN 'Индивидуальный предприниматель'
               THEN 'ИП ' || n.surname_g || ' ' || left(n.first_name, 1) || '. ' || left(n.patronymic, 1) || '.'
           WHEN 'Школа' THEN 'Школа № ' || pg_temp.rnd(1, 150)
           WHEN 'Колледж' THEN pg_temp.pick(ARRAY['Строительный', 'Технический', 'Педагогический', 'Медицинский',
               'Экономический', 'Транспортный', 'Горный', 'Торговый']) || ' колледж'
           WHEN 'Вуз' THEN pg_temp.pick(ARRAY['Технический университет', 'Медицинский университет',
               'Экономический институт', 'Педагогический университет', 'Университет управления',
               'Строительная академия', 'Горный институт', 'Музыкальная академия'])
           WHEN 'Предприятие' THEN pg_temp.pick(ARRAY['ООО', 'АО', 'ПАО', 'ЧП']) || ' «'
               || pg_temp.pick(ARRAY['Стройресурс', 'Металлург', 'Агрохим', 'Техсервис', 'Промснаб', 'Энергомаш',
                   'Автотранс', 'Углепром', 'Хлебозавод', 'Трансгаз', 'Пищепром', 'Кондитер', 'Мебельторг',
                   'Стальконструкция', 'Электромонтаж', 'Донсервис', 'Горизонт', 'Прогресс']) || '»'
           WHEN 'Государственное учреждение' THEN pg_temp.pick(ARRAY['Администрация района',
               'Налоговая инспекция', 'Отделение пенсионного фонда', 'Центр занятости', 'Управление образования',
               'Многофункциональный центр', 'Отдел ЗАГС', 'Отдел полиции']) || ' № ' || pg_temp.rnd(1, 30)
           WHEN 'Библиотека' THEN 'Библиотека № ' || pg_temp.rnd(1, 60)
           WHEN 'Больница' THEN pg_temp.pick(ARRAY['Городская больница', 'Поликлиника', 'Детская больница',
               'Стоматологическая поликлиника']) || ' № ' || pg_temp.rnd(1, 25)
           WHEN 'Интернет-кафе' THEN 'Интернет-кафе «' || pg_temp.pick(ARRAY['Байт', 'Пиксель', 'Матрица',
               'Геймер', 'Орбита', 'Лайк', 'Сигнал']) || '»'
           ELSE 'Общественная организация «' || pg_temp.pick(ARRAY['Молодёжный центр', 'Милосердие',
               'Наш край', 'Ветераны труда', 'Зелёный город', 'Спорт для всех']) || '»'
       END,
       pg_temp.pick(ci.ids),
       st.id,
       pg_temp.street() || CASE WHEN n.tname = 'Частное лицо' AND random() < 0.6
                                THEN ', кв. ' || pg_temp.rnd(1, 200) ELSE '' END,
       CASE WHEN n.tname IN ('Частное лицо', 'Индивидуальный предприниматель')
            THEN pg_temp.phone(pg_temp.pick(ARRAY['949', '990', '901'])) ELSE pg_temp.phone('856') END
FROM named n
JOIN ref.subscriber_type st ON st.name = n.tname
CROSS JOIN (SELECT array_agg(id ORDER BY id) AS ids FROM ref.city) ci
ORDER BY n.g
ON CONFLICT DO NOTHING;   -- реестр общий (D25): совпадение наименования и телефона — тот же абонент, дубль не вставляется

-- ---------------------------------------------------------------- договоры (~12 000)
-- Каждый 20-й абонент (5 %) остаётся без договоров — нужны для внешних соединений (ЛР 5); их видит только главный аналитик.
-- Остальные получают по договору у «своего» провайдера (выбирается хешем кода абонента — равномерно и повторяемо),
-- плюс 4 400 дополнительных договоров случайным абонентам: ~85 % — второе подключение у того же провайдера,
-- ~15 % — у другого провайдера: абонент становится общим (D25), таких ~8 % от абонентов с договорами.
-- Данные подключения (D25): адрес подключения — адрес абонента у первого договора, у дополнительных — в половине
-- случаев другой; контактный телефон и лицо — в основном у организаций.
-- Подключение — с 2024-01-01 до вчерашнего дня (год основания провайдера ≤ 2020, ограничение соблюдено);
-- ~10 % договоров расторгнуты. IP-адрес выводится из порядкового номера строки — уникален.
WITH subs AS (SELECT array_agg(id ORDER BY id) AS ids FROM core.subscriber WHERE id % 20 <> 0),
     pv AS (SELECT array_agg(id ORDER BY id) AS ids, count(*)::int AS cnt FROM core.provider),
     pairs AS (
        SELECT subs.ids[i] AS subscriber_id, false AS extra FROM subs, generate_series(1, cardinality(subs.ids)) i
        UNION ALL
        SELECT pg_temp.pick(subs.ids), true FROM subs, generate_series(1, 4400)),
     c AS (
        SELECT row_number() OVER () AS n,
               p.subscriber_id,
               -- «свой» провайдер абонента: hashint4 даёт int4, сдвиг в неотрицательные bigint и остаток
               ((hashint4(p.subscriber_id)::bigint + 2147483648) % pv.cnt)::int AS home_idx,
               p.extra AND random() < 0.15 AS other_provider,
               pg_temp.rnd(1, pv.cnt - 1) AS shift,
               CASE WHEN NOT p.extra OR random() < 0.5 THEN sb.address::text
                    ELSE pg_temp.street() END AS connection_address,
               CASE WHEN st.is_legal AND random() < 0.7 THEN pg_temp.phone('856')
                    WHEN NOT st.is_legal AND random() < 0.15 THEN pg_temp.phone(pg_temp.pick(ARRAY['949', '990', '901']))
               END AS contact_phone,
               CASE WHEN st.is_legal AND random() < 0.8
                    THEN pg_temp.pick(ARRAY['Коваленко', 'Бондаренко', 'Ткаченко', 'Шевченко', 'Мельник', 'Кравец',
                             'Савченко', 'Руденко', 'Лысенко', 'Марченко', 'Гончаренко', 'Олейник'])
                         || ' ' || pg_temp.pick(ARRAY['А.', 'В.', 'Г.', 'Д.', 'Е.', 'И.', 'Л.', 'М.', 'Н.', 'О.', 'С.', 'Т.'])
                         || ' ' || pg_temp.pick(ARRAY['А.', 'В.', 'И.', 'Н.', 'П.', 'С.'])
               END AS contact_person,
               date '2024-01-01' + floor(random() * (current_date - date '2024-01-01'))::int AS connected_on,
               pg_temp.rnd(0, 30) * 50 AS connection_fee,
               round((0.05 + random() * 0.15)::numeric, 4) AS price_per_mb,
               random() < 0.10 AS is_closed,
               random() AS close_frac
        FROM pairs p
        JOIN core.subscriber sb ON sb.id = p.subscriber_id
        JOIN ref.subscriber_type st ON st.id = sb.subscriber_type_id
        CROSS JOIN pv)
INSERT INTO core.contract (provider_id, contract_no, subscriber_id, connected_on, connection_fee,
                           price_per_mb, ip_address, connection_address, contact_phone, contact_person, closed_on)
SELECT pv.ids[1 + CASE WHEN c.other_provider THEN (c.home_idx + c.shift) % pv.cnt ELSE c.home_idx END],
       'Д-' || to_char(c.connected_on, 'YYYY') || '-' || lpad(nextval('core.contract_no_seq')::text, 6, '0'),
       c.subscriber_id,
       c.connected_on,
       c.connection_fee,
       c.price_per_mb,
       ('10.' || (c.n / 65536) % 256 || '.' || (c.n / 256) % 256 || '.' || c.n % 256)::inet,
       c.connection_address,
       c.contact_phone,
       c.contact_person,
       CASE WHEN c.is_closed
            THEN c.connected_on + floor(c.close_frac * (current_date - c.connected_on))::int END
FROM c
CROSS JOIN pv
ORDER BY c.connected_on, c.n;

-- ---------------------------------------------------------------- сеансы (100 000)
-- Время сеанса — случайное в периоде действия договора (от даты подключения до конца дня расторжения
-- или до начала текущего дня: верхняя граница не зависит от now(), поэтому в пределах суток результат повторяем). Тариф — по окну времени и типу дня (D2/D13, окно через полночь при
-- time_from > time_to); изредка «ручные»: образовательный для учебных заведений, акционный.
-- «Праздничный» и «Служебный» не используются — тарифы без сеансов нужны для внешних соединений (ЛР 5).
-- Скидка и стоимость — снимок на момент сеанса (D3), считаются здесь: триггера ещё нет.
WITH ids AS (SELECT array_agg(id ORDER BY id) AS ids FROM core.contract),
     pick AS (SELECT g, pg_temp.pick(ids.ids) AS contract_id FROM ids, generate_series(1, 100000) g),
     s AS (
        SELECT p.g, ct.id AS contract_id, ct.price_per_mb, st.name AS subscriber_type,
               ct.connected_on::timestamptz
                   + random() * (least(coalesce(ct.closed_on + 1, current_date)::timestamptz, current_date::timestamptz)
                                 - ct.connected_on::timestamptz) AS started_at,
               round((1 + random() ^ 3 * 1999)::numeric, 3) AS volume_mb,
               random() AS manual_roll
        FROM pick p
        JOIN core.contract ct ON ct.id = p.contract_id
        JOIN core.subscriber sb ON sb.id = ct.subscriber_id
        JOIN ref.subscriber_type st ON st.id = sb.subscriber_type_id),
     t AS (
        SELECT s.*,
               CASE WHEN s.subscriber_type IN ('Школа', 'Колледж', 'Вуз') AND s.manual_roll < 0.40
                        THEN (SELECT id FROM ref.tariff WHERE name = 'Образовательный')
                    WHEN s.manual_roll > 0.97
                        THEN (SELECT id FROM ref.tariff WHERE name = 'Акционный')
                    ELSE (SELECT tr.id FROM ref.tariff tr
                          WHERE tr.time_from IS NOT NULL
                            AND tr.is_weekend = (extract(isodow FROM s.started_at) IN (6, 7))
                            AND CASE WHEN tr.time_from < tr.time_to
                                     THEN s.started_at::time >= tr.time_from AND s.started_at::time < tr.time_to
                                     ELSE s.started_at::time >= tr.time_from OR s.started_at::time < tr.time_to
                                END)
               END AS tariff_id
        FROM s)
INSERT INTO core.session (started_at, contract_id, tariff_id, volume_mb, discount_pct, cost)
SELECT t.started_at, t.contract_id, t.tariff_id, t.volume_mb, tr.discount_pct,
       round(t.volume_mb * t.price_per_mb * (1 - tr.discount_pct / 100), 2)
FROM t
JOIN ref.tariff tr ON tr.id = t.tariff_id
ORDER BY t.started_at;

RESET TimeZone;
