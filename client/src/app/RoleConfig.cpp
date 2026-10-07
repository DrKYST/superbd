#include "app/RoleConfig.h"

#include <QHash>

namespace {

NavGroup group(const QString &title, const QList<NavLink> &links) { return {title, links}; }

QList<NavGroup> homeNav()
{
    return {group(QStringLiteral("Главное"), {{QStringLiteral("Начальная страница"), QStringLiteral("home")},
                                              {QStringLiteral("Сменить пароль"), QStringLiteral("change_password")}}),
            group(QStringLiteral("Справка"), {{QStringLiteral("Руководство пользователя"), QStringLiteral("manual")},
                                              {QStringLiteral("О программе"), QStringLiteral("about")}})};
}

// Subscribers.dc.html: canEdit (оператор) и только просмотр (руководитель, главный аналитик).
QList<NavGroup> subscribersNav(bool canEdit)
{
    const NavGroup main = group(QStringLiteral("Абоненты и договоры"),
                                {{QStringLiteral("Абоненты"), QStringLiteral("subscribers")},
                                 {QStringLiteral("Договоры"), QStringLiteral("contracts")}});
    if (canEdit)
        return {main,
                group(QStringLiteral("Создать"), {{QStringLiteral("Абонент"), QStringLiteral("new_subscriber")},
                                                  {QStringLiteral("Договор"), QStringLiteral("new_contract")}}),
                group(QStringLiteral("См. также"), {{QStringLiteral("Сеансы связи"), QStringLiteral("sessions")},
                                                    {QStringLiteral("Тарифы"), QStringLiteral("tariffs")}})};
    return {main,
            group(QStringLiteral("См. также"), {{QStringLiteral("Сеансы связи"), QStringLiteral("sessions")},
                                                {QStringLiteral("Статистика"), QStringLiteral("report_revenue")}})};
}

// Sessions.dc.html (оператор). Для ролей просмотра — без «Создать» и загрузки.
QList<NavGroup> sessionsNav(bool canEdit)
{
    if (canEdit)
        return {group(QStringLiteral("Сеансы связи"), {{QStringLiteral("Журнал сеансов"), QStringLiteral("sessions")},
                                                       {QStringLiteral("Загрузка из биллинга"), QStringLiteral("session_import")}}),
                group(QStringLiteral("Создать"), {{QStringLiteral("Сеанс"), QStringLiteral("new_session")}}),
                group(QStringLiteral("См. также"), {{QStringLiteral("Абоненты"), QStringLiteral("subscribers")},
                                                    {QStringLiteral("Тарифы"), QStringLiteral("tariffs")}})};
    return {group(QStringLiteral("Сеансы связи"), {{QStringLiteral("Журнал сеансов"), QStringLiteral("sessions")}}),
            group(QStringLiteral("См. также"), {{QStringLiteral("Абоненты"), QStringLiteral("subscribers")}})};
}

// Stats.dc.html
QList<NavGroup> statsNav()
{
    return {group(QStringLiteral("Статистика"), {{QStringLiteral("Выручка по периодам"), QStringLiteral("report_revenue")},
                                                 {QStringLiteral("Трафик по тарифам"), QStringLiteral("report_traffic")},
                                                 {QStringLiteral("Новые договоры по типам\nабонентов"), QStringLiteral("report_new_contracts")},
                                                 {QStringLiteral("Крупнейшие абоненты"), QStringLiteral("report_top_subscribers")}}),
            group(QStringLiteral("См. также"), {{QStringLiteral("Абоненты"), QStringLiteral("subscribers")}})};
}

// В макете у «Мой провайдер» и «Провайдеры» главного аналитика навигация не нарисована (href '#');
// минимальный состав — см. docs/ui/deviations.md.
QList<NavGroup> myProviderNav()
{
    return {group(QStringLiteral("Мой провайдер"), {{QStringLiteral("Карточка провайдера"), QStringLiteral("my_provider")}})};
}

QList<NavGroup> chiefProvidersNav()
{
    return {group(QStringLiteral("Провайдеры"), {{QStringLiteral("Провайдеры"), QStringLiteral("providers")}})};
}

// adminNav() из Users.dc.html / Refs.dc.html / Providers.dc.html — одна навигация на три раздела.
// Журнал изменений перешёл к администратору БД (D26); «Общие абоненты» — запрос 13 ЛР 6 (D25, D28), в макете нет.
QList<NavGroup> adminNav()
{
    return {group(QStringLiteral("Администрирование"), {{QStringLiteral("Пользователи"), QStringLiteral("users")}}),
            group(QStringLiteral("Справочники"), {{QStringLiteral("Типы собственности"), QStringLiteral("ref_ownership_types")},
                                                  {QStringLiteral("Города"), QStringLiteral("ref_cities")},
                                                  {QStringLiteral("Типы абонентов"), QStringLiteral("ref_subscriber_types")},
                                                  {QStringLiteral("Тарифы"), QStringLiteral("tariffs")},
                                                  {QStringLiteral("Общие абоненты"), QStringLiteral("shared_subscribers")}}),
            group(QStringLiteral("Провайдеры"), {{QStringLiteral("Провайдеры"), QStringLiteral("providers")}})};
}

// Администратор БД (D26): в макете экранов нет — навигация по аналогии с adminNav, одна на два раздела.
QList<NavGroup> dbaNav()
{
    return {group(QStringLiteral("Администрирование"), {{QStringLiteral("Пользователи"), QStringLiteral("users")},
                                                        {QStringLiteral("Журнал изменений"), QStringLiteral("change_log")}}),
            group(QStringLiteral("База данных"), {{QStringLiteral("Таблицы"), QStringLiteral("db_tables")},
                                                  {QStringLiteral("Подключения"), QStringLiteral("db_connections")}})};
}

Section home()
{
    return {QStringLiteral("home"), QStringLiteral("Главное"), QStringLiteral("home"), QStringLiteral("home"), homeNav()};
}

} // namespace

