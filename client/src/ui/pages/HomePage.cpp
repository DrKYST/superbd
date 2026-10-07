#include "ui/pages/HomePage.h"
#include "ui_HomePage.h"

#include <QFrame>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLocale>
#include <QPushButton>
#include <QSqlQuery>
#include <QSqlRecord>

#include "db/ApiCall.h"

namespace {

// Тексты роли — объект R в docs/ui/mockup/Home.dc.html (дословно).
struct Link {
    QString title;
    QString target;     // ключ раздела (sections) или формы (quick)
    QString descr;
};

struct RoleTexts {
    QString descr;
    QStringList can;
    QStringList cannot;
    QList<Link> sections;
    QString quickTitle;
    QList<Link> quick;
    QStringList help;
};

RoleTexts textsFor(const QString &group)
{
    if (group == QLatin1String("grp_operator"))
        return {QStringLiteral("Ведёте абонентов и договоры своего провайдера и регистрируете сеансы связи. "
                               "В списках видны только абоненты, у которых есть договор с вашим провайдером, "
                               "и абоненты, созданные вами."),
                {QStringLiteral("регистрировать абонентов и заключать договоры"),
                 QStringLiteral("изменять и расторгать договоры"),
                 QStringLiteral("регистрировать и удалять сеансы связи"),
                 QStringLiteral("искать по номеру договора, ФИО, телефону, IP-адресу")},
                {QStringLiteral("данные других провайдеров"), QStringLiteral("справочники и тарифы"),
                 QStringLiteral("статистика и отчёты"), QStringLiteral("управление пользователями")},
                {{QStringLiteral("Абоненты и договоры"), QStringLiteral("subscribers"), QStringLiteral("список абонентов, их договоры и сеансы по договору")},
                 {QStringLiteral("Сеансы связи"), QStringLiteral("sessions"), QStringLiteral("журнал сеансов за период, регистрация сеанса")},
                 {QStringLiteral("Мой провайдер"), QStringLiteral("my_provider"), QStringLiteral("карточка вашего провайдера, только просмотр")}},
                QStringLiteral("Создать"),
                {{QStringLiteral("Абонент"), QStringLiteral("new_subscriber"), {}},
                 {QStringLiteral("Договор"), QStringLiteral("new_contract"), {}},
                 {QStringLiteral("Сеанс связи"), QStringLiteral("new_session"), {}}},
                {QStringLiteral("Новый договор: «Абоненты» → выберите абонента → «Новый договор…». Номер присвоится автоматически."),
                 QStringLiteral("Тариф сеанса можно не указывать — он определяется по времени начала."),
                 QStringLiteral("Провайдера и абонента в записанном договоре изменить нельзя: расторгните договор и заключите новый.")}};
    if (group == QLatin1String("grp_manager"))
        return {QStringLiteral("Контролируете работу своего провайдера: просматриваете абонентов, договоры и сеансы, "
                               "формируете отчёты с распределением по месяцам, кварталам и годам и сохраняете их в Excel. "
                               "Изменять данные роль не позволяет."),
                {QStringLiteral("просмотр абонентов, договоров и сеансов своего провайдера"),
                 QStringLiteral("отчёты по периодам с диаграммами"),
                 QStringLiteral("сохранение отчётов в Excel")},
                {QStringLiteral("изменение абонентов, договоров, сеансов"), QStringLiteral("данные других провайдеров"),
                 QStringLiteral("пользователи и справочники")},
                {{QStringLiteral("Абоненты и договоры"), QStringLiteral("subscribers"), QStringLiteral("абоненты, договоры и сеансы — только просмотр")},
                 {QStringLiteral("Сеансы связи"), QStringLiteral("sessions"), QStringLiteral("журнал сеансов за период")},
                 {QStringLiteral("Статистика"), QStringLiteral("stats"), QStringLiteral("выручка, трафик по тарифам, новые договоры, крупнейшие абоненты")},
                 {QStringLiteral("Мой провайдер"), QStringLiteral("my_provider"), QStringLiteral("карточка провайдера")}},
                QStringLiteral("Отчёты"),
                {{QStringLiteral("Выручка по периодам"), QStringLiteral("report_revenue"), {}},
                 {QStringLiteral("Трафик по тарифам"), QStringLiteral("report_traffic"), {}},
                 {QStringLiteral("Крупнейшие абоненты"), QStringLiteral("report_top_subscribers"), {}}},
                {QStringLiteral("Отчёт: «Статистика» → выберите отчёт, период и периодичность → «Сформировать»."),
                 QStringLiteral("Кнопка «Сохранить в Excel…» выгружает отчёт вместе с итогами."),
                 QStringLiteral("В отчётах всегда только ваш провайдер — отбор по провайдеру изменить нельзя.")}};
    if (group == QLatin1String("grp_chief"))
        return {QStringLiteral("Видите сводную информацию по всем провайдерам объединения: отчёты с распределением по периодам, "
                               "сравнение провайдеров между собой, выгрузку в Excel. Данные только просматриваете."),
                {QStringLiteral("данные всех провайдеров"), QStringLiteral("сводные отчёты и сравнение провайдеров"),
                 QStringLiteral("сохранение отчётов в Excel")},
                {QStringLiteral("изменение данных"), QStringLiteral("пользователи и справочники")},
                {{QStringLiteral("Провайдеры"), QStringLiteral("providers"), QStringLiteral("список провайдеров объединения")},
                 {QStringLiteral("Абоненты и договоры"), QStringLiteral("subscribers"), QStringLiteral("абоненты и договоры всех провайдеров — только просмотр")},
                 {QStringLiteral("Сеансы связи"), QStringLiteral("sessions"), QStringLiteral("журнал сеансов за период")},
                 {QStringLiteral("Статистика"), QStringLiteral("stats"), QStringLiteral("сводные отчёты по провайдерам")}},
                QStringLiteral("Отчёты"),
                {{QStringLiteral("Выручка по периодам"), QStringLiteral("report_revenue"), {}},
                 {QStringLiteral("Доли провайдеров"), QStringLiteral("report_revenue"), {}},
                 {QStringLiteral("Новые договоры"), QStringLiteral("report_new_contracts"), {}}},
                {QStringLiteral("В отчётах отбор «Провайдер» можно оставить пустым — будут показаны все провайдеры рядами диаграммы."),
                 QStringLiteral("Периодичность (месяц, квартал, год) меняется без повторного ввода периода."),
                 QStringLiteral("Выгрузка в Excel сохраняет таблицу отчёта с итогами.")}};
    // Администратор БД (D26): в макете Home.dc.html текстов роли нет — написаны по образцу администратора приложения.
    if (group == QLatin1String("grp_dba"))
        return {QStringLiteral("Отвечаете за саму базу данных: учётные записи администраторов приложения, журнал изменений, "
                               "размер таблиц и подключения, обслуживание и резервные копии. "
                               "Данные приложения — абоненты, договоры, справочники — не изменяете."),
                {QStringLiteral("создание администраторов приложения и запрет входа"),
                 QStringLiteral("журнал изменений: кто, когда и какую запись изменил"),
                 QStringLiteral("таблицы: размер, число строк, очистка и сбор статистики"),
                 QStringLiteral("подключения к базе и выполняемые запросы"),
                 QStringLiteral("изменение структуры и резервное копирование")},
                {QStringLiteral("работа с абонентами, договорами и сеансами"), QStringLiteral("справочники и провайдеры"),
                 QStringLiteral("учётные записи операторов, руководителей и аналитиков")},
                {{QStringLiteral("Администрирование"), QStringLiteral("admin"), QStringLiteral("администраторы приложения, журнал изменений")},
                 {QStringLiteral("База данных"), QStringLiteral("db"), QStringLiteral("таблицы и подключения")}},
                QStringLiteral("Открыть"),
                {{QStringLiteral("Журнал изменений"), QStringLiteral("change_log"), {}},
                 {QStringLiteral("Таблицы"), QStringLiteral("db_tables"), {}},
                 {QStringLiteral("Подключения"), QStringLiteral("db_connections"), {}}},
                {QStringLiteral("Структуру базы меняют скрипты миграций от имени владельца: SET ROLE app_owner, по окончании — RESET ROLE."),
                 QStringLiteral("Резервная копия: pg_dump -Fc -d superbd -f superbd.dump (чтение всех таблиц доступно роли)."),
                 QStringLiteral("Администраторов БД создаёт суперпользователь postgres.")}};
    // grp_admin — администратор приложения
    return {QStringLiteral("Ведёте учётные записи операторов, руководителей и главных аналитиков, справочники "
                           "и список провайдеров. Оперативные данные — абоненты, договоры и сеансы — для роли не нужны "
                           "и не показываются."),
            {QStringLiteral("создание пользователей, назначение группы и провайдера"),
             QStringLiteral("смена паролей и запрет входа"),
             QStringLiteral("справочники: типы собственности, города, типы абонентов, тарифы"),
             QStringLiteral("регистрация и изменение провайдеров")},
            {QStringLiteral("абоненты, договоры и сеансы"), QStringLiteral("отчёты"),
             QStringLiteral("журнал изменений и обслуживание базы данных")},
            {{QStringLiteral("Пользователи"), QStringLiteral("admin"), QStringLiteral("учётные записи, группы, пароли, право входа")},
             {QStringLiteral("Справочники"), QStringLiteral("refs"), QStringLiteral("типы собственности, города, типы абонентов, тарифы и временные зоны")},
             {QStringLiteral("Провайдеры"), QStringLiteral("providers"), QStringLiteral("провайдеры объединения и их сотрудники")}},
            QStringLiteral("Создать"),
            {{QStringLiteral("Пользователь"), QStringLiteral("new_user"), {}},
             {QStringLiteral("Провайдер"), QStringLiteral("new_provider"), {}},
             {QStringLiteral("Тариф"), QStringLiteral("new_tariff"), {}}},
            {QStringLiteral("Новый сотрудник: «Пользователи» → «Создать» → логин, ФИО, группа, провайдер и пароль."),
             QStringLiteral("Пароль хранит только СУБД; забытый пароль не восстанавливается — задайте новый через «Сменить пароль…»."),
             QStringLiteral("Тариф с окном времени не должен пересекаться с другими тарифами того же типа дня."),
             QStringLiteral("Администраторов приложения создаёт администратор БД.")}};
}

QPushButton *linkButton(const QString &text, bool strong, QWidget *parent)
{
    auto *b = new QPushButton(text, parent);
    b->setProperty("role", QStringLiteral("link"));
    if (strong)
        b->setProperty("strong", true);
    b->setCursor(Qt::PointingHandCursor);
    b->setFocusPolicy(Qt::NoFocus);
    b->setSizePolicy(QSizePolicy::Maximum, QSizePolicy::Fixed);
    return b;
}

QLabel *label(const QString &text, const char *role, QWidget *parent, bool wrap = false)
{
    auto *l = new QLabel(text, parent);
    if (role)
        l->setProperty("role", QString::fromLatin1(role));
    l->setWordWrap(wrap);
    return l;
}

void clearLayout(QLayout *layout)
{
    while (QLayoutItem *item = layout->takeAt(0)) {
        if (QWidget *w = item->widget())
            delete w;
        else if (QLayout *l = item->layout())
            clearLayout(l);
        delete item;
    }
}

} // namespace

