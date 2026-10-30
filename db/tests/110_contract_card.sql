-- Тест 110. Модифицируемое представление «абонент + договор» api.v_contract_card (migrations/085): добавление,
-- изменение и удаление через INSTEAD OF, общий реестр абонентов (D25), версия строки (D8), отказ чужому провайдеру
-- и другим ролям. Изменяющие проверки — в транзакциях с ROLLBACK.

SELECT id AS p_donnet FROM core.provider WHERE name = 'ДонНет' \gset
SELECT id AS p_donlink FROM core.provider WHERE name = 'ДонЛинк' \gset
SELECT id AS any_type FROM ref.subscriber_type ORDER BY id LIMIT 1 \gset
SELECT id AS any_city FROM ref.city ORDER BY id LIMIT 1 \gset
-- абонент только «ДонЛинк» (для «ДонНет» — чужой, присоединяется по наименованию и телефону)
SELECT s.id AS f_sub, s.name AS f_name, s.phone AS f_phone
FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = :p_donlink)
  AND NOT EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id <> :p_donlink)
ORDER BY s.id LIMIT 1 \gset
-- договор «ДонНет» с сеансами; договор «ДонЛинк»
SELECT c.id AS d_sess FROM core.contract c
WHERE c.provider_id = :p_donnet AND EXISTS (SELECT 1 FROM core.session s WHERE s.contract_id = c.id AND s.provider_id = c.provider_id)
ORDER BY c.id LIMIT 1 \gset
SELECT c.id AS d_foreign, c.row_version AS d_foreign_ver FROM core.contract c WHERE c.provider_id = :p_donlink ORDER BY c.id LIMIT 1 \gset
-- общий абонент «ДонНет» (договоры и с другими провайдерами) и его договор «ДонНет»
SELECT c.id AS g_contract, s.id AS g_sub
FROM core.subscriber s JOIN core.contract c ON c.subscriber_id = s.id AND c.provider_id = :p_donnet
WHERE EXISTS (SELECT 1 FROM core.contract x WHERE x.subscriber_id = s.id AND x.provider_id <> :p_donnet)
ORDER BY c.id LIMIT 1 \gset

-- ============================================================================ 16.1–16.3 добавление
BEGIN;
SELECT coalesce(max(id), 0) AS log_from FROM audit.change_log \gset
SET SESSION AUTHORIZATION op_donnet;
-- новый абонент: создаётся вместе с договором; номер — из последовательности
INSERT INTO api.v_contract_card (subscriber_name, subscriber_type_id, city_id, subscriber_address, subscriber_phone,
                                 connection_fee, price_per_mb, ip_address, note)
VALUES ('Тестовый Абонент Карточки', :any_type, :any_city, 'ул. Карточная, д. 1', '+7 949 555-88-01',
        500, 0.05, '192.0.2.101', 'через представление')
RETURNING id AS n_id, contract_no AS n_no, subscriber_id AS n_sub, row_version AS n_ver, subscriber_row_version AS n_sver,
          provider_id AS n_prov, connection_address AS n_addr, state AS n_state \gset
-- абонент другого провайдера — присоединяется по наименованию (другой регистр) и телефону (другое написание);
-- номер договора — введённый вручную
INSERT INTO api.v_contract_card (contract_no, subscriber_name, subscriber_phone, subscriber_address,
                                 connection_fee, price_per_mb, ip_address, connection_address)
VALUES ('Д-ТЕСТ-1', upper(:'f_name'), translate(:'f_phone', ' ()-', ''), NULL, 0, 0.07, '192.0.2.102', 'ул. Подключения, д. 2')
RETURNING id AS a_id, contract_no AS a_no, subscriber_id AS a_sub, subscriber_shared AS a_shared \gset
SELECT pg_temp.try_msg($q$INSERT INTO api.v_contract_card (contract_no, subscriber_name, subscriber_type_id, city_id,
                                                            subscriber_address, subscriber_phone, connection_fee,
                                                            price_per_mb, ip_address)
                          VALUES ('Д-ТЕСТ-1', 'Ещё Один', 1, 1, 'ул. А, д. 1', '+7 949 555-88-02', 0, 0.07, '192.0.2.103')$q$) AS e_dup_no \gset
