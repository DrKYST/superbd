# Приложение В // Листинг клиентского приложения

<!-- Ключевые объекты client/src (кроме шаблонов приложения А) в сокращении; полный состав — таблица (!filelist:cpp). Файлы форм .ui (XML Qt Designer) и заглушки export/compat не приводятся. -->

Клиентское приложение состоит из файлов каталога client/src (таблица [@tab:files-cpp]) и файла сборки CMakeLists.txt; формы, созданные в Qt Designer (файлы .ui), не приводятся. Ниже приведены ключевые объекты в сокращении (листинги [@lst:v-main]–[@lst:v-cmake]), общие шаблоны — в приложении А.

!filelist:cpp

!listing[Точка входа: вход, смена временного пароля, главное окно (main)](client/src/main.cpp#method:main){#lst:v-main limit=40}

!listing[Подключение к серверу (Db::open)](client/src/db/Db.cpp#method:Db::open;full){#lst:v-db-open}

!listing[Сведения о пользователе (Db::loadWhoami)](client/src/db/Db.cpp#method:Db::loadWhoami){#lst:v-whoami limit=34}

!listing[Сообщение об ошибке сервера (Db::userMessage)](client/src/db/Db.cpp#method:Db::userMessage;full){#lst:v-usermessage}

!listing[Разделы главного окна по группе (RoleConfig::sectionsFor)](client/src/app/RoleConfig.cpp#method:RoleConfig::sectionsFor){#lst:v-sections limit=40}

!listing[Создание страницы формы (MainWindow::createPage)](client/src/ui/MainWindow.cpp#method:MainWindow::createPage){#lst:v-createpage limit=40}

!listing[Вход в программу (LoginDialog::tryLogin)](client/src/ui/LoginDialog.cpp#method:LoginDialog::tryLogin){#lst:v-login limit=40}

!listing[Счётчики начальной страницы (HomePage::refresh)](client/src/ui/pages/HomePage.cpp#method:HomePage::refresh){#lst:v-home limit=34}

!listing[Сброс пароля пользователя (UsersPage::resetPassword)](client/src/ui/pages/UsersPage.cpp#method:UsersPage::resetPassword;full){#lst:v-reset}

!listing[Запись нового пользователя (UserDialog::save)](client/src/ui/dialogs/UserDialog.cpp#method:UserDialog::save){#lst:v-userdialog limit=40}

!listing[Смена пароля (PasswordChangeDialog::save)](client/src/ui/dialogs/PasswordDialogs.cpp#method:PasswordChangeDialog::save;full){#lst:v-password}

!listing[Доли провайдеров в выручке (ReportPage::buildShares)](client/src/ui/pages/ReportPage.cpp#method:ReportPage::buildShares){#lst:v-shares limit=40}

!listing[Диаграмма отчёта (ReportChart::setData)](client/src/charts/ReportChart.cpp#method:ReportChart::setData){#lst:v-chart limit=40}

!listing[Выгрузка отчёта в Excel (ExcelExport::save)](client/src/export/ExcelExport.cpp#method:save){#lst:v-excel limit=40}

!listing[Журнал изменений: поля записи (ChangeLogPage::showFields)](client/src/ui/pages/DbAdminPages.cpp#method:ChangeLogPage::showFields){#lst:v-changelog limit=34}

!listing[Файл сборки (CMakeLists.txt)](client/CMakeLists.txt#file){#lst:v-cmake limit=40}
