# Приложение В // Листинг клиентского приложения

<!-- Ключевые объекты client/src (кроме шаблонов приложения А) в сокращении; только текст кода, без подписей и таблиц (требование студента). Файлы форм .ui и заглушки export/compat не приводятся. -->

!listing[Точка входа: вход, смена временного пароля, главное окно (main)](client/src/main.cpp#method:main){#lst:v-main limit=28}

!listing[Подключение к серверу (Db::open)](client/src/db/Db.cpp#method:Db::open;full){#lst:v-db-open}

!listing[Сообщение об ошибке сервера (Db::userMessage)](client/src/db/Db.cpp#method:Db::userMessage;full){#lst:v-usermessage}

!listing[Разделы главного окна по группе (RoleConfig::sectionsFor)](client/src/app/RoleConfig.cpp#method:RoleConfig::sectionsFor){#lst:v-sections limit=26}

!listing[Вход в программу (LoginDialog::tryLogin)](client/src/ui/LoginDialog.cpp#method:LoginDialog::tryLogin){#lst:v-login limit=26}

!listing[Сброс пароля пользователя (UsersPage::resetPassword)](client/src/ui/pages/UsersPage.cpp#method:UsersPage::resetPassword;full){#lst:v-reset}

!listing[Смена пароля (PasswordChangeDialog::save)](client/src/ui/dialogs/PasswordDialogs.cpp#method:PasswordChangeDialog::save;full){#lst:v-password}

!listing[Диаграмма отчёта (ReportChart::setData)](client/src/charts/ReportChart.cpp#method:ReportChart::setData){#lst:v-chart limit=28}

!listing[Выгрузка отчёта в Excel (ExcelExport::save)](client/src/export/ExcelExport.cpp#method:save){#lst:v-excel limit=26}

!listing[Файл сборки (CMakeLists.txt)](client/CMakeLists.txt#file){#lst:v-cmake limit=26}
