# Приложение А // Листинг шаблонов

<!-- Шаблоны клиента для работы с таблицами БД (подраздел 3.3). Только текст кода: tools/pzbuild.py вырезает фрагменты из client/src и выводит их без подписей сплошь в три колонки, Times New Roman 11 пт, пропуски — «…». Других абзацев в приложении нет (требование студента). -->

!listing[Вызов функции и страницы представления api (ApiCall.cpp)](client/src/db/ApiCall.cpp#lines:58-87;full){#lst:a-apicall}

!listing[Загрузка страницы списка (PagedTableModel::reload)](client/src/models/PagedTableModel.cpp#method:PagedTableModel::reload){#lst:a-model limit=18}

!listing[Страница-список по шаблону (IdleContractsPage)](client/src/ui/pages/ListPages.cpp#method:IdleContractsPage::IdleContractsPage){#lst:a-list limit=20}

!listing[Составная форма «один-ко-многим»: выбор абонента и договора (SubscribersPage)](client/src/ui/pages/SubscribersPage.cpp#lines:191-230){#lst:a-composite limit=20}

!listing[Отчёт по шаблону: выручка по периодам (ReportPage::buildRevenue)](client/src/ui/pages/ReportPage.cpp#method:ReportPage::buildRevenue){#lst:a-report limit=14}
