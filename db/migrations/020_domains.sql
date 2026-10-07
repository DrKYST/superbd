-- 020. Домены: повторяющиеся ограничения значений (labs/lab02/model.md, раздел 5).
-- Все домены — в схеме ref. У CREATE DOMAIN нет IF NOT EXISTS, поэтому создание обёрнуто в проверку.
-- Допустимые символы проверяются без регулярных выражений: translate() удаляет из значения все разрешённые
-- символы, и если осталась пустая строка — посторонних нет (один проход по строке, без разбора шаблона).
SET ROLE app_owner;

DO $$
DECLARE
    d record;
BEGIN
    FOR d IN
        SELECT * FROM (VALUES
            ('d_name',        'varchar(150)',  $c$VALUE = btrim(VALUE) AND VALUE <> ''$c$),
            ('d_address',     'varchar(200)',  $c$btrim(VALUE) <> ''$c$),
            ('d_phone',       'varchar(20)',   $c$translate(VALUE, '+0123456789 ()-', '') = '' AND strpos(substr(VALUE, 2), '+') = 0
                                             AND length(ltrim(VALUE, '+')) >= 7$c$),
            ('d_year',        'smallint',      $c$VALUE BETWEEN 1970 AND 2100$c$),
            ('d_contract_no', 'varchar(20)',   $c$VALUE = btrim(VALUE) AND VALUE <> ''$c$),
            ('d_login',       'varchar(31)',   $c$length(VALUE) >= 3
                                             AND translate(left(VALUE, 1), 'abcdefghijklmnopqrstuvwxyz', '') = ''
                                             AND translate(VALUE, 'abcdefghijklmnopqrstuvwxyz0123456789_', '') = ''$c$),
            ('d_money',       'numeric(12,2)', $c$VALUE >= 0$c$),
            ('d_price_mb',    'numeric(10,4)', $c$VALUE > 0$c$),
            ('d_percent',     'numeric(5,2)',  $c$VALUE BETWEEN 0 AND 100$c$),
            ('d_mb',          'numeric(12,3)', $c$VALUE > 0$c$)
        ) AS t(name, base, chk)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
                       WHERE n.nspname = 'ref' AND t.typname = d.name) THEN
            EXECUTE format('CREATE DOMAIN ref.%I AS %s CONSTRAINT %I CHECK (%s)',
                           d.name, d.base, 'ck_' || d.name, d.chk);
        END IF;
    END LOOP;
END $$;

COMMENT ON DOMAIN ref.d_name        IS 'Наименование: непустая строка без пробелов по краям';
COMMENT ON DOMAIN ref.d_address     IS 'Адрес в пределах города: непустая строка';
COMMENT ON DOMAIN ref.d_phone       IS 'Телефон: цифры, пробелы, скобки, дефис, необязательный «+» в начале; 7–20 символов';
COMMENT ON DOMAIN ref.d_year        IS 'Год от 1970 до 2100 (не позже текущего — проверка триггером)';
COMMENT ON DOMAIN ref.d_contract_no IS 'Номер договора: непустая строка без пробелов по краям';
COMMENT ON DOMAIN ref.d_login       IS 'Логин сотрудника — имя LOGIN-роли PostgreSQL: латиница в нижнем регистре, цифры, «_», 3–31 символ';
COMMENT ON DOMAIN ref.d_money       IS 'Денежная сумма, руб.: не меньше 0, два знака после запятой';
COMMENT ON DOMAIN ref.d_price_mb    IS 'Стоимость 1 Мб, руб.: больше 0, четыре знака после запятой';
COMMENT ON DOMAIN ref.d_percent     IS 'Процент от 0 до 100';
COMMENT ON DOMAIN ref.d_mb          IS 'Объём информации, Мб: больше 0';

RESET ROLE;
