#include "ui/pages/UsersPage.h"

#include <QHBoxLayout>
#include <QHeaderView>
#include <QItemSelectionModel>
#include <QLabel>
#include <QLineEdit>
#include <QLocale>
#include <QMessageBox>
#include <QPushButton>
#include <QShortcut>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QStandardItemModel>
#include <QTableView>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/Theme.h"
#include "ui/dialogs/PasswordDialogs.h"
#include "ui/dialogs/UserDialog.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

UsersPage::UsersPage(const Whoami &me, QWidget *parent)
    : QWidget(parent)
    , m_me(me)
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Пользователи"));

    FormKit::CommandBar bar(this);
    connect(bar.button(QStringLiteral("Создать"), true), &QPushButton::clicked, this, &UsersPage::createUser);
    connect(bar.button(QStringLiteral("Изменить")), &QPushButton::clicked, this,
            [this] { FormKit::pending(this, QStringLiteral("Изменить пользователя")); });
    m_resetButton = bar.button(QStringLiteral("Сбросить пароль…"));
    connect(m_resetButton, &QPushButton::clicked, this, &UsersPage::resetPassword);
    m_loginButton = bar.button(QStringLiteral("Запретить вход"));
    connect(m_loginButton, &QPushButton::clicked, this, &UsersPage::toggleLogin);
    connect(bar.button(QStringLiteral("Удалить")), &QPushButton::clicked, this,
            [this] { FormKit::pending(this, QStringLiteral("Удалить пользователя")); });
    bar.separator();
    QPushButton *find = bar.button(QStringLiteral("Найти…"));
    bar.stretch();
    m_search = bar.search();
    bar.more();
    layout->addLayout(bar.layout());

    auto *row = new QHBoxLayout;
    row->setSpacing(12);

    // Панель групп — запрос 11 (ROLLUP: «Все пользователи» и «в том числе» по группам)
    m_groupModel = new QStandardItemModel(this);
    m_groups = new QTableView(this);
    m_groups->setObjectName(QStringLiteral("groupPanel"));
    m_groups->setModel(m_groupModel);
    m_groups->verticalHeader()->hide();
    m_groups->verticalHeader()->setDefaultSectionSize(Theme::rowHeight);
    m_groups->horizontalHeader()->setHighlightSections(false);
    m_groups->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_groups->setSelectionMode(QAbstractItemView::SingleSelection);
    m_groups->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_groups->horizontalHeader()->setDefaultAlignment(Qt::AlignLeft | Qt::AlignVCenter);
    m_groups->setFixedWidth(280);       // «Администраторы приложения» (D26) длиннее «Администраторов» макета
    row->addWidget(m_groups);

    m_users = new DataGrid(this, true, 20);
    m_users->setFunction(QStringLiteral("q_users"),
        {{QStringLiteral("login"), QStringLiteral("Логин"), ColumnSpec::Text, 0, 95},
         {QStringLiteral("full_name"), QStringLiteral("ФИО"), ColumnSpec::Text, 0, 236},
         {QStringLiteral("group_title"), QStringLiteral("Группа"), ColumnSpec::Text, 0, 180},
         {QStringLiteral("provider_name"), QStringLiteral("Провайдер"), ColumnSpec::Text, 0, 160},
         {QStringLiteral("can_login"), QStringLiteral("Вход разрешён"), ColumnSpec::Bool, 0, 110},
         {QStringLiteral("valid_until"), QStringLiteral("Пароль действует до"), ColumnSpec::Date, 0, 170, QString(),
          QStringLiteral("reset_pending"), QStringLiteral(" (временный)")}});
    // ФИО — по остатку ширины: панель групп шире макета (D26), срок пароля «08.10.2026 (временный)» — целиком
    m_users->setStretchColumn(QStringLiteral("full_name"));
    row->addWidget(m_users, 1);
    layout->addLayout(row, 1);
    layout->addWidget(FormKit::hint(QStringLiteral("Пользователь — роль PostgreSQL с правом входа, группа — роль без права "
                                                   "входа. Пароли хранит только СУБД."),
                                    this));

    connect(m_groups->selectionModel(), &QItemSelectionModel::currentRowChanged, this, [this](const QModelIndex &current) {
        const QString group = current.isValid() ? m_groupModel->item(current.row(), 0)->data(Qt::UserRole).toString()
                                                : QString();
        if (group != m_group) {
            m_group = group;
            reload();
        }
    });
    connect(m_users, &DataGrid::currentChanged, this, &UsersPage::updateButtons);
    connect(m_search, &QLineEdit::returnPressed, this, &UsersPage::reload);
    connect(find, &QPushButton::clicked, this, [this] { m_search->setFocus(); m_search->selectAll(); });
    auto *ctrlF = new QShortcut(QKeySequence::Find, this);
    connect(ctrlF, &QShortcut::activated, this, [this] { m_search->setFocus(); m_search->selectAll(); });

    loadGroups();
    reload();
}

