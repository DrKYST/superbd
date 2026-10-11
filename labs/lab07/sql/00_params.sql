-- ЛР 7. Параметры запросов (подключается из 03–09 командой \ir).
-- Номер договора и код сеанса выбираются по данным, а не вписываются руками: генератор курсовой (db/seed/020)
-- строит договоры от текущей даты, и после пересборки базы номера другие. Значения подставляются в запросы
-- psql-переменными как константы (:'имя'), поэтому планировщик видит их так же, как вписанные вручную.
--   q_provider     — провайдер, от имени которого работают оператор и инженер;
--   q_contract     — договор этого провайдера с наибольшим числом обрывов связи (lost_carrier) в 2026 году —
--                    «абонент жалуется на обрывы»;
--   q_contract_doc — тот же договор образцом для оператора @> (провайдер + номер договора);
--   q_acct         — Acct-Session-Id последнего сеанса этого договора (инженер нашёл его в журнале NAS);
--   q_from, q_to   — отчётный месяц (сентябрь 2026 года, последний полный месяц данных).
\set q_provider 'ДонНет'
\set q_year_from '2026-01-01'
\set q_from '2026-09-01'
\set q_to '2026-10-01'

SELECT doc #>> '{contract,number}' AS q_contract
FROM lab7.session_record
WHERE doc @> jsonb_build_object('source', jsonb_build_object('provider', jsonb_build_object('name', :'q_provider')),
                                'session', jsonb_build_object('stop_cause', 'lost_carrier'))
  AND (doc #>> '{session,started_at}')::timestamptz >= :'q_year_from'
GROUP BY 1
ORDER BY count(*) DESC, 1
LIMIT 1 \gset

SELECT jsonb_build_object('source', jsonb_build_object('provider', jsonb_build_object('name', :'q_provider')),
                          'contract', jsonb_build_object('number', :'q_contract'))::text AS q_contract_doc \gset

SELECT doc #>> '{session,acct_id}' AS q_acct
FROM lab7.session_record
WHERE doc @> :'q_contract_doc'
ORDER BY (doc #>> '{session,started_at}')::timestamptz DESC
LIMIT 1 \gset

\echo 'Параметры: провайдер' :q_provider ', договор' :q_contract ', сеанс' :q_acct ', месяц' :q_from '–' :q_to
