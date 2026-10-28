-- Тест 010. Структура БД и сгенерированные данные (ЛР 3, labs/lab03/spec.md §7).
-- Совпадение комментариев колонок с полями концептуальной схемы проверяет
-- tools/drawio/check_concept_vs_db.py; здесь — их наличие.

-- 1. Таблицы, отсутствие таблиц пользователей/паролей, комментарии.
DO $$
DECLARE
    v_cnt int;
    v_list text;
BEGIN
    SELECT count(*) INTO v_cnt
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    -- секция — часть своей таблицы, а не отдельная таблица (D30)
    WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname IN ('ref', 'core', 'sec', 'audit');
    PERFORM pg_temp.check('1.1 в схемах ref, core, sec, audit ровно 10 таблиц', v_cnt = 10, v_cnt || ' шт.');

    SELECT string_agg(n.nspname || '.' || c.relname, ', ') INTO v_list
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname IN ('ref', 'core', 'sec', 'audit', 'api')
      AND c.relname ILIKE ANY (ARRAY['%user%', '%role%', '%passw%', '%account%'])
      AND (n.nspname, c.relname) <> ('sec', 'app_user')
      -- запрос 11 (ЛР 6): число пользователей по группам из pg_auth_members, ничего не хранит
      AND (n.nspname, c.relname) <> ('api', 'v_user_groups');
    PERFORM pg_temp.check('1.2 нет своих таблиц пользователей, ролей, паролей (кроме sec.app_user)',
                          v_list IS NULL, v_list);

    SELECT string_agg(n.nspname || '.' || c.relname || '.' || a.attname, ', ') INTO v_list
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p') AND n.nspname IN ('ref', 'core', 'sec', 'audit')
      AND a.attnum > 0 AND NOT a.attisdropped
      AND (a.attname ILIKE ANY (ARRAY['%passw%', '%pwd%', '%hash%'])
           OR (n.nspname, c.relname) = ('sec', 'app_user') AND a.attname ILIKE ANY (ARRAY['%role%', '%group%', '%grp%']));
    PERFORM pg_temp.check('1.3 нет колонок с паролями и поля роли у сотрудника', v_list IS NULL, v_list);

    SELECT string_agg(n.nspname || '.' || c.relname, ', ') INTO v_list
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname IN ('ref', 'core', 'sec', 'audit')
      AND coalesce(obj_description(c.oid, 'pg_class'), '') = '';
    PERFORM pg_temp.check('1.4 у каждой таблицы есть комментарий', v_list IS NULL, v_list);

    SELECT string_agg(n.nspname || '.' || c.relname || '.' || a.attname, ', ') INTO v_list
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname IN ('ref', 'core', 'sec', 'audit')
      AND a.attnum > 0 AND NOT a.attisdropped
      AND coalesce(col_description(c.oid, a.attnum), '') = '';
    PERFORM pg_temp.check('1.5 у каждой колонки есть комментарий', v_list IS NULL, v_list);
END $$;

-- 2. Внешние ключи: ровно 9, правила удаления по модели (R1–R9).
DO $$
DECLARE
    v_cnt int;
    v_diff text;
