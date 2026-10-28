-- ЛР 8. Параметры запросов сравнения (подключается из 03 и 04 командой \ir): выбираются по данным, подставляются
-- константами (:'имя'), как в ЛР 7.
--   q_provider — код провайдера «ДонНет» (от его имени работают оператор и руководитель);
--   q_contract — договор «ДонНет» с наибольшим числом сеансов (карточка договора);
--   месяц — сентябрь 2026 года, квартал — III квартал 2026 года (последние полные периоды данных).
SELECT id AS q_provider FROM core.provider WHERE name = 'ДонНет' \gset
SELECT s.contract_id AS q_contract
FROM core.session s
WHERE s.provider_id = :q_provider
GROUP BY s.contract_id
ORDER BY count(*) DESC, s.contract_id
LIMIT 1 \gset
\echo 'Параметры: провайдер' :q_provider ', договор' :q_contract
