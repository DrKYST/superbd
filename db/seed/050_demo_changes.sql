-- Seed 050. Работа демо-пользователей: несколько изменений через функции api от их имени.
-- Заполнение базы (seed 010–040) в журнал изменений не попадает (db/build.sql отключает журнал на время загрузки);
-- эти изменения проходят обычным путём — функция api, триггеры, запись в audit.change_log с логином пользователя.
-- Нужны экрану администратора БД «Журнал изменений» и начальной странице («Изменений за сегодня»).
-- Выполняется один раз — пока журнал пуст.
SET TimeZone = 'Europe/Moscow';

SELECT NOT EXISTS (SELECT 1 FROM audit.change_log) AS demo_needed \gset
\if :demo_needed

SELECT id AS demo_type FROM ref.subscriber_type WHERE name = 'Частное лицо' \gset
SELECT id AS demo_city FROM ref.city WHERE name = 'Донецк' \gset
-- договоры «ДонНет» для изменений (пустой контакт — пустая строка: NULL в \gset снимает переменную): последние действующие, заключённые до сегодняшнего дня
SELECT c.id AS demo_c1, c.row_version AS demo_c1_ver, c.connection_address AS demo_c1_addr, coalesce(c.contact_phone, '') AS demo_c1_phone,
       c.price_per_mb AS demo_c1_price, host(c.ip_address) AS demo_c1_ip
FROM core.contract c JOIN core.provider p ON p.id = c.provider_id
WHERE p.name = 'ДонНет' AND c.closed_on IS NULL AND c.connected_on < current_date
ORDER BY c.id DESC LIMIT 1 \gset
SELECT c.id AS demo_c2, c.row_version AS demo_c2_ver, c.connection_address AS demo_c2_addr, coalesce(c.contact_phone, '') AS demo_c2_phone,
       coalesce(c.contact_person, '') AS demo_c2_person, c.price_per_mb AS demo_c2_price, host(c.ip_address) AS demo_c2_ip
FROM core.contract c JOIN core.provider p ON p.id = c.provider_id
WHERE p.name = 'ДонНет' AND c.closed_on IS NULL AND c.connected_on < current_date
ORDER BY c.id DESC OFFSET 1 LIMIT 1 \gset
-- общий абонент (договоры с несколькими провайдерами, не «ДонНет» и не «ДонЛинк») — его сведения меняет администратор (D25)
SELECT s.id AS demo_s, s.row_version AS demo_s_ver, s.name AS demo_s_name, s.subscriber_type_id AS demo_s_type,
       s.city_id AS demo_s_city, s.address AS demo_s_addr, s.phone AS demo_s_phone
FROM core.subscriber s
WHERE (SELECT count(DISTINCT c.provider_id) FROM core.contract c WHERE c.subscriber_id = s.id) >= 2
  AND NOT EXISTS (SELECT 1 FROM core.contract c JOIN core.provider p ON p.id = c.provider_id
                  WHERE c.subscriber_id = s.id AND p.name IN ('ДонНет', 'ДонЛинк'))
ORDER BY s.id LIMIT 1 \gset

-- Оператор «ДонЛинк» заключает договор с новым абонентом (в журнале — абонент и договор).
SET SESSION AUTHORIZATION op_donlink;
SELECT contract_no AS demo_new_no
FROM api.contract_create(NULL, 'Савченко Андрей Петрович', :demo_type, :demo_city, 'ул. Артёма, д. 45, кв. 12',
                         '+7 949 210-34-56', 300, 0.0600, '10.201.0.1',
                         p_note => 'Заявка по телефону') \gset

-- Оператор «ДонНет» меняет контактное лицо договора.
SET SESSION AUTHORIZATION op_donnet;
SELECT api.contract_update(:demo_c1, :demo_c1_ver, :'demo_c1_addr', :'demo_c1_phone', 'Лысенко О. В.', :demo_c1_price,
                           :'demo_c1_ip', NULL, 'Смена контактного лица по заявлению абонента') AS demo_c1_new \gset

-- Второй оператор «ДонНет» меняет цену 1 Мб другого договора.
SET SESSION AUTHORIZATION op_donnet2;
SELECT api.contract_update(:demo_c2, :demo_c2_ver, :'demo_c2_addr', :'demo_c2_phone', :'demo_c2_person', 0.0450,
                           :'demo_c2_ip', NULL, 'Переход на тариф с ценой 0,045 за 1 Мб') AS demo_c2_new \gset

-- Администратор приложения исправляет адрес общего абонента.
SET SESSION AUTHORIZATION adm_main;
SELECT api.subscriber_update(:demo_s, :demo_s_ver, :'demo_s_name', :demo_s_type, :demo_s_city,
                             :'demo_s_addr' || ', корп. 2', :'demo_s_phone') AS demo_s_new \gset

RESET SESSION AUTHORIZATION;
\endif
RESET TimeZone;