BEGIN
    SELECT count(*) INTO v_cnt
    FROM pg_catalog.pg_constraint k JOIN pg_catalog.pg_namespace n ON n.oid = k.connamespace
    -- conparentid = 0: ключи таблиц, без копий, которые PostgreSQL заводит для каждой секции (D30)
    WHERE k.contype = 'f' AND k.conparentid = 0 AND n.nspname IN ('ref', 'core', 'sec', 'audit');
    PERFORM pg_temp.check('2.1 внешних ключей ровно 9', v_cnt = 9, v_cnt || ' шт.');

    WITH expected(child, col, parent, del) AS (VALUES
            ('core.provider',   'ownership_type_id',  'ref.ownership_type',  'r'),
            ('core.provider',   'city_id',            'ref.city',            'r'),
            ('core.subscriber', 'city_id',            'ref.city',            'r'),
            ('core.subscriber', 'subscriber_type_id', 'ref.subscriber_type', 'r'),
            ('core.contract',   'provider_id',        'core.provider',       'r'),
            ('core.contract',   'subscriber_id',      'core.subscriber',     'c'),
            ('core.session',    'contract_id',        'core.contract',       'c'),
            ('core.session',    'tariff_id',          'ref.tariff',          'r'),
            ('sec.app_user',    'provider_id',        'core.provider',       'r')),
         actual AS (
            SELECT k.conrelid::regclass::text AS child, a.attname::text AS col,
                   k.confrelid::regclass::text AS parent, k.confdeltype::text AS del
            FROM pg_catalog.pg_constraint k
            JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
            JOIN pg_catalog.pg_namespace n ON n.oid = k.connamespace
            WHERE k.contype = 'f' AND k.conparentid = 0 AND n.nspname IN ('ref', 'core', 'sec', 'audit'))
    SELECT string_agg(x, '; ') INTO v_diff FROM (
        (SELECT 'нет ' || child || '.' || col || ' → ' || parent || ' (' || del || ')' AS x FROM expected
         EXCEPT SELECT 'нет ' || child || '.' || col || ' → ' || parent || ' (' || del || ')' FROM actual)
        UNION ALL
        (SELECT 'лишний ' || child || '.' || col || ' → ' || parent || ' (' || del || ')' FROM actual
         EXCEPT SELECT 'лишний ' || child || '.' || col || ' → ' || parent || ' (' || del || ')' FROM expected)) d;
    PERFORM pg_temp.check('2.2 связи и правила удаления совпадают с моделью (r — RESTRICT, c — CASCADE)',
                          v_diff IS NULL, v_diff);

    -- Каждый внешний ключ проиндексирован (индекс, у которого FK — первая колонка).
    SELECT string_agg(k.conrelid::regclass::text || '.' || a.attname, ', ') INTO v_diff
    FROM pg_catalog.pg_constraint k
    JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
    JOIN pg_catalog.pg_namespace n ON n.oid = k.connamespace
    WHERE k.contype = 'f' AND k.conparentid = 0 AND n.nspname IN ('ref', 'core', 'sec', 'audit')
      AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                      WHERE i.indrelid = k.conrelid AND i.indkey[0] = k.conkey[1]);
    PERFORM pg_temp.check('2.3 у каждого внешнего ключа есть индекс', v_diff IS NULL, v_diff);
END $$;

-- 3. Данные: объёмы и соблюдение ограничений, которые позже будут проверять триггеры.
DO $$
DECLARE
    v_list text;
    v_total bigint;
    v_bad bigint;
    v_pct numeric;
