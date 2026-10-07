-- Тест 040. Общий реестр абонентов (D25, migrations/066): видимость общего абонента, данные подключения в договоре,
-- договор без дублей, правила изменения и удаления. Изменяющие проверки — в транзакциях с ROLLBACK:
-- результат снимается через \gset до отката (временная таблица результатов и set_config откатываются вместе с ней).

-- Выполнить SQL от имени текущего пользователя: 'ok' или SQLSTATE ошибки.
CREATE OR REPLACE FUNCTION pg_temp.try(p_sql text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE;
END $$;

SELECT id AS donnet_id FROM core.provider WHERE name = 'ДонНет' \gset
SELECT id AS donlink_id FROM core.provider WHERE name = 'ДонЛинк' \gset
-- X — общий абонент: договоры с «ДонНет» и с другим провайдером (не «ДонЛинк»)
SELECT s.id AS x_id, s.row_version AS x_ver,
       (SELECT count(*) FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = :donnet_id) AS x_own,
       (SELECT count(*) FROM core.contract c WHERE c.subscriber_id = s.id) AS x_all
FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = :donnet_id)
  AND EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id
              AND c.provider_id NOT IN (:donnet_id, :donlink_id))
  AND NOT EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = :donlink_id)
ORDER BY s.id LIMIT 1 \gset
-- Y — абонент только «ДонНет»
SELECT s.id AS y_id, s.row_version AS y_ver, s.name AS y_name, s.phone AS y_phone,
       upper(s.name) AS y_name_upper, translate(s.phone, ' ()-', '') AS y_phone_digits, left(s.name, 5) AS y_name_part,
       s.subscriber_type_id AS y_type, s.city_id AS y_city, s.address AS y_address
FROM core.subscriber s
WHERE EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id = :donnet_id)
  AND NOT EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id AND c.provider_id <> :donnet_id)
ORDER BY s.id LIMIT 1 \gset
-- IP действующего договора «ДонНет» и договор «ДонНет»
SELECT host(ip_address) AS busy_ip, id AS donnet_contract, row_version AS donnet_contract_ver
FROM core.contract WHERE provider_id = :donnet_id AND closed_on IS NULL ORDER BY id LIMIT 1 \gset
SELECT id AS any_type FROM ref.subscriber_type ORDER BY id LIMIT 1 \gset
SELECT id AS any_city FROM ref.city ORDER BY id LIMIT 1 \gset

-- ---------------------------------------------------------------- видимость
SET SESSION AUTHORIZATION op_donnet;
SELECT count(*) AS x_seen_op, bool_or(can_edit) AS x_can_edit FROM api.v_subscribers WHERE id = :x_id \gset
SELECT count(*) AS y_can_edit_op FROM api.v_subscribers WHERE id = :y_id AND can_edit \gset
SELECT count(*) AS x_contracts_op FROM api.q_contracts(p_subscriber_id => :x_id, p_limit => 200) \gset
SELECT count(*) AS x_contracts_view FROM api.v_contracts WHERE subscriber_id = :x_id \gset
SELECT pg_temp.try(format('SELECT api.subscriber_update(%s, %s, ''Новое имя'', %s, %s, ''ул. Новая, д. 1'', ''+7 949 000-00-01'')',
                          :x_id, :x_ver, :any_type, :any_city)) AS x_update_op \gset
SELECT pg_temp.try(format('SELECT api.subscriber_delete(%s, %s)', :x_id, :x_ver)) AS x_delete_op \gset

SET SESSION AUTHORIZATION op_donlink;
SELECT count(*) AS y_seen_donlink FROM api.v_subscribers WHERE id = :y_id \gset
SELECT count(*) AS y_q8_donlink FROM api.q_subscribers(p_search => :'y_phone', p_limit => 200) WHERE id = :y_id \gset
SELECT count(*) AS y_find_exact, bool_or(has_own_contract) AS y_find_own
FROM api.subscriber_find_exact(:'y_name_upper', :'y_phone_digits') \gset
SELECT count(*) AS y_find_part FROM api.subscriber_find_exact(:'y_name_part', :'y_phone') \gset
SELECT pg_temp.try(format('SELECT * FROM api.contract_create(%s, NULL, NULL, NULL, NULL, NULL, 0, 0.1, ''192.0.2.10'')',
                          :y_id)) AS y_by_id_donlink \gset
