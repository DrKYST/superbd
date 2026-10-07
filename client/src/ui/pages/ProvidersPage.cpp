#include "ui/pages/ProvidersPage.h"

#include <QDate>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QShortcut>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

namespace {

QList<ColumnSpec> staffColumns()
{
    return {{QStringLiteral("login"), QStringLiteral("Логин"), ColumnSpec::Text, 0, 138},
            {QStringLiteral("full_name"), QStringLiteral("ФИО"), ColumnSpec::Text, 0, 305},
            {QStringLiteral("group_title"), QStringLiteral("Группа"), ColumnSpec::Text, 0, 152},
            {QStringLiteral("can_login"), QStringLiteral("Вход разрешён"), ColumnSpec::Bool, 0, 0}};
}

} // namespace

ProvidersPage::ProvidersPage(const Whoami &me, bool readOnly, QWidget *parent)
    : QWidget(parent)
{
    Q_UNUSED(me);
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Провайдеры"), readOnly);

    FormKit::CommandBar bar(this);
    if (!readOnly) {
        connect(bar.button(QStringLiteral("Создать"), true), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Создать провайдера")); });
        connect(bar.button(QStringLiteral("Изменить")), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Изменить провайдера")); });
        QPushButton *remove = bar.button(QStringLiteral("Удалить"));
        remove->setEnabled(false);      // провайдера с договорами удалить нельзя (D9); удаление — этап CRUD
        bar.separator();
    }
    QPushButton *find = bar.button(QStringLiteral("Найти…"));
    QPushButton *cancelFind = bar.button(QStringLiteral("Отменить поиск"));
    bar.stretch();
    m_search = bar.search();
    bar.more();
    layout->addLayout(bar.layout());

    // Провайдеры — запрос 10
    m_providers = new DataGrid(this, true, 20);
    m_providers->setFunction(QStringLiteral("q_providers"),
        {{QStringLiteral("display_name"), QStringLiteral("Наименование"), ColumnSpec::Text, 0, 273},
         {QStringLiteral("ownership_type"), QStringLiteral("Тип собственности"), ColumnSpec::Text, 0, 146},
         {QStringLiteral("city"), QStringLiteral("Город"), ColumnSpec::Text, 0, 99},
         {QStringLiteral("address"), QStringLiteral("Адрес"), ColumnSpec::Text, 0, 206},
         {QStringLiteral("phone"), QStringLiteral("Телефон"), ColumnSpec::Text, 0, 144},
         {QStringLiteral("founded_year"), QStringLiteral("Год начала работы"), ColumnSpec::TextRight, 0, 147},
         {QStringLiteral("contracts_active"), QStringLiteral("Действующих договоров"), ColumnSpec::Integer, 0, 0}});
    layout->addWidget(m_providers, 3);

    // Сотрудники выбранного провайдера — запрос 1
    auto *captionRow = new QHBoxLayout;
    m_staffCaption = FormKit::gridCaption(QStringLiteral("Сотрудники провайдера"), this);
    captionRow->addWidget(m_staffCaption);
    captionRow->addStretch(1);
    if (!readOnly) {
        QPushButton *toUsers = FormKit::link(QStringLiteral("Открыть в списке пользователей"), this);
        connect(toUsers, &QPushButton::clicked, this, [this] { emit openFormRequested(QStringLiteral("users"), {}); });
        captionRow->addWidget(toUsers);
    }
    layout->addSpacing(8);
    layout->addLayout(captionRow);
    m_staff = new DataGrid(this, false, 200);
    m_staff->setFunction(QStringLiteral("q_provider_staff"), staffColumns());
    m_staff->setFixedWidth(762);
    auto *staffRow = new QHBoxLayout;
    staffRow->addWidget(m_staff);
    staffRow->addStretch(1);
    layout->addLayout(staffRow, 1);
    layout->addWidget(FormKit::hint(QStringLiteral("Удаление провайдера невозможно, пока у него есть договоры. Оператор и "
                                                   "руководитель открывают только карточку своего провайдера, без изменения."),
                                    this, true));

    connect(m_search, &QLineEdit::returnPressed, this, &ProvidersPage::reload);
    connect(find, &QPushButton::clicked, this, [this] { m_search->setFocus(); m_search->selectAll(); });
    connect(cancelFind, &QPushButton::clicked, this, [this] { m_search->clear(); m_withoutNew = false; reload(); });
    auto *ctrlF = new QShortcut(QKeySequence::Find, this);
    connect(ctrlF, &QShortcut::activated, this, [this] { m_search->setFocus(); m_search->selectAll(); });
    connect(m_providers, &DataGrid::currentChanged, this, [this](const QVariant &id) {
        if (!id.isValid() || id.isNull()) {
            m_staffCaption->setText(QStringLiteral("Сотрудники провайдера"));
            m_staff->clear();
            return;
        }
        m_staffCaption->setText(QStringLiteral("Сотрудники провайдера «%1»")
                                    .arg(m_providers->currentValue(QStringLiteral("display_name")).toString()));
        m_staff->setFilter({{QStringLiteral("p_provider_id"), id}});
        m_staff->reloadFromStart();
    });

    reload();
}

void ProvidersPage::reload()
{
    const QDate today = QDate::currentDate();
    const QString text = m_search->text().trimmed();
    m_providers->setFilter({{QStringLiteral("p_from"), QDate(today.year(), today.month(), 1)},
                            {QStringLiteral("p_to"), today},
                            {QStringLiteral("p_search"), text.isEmpty() ? QVariant() : QVariant(text)},
                            {QStringLiteral("p_without_new"), m_withoutNew}});
    m_providers->reloadFromStart();
}

void ProvidersPage::applyArgs(const QVariantMap &args)
{
    m_withoutNew = args.value(QStringLiteral("without_new")).toBool();
    reload();
}

MyProviderPage::MyProviderPage(const Whoami &me, QWidget *parent)
    : QWidget(parent)
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Мой провайдер"), true);

    // Карточка — запрос 5: оператору и руководителю представление возвращает только их провайдера.
    QSqlQuery q;
    QString error;
    if (!ApiCall::selectView(QStringLiteral("v_providers"), QStringLiteral("name"), 1, 0, &q, &error) || !q.next()) {
        layout->addWidget(FormKit::hint(error.isEmpty() ? QStringLiteral("Провайдер не найден") : error, this, true));
        layout->addStretch(1);
        return;
    }
    const QSqlRecord r = q.record();
    const QVariant providerId = q.value(r.indexOf(QStringLiteral("id")));
    auto *grid = new QGridLayout;
    grid->setHorizontalSpacing(8);
    grid->setVerticalSpacing(8);
    grid->setColumnMinimumWidth(0, 170);
    const QList<QPair<QString, QString>> rows = {
        {QStringLiteral("Наименование:"), QStringLiteral("display_name")},
        {QStringLiteral("Тип собственности:"), QStringLiteral("ownership_type")},
        {QStringLiteral("Город:"), QStringLiteral("city")},
        {QStringLiteral("Адрес:"), QStringLiteral("address")},
        {QStringLiteral("Телефон:"), QStringLiteral("phone")},
        {QStringLiteral("Год начала работы:"), QStringLiteral("founded_year")},
    };
    int row = 0;
    for (const auto &f : rows) {
        grid->addWidget(FormKit::caption(f.first, this), row, 0);
        auto *field = FormKit::readOnlyField(q.value(r.indexOf(f.second)).toString(), this);
        field->setFixedWidth(420);
        grid->addWidget(field, row, 1, Qt::AlignLeft);
        ++row;
    }
    grid->setColumnStretch(2, 1);
    layout->addLayout(grid);
    layout->addWidget(FormKit::hint(QStringLiteral("Карточку провайдера изменяет администратор системы."), this));

    if (me.groupName == QLatin1String("grp_manager")) {
        layout->addSpacing(10);
        layout->addWidget(FormKit::gridCaption(QStringLiteral("Сотрудники провайдера"), this));
        auto *staff = new DataGrid(this, false, 200);
        staff->setFunction(QStringLiteral("q_provider_staff"), staffColumns());
        staff->setFixedWidth(762);
        staff->setFilter({{QStringLiteral("p_provider_id"), providerId}});
        auto *staffRow = new QHBoxLayout;
        staffRow->addWidget(staff);
        staffRow->addStretch(1);
        layout->addLayout(staffRow, 1);
        staff->reload();
    } else {
        layout->addStretch(1);
    }
}