HomePage::HomePage(const Whoami &me, QWidget *parent)
    : QWidget(parent)
    , ui(new Ui::HomePage)
    , m_me(me)
{
    ui->setupUi(this);
    fillRole();
    fillSections();
    fillKeys();
    fillConnection();
    fillHelp();
}

HomePage::~HomePage()
{
    delete ui;
}

void HomePage::showEvent(QShowEvent *event)
{
    QWidget::showEvent(event);
    refresh();
}

void HomePage::fillRole()
{
    const RoleTexts t = textsFor(m_me.groupName);
    QVBoxLayout *l = ui->roleLayout;
    l->addWidget(label(QStringLiteral("Здравствуйте, %1. Вы вошли как").arg(m_me.fullName), "caption", this));
    auto *title = label(m_me.roleTitle, nullptr, this);
    title->setObjectName(QStringLiteral("roleTitle"));
    l->addWidget(title);

    auto *grid = new QGridLayout;
    grid->setHorizontalSpacing(8);
    grid->setVerticalSpacing(3);
    grid->setColumnMinimumWidth(0, 150);
    grid->addWidget(label(QStringLiteral("Организация:"), "caption", this), 0, 0);
    grid->addWidget(label(m_me.organization, nullptr, this), 0, 1);
    grid->addWidget(label(QStringLiteral("Группа PostgreSQL:"), "caption", this), 1, 0);
    grid->addWidget(label(m_me.groupName, nullptr, this), 1, 1);
    grid->setColumnStretch(1, 1);
    l->addLayout(grid);

    l->addWidget(label(t.descr, nullptr, this, true));

    auto *cols = new QHBoxLayout;
    cols->setSpacing(12);
    // Маркированный список ul.li: отступ 18 px, между пунктами 3 px.
    auto addList = [&](const QString &caption, const QStringList &items, const char *role) {
        auto *box = new QVBoxLayout;
        box->setSpacing(3);
        auto *head = label(caption, "caption", this);
        head->setProperty("strong", true);
        box->addWidget(head);
        box->addSpacing(1);
        for (const QString &item : items) {
            auto *row = new QHBoxLayout;
            row->setContentsMargins(6, 0, 0, 0);
            row->setSpacing(6);
            auto *bullet = label(QStringLiteral("•"), role, this);
            bullet->setAlignment(Qt::AlignTop);
            row->addWidget(bullet);
            row->addWidget(label(item, role, this, true), 1);
            box->addLayout(row);
        }
        box->addStretch(1);
        cols->addLayout(box, 1);
    };
    addList(QStringLiteral("Вам доступно"), t.can, nullptr);
    addList(QStringLiteral("Недоступно для роли"), t.cannot, "muted");
    l->addLayout(cols);
}