BEGIN
    SELECT string_agg(t || ': ' || n, ', ') INTO v_list FROM (
        SELECT 'ownership_type' AS t, count(*) AS n FROM ref.ownership_type
        UNION ALL SELECT 'city', count(*) FROM ref.city
        UNION ALL SELECT 'subscriber_type', count(*) FROM ref.subscriber_type
        UNION ALL SELECT 'tariff', count(*) FROM ref.tariff) x
    WHERE n < 10;
    PERFORM pg_temp.check('3.1 в каждом справочнике не менее 10 записей', v_list IS NULL, v_list);

    SELECT (SELECT count(*) FROM core.provider) + (SELECT count(*) FROM core.subscriber)
         + (SELECT count(*) FROM core.contract) + (SELECT count(*) FROM core.session) INTO v_total;
    PERFORM pg_temp.check('3.2 в основных таблицах не менее 10 000 строк', v_total >= 10000, v_total || ' строк');

    SELECT count(*) INTO v_bad
    FROM core.session s JOIN core.contract c ON c.id = s.contract_id
    WHERE s.started_at < c.connected_on::timestamptz
       OR s.started_at >= (c.closed_on + 1)::timestamptz
       OR s.started_at > now();
    PERFORM pg_temp.check('3.3 нет сеансов вне периода договора и в будущем', v_bad = 0, v_bad || ' шт.');

    SELECT count(*) INTO v_bad
    FROM core.session s
    JOIN core.contract c ON c.id = s.contract_id
    JOIN ref.tariff t ON t.id = s.tariff_id
    WHERE s.discount_pct <> t.discount_pct
       OR s.cost <> round(s.volume_mb * c.price_per_mb * (1 - s.discount_pct / 100), 2);
    PERFORM pg_temp.check('3.4 скидка сеанса равна скидке тарифа, стоимость — по формуле D3', v_bad = 0, v_bad || ' шт.');

    SELECT count(*) INTO v_bad
    FROM core.session s JOIN ref.tariff t ON t.id = s.tariff_id
    WHERE t.time_from IS NOT NULL
      AND NOT (t.is_weekend = (extract(isodow FROM s.started_at) IN (6, 7))
               AND CASE WHEN t.time_from < t.time_to
                        THEN s.started_at::time >= t.time_from AND s.started_at::time < t.time_to
                        ELSE s.started_at::time >= t.time_from OR s.started_at::time < t.time_to END);
    PERFORM pg_temp.check('3.5 автоматический тариф сеанса соответствует окну времени и типу дня', v_bad = 0, v_bad || ' шт.');

    SELECT count(*) INTO v_bad
    FROM core.contract c JOIN core.provider p ON p.id = c.provider_id
    WHERE c.connected_on < make_date(p.founded_year, 1, 1) OR c.connected_on > current_date
       OR c.closed_on > current_date OR p.founded_year > extract(year FROM current_date);
    PERFORM pg_temp.check('3.6 даты договоров и год основания провайдера согласованы', v_bad = 0, v_bad || ' шт.');

    SELECT count(*) INTO v_bad FROM core.subscriber s
    WHERE NOT EXISTS (SELECT 1 FROM core.contract c WHERE c.subscriber_id = s.id);
    PERFORM pg_temp.check('3.7 есть абоненты без договоров (для внешних соединений ЛР 5)', v_bad > 0, v_bad || ' шт.');

    SELECT count(*) INTO v_bad FROM ref.tariff t
    WHERE NOT EXISTS (SELECT 1 FROM core.session s WHERE s.tariff_id = t.id);
    PERFORM pg_temp.check('3.8 есть тарифы без сеансов (для внешних соединений ЛР 5)', v_bad BETWEEN 1 AND 2, v_bad || ' шт.');

    -- Общий реестр (D25): часть абонентов обслуживают несколько провайдеров — одна запись абонента, договоры разных провайдеров.
    SELECT round(100.0 * count(*) FILTER (WHERE n > 1) / count(*), 1) INTO v_pct
    FROM (SELECT count(DISTINCT provider_id) AS n FROM core.contract GROUP BY subscriber_id) x;
    PERFORM pg_temp.check('3.9 есть общие абоненты: договоры с несколькими провайдерами у 5–12 % абонентов (D25)',
                          v_pct BETWEEN 5 AND 12, v_pct || ' %');

    SELECT count(*) INTO v_bad FROM core.contract c JOIN core.subscriber s ON s.id = c.subscriber_id
    WHERE c.connection_address::text <> s.address::text;
    PERFORM pg_temp.check('3.10 адрес подключения в договоре может отличаться от адреса абонента (D25)', v_bad > 0, v_bad || ' шт.');
END $$;

-- 4. Пользователи: логины сотрудников — LOGIN-роли, каждая ровно в одной группе; чужой логин отклоняется.
DO $$
DECLARE
    v_list text;
    v_rejected boolean := false;
BEGIN
    SELECT string_agg(u.login, ', ') INTO v_list
    FROM sec.app_user u
    WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname = u.login);
    -- вход может быть запрещён администратором (NOLOGIN, D26) — роль при этом остаётся
    PERFORM pg_temp.check('4.1 логин каждого сотрудника — роль PostgreSQL', v_list IS NULL, v_list);

    SELECT string_agg(u.login || ' (' || coalesce(g.n, 0) || ')', ', ') INTO v_list
    FROM sec.app_user u
    LEFT JOIN LATERAL (
        SELECT count(*) AS n
        FROM pg_catalog.pg_auth_members m
        JOIN pg_catalog.pg_roles grp ON grp.oid = m.roleid
        JOIN pg_catalog.pg_roles mem ON mem.oid = m.member
        WHERE mem.rolname = u.login
          AND grp.rolname IN ('grp_admin', 'grp_dba', 'grp_operator', 'grp_manager', 'grp_chief')) g ON true
    WHERE coalesce(g.n, 0) <> 1;
    PERFORM pg_temp.check('4.2 каждый сотрудник входит ровно в одну группу grp_*', v_list IS NULL, v_list);

    SELECT string_agg(u.login, ', ') INTO v_list
    FROM sec.app_user u
    WHERE (sec.group_of(u.login) IN ('grp_operator', 'grp_manager')) = (u.provider_id IS NULL);
    PERFORM pg_temp.check('4.3 провайдер указан у операторов и руководителей и только у них', v_list IS NULL, v_list);

    BEGIN
        INSERT INTO sec.app_user (provider_id, login, full_name) VALUES (NULL, 'no_such_login_x', 'Тест Тест Тест');
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        v_rejected := true;
    END;
    PERFORM pg_temp.check('4.4 сотрудник с несуществующим логином отклоняется триггером', v_rejected);
