# Приложение Б // Листинг серверного приложения

<!-- Ключевые объекты db/ (миграции, данные, тесты) в сокращении; полный состав файлов — таблица, генерируемая сборщиком (!filelist:sql). -->

Серверное приложение состоит из сценариев каталога db: создание базы (create_db.sql), пересборка (build.sql), миграции, данные и тесты. Состав сценариев приведён в таблице [@tab:files-sql]; ниже приведены ключевые объекты в сокращении (листинги [@lst:b-create-db]–[@lst:b-test]), пропущенные строки отмечены знаком «…».

!filelist:sql

!listing[Создание базы данных и роли-владельца (create_db.sql)](db/create_db.sql#file;full){#lst:b-create-db}

!listing[Пересборка базы данных (build.sql)](db/build.sql#file;full){#lst:b-build}

!listing[Группы пользователей и права (010_schemas_roles_base.sql)](db/migrations/010_schemas_roles_base.sql#lines:5-58){#lst:b-roles limit=40}

!listing[Домены (020_domains.sql)](db/migrations/020_domains.sql#lines:7-34;full){#lst:b-domains}

!listing[Справочник «Тариф» (030_ref_tables.sql)](db/migrations/030_ref_tables.sql#table:ref.tariff;full){#lst:b-tariff}

!listing[Таблица «Сеанс связи» (040_core_tables.sql)](db/migrations/040_core_tables.sql#table:core.session;full){#lst:b-session}

!listing[Таблица «Сотрудник» (040_core_tables.sql)](db/migrations/040_core_tables.sql#table:sec.app_user;full){#lst:b-app-user}

!listing[Индексы (050_indexes.sql)](db/migrations/050_indexes.sql#file){#lst:b-indexes limit=30}

!listing[Проверка группы пользователя (sec.check_group)](db/migrations/055_sec_whoami.sql#func:sec.check_group;full){#lst:b-check-group}

!listing[Сведения о текущем пользователе (api.whoami)](db/migrations/055_sec_whoami.sql#func:api.whoami){#lst:b-whoami limit=34}

!listing[Область видимости данных (sec.scope_data)](db/migrations/057_sec_scope.sql#func:sec.scope_data;full){#lst:b-scope}

!listing[Журнал сеансов (api.q_sessions)](db/migrations/060_queries_simple.sql#func:api.q_sessions){#lst:b-q-sessions limit=40}

!listing[Выручка по периодам (api.report_revenue)](db/migrations/061_queries_aggregate.sql#func:api.report_revenue){#lst:b-report-revenue limit=40}

!listing[Заключение договора (api.contract_create)](db/migrations/066_api_subscriber_write.sql#func:api.contract_create){#lst:b-contract-create limit=40}

!listing[Создание пользователя (api.user_create)](db/migrations/070_api_admin.sql#func:api.user_create){#lst:b-user-create limit=40}

!listing[Сброс пароля (api.user_reset_password)](db/migrations/075_password_reset.sql#func:api.user_reset_password;full){#lst:b-reset}

!listing[Генерация сеансов связи (seed/020_generate.sql)](db/seed/020_generate.sql#lines:193-226){#lst:b-seed limit=34}

!listing[Помощники тестов (tests/_helpers.sql)](db/tests/_helpers.sql#lines:4-21;full){#lst:b-test}