void HomePage::fillSections()
{
    const RoleTexts t = textsFor(m_me.groupName);
    QVBoxLayout *l = ui->sectionsLayout;
    auto *grid = new QGridLayout;
    grid->setHorizontalSpacing(10);
    grid->setVerticalSpacing(9);
    grid->setColumnMinimumWidth(0, 190);
    int row = 0;
    for (const Link &s : t.sections) {
        QPushButton *b = linkButton(s.title, true, this);
        const QString key = s.target;
        connect(b, &QPushButton::clicked, this, [this, key] { emit openSectionRequested(key); });
        grid->addWidget(b, row, 0, Qt::AlignLeft);
        grid->addWidget(label(s.descr, "caption", this), row, 1);
        ++row;
    }
    grid->setColumnStretch(1, 1);
    l->addLayout(grid);

    auto *line = new QFrame(this);
    line->setObjectName(QStringLiteral("blockSeparator"));
    line->setFrameShape(QFrame::HLine);
    l->addWidget(line);

    auto *quick = new QHBoxLayout;
    quick->setSpacing(14);
    auto *caption = label(t.quickTitle + QLatin1Char(':'), "caption", this);
    caption->setProperty("strong", true);
    quick->addWidget(caption);
    for (const Link &q : t.quick) {
        QPushButton *b = linkButton(q.title, false, this);
        const QString form = q.target;
        connect(b, &QPushButton::clicked, this, [this, form] { emit openFormRequested(form); });
        quick->addWidget(b);
    }
    quick->addStretch(1);
    l->addLayout(quick);
}

