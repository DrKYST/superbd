# Приложение А // Листинг шаблонов

<!-- Шаблоны клиента для работы с таблицами БД (подраздел 3.3). Листинги вырезаются из client/src сборщиком tools/pzbuild.py: три колонки, Times New Roman 11 пт, ключевые фрагменты, пропуски — «…». -->

В приложении приведены общие классы клиента, из которых собираются страницы для работы с таблицами базы данных: вызов функций api (листинги [@lst:a-apicall-h] и [@lst:a-apicall]), постраничная модель (листинги [@lst:a-model-h] и [@lst:a-model]), таблица со страницами и панель страниц (листинги [@lst:a-grid] и [@lst:a-pager]), страница-список, составная форма «один-ко-многим» и отчёт по шаблону (листинги [@lst:a-list]–[@lst:a-report]).

!listing[Класс ApiCall (ApiCall.h)](client/src/db/ApiCall.h#class:ApiCall;full){#lst:a-apicall-h}

!listing[Вызов функции и страницы представления api (ApiCall.cpp)](client/src/db/ApiCall.cpp#lines:58-87;full){#lst:a-apicall}

!listing[Класс PagedTableModel (PagedTableModel.h)](client/src/models/PagedTableModel.h#class:PagedTableModel){#lst:a-model-h limit=40}

!listing[Загрузка страницы списка (PagedTableModel::reload)](client/src/models/PagedTableModel.cpp#method:PagedTableModel::reload){#lst:a-model limit=40}

!listing[Таблица со страницами (DataGrid::DataGrid)](client/src/ui/widgets/DataGrid.cpp#method:DataGrid::DataGrid){#lst:a-grid limit=40}

!listing[Панель страниц (PagerBar::setState)](client/src/ui/widgets/PagerBar.cpp#method:PagerBar::setState;full){#lst:a-pager}

!listing[Страница-список по шаблону (IdleContractsPage)](client/src/ui/pages/ListPages.cpp#method:IdleContractsPage::IdleContractsPage){#lst:a-list limit=40}

!listing[Составная форма «один-ко-многим»: выбор абонента и договора (SubscribersPage)](client/src/ui/pages/SubscribersPage.cpp#lines:191-230;full){#lst:a-composite}

!listing[Отчёт по шаблону: выручка по периодам (ReportPage::buildRevenue)](client/src/ui/pages/ReportPage.cpp#method:ReportPage::buildRevenue){#lst:a-report limit=40}