SELECT pg_temp.try_msg($q$INSERT INTO api.v_contract_card (subscriber_name, subscriber_type_id, city_id, subscriber_address,
                                                            subscriber_phone, connection_fee, price_per_mb, ip_address)
                          VALUES ('Ещё Один', 1, 1, 'ул. Б, д. 2', '+7 949 555-88-03', 0, 0.07, '192.0.2.101')$q$) AS e_busy_ip \gset
SELECT pg_temp.try_msg(format($q$INSERT INTO api.v_contract_card (provider_id, subscriber_name, subscriber_type_id, city_id,
                                   subscriber_address, subscriber_phone, connection_fee, price_per_mb, ip_address)
                                 VALUES (%s, 'Ещё Один', 1, 1, 'ул. В, д. 3', '+7 949 555-88-04', 0, 0.07, '192.0.2.104')$q$,
                              :p_donlink)) AS e_foreign_prov \gset
RESET SESSION AUTHORIZATION;
SELECT count(*) AS a_registry FROM core.subscriber
WHERE lower(name) = lower(:'f_name') AND translate(phone, '+ ()-', '') = translate(:'f_phone', '+ ()-', '') \gset
SELECT string_agg(l.table_name || ' ' || l.operation, ', ' ORDER BY l.id) AS n_log FROM audit.change_log l
WHERE l.id > :log_from AND l.db_user = 'op_donnet' \gset
ROLLBACK;
SELECT pg_temp.check('16.1 добавление через представление: новый абонент создаётся с договором, номер из последовательности, провайдер — оператора; запись в журнале',
    :n_prov = :p_donnet AND :'n_no' LIKE 'Д-____-______' AND :n_ver = 1 AND :n_sver = 1
    AND :'n_addr' = 'ул. Карточная, д. 1' AND :'n_state' = 'Действует'
    AND :'n_log' = 'core.subscriber INSERT, core.contract INSERT, core.contract INSERT',
    format('номер %s, версии %s/%s, адрес подключения «%s», журнал: %s', :'n_no', :n_ver, :n_sver, :'n_addr', :'n_log'));
SELECT pg_temp.check('16.2 абонент другого провайдера присоединяется (по наименованию и телефону), а не копируется; номер — введённый вручную',
    :a_sub = :f_sub AND :a_registry = 1 AND :'a_no' = 'Д-ТЕСТ-1' AND :'a_shared'::boolean,
    format('абонент %s (ожидался %s), записей в реестре %s, номер %s, общий %s', :a_sub, :f_sub, :a_registry, :'a_no', :'a_shared'));
SELECT pg_temp.check('16.3 повтор номера и занятый IP — 23505 с понятным текстом; чужой провайдер в договоре — отказ',
    left(:'e_dup_no', 5) = '23505' AND strpos(:'e_dup_no', 'номером') > 0
    AND left(:'e_busy_ip', 5) = '23505' AND strpos(:'e_busy_ip', 'IP-адрес') > 0 AND left(:'e_foreign_prov', 5) = '42501',
    format('номер: %s; IP: %s; чужой провайдер: %s', :'e_dup_no', :'e_busy_ip', left(:'e_foreign_prov', 5)));

-- ============================================================================ 16.4–16.6 изменение
BEGIN;
SET SESSION AUTHORIZATION op_donnet;
INSERT INTO api.v_contract_card (subscriber_name, subscriber_type_id, city_id, subscriber_address, subscriber_phone,
                                 connection_fee, price_per_mb, ip_address)
VALUES ('Тестовый Абонент Изменения', :any_type, :any_city, 'ул. Старая, д. 1', '+7 949 555-88-11', 0, 0.05, '192.0.2.111')
RETURNING id AS u_id, row_version AS u_ver, subscriber_row_version AS u_sver \gset
-- данные договора и сведения своего (не общего) абонента — одним изменением
UPDATE api.v_contract_card
SET price_per_mb = 0.06, contact_person = 'Иванов И. И.', subscriber_address = 'ул. Новая, д. 2', row_version = :u_ver
WHERE id = :u_id
RETURNING row_version AS u_ver2, subscriber_row_version AS u_sver2, price_per_mb AS u_price \gset
-- устаревшая версия договора — конфликт
SELECT pg_temp.try_msg(format('UPDATE api.v_contract_card SET note = ''второй'', row_version = %s WHERE id = %s', :u_ver, :u_id)) AS e_stale \gset
-- устаревшая версия абонента — конфликт
SELECT pg_temp.try_msg(format('UPDATE api.v_contract_card SET subscriber_phone = ''+7 949 555-88-12'', subscriber_row_version = %s WHERE id = %s',
                              :u_sver, :u_id)) AS e_stale_sub \gset