SELECT pg_temp.try(format('SELECT api.contract_update(%s, %s, ''ул. Чужая, д. 1'', NULL, NULL, 0.1, ''192.0.2.11'')',
                          :donnet_contract, :donnet_contract_ver)) AS foreign_contract_update \gset

SET SESSION AUTHORIZATION chief_main;
SELECT count(*) AS x_contracts_chief FROM api.q_contracts(p_subscriber_id => :x_id, p_limit => 200) \gset

SET SESSION AUTHORIZATION mgr_donnet;
SELECT count(*) AS x_seen_mgr, bool_or(can_edit) AS x_can_edit_mgr FROM api.v_subscribers WHERE id = :x_id \gset
SELECT pg_temp.try(format('SELECT api.subscriber_update(%s, %s, ''Новое имя'', %s, %s, ''ул. Новая, д. 1'', ''+7 949 000-00-01'')',
                          :y_id, :y_ver, :any_type, :any_city)) AS y_update_mgr \gset

SET SESSION AUTHORIZATION adm_main;
SELECT count(*) AS subs_admin FROM api.v_subscribers \gset
SELECT count(*) AS x_seen_adm, bool_and(can_edit) AS x_can_edit_adm FROM api.v_subscribers WHERE id = :x_id \gset
SELECT pg_temp.try('SELECT count(*) FROM api.v_contracts') AS contracts_admin \gset
SELECT pg_temp.try(format('SELECT api.subscriber_delete(%s, %s)', :x_id, :x_ver)) AS x_delete_adm \gset
RESET SESSION AUTHORIZATION;
SELECT count(*) AS subs_all FROM core.subscriber \gset

-- ---------------------------------------------------------------- администратор меняет сведения общего абонента
BEGIN;
SET SESSION AUTHORIZATION adm_main;
SELECT api.subscriber_update(:x_id, :x_ver, 'Общий Абонент Исправленный', :any_type, :any_city, 'ул. Исправленная, д. 1',
                             '+7 949 111-22-33') AS x_new_ver_adm \gset
SET SESSION AUTHORIZATION op_donnet;
SELECT name AS x_name_op_after FROM api.v_subscribers WHERE id = :x_id \gset
RESET SESSION AUTHORIZATION;
ROLLBACK;

-- ---------------------------------------------------------------- «ДонЛинк» заключает договор с абонентом «ДонНет»
BEGIN;
SET SESSION AUTHORIZATION op_donlink;
SELECT subscriber_id AS c1_sub, subscriber_created AS c1_created, contract_no AS c1_no
FROM api.contract_create(NULL, :'y_name_upper', NULL, NULL, 'ул. Офисная, д. 7', :'y_phone_digits', 0, 0.08, '192.0.2.20',
                         p_contact_person => 'Иванов И. И.') \gset
SELECT count(*) AS y_seen_after, bool_or(can_edit) AS y_can_edit_after FROM api.v_subscribers WHERE id = :y_id \gset
SELECT connection_address AS c1_conn_address, contact_person AS c1_contact FROM api.v_contracts WHERE contract_no = :'c1_no' \gset
SET SESSION AUTHORIZATION op_donnet;
SELECT count(*) AS y_contracts_op_after FROM api.v_contracts WHERE subscriber_id = :y_id AND provider_id = :donlink_id \gset
SELECT pg_temp.try(format('SELECT api.subscriber_update(%s, %s, ''Новое имя'', %s, %s, ''ул. Новая, д. 1'', ''+7 949 000-00-01'')',
                          :y_id, :y_ver, :y_type, :y_city)) AS y_update_after \gset
RESET SESSION AUTHORIZATION;
SELECT name AS y_name_after FROM core.subscriber WHERE id = :y_id \gset
ROLLBACK;

