---
paths:
  - "client/**"
---

# Правила для клиента Qt 6 / C++

## Роль клиента
Тонкий клиент: показать данные, собрать ввод, вызвать функцию `api.*`, показать результат или текст ошибки. Никаких расчётов, проверок бизнес-правил и решений о правах на стороне клиента (скрытие кнопок по роли — только удобство).

## Сборка
- CMake, Qt 6.5+, модули `Core Gui Widgets Sql` (+ `Charts` или `Graphs` для диаграмм). Стандарт C++17.
- Excel: QXlsx (подключать через `FetchContent` или `client/3rdparty/QXlsx`).
- Формы — Qt Designer (`client/src/ui/*.ui`); макеты из ЛР 4 используются как настоящие формы.
- Windows: рядом с exe должны лежать `libpq.dll` и её зависимости (из `PostgreSQL/<версия>/bin`), иначе драйвер QPSQL не загрузится. Проверка: `QSqlDatabase::drivers()`.

## Структура
```
client/
  CMakeLists.txt
  config.ini.example        # host, port, dbname, last_login — без пароля
  src/
    main.cpp
    db/Db.{h,cpp}           # подключение, whoami, общий вызов функций
    db/ApiCall.{h,cpp}      # SELECT * FROM api.f(:p1,...) через prepare/bindValue
    models/PagedTableModel.{h,cpp}  # QAbstractTableModel: страницы 20/100/200, total_count, скрытые id
    ui/LoginDialog.*  ui/MainWindow.*  ui/pages/*.{h,cpp,ui}
    export/ExcelExport.*    charts/ChartView.*
```

## Работа с БД
- Подключение: `QSqlDatabase::addDatabase("QPSQL")`, логин и пароль вводит пользователь; пароль не сохраняется.
- Сразу после входа: `SELECT * FROM api.whoami()` → группа, ФИО, провайдер → построение интерфейса.
- Только `QSqlQuery::prepare("SELECT * FROM api.contract_list(:search, :limit, :offset)")` + `bindValue`. Конкатенация SQL-строк запрещена.
- Ошибка запроса: показать `query.lastError().databaseText()` (там текст `RAISE EXCEPTION` на русском). Для конфликта версии — предложить перечитать запись.

## Интерфейс
- Одна страница на тему; видимость страниц/кнопок — по группе из `whoami`.
- Колонки `id`, `*_id` не показывать; хранить в `Qt::UserRole` или скрытых колонках (`setColumnHidden`).
- Пагинация: комбобокс 20/100/200, кнопки «назад/вперёд», надпись «Стр. X из Y (N записей)».
- Поиск/фильтры передаются параметрами функции, фильтрация на клиенте не делается.
- Составная форма 1:N: абонент (верх) → договоры (середина) → сеансы выбранного договора (низ).
- Все тексты интерфейса — на русском.