QList<Section> RoleConfig::sectionsFor(const QString &group)
{
    const QString subscribersTitle = QStringLiteral("Абоненты и\nдоговоры");
    if (group == QLatin1String("grp_operator"))
        return {home(),
                {QStringLiteral("subscribers"), subscribersTitle, QStringLiteral("card"), QStringLiteral("subscribers"), subscribersNav(true)},
                {QStringLiteral("sessions"), QStringLiteral("Сеансы связи"), QStringLiteral("activity"), QStringLiteral("sessions"), sessionsNav(true)},
                {QStringLiteral("my_provider"), QStringLiteral("Мой провайдер"), QStringLiteral("building"), QStringLiteral("my_provider"), myProviderNav()}};
    if (group == QLatin1String("grp_manager"))
        return {home(),
                {QStringLiteral("subscribers"), subscribersTitle, QStringLiteral("card"), QStringLiteral("subscribers"), subscribersNav(false)},
                {QStringLiteral("sessions"), QStringLiteral("Сеансы связи"), QStringLiteral("activity"), QStringLiteral("sessions"), sessionsNav(false)},
                {QStringLiteral("stats"), QStringLiteral("Статистика"), QStringLiteral("chart"), QStringLiteral("report_revenue"), statsNav()},
                {QStringLiteral("my_provider"), QStringLiteral("Мой провайдер"), QStringLiteral("building"), QStringLiteral("my_provider"), myProviderNav()}};
    if (group == QLatin1String("grp_chief"))
        return {home(),
                {QStringLiteral("providers"), QStringLiteral("Провайдеры"), QStringLiteral("building"), QStringLiteral("providers"), chiefProvidersNav()},
                {QStringLiteral("subscribers"), subscribersTitle, QStringLiteral("card"), QStringLiteral("subscribers"), subscribersNav(false)},
                {QStringLiteral("sessions"), QStringLiteral("Сеансы связи"), QStringLiteral("activity"), QStringLiteral("sessions"), sessionsNav(false)},
                {QStringLiteral("stats"), QStringLiteral("Статистика"), QStringLiteral("chart"), QStringLiteral("report_revenue"), statsNav()}};
    if (group == QLatin1String("grp_admin"))
        return {home(),
                {QStringLiteral("admin"), QStringLiteral("Администри-\nрование"), QStringLiteral("users"), QStringLiteral("users"), adminNav()},
                {QStringLiteral("refs"), QStringLiteral("Справочники"), QStringLiteral("book"), QStringLiteral("tariffs"), adminNav()},
                {QStringLiteral("providers"), QStringLiteral("Провайдеры"), QStringLiteral("building"), QStringLiteral("providers"), adminNav()}};
    if (group == QLatin1String("grp_dba"))
        return {home(),
                {QStringLiteral("admin"), QStringLiteral("Администри-\nрование"), QStringLiteral("users"), QStringLiteral("users"), dbaNav()},
                {QStringLiteral("db"), QStringLiteral("База данных"), QStringLiteral("table"), QStringLiteral("db_tables"), dbaNav()}};
    return {home()};
}

