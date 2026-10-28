# Приложение А // Листинг шаблонов

<!-- Шаблоны клиента для работы с таблицами БД (подраздел 3.3). Листинги вырезаются из client/src сборщиком tools/pzbuild.py: три колонки, Times New Roman 11 пт, ключевые фрагменты, пропуски — «…». -->

В приложении приведены общие классы клиента, из которых собираются страницы для работы с таблицами базы данных: вызов функций и представлений api (листинг [@lst:a-apicall]), загрузка страницы постраничной модели (листинг [@lst:a-model]), страница-список, составная форма «один-ко-многим» и отчёт по шаблону (листинги [@lst:a-list]–[@lst:a-report]); пропущенные строки отмечены знаком «…».

!listing[Вызов функции и страницы представления api (ApiCall.cpp)](client/src/db/ApiCall.cpp#lines:58-87;full){#lst:a-apicall}

!listing[Загрузка страницы списка (PagedTableModel::reload)](client/src/models/PagedTableModel.cpp#method:PagedTableModel::reload){#lst:a-model limit=18}

!listing[Страница-список по шаблону (IdleContractsPage)](client/src/ui/pages/ListPages.cpp#method:IdleContractsPage::IdleContractsPage){#lst:a-list limit=20}

!listing[Составная форма «один-ко-многим»: выбор абонента и договора (SubscribersPage)](client/src/ui/pages/SubscribersPage.cpp#lines:191-230){#lst:a-composite limit=20}

!listing[Отчёт по шаблону: выручка по периодам (ReportPage::buildRevenue)](client/src/ui/pages/ReportPage.cpp#method:ReportPage::buildRevenue){#lst:a-report limit=14}
