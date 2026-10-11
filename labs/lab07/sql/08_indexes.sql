-- ЛР 7, шаг 8. Индексы: один по документу целиком и три по элементам ключей.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/08_indexes.sql
-- Индексы строятся после загрузки и правок (02, 06, 07): построить индекс по готовым данным быстрее, чем
-- поддерживать его при вставке каждой записи; так же загружают выгрузки биллинга в реальной системе.
-- Под какие запросы какой индекс — labs/lab07/explain/INDEX.md; планы до и после — 09_optimize.sql и explain/.
-- Идемпотентно: CREATE INDEX IF NOT EXISTS.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- После массовых изменений (06) и удалений (07) в таблице мёртвые версии строк (≈ 30 % объёма). Пока индексов,
-- кроме первичного ключа, нет, таблицу дёшево переписать целиком (VACUUM FULL): планы «до» и «после» сравниваются
-- на компактной таблице, а не на раздутой. Свежая статистика — ANALYZE.
VACUUM (FULL, ANALYZE) lab7.session_record;

SET ROLE app_owner;

-- 1. GIN по документу целиком, класс операторов jsonb_path_ops.
-- Поддерживает @> (образец), @? и @@ (jsonpath с условиями равенства) — так ищут оператор (договор), инженер
-- (узел, причина завершения, событие в журнале) и аналитик (производитель + тариф). В индекс попадает хеш пути
-- до каждого значения: элемент индекса — «source.nas.vendor = Huawei», а не отдельные «vendor» и «Huawei»,
-- поэтому индекс меньше jsonb_ops (сравнение размеров — ниже) и поиск по образцу из нескольких ключей точнее.
-- Проверку наличия ключа (?, ?|, ?&) jsonb_path_ops не поддерживает — она нужна только для атрибутов (индекс 2).
CREATE INDEX IF NOT EXISTS ix_session_record_doc
    ON lab7.session_record USING gin (doc jsonb_path_ops);

-- 2. GIN по вложенному объекту attributes, класс jsonb_ops (по умолчанию).
-- Набор атрибутов зависит от производителя NAS, и вопрос к ним — «есть ли атрибут» (? и ?|): признак должника
-- у MikroTik — address_list, у остальных — redirect_url (запрос 3.2). jsonb_ops индексирует и ключи, и значения.
CREATE INDEX IF NOT EXISTS ix_session_record_attributes
    ON lab7.session_record USING gin ((doc -> 'attributes'));

-- 3. Уникальный B-дерево по элементам ключей: провайдер + Acct-Session-Id.
-- Одна учётная запись сеанса — один документ: повторная выгрузка того же сеанса (биллинг пересылает файл после
-- сбоя) отвергается, а не дублирует выручку. Тот же индекс находит запись по идентификатору из журнала NAS (5.3).
CREATE UNIQUE INDEX IF NOT EXISTS uq_session_record_provider_acct
    ON lab7.session_record ((doc #>> '{source,provider,name}'), (doc #>> '{session,acct_id}'));

-- 4. B-дерево по времени начала сеанса — для отборов за период (отчёт за месяц, архивирование).
-- Значение — строка ISO 8601 с одинаковым смещением +03:00 (D19), поэтому порядок строк совпадает с порядком
-- времени при побайтовом сравнении (COLLATE "C"). Приведение к timestamptz в индексе невозможно: оно зависит от
-- настроек сеанса (функция STABLE, а не IMMUTABLE). Правила сравнения по умолчанию (Russian_Russia.1251)
-- не годятся: медленнее и могут не учитывать знаки «-» и «:».
CREATE INDEX IF NOT EXISTS ix_session_record_started_at
    ON lab7.session_record (((doc #>> '{session,started_at}')) COLLATE "C");

COMMENT ON INDEX lab7.ix_session_record_doc IS 'Поиск по образцу (@>) и jsonpath (@?, @@) в документе целиком';
COMMENT ON INDEX lab7.ix_session_record_attributes IS 'Наличие атрибутов производителя (?, ?|, ?&) и образец по атрибутам';
COMMENT ON INDEX lab7.uq_session_record_provider_acct IS 'Учётная запись сеанса уникальна: провайдер + Acct-Session-Id';
COMMENT ON INDEX lab7.ix_session_record_started_at IS 'Записи за период по времени начала сеанса (строка ISO 8601, COLLATE "C")';

RESET ROLE;
-- Статистика по выражениям индексов 3 и 4 собирается только ANALYZE после их создания — без неё планировщик
-- оценивает условие «выражение = константа» наугад (0,5 % строк).
ANALYZE lab7.session_record;
RESET client_min_messages;

SELECT c.relname AS index_name, am.amname AS method,
       pg_size_pretty(pg_relation_size(c.oid)) AS size,
       pg_size_pretty(pg_relation_size('lab7.session_record')) AS table_size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam
WHERE i.indrelid = 'lab7.session_record'::regclass
ORDER BY pg_relation_size(c.oid) DESC;

-- Обоснование выбора jsonb_path_ops: тот же индекс с классом jsonb_ops строится в транзакции, сравнивается
-- по размеру и откатывается (в базе не остаётся).
BEGIN;
SET LOCAL client_min_messages = warning;
CREATE INDEX tmp_session_record_doc_jsonb_ops ON lab7.session_record USING gin (doc jsonb_ops);
SELECT 'jsonb_path_ops' AS opclass, pg_size_pretty(pg_relation_size('lab7.ix_session_record_doc')) AS size
UNION ALL
SELECT 'jsonb_ops', pg_size_pretty(pg_relation_size('lab7.tmp_session_record_doc_jsonb_ops'));
ROLLBACK;