-- расторжение
UPDATE api.v_contract_card SET closed_on = current_date WHERE id = :u_id RETURNING state AS u_state \gset
-- неизменяемое
SELECT pg_temp.try_msg(format('UPDATE api.v_contract_card SET contract_no = ''Д-ДРУГОЙ'' WHERE id = %s', :u_id)) AS e_no \gset
SELECT pg_temp.try_msg(format('UPDATE api.v_contract_card SET subscriber_id = %s WHERE id = %s', :f_sub, :u_id)) AS e_party \gset
-- сведения общего абонента оператор не меняет (D25)
SELECT pg_temp.try_msg(format('UPDATE api.v_contract_card SET subscriber_address = ''ул. Чужая, д. 9'' WHERE id = %s', :g_contract)) AS e_shared \gset
-- договор другого провайдера не виден: изменение не затрагивает ни одной строки
UPDATE api.v_contract_card SET note = 'чужой' WHERE id = :d_foreign;
SELECT count(*) AS u_foreign_seen FROM api.v_contract_card WHERE id = :d_foreign \gset
RESET SESSION AUTHORIZATION;
SELECT row_version AS u_foreign_ver FROM core.contract WHERE id = :d_foreign \gset
SELECT address AS u_addr FROM core.subscriber s JOIN core.contract c ON c.subscriber_id = s.id WHERE c.id = :u_id \gset
ROLLBACK;
SELECT pg_temp.check('16.4 изменение договора и сведений своего абонента одним UPDATE представления: версии +1, расторжение меняет состояние',
    :u_ver2 = :u_ver + 1 AND :u_sver2 = :u_sver + 1 AND :u_price = 0.06 AND :'u_addr' = 'ул. Новая, д. 2'
    AND :'u_state' = 'Расторгнут ' || to_char(current_date, 'DD.MM.YYYY'),
    format('версия договора %s → %s, абонента %s → %s, состояние «%s»', :u_ver, :u_ver2, :u_sver, :u_sver2, :'u_state'));
SELECT pg_temp.check('16.5 устаревшая версия договора или абонента — конфликт 40001',
    left(:'e_stale', 5) = '40001' AND left(:'e_stale_sub', 5) = '40001',
    format('договор: %s; абонент: %s', left(:'e_stale', 5), left(:'e_stale_sub', 5)));
SELECT pg_temp.check('16.6 номер и стороны договора не меняются; сведения общего абонента оператору не изменить; чужой договор не виден и не меняется',
    left(:'e_no', 5) = 'P0001' AND left(:'e_party', 5) = 'P0001' AND left(:'e_shared', 5) = '42501'
    AND :u_foreign_seen = 0 AND :u_foreign_ver = :d_foreign_ver,
    format('номер: %s; абонент: %s; общий абонент: %s; чужой виден %s, версия %s → %s',
           left(:'e_no', 5), left(:'e_party', 5), left(:'e_shared', 5), :u_foreign_seen, :d_foreign_ver, :u_foreign_ver));

-- ============================================================================ 16.7 удаление
BEGIN;
SET SESSION AUTHORIZATION op_donnet;
INSERT INTO api.v_contract_card (subscriber_name, subscriber_type_id, city_id, subscriber_address, subscriber_phone,
                                 connection_fee, price_per_mb, ip_address)
VALUES ('Тестовый Абонент Удаления', :any_type, :any_city, 'ул. Удаления, д. 1', '+7 949 555-88-21', 0, 0.05, '192.0.2.121')
RETURNING id AS x_id, row_version AS x_ver \gset
UPDATE api.v_contract_card SET note = 'изменён до удаления' WHERE id = :x_id;
-- удаление с прочитанной (теперь устаревшей) версией: ни одной строки
DELETE FROM api.v_contract_card WHERE id = :x_id AND row_version = :x_ver;
SELECT count(*) AS x_after_stale FROM api.v_contract_card WHERE id = :x_id \gset
DELETE FROM api.v_contract_card WHERE id = :x_id;
SELECT count(*) AS x_after FROM api.v_contract_card WHERE id = :x_id \gset
SELECT pg_temp.try_msg(format('DELETE FROM api.v_contract_card WHERE id = %s', :d_sess)) AS e_sess \gset
RESET SESSION AUTHORIZATION;
SELECT count(*) AS x_sub_left FROM core.subscriber WHERE name = 'Тестовый Абонент Удаления' \gset
ROLLBACK;
SELECT pg_temp.check('16.7 удаление: договор без сеансов удаляется (абонент остаётся в реестре), с устаревшей версией — не удаляется, с сеансами — отказ',
    :x_after_stale = 1 AND :x_after = 0 AND :x_sub_left = 1 AND left(:'e_sess', 5) = 'P0001',
    format('после устаревшей версии %s, после удаления %s, абонент в реестре %s; с сеансами: %s',
           :x_after_stale, :x_after, :x_sub_left, :'e_sess'));