void HomePage::refresh()
{
    QVBoxLayout *l = ui->todoLayout;
    clearLayout(l);
    QSqlQuery q;
    QString error;
    if (!ApiCall::select(QStringLiteral("home_todo"), {}, &q, &error)) {
        l->addWidget(label(error, "hint", this, true));
        return;
    }
    const QLocale ru(QLocale::Russian, QLocale::Russia);
    QDateTime asOf;
    while (q.next()) {
        const QSqlRecord r = q.record();
        auto *row = new QHBoxLayout;
        row->setSpacing(10);
        QPushButton *b = linkButton(q.value(r.indexOf(QStringLiteral("caption"))).toString(), false, this);
        const QString form = q.value(r.indexOf(QStringLiteral("form"))).toString();
        connect(b, &QPushButton::clicked, this, [this, form] { emit openFormRequested(form); });
        row->addWidget(b);
        row->addStretch(1);
        auto *value = label(ru.toString(q.value(r.indexOf(QStringLiteral("value"))).toLongLong()), nullptr, this);
        value->setProperty("strong", true);
        row->addWidget(value);
        l->addLayout(row);
        asOf = q.value(r.indexOf(QStringLiteral("as_of"))).toDateTime().toLocalTime();
    }
    l->addWidget(label(QStringLiteral("Данные на %1 · обновляются при открытии страницы")
                           .arg(asOf.toString(QStringLiteral("dd.MM.yyyy HH:mm"))),
                       "hint", this));
}