END $$;

-- 5. Удаление: каскад абонент → договоры → сеансы; запрет удаления используемой справочной записи.
-- ON DELETE RESTRICT сообщает restrict_violation (23001), NO ACTION — foreign_key_violation (23503).
DO $$
DECLARE
    v_sub int;
    v_contracts_before int;
    v_sessions_before int;
    v_contracts_after int;
    v_sessions_after int;
    v_blocked boolean := false;
BEGIN
    SELECT c.subscriber_id INTO v_sub
    FROM core.contract c JOIN core.session s ON s.contract_id = c.id
    GROUP BY c.subscriber_id ORDER BY count(*) DESC, c.subscriber_id LIMIT 1;

    SELECT count(*) INTO v_contracts_before FROM core.contract WHERE subscriber_id = v_sub;
    SELECT count(*) INTO v_sessions_before
    FROM core.session s JOIN core.contract c ON c.id = s.contract_id WHERE c.subscriber_id = v_sub;

    -- Удаление внутри подтранзакции, которая затем откатывается: данные не меняются.
    BEGIN
        DELETE FROM core.subscriber WHERE id = v_sub;
        SELECT count(*) INTO v_contracts_after FROM core.contract WHERE subscriber_id = v_sub;
        SELECT count(*) INTO v_sessions_after
        FROM core.session s WHERE s.contract_id IN (SELECT id FROM core.contract WHERE subscriber_id = v_sub);
        RAISE EXCEPTION USING ERRCODE = 'T0001', MESSAGE = 'откат тестового удаления';
    EXCEPTION WHEN SQLSTATE 'T0001' THEN
        NULL;
    END;
    PERFORM pg_temp.check('5.1 удаление абонента каскадно удаляет его договоры и сеансы',
                          v_contracts_before > 0 AND v_sessions_before > 0
                          AND v_contracts_after = 0 AND v_sessions_after = 0,
                          format('договоров %s → %s, сеансов %s → %s',
                                 v_contracts_before, v_contracts_after, v_sessions_before, v_sessions_after));
    PERFORM pg_temp.check('5.2 после отката абонент на месте',
                          EXISTS (SELECT 1 FROM core.subscriber WHERE id = v_sub));

    BEGIN
        DELETE FROM ref.tariff WHERE id = (SELECT tariff_id FROM core.session LIMIT 1);
    EXCEPTION WHEN restrict_violation OR foreign_key_violation THEN
        v_blocked := true;
    END;
    PERFORM pg_temp.check('5.3 удаление тарифа, на который ссылаются сеансы, отклоняется', v_blocked);

    v_blocked := false;
    BEGIN
        DELETE FROM core.provider WHERE id = (SELECT provider_id FROM core.contract LIMIT 1);
    EXCEPTION WHEN restrict_violation OR foreign_key_violation THEN
        v_blocked := true;
    END;
    PERFORM pg_temp.check('5.4 удаление провайдера с договорами отклоняется', v_blocked);

    -- Абонент в реестре один (D25): то же наименование в другом регистре и телефон в другом написании — дубль.
    v_blocked := false;
    BEGIN
        INSERT INTO core.subscriber (name, city_id, subscriber_type_id, address, phone)
        SELECT upper(s.name), s.city_id, s.subscriber_type_id, 'другой адрес', translate(s.phone, ' ()-', '')
        FROM core.subscriber s ORDER BY s.id LIMIT 1;
    EXCEPTION WHEN unique_violation THEN
        v_blocked := true;
    END;
    PERFORM pg_temp.check('5.5 дубль абонента (наименование в другом регистре, телефон в другом написании) отклоняется (D25)', v_blocked);