-- ============================================================================ 16.8 другие роли
SET SESSION AUTHORIZATION mgr_donnet;
SELECT count(*) AS r_mgr_seen, count(*) FILTER (WHERE provider_id <> :p_donnet) AS r_mgr_foreign FROM api.v_contract_card \gset
SELECT pg_temp.try_msg(format('UPDATE api.v_contract_card SET note = ''x'' WHERE id = %s', :d_sess)) AS r_mgr_upd \gset
SELECT pg_temp.try_msg($q$INSERT INTO api.v_contract_card (subscriber_name, subscriber_phone, connection_fee, price_per_mb, ip_address)
                          VALUES ('Х', '+7 949 555-88-31', 0, 0.05, '192.0.2.131')$q$) AS r_mgr_ins \gset
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION chief_main;
SELECT count(DISTINCT provider_id) AS r_chief_prov FROM api.v_contract_card \gset
SELECT pg_temp.try_msg(format('DELETE FROM api.v_contract_card WHERE id = %s', :d_sess)) AS r_chief_del \gset
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION adm_main;
SELECT pg_temp.try_msg('SELECT count(*) FROM api.v_contract_card') AS r_adm \gset
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION dba_main;
SELECT pg_temp.try_msg('SELECT count(*) FROM api.v_contract_card') AS r_dba \gset
RESET SESSION AUTHORIZATION;
SELECT count(*) AS r_donnet_all FROM core.contract WHERE provider_id = :p_donnet \gset
SELECT count(*) AS r_prov_all FROM core.provider p WHERE EXISTS (SELECT 1 FROM core.contract c WHERE c.provider_id = p.id) \gset
SELECT pg_temp.check('16.8 руководитель видит договоры своего провайдера, аналитик — всех; изменять не могут; администраторам представление недоступно',
    :r_mgr_seen = :r_donnet_all AND :r_mgr_foreign = 0 AND left(:'r_mgr_upd', 5) = '42501' AND left(:'r_mgr_ins', 5) = '42501'
    AND :r_chief_prov = :r_prov_all AND left(:'r_chief_del', 5) = '42501'
    AND left(:'r_adm', 5) = '42501' AND left(:'r_dba', 5) = '42501',
    format('руководитель видит %s из %s; изменение %s, добавление %s; аналитик — провайдеров %s, удаление %s; администраторы: %s, %s',
           :r_mgr_seen, :r_donnet_all, left(:'r_mgr_upd', 5), left(:'r_mgr_ins', 5), :r_chief_prov, left(:'r_chief_del', 5),
           left(:'r_adm', 5), left(:'r_dba', 5)));

-- ============================================================================ 16.9 устройство
SELECT is_insertable_into AS v_ins, is_trigger_insertable_into AS v_tins, is_trigger_updatable AS v_tupd,
       is_trigger_deletable AS v_tdel
FROM information_schema.views WHERE table_schema = 'api' AND table_name = 'v_contract_card' \gset
SELECT count(*) AS v_instead FROM pg_catalog.pg_trigger
WHERE tgrelid = 'api.v_contract_card'::regclass AND tgtype & 64 <> 0 \gset
SELECT pg_temp.check('16.9 представление изменяется только триггерами INSTEAD OF (INSERT, UPDATE, DELETE)',
    :'v_tins' = 'YES' AND :'v_tupd' = 'YES' AND :'v_tdel' = 'YES' AND :v_instead = 3,
    format('вставка %s / %s, изменение %s, удаление %s, триггеров INSTEAD OF %s', :'v_ins', :'v_tins', :'v_tupd', :'v_tdel', :v_instead));
