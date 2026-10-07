# Клиент СуперБД (Qt 6 / C++)

Тонкий клиент: все данные — только через функции и представления схемы `api` (CLAUDE.md, правило 3).
Интерфейс — строго по макету ЛР 4: `docs/ui/ui-spec.md`, стиль — `docs/ui/superbd.qss` (подключается ресурсом без копирования).

## Что готово (каркас, 30.09)

| Часть | Файлы |
|---|---|
| Окно входа «Доступ к информационной базе» | `src/ui/LoginDialog.{ui,h,cpp}` — сервер, порт, база и последний логин в `config.ini` рядом с exe; пароль не сохраняется |
| Главное окно: панель разделов по роли, панель навигации, вкладки открытых окон, строка состояния | `src/ui/MainWindow.{ui,h,cpp}`, `src/app/RoleConfig.*` (перенос массивов `S`, `nav`, `adminNav` макета) |
| Начальная страница для всех ролей | `src/ui/pages/HomePage.{ui,h,cpp}`; данные — `api.whoami()`, `api.home_todo()` |
| Подключение и вызов функций `api` | `src/db/Db.*` (QPSQL, тексты ошибок сервера), `src/db/ApiCall.*` (`SELECT * FROM api.f(p => :p)`, только `prepare` + `bindValue`) |
| Списки с пагинацией | `src/models/PagedTableModel.*` (`p_limit`/`p_offset`, `total_count`, код строки в `Qt::UserRole`, итоговая строка), `src/ui/widgets/PagerBar.*` («Показывать по: 20/100/200 … Записи A–B из N») |
| «Абоненты» (абонент → договоры → сеансы) | `src/ui/pages/SubscribersPage.*` — запросы ЛР 5 № 8, 4, 2 |
| «Договоры» | `src/ui/pages/ContractsPage.*` — запрос 4, форма выбора абонента (запрос 8) |
| «Сеансы связи» | `src/ui/pages/SessionsPage.*` — запрос 3 с отбором, «Итого за период», форма выбора договора |
| «Провайдеры», «Мой провайдер» | `src/ui/pages/ProvidersPage.*` — запросы 10, 1, 5 |
| Карточки договора и абонента, формы выбора | `src/ui/dialogs/` — запросы 7 (+2 на вкладке «Сеансы»), 6; `PickerDialog` |
| Общие элементы форм | `src/ui/widgets/FormKit.*` (заголовок, командная панель, поле «…»), `DataGrid.*` (таблица + модель + страницы) |
| «Статистика» (ЛР 6, 07.10): «Выручка по периодам» (у главного аналитика без отбора — доли провайдеров), «Новые договоры по типам абонентов», «Крупнейшие абоненты» — табличный документ с диаграммой, «Сохранить в Excel…», «Печать» | `src/ui/pages/ReportPage.*` — запросы 15б, 17, 12, «Крупнейшие абоненты»; `src/charts/ReportChart.*` (Qt Charts), `src/export/ExcelExport.*` (QXlsx) |
| «Трафик по тарифам» | `src/ui/pages/TariffUsagePage.*` — запрос 9, «Сохранить в Excel…» |
| «Пользователи» (оба администратора) и форма «Пользователь (создание)» | `src/ui/pages/UsersPage.*` — панель групп (запрос 11), `api.q_users`, «Запретить/Разрешить вход»; `src/ui/dialogs/UserDialog.*` — `api.user_create` |
| «Общие абоненты» (администратор), «Договоры без сеансов» (оператор, руководитель; по счётчику) | `src/ui/pages/ListPages.*` — запросы 13, 14 |
| Отбор «Без сотрудников» на «Провайдерах» (по счётчику администратора) | `src/ui/pages/ProvidersPage.*` — запрос 16 |
| Остальные формы (справочники, экраны администратора БД) | временная заглушка `src/ui/pages/PlaceholderPage.*`; создание и изменение записей — этап CRUD |

Отличия от макета — `docs/ui/deviations.md`.

## Сборка (Windows, Qt из MSYS2)

Из PowerShell:

```powershell
$env:Path = "C:\msys64\ucrt64\bin;" + $env:Path
```
```powershell
cmake -S client -B client/build -G Ninja -DCMAKE_PREFIX_PATH=C:/msys64/ucrt64 -DCMAKE_BUILD_TYPE=Debug
```
```powershell
cmake --build client/build
```

Зависимости из MSYS2, кроме Qt: `mingw-w64-ucrt-x86_64-qt6-charts`, `mingw-w64-ucrt-x86_64-qxlsx` (в пакете qxlsx 1.5.1-1 нет заголовка `xlsxreadsax.h` — объявления-заглушки в `src/export/compat/`).

Запуск: `client\build\superbd.exe` (в `PATH` должен быть `C:\msys64\ucrt64\bin` — там Qt, `libpq.dll` и плагин `qsqlpsql`). Для запуска на другом компьютере — `windeployqt6 client\build\superbd.exe` и `libpq.dll` с зависимостями рядом с exe.

Пользователь входит своим логином PostgreSQL (демо: `op_donnet`, `mgr_donnet`, `chief_main`, `adm_main`, см. `labs/lab03/README.md`); пароль задаётся в psql командой `\password <логин>`.

## Инструменты разработчика

Отдельная сборка в `client/build-dev` с `-DSUPERBD_DEV_TOOLS=ON` добавляет ключи (в сборке для защиты их нет):

| Ключ | Что делает |
|---|---|
| `--dev-as <логин>` | вход без окна: подключение от `--dev-user` (по умолчанию `postgres`, пароль из pgpass), затем `SET SESSION AUTHORIZATION <логин>` — видно ровно то, что увидит этот пользователь |
| `--open <форма>` | после входа открыть форму (`subscribers`, `users`, …; ключи — `src/app/RoleConfig.cpp`) |
| `--screenshot <файл.png>` | снимок главного окна 1440×900 и выход — сверка с `docs/ui/screens/*.png` |
| `--screenshot-login <файл.png>` | снимок окна входа и выход |

Пример: `superbd.exe --dev-as op_donnet --open subscribers --screenshot shot.png`.