-- ---------------------------------------------------------------- новый абонент и дубль в другом написании
BEGIN;
SET SESSION AUTHORIZATION op_donnet;
SELECT subscriber_id AS n_sub, subscriber_created AS n_created
FROM api.contract_create(NULL, 'Тестовый Абонент Реестрович', :any_type, :any_city, 'ул. Тестовая, д. 1', '+7 949 555-12-34',
                         0, 0.1, '192.0.2.30') \gset
SET SESSION AUTHORIZATION op_donlink;
SELECT subscriber_id AS d_sub, subscriber_created AS d_created
FROM api.contract_create(NULL, 'тестовый абонент реестрович', :any_type, :any_city, 'ул. Другая, д. 2', '79495551234',
                         0, 0.1, '192.0.2.31') \gset
RESET SESSION AUTHORIZATION;
SELECT count(*) AS n_registry FROM core.subscriber WHERE lower(name) = 'тестовый абонент реестрович' \gset
ROLLBACK;

-- ---------------------------------------------------------------- изменение и удаление своего абонента
BEGIN;
SET SESSION AUTHORIZATION op_donnet;
SELECT api.subscriber_update(:y_id, :y_ver, :'y_name', :y_type, :y_city, 'ул. Новая, д. 5', :'y_phone') AS y_new_ver \gset
SELECT pg_temp.try(format('SELECT api.subscriber_update(%s, %s, %L, %s, %s, ''ул. Новая, д. 6'', %L)',
                          :y_id, :y_ver, :'y_name', :y_type, :y_city, :'y_phone')) AS y_stale \gset
SELECT pg_temp.try(format('SELECT * FROM api.contract_create(NULL, %L, %s, %s, ''ул. Х, д. 1'', ''+7 949 555-00-99'', 0, 0.1, %L)',
                          'Ещё Один Абонент', :any_type, :any_city, :'busy_ip')) AS busy_ip_result \gset
SELECT pg_temp.try('SELECT * FROM api.contract_create(NULL, ''Абонент Без Ip'', 1, 1, ''ул. Х, д. 1'', ''+7 949 555-00-98'', 0, 0.1, ''10.0.999.1'')')
    AS bad_ip_result \gset
SELECT api.contract_update(:donnet_contract, :donnet_contract_ver, 'ул. Подключения, д. 3', '+7 856 300-00-00',
                           'Петров П. П.', 0.07, :'busy_ip') AS c_new_ver \gset
SELECT pg_temp.try(format('SELECT api.subscriber_delete(%s, %s)', :y_id, :y_new_ver)) AS y_delete \gset
RESET SESSION AUTHORIZATION;
SELECT count(*) AS y_left FROM core.subscriber WHERE id = :y_id \gset
ROLLBACK;

-- ---------------------------------------------------------------- проверки
SELECT pg_temp.check('9.1 общий абонент виден оператору своего провайдера; изменять реестр ему нельзя (can_edit = false)',
    :x_seen_op = 1 AND NOT :'x_can_edit'::boolean, format('видно %s, can_edit %s', :x_seen_op, :'x_can_edit'));
SELECT pg_temp.check('9.2 у общего абонента оператор видит только договоры своего провайдера, аналитик — все',
    :x_contracts_op = :x_own AND :x_contracts_view = :x_own AND :x_contracts_chief = :x_all AND :x_all > :x_own,
    format('оператор %s/%s, аналитик %s из %s', :x_contracts_op, :x_contracts_view, :x_contracts_chief, :x_all));
SELECT pg_temp.check('9.3 абонент чужого провайдера не виден ни в карточке, ни в списке',
    :y_seen_donlink = 0 AND :y_q8_donlink = 0);
SELECT pg_temp.check('9.4 поиск в реестре — только точное наименование (регистр не важен) и телефон (по цифрам)',
    :y_find_exact = 1 AND NOT :'y_find_own'::boolean AND :y_find_part = 0,
    format('точно %s, частично %s', :y_find_exact, :y_find_part));
SELECT pg_temp.check('9.5 договор с чужим абонентом по коду не заключить (перебор кодов ничего не даёт)',
    :'y_by_id_donlink' = '22023', :'y_by_id_donlink');
