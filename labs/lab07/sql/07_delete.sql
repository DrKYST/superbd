-- ЛР 7, шаг 7. Удаление документов: записи, которые в учёт не идут.
--   7.1 — по условию на содержимое (@>): служебные сеансы наладки NAS — договора нет ("contract": null);
--   7.2 — по условию jsonpath (@?): неудачные подключения — входящего и исходящего трафика нет.
-- Перед удалением — сколько записей подходит, после — сколько осталось (не меньше 100 000).
--   psql -U postgres -d superbd -v ON_ERROR_STOP=1 -f labs/lab07/sql/07_delete.sql   (запросы выводятся: ECHO queries)
-- Идемпотентно: при повторном запуске удалять нечего.
\set ON_ERROR_STOP on
\set ECHO queries

\echo '7.1 Служебные сеансы наладки узлов доступа: в учёт не идут — договора нет, тариф «Служебный»'
SELECT doc #>> '{source,nas,name}' AS nas, doc #>> '{session,user_name}' AS user_name,
       doc #>> '{session,started_at}' AS started_at, doc -> 'contract' AS contract, doc #> '{billing,tariff,code}' AS tariff
FROM lab7.session_record WHERE doc @> '{"contract": null}' ORDER BY id LIMIT 3;
SELECT count(*) AS to_delete FROM lab7.session_record WHERE doc @> '{"contract": null}';
DELETE FROM lab7.session_record
WHERE doc @> '{"contract": null}';
\echo 'удалено записей:' :ROW_COUNT

\echo '7.2 Неудачные подключения: NAS завершил сеанс ошибкой, трафика нет — в core.session такая запись не превращается (объём > 0)'
SELECT doc #>> '{contract,number}' AS contract, doc #>> '{session,stop_cause}' AS stop_cause,
       doc #>> '{session,duration_s}' AS duration_s, doc #> '{session,traffic}' AS traffic
FROM lab7.session_record
WHERE doc @? '$.session.traffic ? (@.in.mb == 0 && @.out.mb == 0)' ORDER BY id LIMIT 3;
SELECT count(*) AS to_delete FROM lab7.session_record
WHERE doc @? '$.session.traffic ? (@.in.mb == 0 && @.out.mb == 0)';
DELETE FROM lab7.session_record
WHERE doc @? '$.session.traffic ? (@.in.mb == 0 && @.out.mb == 0)';
\echo 'удалено записей:' :ROW_COUNT

SELECT count(*) AS documents_left,
       count(*) FILTER (WHERE doc @> '{"contract": null}') AS service_test,
       count(*) FILTER (WHERE doc @? '$.session.traffic ? (@.in.mb == 0 && @.out.mb == 0)') AS failed
FROM lab7.session_record;
\set ECHO none