END $$;

-- 8. Регулярные выражения не используются (D24): ни в ограничениях и доменах, ни в функциях, ни в представлениях.
--    Проверки доменов на translate() принимают и отклоняют те же значения, что и прежние шаблоны.
DO $$
DECLARE
    v_list text;
    v_ok text;
    v_bad text;
BEGIN
    WITH defs AS (
        SELECT 'ограничение ' || coalesce(t.typname, k.conrelid::regclass::text) || '.' || k.conname AS obj,
               lower(pg_catalog.pg_get_constraintdef(k.oid)) AS def
        FROM pg_catalog.pg_constraint k
        JOIN pg_catalog.pg_namespace n ON n.oid = k.connamespace
        LEFT JOIN pg_catalog.pg_type t ON t.oid = k.contypid
        WHERE n.nspname IN ('ref', 'core', 'sec', 'audit', 'api') AND k.contype = 'c'
        UNION ALL
        SELECT 'функция ' || n.nspname || '.' || p.proname, lower(p.prosrc)
        FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('ref', 'core', 'sec', 'audit', 'api')
        UNION ALL
        SELECT 'представление ' || n.nspname || '.' || c.relname, lower(pg_catalog.pg_get_viewdef(c.oid))
        FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('v', 'm') AND n.nspname IN ('ref', 'core', 'sec', 'audit', 'api'))
    SELECT string_agg(obj, ', ') INTO v_list
    FROM defs
    WHERE EXISTS (SELECT 1 FROM unnest(ARRAY['regexp_', ' ~ ', ' ~* ', ' !~', 'similar to']) AS x
                  WHERE strpos(def, x) > 0);
    PERFORM pg_temp.check('8.1 регулярные выражения не используются в ограничениях, функциях и представлениях',
                          v_list IS NULL, v_list);

    -- Допустимые и недопустимые значения доменов: каждое приводится к домену в подтранзакции.
    SELECT string_agg(v, ', ') FILTER (WHERE NOT ok), string_agg(v, ', ') FILTER (WHERE ok) INTO v_bad, v_ok
    FROM (VALUES ('+7 (071) 300-12-34', 'd_phone', true), ('071 300 12 34', 'd_phone', true),
                 ('3001234', 'd_phone', true), ('7-12+345678', 'd_phone', false), ('++71234567', 'd_phone', false),
                 ('+7 (071) 3OO-12-34', 'd_phone', false), ('12-34', 'd_phone', false),
                 ('op_donnet', 'd_login', true), ('a1_', 'd_login', true), ('1abc', 'd_login', false),
                 ('Abc', 'd_login', false), ('ab', 'd_login', false), ('ab-c', 'd_login', false),
                 ('логин', 'd_login', false)) AS t(v, dom, expected)
    CROSS JOIN LATERAL (SELECT pg_temp.casts_to(t.v, t.dom) = t.expected AS ok) r;
    PERFORM pg_temp.check('8.2 домены d_phone и d_login без регулярных выражений принимают и отклоняют нужные значения',
                          v_bad IS NULL, 'не так: ' || v_bad);

    v_bad := NULL;
    BEGIN
        INSERT INTO ref.tariff (code, name) VALUES ('БX', 'Тест латиницы');   -- X — латинская
        v_bad := 'БX принят';
        RAISE EXCEPTION USING ERRCODE = 'T0001', MESSAGE = 'откат';
    EXCEPTION WHEN check_violation THEN NULL;
              WHEN SQLSTATE 'T0001' THEN NULL;
    END;
    BEGIN
        INSERT INTO ref.tariff (code, name) VALUES ('ЁЯ', 'Тест кириллицы');
        RAISE EXCEPTION USING ERRCODE = 'T0001', MESSAGE = 'откат';
    EXCEPTION WHEN check_violation THEN v_bad := concat_ws('; ', v_bad, 'ЁЯ отклонён');
              WHEN SQLSTATE 'T0001' THEN NULL;
    END;
    PERFORM pg_temp.check('8.3 обозначение тарифа — 1–3 заглавные русские буквы', v_bad IS NULL, v_bad);
END $$;