void UsersPage::loadGroups()
{
    QSqlQuery q;
    QString error;
    if (!ApiCall::selectView(QStringLiteral("v_user_groups"), QStringLiteral("ord"), 20, 0, &q, &error)) {
        FormKit::error(this, error);
        return;
    }
    const QSignalBlocker block(m_groups->selectionModel());
    m_groupModel->clear();
    m_groupModel->setHorizontalHeaderLabels({QStringLiteral("Группа"), QStringLiteral("Кол-во")});
    m_groupModel->setHeaderData(1, Qt::Horizontal, int(Qt::AlignRight | Qt::AlignVCenter), Qt::TextAlignmentRole);
    int current = 0;
    while (q.next()) {
        const QSqlRecord r = q.record();
        const QString group = q.value(r.indexOf(QStringLiteral("group_name"))).toString();
        const bool all = group.isEmpty();
        // «Все пользователи» — жирная, группы — с отступом (как в макете)
        auto *title = new QStandardItem((all ? QString() : QStringLiteral("    "))
                                        + q.value(r.indexOf(QStringLiteral("title"))).toString());
        title->setData(group, Qt::UserRole);
        auto *count = new QStandardItem(QLocale(QLocale::Russian).toString(q.value(r.indexOf(QStringLiteral("users"))).toLongLong()));
        count->setTextAlignment(Qt::AlignRight | Qt::AlignVCenter);
        if (all) {
            QFont f;
            f.setBold(true);
            title->setFont(f);
            count->setFont(f);
        }
        if (group == m_group)
            current = m_groupModel->rowCount();
        m_groupModel->appendRow({title, count});
    }
    m_groups->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
    m_groups->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Fixed);
    m_groups->setColumnWidth(1, 68);
    m_groups->selectRow(current);
}

void UsersPage::applyArgs(const QVariantMap &args)
{
    if (args.value(QStringLiteral("refresh")).toBool()) {
        loadGroups();
        reload();
    }
}

void UsersPage::reload()
{
    const QString text = m_search->text().trimmed();
    m_users->setFilter({{QStringLiteral("p_group"), m_group.isEmpty() ? QVariant() : QVariant(m_group)},
                        {QStringLiteral("p_search"), text.isEmpty() ? QVariant() : QVariant(text)}});
    m_users->reloadFromStart();
    updateButtons();
}

void UsersPage::updateButtons()
{
    const bool canManage = m_users->currentValue(QStringLiteral("can_manage")).toBool();
    const bool canLogin = m_users->currentValue(QStringLiteral("can_login")).toBool();
    m_loginButton->setText(canLogin || !m_users->currentId().isValid() ? QStringLiteral("Запретить вход")
                                                                       : QStringLiteral("Разрешить вход"));
    m_loginButton->setEnabled(canManage);
    m_resetButton->setEnabled(canManage);       // can_manage: управляемая группа и не своя учётная запись (сервер)
}

void UsersPage::toggleLogin()
{
    const QString login = m_users->currentValue(QStringLiteral("login")).toString();
    if (login.isEmpty())
        return;
    const bool enable = !m_users->currentValue(QStringLiteral("can_login")).toBool();
    const QString question = enable ? QStringLiteral("Разрешить вход пользователю «%1»?")
                                    : QStringLiteral("Запретить вход пользователю «%1»? Открытые сеансы работы не прерываются.");
    if (QMessageBox::question(this, QStringLiteral("СуперБД"), question.arg(login)) != QMessageBox::Yes)
        return;
    QString error;
    if (!ApiCall::exec(QStringLiteral("user_set_login"),
                       {{QStringLiteral("p_login"), login}, {QStringLiteral("p_enabled"), enable}}, &error)) {
        FormKit::error(this, error);
        return;
    }
    m_users->reload();
    updateButtons();
}

void UsersPage::resetPassword()
{
    const QString login = m_users->currentValue(QStringLiteral("login")).toString();
    if (login.isEmpty())
        return;
    const QString fullName = m_users->currentValue(QStringLiteral("full_name")).toString();
    ResetConfirmDialog confirm(login, fullName, m_users->currentValue(QStringLiteral("group_title")).toString(),
                               m_users->currentValue(QStringLiteral("provider_name")).toString(), this);
    if (confirm.exec() != QDialog::Accepted)
        return;
    QSqlQuery q;
    QString error;
    if (!ApiCall::select(QStringLiteral("user_reset_password"), {{QStringLiteral("p_login"), login}}, &q, &error)
        || !q.next()) {
        FormKit::error(this, error.isEmpty() ? QStringLiteral("Сервер не вернул временный пароль") : error);
        return;
    }
    QString password = q.value(0).toString();
    const QDateTime validUntil = q.value(1).toDateTime();
    q = QSqlQuery();                              // результат с паролем больше не держим
    m_users->reload();                            // «Пароль действует до … (временный)»
    TempPasswordDialog::showOnce(this, login, fullName, password, validUntil);
}

void UsersPage::createUser()
{
    UserDialog dialog(this);
    dialog.exec();
    if (dialog.created()) {
        loadGroups();
        reload();
    }
}
