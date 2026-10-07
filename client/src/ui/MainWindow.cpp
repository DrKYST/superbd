#include "ui/MainWindow.h"
#include "ui_MainWindow.h"

#include <QButtonGroup>
#include <QDate>
#include <QHash>
#include <QLabel>
#include <QMessageBox>
#include <QPushButton>
#include <QTabBar>
#include <QToolButton>

#include "ui/pages/ContractsPage.h"
#include "ui/dialogs/UserDialog.h"
#include "ui/pages/HomePage.h"
#include "ui/pages/ListPages.h"
#include "ui/pages/PlaceholderPage.h"
#include "ui/pages/ProvidersPage.h"
#include "ui/pages/ReportPage.h"
#include "ui/pages/SessionsPage.h"
#include "ui/pages/SubscribersPage.h"
#include "ui/pages/TariffUsagePage.h"
#include "ui/pages/UsersPage.h"

namespace {

const char *kFormProperty = "form";

// Экран макета, по которому будет сделана форма (для временной заглушки).
QString mockupScreen(const QString &form)
{
    static const QHash<QString, QString> screens = {
        {QStringLiteral("subscribers"), QStringLiteral("Subscribers")},
        {QStringLiteral("sessions"), QStringLiteral("Sessions")},
        {QStringLiteral("report_revenue"), QStringLiteral("Stats")},
        {QStringLiteral("tariffs"), QStringLiteral("Refs")},
        {QStringLiteral("providers"), QStringLiteral("Providers")},
    };
    return screens.value(form);
}

} // namespace

MainWindow::MainWindow(const Whoami &me, QWidget *parent)
    : QMainWindow(parent)
    , ui(new Ui::MainWindow)
    , m_me(me)
    , m_sectionButtons(new QButtonGroup(this))
    , m_tabs(nullptr)
{
    ui->setupUi(this);
    for (QWidget *w : {ui->sectionBar, ui->navPanel, ui->windowTabs})
        w->setAttribute(Qt::WA_StyledBackground, true);

    m_tabs = new QTabBar(ui->windowTabs);
    m_tabs->setTabsClosable(true);
    m_tabs->setDrawBase(false);
    m_tabs->setExpanding(false);
    m_tabs->setUsesScrollButtons(true);
    m_tabs->setFocusPolicy(Qt::NoFocus);
    ui->windowTabsLayout->addWidget(m_tabs, 0, Qt::AlignBottom | Qt::AlignLeft);
    ui->windowTabsLayout->addStretch(1);

    // «СуперБД: Учёт услуг связи интернет-провайдеров (Ковалёва М. И., оператор, ООО «Степной провод»)»
    QString who = me.shortName + QStringLiteral(", ") + me.roleShort;
    if (!me.providerName.isEmpty())
        who += QStringLiteral(", ") + me.providerName;
    setWindowTitle(QStringLiteral("СуперБД: Учёт услуг связи интернет-провайдеров (%1)").arg(who));

    ui->userLogin->setText(me.login);
    connect(ui->logoutButton, &QPushButton::clicked, this, [this] {
        m_logout = true;
        close();
    });

    // Строка состояния: база, пользователь, справа — дата.
    auto *dbLabel = new QLabel(QStringLiteral("База: %1 на %2:%3")
                                   .arg(me.connection.database, me.connection.host)
                                   .arg(me.connection.port), this);
    auto *userLabel = new QLabel(QStringLiteral("Пользователь: %1 (%2)").arg(me.login, me.groupName), this);
    auto *dateLabel = new QLabel(QDate::currentDate().toString(QStringLiteral("dd.MM.yyyy")), this);
    statusBar()->addWidget(dbLabel);
    statusBar()->addWidget(userLabel);
    statusBar()->addPermanentWidget(dateLabel);

    connect(m_tabs, &QTabBar::tabCloseRequested, this, &MainWindow::closeTab);
    connect(m_tabs, &QTabBar::currentChanged, this, [this](int index) {
        if (QWidget *page = pageAt(index))
            ui->pages->setCurrentWidget(page);
        syncNavWithCurrentTab();
    });

    m_sections = RoleConfig::sectionsFor(me.groupName);
    buildSections();
    openSection(QStringLiteral("home"));
}

MainWindow::~MainWindow()
{
    delete ui;
}