QString RoleConfig::formTitle(const QString &form)
{
    static const QHash<QString, QString> titles = {
        {QStringLiteral("home"), QStringLiteral("Начальная страница")},
        {QStringLiteral("subscribers"), QStringLiteral("Абоненты")},
        {QStringLiteral("contracts"), QStringLiteral("Договоры")},
        {QStringLiteral("sessions"), QStringLiteral("Сеансы связи")},
        {QStringLiteral("session_import"), QStringLiteral("Загрузка из биллинга")},
        {QStringLiteral("my_provider"), QStringLiteral("Мой провайдер")},
        {QStringLiteral("providers"), QStringLiteral("Провайдеры")},
        {QStringLiteral("report_revenue"), QStringLiteral("Выручка по периодам")},
        {QStringLiteral("report_traffic"), QStringLiteral("Трафик по тарифам")},
        {QStringLiteral("report_new_contracts"), QStringLiteral("Новые договоры по типам абонентов")},
        {QStringLiteral("report_top_subscribers"), QStringLiteral("Крупнейшие абоненты")},
        {QStringLiteral("users"), QStringLiteral("Пользователи")},
        {QStringLiteral("change_log"), QStringLiteral("Журнал изменений")},
        {QStringLiteral("db_tables"), QStringLiteral("Таблицы базы данных")},
        {QStringLiteral("db_connections"), QStringLiteral("Подключения к базе")},
        {QStringLiteral("ref_ownership_types"), QStringLiteral("Типы собственности")},
        {QStringLiteral("ref_cities"), QStringLiteral("Города")},
        {QStringLiteral("ref_subscriber_types"), QStringLiteral("Типы абонентов")},
        {QStringLiteral("tariffs"), QStringLiteral("Тарифы")},
        {QStringLiteral("shared_subscribers"), QStringLiteral("Общие абоненты")},
        {QStringLiteral("idle_contracts"), QStringLiteral("Договоры без сеансов")},
        {QStringLiteral("new_subscriber"), QStringLiteral("Абонент (создание)")},
        {QStringLiteral("new_contract"), QStringLiteral("Договор (создание)")},
        {QStringLiteral("new_session"), QStringLiteral("Сеанс связи (создание)")},
        {QStringLiteral("new_user"), QStringLiteral("Пользователь (создание)")},
        {QStringLiteral("new_provider"), QStringLiteral("Провайдер (создание)")},
        {QStringLiteral("new_tariff"), QStringLiteral("Тариф (создание)")},
        {QStringLiteral("change_password"), QStringLiteral("Смена пароля")},
        {QStringLiteral("manual"), QStringLiteral("Руководство пользователя")},
        {QStringLiteral("about"), QStringLiteral("О программе")},
    };
    return titles.value(form);
}

bool RoleConfig::isDialog(const QString &form)
{
    return form.startsWith(QLatin1String("new_")) || form == QLatin1String("change_password")
        || form == QLatin1String("about");
}

bool RoleConfig::isReadOnly(const QString &group)
{
    return group == QLatin1String("grp_manager") || group == QLatin1String("grp_chief");
}
