# Приложение Б // Листинг серверного приложения

<!-- Ключевые объекты db/ (миграции, данные, тесты) в сокращении; полный состав файлов — таблица, генерируемая сборщиком (!filelist:sql). -->

Серверное приложение состоит из сценариев каталога db: создание базы (create_db.sql), пересборка (build.sql), миграции, данные и тесты. Состав сценариев приведён в таблице [@tab:files-sql]; ниже приведены ключевые объекты в сокращении (листинги [@lst:b-create-db]–[@lst:b-test]), пропущенные строки отмечены знаком «…».

!filelist:sql

!listing[Создание базы данных и роли-владельца (create_db.sql)](db/create_db.sql#file;full){#lst:b-create-db}

!listing[Пересборка базы данных (build.sql)](db/build.sql#file;full){#lst:b-build}

!listing[Группы пользователей и права (010_schemas_roles_base.sql)](db/migrations/010_schemas_roles_base.sql#lines:5-58){#lst:b-roles limit=28}

!listing[Домены (020_domains.sql)](db/migrations/020_domains.sql#lines:7-34;full){#lst:b-domains}

!listing[Таблица «Сеанс связи» (040_core_tables.sql)](db/migrations/040_core_tables.sql#table:core.session;full){#lst:b-session}

!listing[Индексы (050_indexes.sql)](db/migrations/050_indexes.sql#file){#lst:b-indexes limit=22}

!listing[Область видимости данных (sec.scope_data)](db/migrations/057_sec_scope.sql#func:sec.scope_data;full){#lst:b-scope}

!listing[Выручка по периодам (api.report_revenue)](db/migrations/061_queries_aggregate.sql#func:api.report_revenue){#lst:b-report-revenue limit=28}

!listing[Заключение договора (api.contract_create)](db/migrations/066_api_subscriber_write.sql#func:api.contract_create){#lst:b-contract-create limit=28}

!listing[Сброс пароля (api.user_reset_password)](db/migrations/075_password_reset.sql#func:api.user_reset_password;full){#lst:b-reset}

!listing[Генерация сеансов связи (seed/020_generate.sql)](db/seed/020_generate.sql#lines:193-226){#lst:b-seed limit=24}

!listing[Помощники тестов (tests/_helpers.sql)](db/tests/_helpers.sql#lines:4-21;full){#lst:b-test}