void MainWindow::buildSections()
{
    for (const Section &s : m_sections) {
        auto *b = new QToolButton(ui->sectionBar);
        b->setText(s.title);
        b->setIcon(QIcon(QStringLiteral(":/icons/%1.svg").arg(s.icon)));
        b->setIconSize(QSize(26, 26));
        b->setToolButtonStyle(Qt::ToolButtonTextUnderIcon);
        b->setCheckable(true);
        b->setAutoRaise(true);
        b->setFocusPolicy(Qt::NoFocus);
        b->setProperty("section", s.key);
        m_sectionButtons->addButton(b);
        ui->sectionButtonsLayout->addWidget(b);
        const QString key = s.key;
        connect(b, &QToolButton::clicked, this, [this, key] { openSection(key); });
    }
}

void MainWindow::openSection(const QString &sectionKey)
{
    const Section *section = nullptr;
    for (const Section &s : m_sections)
        if (s.key == sectionKey)
            section = &s;
    if (!section)
        return;
    activateSection(*section);
    openForm(section->defaultForm);
}

void MainWindow::activateSection(const Section &section)
{
    m_currentSection = section.key;
    for (QAbstractButton *b : m_sectionButtons->buttons())
        b->setChecked(b->property("section").toString() == section.key);
    buildNav(section);
}

// Раздел, к которому относится форма: текущий, если форма есть в его навигации; иначе раздел,
// для которого она основная; иначе первый раздел, в навигации которого она есть.
const Section *MainWindow::sectionForForm(const QString &form) const
{
    auto inNav = [&form](const Section &s) {
        for (const NavGroup &g : s.nav)
            for (const NavLink &l : g.links)
                if (l.form == form)
                    return true;
        return false;
    };
    for (const Section &s : m_sections)
        if (s.key == m_currentSection && inNav(s) && (form != QLatin1String("home") || s.key == QLatin1String("home")))
            return &s;
    for (const Section &s : m_sections)
        if (s.defaultForm == form)
            return &s;
    for (const Section &s : m_sections)
        if (inNav(s))
            return &s;
    return nullptr;
}

void MainWindow::buildNav(const Section &section)
{
    QLayout *layout = ui->navLayout;
    while (QLayoutItem *item = layout->takeAt(0)) {
        delete item->widget();
        delete item;
    }
    m_navLinks.clear();
    for (const NavGroup &g : section.nav) {
        auto *title = new QLabel(g.title, ui->navPanel);
        title->setProperty("role", QStringLiteral("group"));
        layout->addWidget(title);
        for (const NavLink &link : g.links) {
            auto *b = new QPushButton(link.title, ui->navPanel);
            b->setProperty("role", QStringLiteral("link"));
            b->setProperty(kFormProperty, link.form);
            b->setCheckable(true);
            b->setCursor(Qt::PointingHandCursor);
            if (link.title.contains(QLatin1Char('\n')))     // ссылка в две строки (как в макете): высота — в superbd.qss
                b->setProperty("multiline", true);
            b->setFocusPolicy(Qt::NoFocus);
            const QString form = link.form;
            connect(b, &QPushButton::clicked, this, [this, form] { openForm(form); });
            layout->addWidget(b);
            m_navLinks << b;
        }
    }
    static_cast<QVBoxLayout *>(layout)->addStretch(1);
    syncNavWithCurrentTab();
}

void MainWindow::syncNavWithCurrentTab()
{
    const QWidget *page = pageAt(m_tabs->currentIndex());
    const QString form = page ? page->property(kFormProperty).toString() : QString();
    for (QPushButton *b : m_navLinks)
        b->setChecked(b->property(kFormProperty).toString() == form);
}

void MainWindow::openForm(const QString &form)
{
    // Счётчики начальной страницы, открывающие форму с отбором (api.home_todo, поле form).
    if (form == QLatin1String("providers_without_staff"))
        openFormWithArgs(QStringLiteral("providers"), {{QStringLiteral("without_staff"), true}});
    else if (form == QLatin1String("providers_without_new"))
        openFormWithArgs(QStringLiteral("providers"), {{QStringLiteral("without_new"), true}});
    else
        openFormWithArgs(form, {});
}

void MainWindow::openFormWithArgs(const QString &form, const QVariantMap &args)
{
    if (RoleConfig::isDialog(form)) {
        openDialog(form);
        return;
    }
    if (const Section *section = sectionForForm(form); section && section->key != m_currentSection)
        activateSection(*section);
    for (int i = 0; i < m_tabs->count(); ++i) {
        if (pageAt(i)->property(kFormProperty).toString() == form) {
            m_tabs->setCurrentIndex(i);
            syncNavWithCurrentTab();
            if (!args.isEmpty())
                QMetaObject::invokeMethod(pageAt(i), "applyArgs", Q_ARG(QVariantMap, args));
            return;
        }
    }
    QWidget *page = createPage(form);
    page->setProperty(kFormProperty, form);
    ui->pages->addWidget(page);
    const int index = m_tabs->addTab(RoleConfig::formTitle(form));
    if (form == QLatin1String("home")) {
        // «Начальная страница» всегда открыта и не закрывается.
        m_tabs->setTabButton(index, QTabBar::RightSide, nullptr);
        m_tabs->setTabButton(index, QTabBar::LeftSide, nullptr);
    }
    m_tabs->setCurrentIndex(index);
    ui->pages->setCurrentWidget(page);
    syncNavWithCurrentTab();
    if (!args.isEmpty())
        QMetaObject::invokeMethod(page, "applyArgs", Q_ARG(QVariantMap, args));
}