SELECT pg_temp.check('9.6 договор по наименованию и телефону присоединяет существующего абонента, а не создаёт дубль',
    :c1_sub = :y_id AND NOT :'c1_created'::boolean, format('абонент %s (ожидался %s), создан %s', :c1_sub, :y_id, :'c1_created'));
SELECT pg_temp.check('9.7 после договора абонент виден второму провайдеру; адрес подключения и контакт — в договоре',
    :y_seen_after = 1 AND NOT :'y_can_edit_after'::boolean AND :'c1_conn_address' = 'ул. Офисная, д. 7' AND :'c1_contact' = 'Иванов И. И.',
    format('видно %s, адрес «%s», контакт «%s»', :y_seen_after, :'c1_conn_address', :'c1_contact'));
SELECT pg_temp.check('9.8 договоры другого провайдера с тем же абонентом оператору не видны', :y_contracts_op_after = 0);
SELECT pg_temp.check('9.9 сведения общего абонента не меняет ни один оператор (42501) — только администратор',
    :'x_update_op' = '42501' AND :'x_delete_op' = '42501' AND :'y_update_after' = '42501' AND :'y_name_after' = :'y_name',
    format('изменение %s, удаление %s, после второго договора %s', :'x_update_op', :'x_delete_op', :'y_update_after'));
SELECT pg_temp.check('9.10 новый абонент создаётся вместе с договором; тот же абонент в другом написании не дублируется',
    :'n_created'::boolean AND NOT :'d_created'::boolean AND :d_sub = :n_sub AND :n_registry = 1,
    format('создан %s / %s, записей в реестре %s', :'n_created', :'d_created', :n_registry));
SELECT pg_temp.check('9.11 оператор меняет своего (не общего) абонента; устаревшая версия строки отклоняется (40001)',
    :y_can_edit_op = 1 AND :y_new_ver = :y_ver + 1 AND :'y_stale' = '40001',
    format('версия %s → %s, повтор со старой версией: %s', :y_ver, :y_new_ver, :'y_stale'));
SELECT pg_temp.check('9.12 занятый IP — 23505, неверный IP — 22023; данные подключения договора меняются',
    :'busy_ip_result' = '23505' AND :'bad_ip_result' = '22023' AND :c_new_ver = :donnet_contract_ver + 1,
    format('занятый %s, неверный %s, версия договора %s', :'busy_ip_result', :'bad_ip_result', :c_new_ver));
SELECT pg_temp.check('9.13 оператор удаляет своего абонента; чужой договор не изменить',
    :'y_delete' = 'ok' AND :y_left = 0 AND :'foreign_contract_update' = '22023',
    format('удаление %s, осталось %s, чужой договор %s', :'y_delete', :y_left, :'foreign_contract_update'));
SELECT pg_temp.check('9.14 руководитель видит общего абонента, но ничего не меняет',
    :x_seen_mgr = 1 AND NOT :'x_can_edit_mgr'::boolean AND :'y_update_mgr' = '42501',
    format('видно %s, изменение %s', :x_seen_mgr, :'y_update_mgr'));
SELECT pg_temp.check('9.15 администратор видит весь реестр (без договоров) и меняет сведения общего абонента — изменение видят его провайдеры',
    :subs_admin = :subs_all AND :x_seen_adm = 1 AND :'x_can_edit_adm'::boolean AND :'contracts_admin' = '42501'
    AND :x_new_ver_adm = :x_ver + 1 AND :'x_name_op_after' = 'Общий Абонент Исправленный',
    format('реестр %s из %s, договоры: %s, версия %s → %s, у оператора: %s', :subs_admin, :subs_all, :'contracts_admin',
           :x_ver, :x_new_ver_adm, :'x_name_op_after'));
SELECT pg_temp.check('9.16 удалить общего абонента нельзя никому (каскадом ушли бы чужие договоры)',
    :'x_delete_op' = '42501' AND :'x_delete_adm' = '42501', format('оператор %s, администратор %s', :'x_delete_op', :'x_delete_adm'));