void HomePage::fillKeys()
{
    static const QList<QPair<QString, QString>> keys = {
        {QStringLiteral("Ctrl+F"), QStringLiteral("поиск в текущем списке")},
        {QStringLiteral("Ins"), QStringLiteral("создать")},
        {QStringLiteral("F2"), QStringLiteral("изменить выбранную строку")},
        {QStringLiteral("Enter"), QStringLiteral("открыть")},
        {QStringLiteral("Ctrl+Enter"), QStringLiteral("записать и закрыть форму")},
        {QStringLiteral("Ctrl+Tab"), QStringLiteral("следующая вкладка")},
    };
    auto *grid = new QGridLayout;
    grid->setHorizontalSpacing(0);
    grid->setVerticalSpacing(5);
    grid->setColumnMinimumWidth(0, 110);
    int row = 0;
    for (const auto &k : keys) {
        auto *kbd = label(k.first, "kbd", this);
        kbd->setSizePolicy(QSizePolicy::Maximum, QSizePolicy::Fixed);
        grid->addWidget(kbd, row, 0, Qt::AlignLeft);
        grid->addWidget(label(k.second, nullptr, this), row, 1);
        ++row;
    }
    grid->setColumnStretch(1, 1);
    ui->keysLayout->addLayout(grid);
}

void HomePage::fillConnection()
{
    const QList<QPair<QString, QString>> rows = {
        {QStringLiteral("Пользователь"), m_me.login},
        {QStringLiteral("ФИО"), m_me.fullName},
        {QStringLiteral("Группа"), m_me.groupName},
        {QStringLiteral("База данных"), QStringLiteral("%1 на %2:%3").arg(m_me.connection.database, m_me.connection.host)
                                            .arg(m_me.connection.port)},
        {QStringLiteral("СУБД"), m_me.serverVersion},
        {QStringLiteral("Сеанс работы начат"), m_me.sessionStarted.toString(QStringLiteral("dd.MM.yyyy HH:mm"))},
    };
    auto *grid = new QGridLayout;
    grid->setHorizontalSpacing(8);
    grid->setVerticalSpacing(4);
    grid->setColumnMinimumWidth(0, 150);
    int row = 0;
    for (const auto &r : rows) {
        grid->addWidget(label(r.first + QLatin1Char(':'), "caption", this), row, 0);
        grid->addWidget(label(r.second, nullptr, this), row, 1);
        ++row;
    }
    grid->setColumnStretch(1, 1);
    ui->connLayout->addLayout(grid);
}

void HomePage::fillHelp()
{
    const RoleTexts t = textsFor(m_me.groupName);
    for (const QString &h : t.help)
        ui->helpLayout->addWidget(label(h, nullptr, this, true));
    if (!m_me.adminContact.isEmpty())
        ui->helpLayout->addWidget(label(QStringLiteral("По вопросам доступа обращайтесь к администратору системы: %1.")
                                            .arg(m_me.adminContact),
                                        "hint", this, true));
}