void MainWindow::closeTab(int index)
{
    QWidget *page = pageAt(index);
    if (!page || page->property(kFormProperty).toString() == QLatin1String("home"))
        return;
    ui->pages->removeWidget(page);   // сначала страницу: currentChanged вкладок сопоставляет индексы
    m_tabs->removeTab(index);
    page->deleteLater();
}

QWidget *MainWindow::pageAt(int index) const
{
    // Вкладки не перемещаются и добавляются вместе со страницами, поэтому индексы совпадают.
    return (index >= 0 && index < ui->pages->count()) ? ui->pages->widget(index) : nullptr;
}

QWidget *MainWindow::createPage(const QString &form)
{
    if (form == QLatin1String("home")) {
        auto *home = new HomePage(m_me, ui->pages);
        connect(home, &HomePage::openFormRequested, this, &MainWindow::openForm);
        connect(home, &HomePage::openSectionRequested, this, &MainWindow::openSection);
        return home;
    }
    // Рабочие экраны на запросах ЛР 5 (D22): руководитель и главный аналитик — только просмотр.
    const bool readOnly = RoleConfig::isReadOnly(m_me.groupName);
    if (form == QLatin1String("subscribers")) {
        auto *page = new SubscribersPage(m_me, readOnly, ui->pages);
        connect(page, &SubscribersPage::openFormRequested, this, &MainWindow::openFormWithArgs);
        return page;
    }
    if (form == QLatin1String("contracts"))
        return new ContractsPage(m_me, readOnly, ui->pages);
    if (form == QLatin1String("sessions"))
        return new SessionsPage(m_me, readOnly, ui->pages);
    if (form == QLatin1String("providers")) {
        auto *page = new ProvidersPage(m_me, m_me.groupName != QLatin1String("grp_admin"), ui->pages);
        connect(page, &ProvidersPage::openFormRequested, this, &MainWindow::openFormWithArgs);
        return page;
    }
    if (form == QLatin1String("my_provider"))
        return new MyProviderPage(m_me, ui->pages);
    if (form == QLatin1String("report_traffic"))
        return new TariffUsagePage(m_me, ui->pages);
    // Отчёты «Статистики» и списки ЛР 6
    if (form == QLatin1String("report_revenue"))
        return new ReportPage(m_me, ReportPage::Revenue, ui->pages);
    if (form == QLatin1String("report_new_contracts"))
        return new ReportPage(m_me, ReportPage::NewContracts, ui->pages);
    if (form == QLatin1String("report_top_subscribers"))
        return new ReportPage(m_me, ReportPage::TopSubscribers, ui->pages);
    if (form == QLatin1String("users"))
        return new UsersPage(m_me, ui->pages);
    if (form == QLatin1String("shared_subscribers"))
        return new SharedSubscribersPage(ui->pages);
    if (form == QLatin1String("idle_contracts"))
        return new IdleContractsPage(m_me, ui->pages);
    return new PlaceholderPage(RoleConfig::formTitle(form), mockupScreen(form), ui->pages);
}

void MainWindow::openDialog(const QString &form)
{
    if (form == QLatin1String("about")) {
        QMessageBox::about(this, QStringLiteral("О программе"),
                           QStringLiteral("<b>СуперБД</b><br>Учёт услуг связи интернет-провайдеров<br><br>"
                                          "Курсовой проект по дисциплине «Программирование систем с серверами баз данных», "
                                          "вариант Б-16.<br>Клиент: Qt %1, сервер: %2.")
                               .arg(QString::fromLatin1(qVersion()), m_me.serverVersion));
        return;
    }
    if (form == QLatin1String("new_user")) {
        UserDialog dialog(this);
        dialog.exec();
        if (dialog.created())
            openFormWithArgs(QStringLiteral("users"), {{QStringLiteral("refresh"), true}});
        return;
    }
    statusBar()->showMessage(QStringLiteral("Форма «%1» будет добавлена на следующем этапе разработки клиента.")
                                 .arg(RoleConfig::formTitle(form)),
                             5000);
}
