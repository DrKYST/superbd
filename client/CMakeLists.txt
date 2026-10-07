cmake_minimum_required(VERSION 3.21)
project(superbd_client VERSION 0.1 LANGUAGES CXX)

# Тонкий клиент СуперБД: Qt 6 Widgets + QPSQL. Интерфейс — строго по макету docs/ui/ (ui-spec.md).
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Sql Svg Charts PrintSupport)
# Выгрузка отчётов в Excel (.xlsx) — QXlsx; в MSYS2: pacman -S mingw-w64-ucrt-x86_64-qxlsx
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)   # QXlsx ссылается на Qt6::GuiPrivate
find_package(QXlsxQt6 REQUIRED)
qt_standard_project_setup()
set(CMAKE_AUTORCC ON)   # qt_standard_project_setup включает только AUTOMOC и AUTOUIC
set(CMAKE_AUTOUIC_SEARCH_PATHS ${CMAKE_CURRENT_SOURCE_DIR}/src/ui ${CMAKE_CURRENT_SOURCE_DIR}/src/ui/pages)

# Инструменты разработчика: вход без пароля через SET SESSION AUTHORIZATION (нужен суперпользователь
# и pgpass) и снимки окон для сверки с макетом. В сборке для студента/преподавателя выключены.
option(SUPERBD_DEV_TOOLS "Ключи --dev-as и --screenshot для разработки" OFF)

qt_add_executable(superbd WIN32
    src/main.cpp
    src/app/AppConfig.h src/app/AppConfig.cpp
    src/app/DevOptions.h src/app/DevOptions.cpp
    src/app/RoleConfig.h src/app/RoleConfig.cpp
    src/db/Db.h src/db/Db.cpp
    src/db/ApiCall.h src/db/ApiCall.cpp
    src/models/PagedTableModel.h src/models/PagedTableModel.cpp
    src/ui/Theme.h
    src/ui/LoginDialog.h src/ui/LoginDialog.cpp src/ui/LoginDialog.ui
    src/ui/MainWindow.h src/ui/MainWindow.cpp src/ui/MainWindow.ui
    src/ui/widgets/PagerBar.h src/ui/widgets/PagerBar.cpp
    src/ui/widgets/FormKit.h src/ui/widgets/FormKit.cpp
    src/ui/widgets/DataGrid.h src/ui/widgets/DataGrid.cpp
    src/export/ExcelExport.h src/export/ExcelExport.cpp
    src/charts/ReportChart.h src/charts/ReportChart.cpp
    src/ui/dialogs/PickerDialog.h src/ui/dialogs/PickerDialog.cpp
    src/ui/dialogs/ContractDialog.h src/ui/dialogs/ContractDialog.cpp
    src/ui/dialogs/SubscriberDialog.h src/ui/dialogs/SubscriberDialog.cpp
    src/ui/dialogs/UserDialog.h src/ui/dialogs/UserDialog.cpp
    src/ui/dialogs/PasswordDialogs.h src/ui/dialogs/PasswordDialogs.cpp
    src/ui/pages/HomePage.h src/ui/pages/HomePage.cpp src/ui/pages/HomePage.ui
    src/ui/pages/PlaceholderPage.h src/ui/pages/PlaceholderPage.cpp
    src/ui/pages/SubscribersPage.h src/ui/pages/SubscribersPage.cpp
    src/ui/pages/ContractsPage.h src/ui/pages/ContractsPage.cpp
    src/ui/pages/SessionsPage.h src/ui/pages/SessionsPage.cpp
    src/ui/pages/ProvidersPage.h src/ui/pages/ProvidersPage.cpp
    src/ui/pages/TariffUsagePage.h src/ui/pages/TariffUsagePage.cpp
    src/ui/pages/ReportPage.h src/ui/pages/ReportPage.cpp
    src/ui/pages/UsersPage.h src/ui/pages/UsersPage.cpp
    src/ui/pages/ListPages.h src/ui/pages/ListPages.cpp
    src/ui/pages/DbAdminPages.h src/ui/pages/DbAdminPages.cpp
    resources/superbd.qrc
)

target_include_directories(superbd PRIVATE src)
# xlsxreadsax.h отсутствует в пакете MSYS2 qxlsx 1.5.1-1 — объявления-заглушки (см. файл)
target_include_directories(superbd PRIVATE src/export/compat)
target_link_libraries(superbd PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Sql Qt6::Svg Qt6::Charts Qt6::PrintSupport
                                      QXlsx::QXlsx)
if(SUPERBD_DEV_TOOLS)
    target_compile_definitions(superbd PRIVATE SUPERBD_DEV_TOOLS)
endif()
