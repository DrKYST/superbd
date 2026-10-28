-- ЛР 8, шаг 2. Устройство секций: дерево, границы, число строк и размер каждой секции; сравнение размеров с копией.
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab08/sql/02_structure.sql
-- Только чтение.
\set ON_ERROR_STOP on

\echo '2.1 core.session — секционирование по диапазону started_at: год → квартал (вложенные секции) и секция по умолчанию'
WITH cnt AS (SELECT s.tableoid AS relid, count(*) AS n FROM core.session s GROUP BY 1)
SELECT repeat('    ', t.level) || c.relname                                   AS partition,
       CASE p.partstrat WHEN 'r' THEN 'RANGE (started_at)' WHEN 'l' THEN 'LIST' END AS split_by,
       pg_get_expr(c.relpartbound, c.oid)                                       AS bound,
       (SELECT coalesce(sum(cnt.n), 0) FROM pg_partition_tree(t.relid) x JOIN cnt ON cnt.relid = x.relid) AS rows,
       pg_size_pretty((SELECT sum(pg_total_relation_size(x.relid)) FROM pg_partition_tree(t.relid) x WHERE x.isleaf)) AS size
FROM pg_partition_tree('core.session') t
JOIN pg_class c ON c.oid = t.relid
LEFT JOIN pg_partitioned_table p ON p.partrelid = t.relid
ORDER BY c.relname;

\echo '2.2 core.contract — секционирование по списку provider_id: секция провайдера и секция по умолчанию'
WITH cnt AS (SELECT c.tableoid AS relid, count(*) AS n FROM core.contract c GROUP BY 1)
SELECT c.relname                                AS partition,
       pg_get_expr(c.relpartbound, c.oid)       AS bound,
       coalesce(pr.name::text, '—')             AS provider,
       coalesce(cnt.n, 0)                       AS rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_partition_tree('core.contract') t
JOIN pg_class c ON c.oid = t.relid
LEFT JOIN cnt ON cnt.relid = t.relid
LEFT JOIN core.provider pr ON c.relname = 'contract_p' || pr.id
WHERE t.level = 1
ORDER BY c.relname = 'contract_default', (SELECT pr2.id FROM core.provider pr2 WHERE c.relname = 'contract_p' || pr2.id);

\echo '2.3 Размер: секционированные таблицы (сумма секций) и обычные копии'
SELECT x.name AS table_name, x.leaves,
       pg_size_pretty(x.heap)  AS heap,
       pg_size_pretty(x.idx)   AS indexes,
       pg_size_pretty(x.heap + x.idx) AS total
FROM (
    SELECT 'core.session' AS name, count(*) AS leaves,
           sum(pg_table_size(t.relid)) AS heap, sum(pg_indexes_size(t.relid)) AS idx
    FROM pg_partition_tree('core.session') t WHERE t.isleaf
    UNION ALL
    SELECT 'lab8.session_plain', 1, pg_table_size('lab8.session_plain'), pg_indexes_size('lab8.session_plain')
    UNION ALL
    SELECT 'core.contract', count(*), sum(pg_table_size(t.relid)), sum(pg_indexes_size(t.relid))
    FROM pg_partition_tree('core.contract') t WHERE t.isleaf
    UNION ALL
    SELECT 'lab8.contract_plain', 1, pg_table_size('lab8.contract_plain'), pg_indexes_size('lab8.contract_plain')) x;

\echo '2.4 Индексы секционированной таблицы: индекс родителя — секционированный, в каждой секции — свой'
SELECT i.indexrelid::regclass AS parent_index,
       (SELECT count(*) FROM pg_partition_tree(i.indexrelid) x WHERE x.isleaf) AS partition_indexes,
       pg_size_pretty((SELECT sum(pg_relation_size(x.relid)) FROM pg_partition_tree(i.indexrelid) x WHERE x.isleaf)) AS size
FROM pg_index i
WHERE i.indrelid IN ('core.session'::regclass, 'core.contract'::regclass)
ORDER BY 1;
