#include "ui/pages/ListPages.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QSpinBox>
#include <QVBoxLayout>

#include "ui/dialogs/ContractDialog.h"
#include "ui/dialogs/SubscriberDialog.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

SharedSubscribersPage::SharedSubscribersPage(QWidget *parent)
    : QWidget(parent)
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Общие абоненты"));

    FormKit::CommandBar bar(this);
    QPushButton *open = bar.button(QStringLiteral("Открыть"), true);
    connect(bar.button(QStringLiteral("Изменить")), &QPushButton::clicked, this,
            [this] { FormKit::pending(this, QStringLiteral("Изменить сведения абонента")); });
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    auto *params = new QHBoxLayout;
    params->setSpacing(6);
    params->addWidget(FormKit::caption(QStringLiteral("Провайдеров не меньше:"), this));
    m_minProviders = new QSpinBox(this);
    m_minProviders->setRange(2, 99);
    m_minProviders->setFixedWidth(70);
    params->addWidget(m_minProviders);
    params->addStretch(1);
    layout->addLayout(params);

    m_grid = new DataGrid(this, true, 20);
    m_grid->setFunction(QStringLiteral("q_shared_subscribers"),
        {{QStringLiteral("name"), QStringLiteral("Наименование"), ColumnSpec::Text, 0, 300},
         {QStringLiteral("subscriber_type"), QStringLiteral("Тип абонента"), ColumnSpec::Text, 0, 200},
         {QStringLiteral("city"), QStringLiteral("Город"), ColumnSpec::Text, 0, 110},
         {QStringLiteral("address"), QStringLiteral("Физический адрес"), ColumnSpec::Text, 0, 260},
         {QStringLiteral("phone"), QStringLiteral("Телефон"), ColumnSpec::Text, 0, 150},
         {QStringLiteral("providers"), QStringLiteral("Провайдеров"), ColumnSpec::Integer, 0, 0}});
    layout->addWidget(m_grid, 1);
    layout->addWidget(FormKit::hint(QStringLiteral("Абоненты, у которых есть договоры с несколькими провайдерами. Сведения "
                                                   "реестра (наименование, тип, адрес, телефон) у них меняет только "
                                                   "администратор; адрес подключения и контакты — в договоре у оператора."),
                                    this, true));

    auto openCard = [this] {
        const QVariant id = m_grid->currentId();
        if (id.isValid() && !id.isNull())
            SubscriberDialog(id, this).exec();
    };
    connect(open, &QPushButton::clicked, this, openCard);
    connect(m_grid, &DataGrid::activated, this, openCard);
    connect(m_minProviders, &QSpinBox::editingFinished, this, &SharedSubscribersPage::reload);
    reload();
}

void SharedSubscribersPage::reload()
{
    m_grid->setFilter({{QStringLiteral("p_min_providers"), m_minProviders->value()}});
    m_grid->reloadFromStart();
}

IdleContractsPage::IdleContractsPage(const Whoami &me, QWidget *parent)
    : QWidget(parent)
{
    Q_UNUSED(me);
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Договоры без сеансов"));

    FormKit::CommandBar bar(this);
    QPushButton *open = bar.button(QStringLiteral("Открыть договор"), true);
    QPushButton *refresh = bar.button(QStringLiteral("Обновить"));
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    auto *params = new QHBoxLayout;
    params->setSpacing(6);
    params->addWidget(FormKit::caption(QStringLiteral("Без сеансов более:"), this));
    m_days = new QSpinBox(this);
    m_days->setRange(1, 3650);
    m_days->setValue(30);
    m_days->setFixedWidth(80);
    params->addWidget(m_days);
    params->addWidget(FormKit::caption(QStringLiteral("дней"), this));
    params->addStretch(1);
    layout->addLayout(params);

    m_grid = new DataGrid(this, true, 20);
    m_grid->setFunction(QStringLiteral("q_idle_contracts"),
        {{QStringLiteral("contract_no"), QStringLiteral("Номер договора"), ColumnSpec::Text, 0, 130},
         {QStringLiteral("subscriber_name"), QStringLiteral("Абонент"), ColumnSpec::Text, 0, 300},
         {QStringLiteral("phone"), QStringLiteral("Телефон"), ColumnSpec::Text, 0, 150},
         {QStringLiteral("connected_on"), QStringLiteral("Дата подключения"), ColumnSpec::Date, 0, 130},
         {QStringLiteral("last_session"), QStringLiteral("Последний сеанс"), ColumnSpec::DateTime, 0, 140},
         {QStringLiteral("idle_days"), QStringLiteral("Дней без сеансов"), ColumnSpec::Integer, 0, 0}});
    layout->addWidget(m_grid, 1);
    layout->addWidget(FormKit::hint(QStringLiteral("Действующие договоры, заключённые раньше границы и без сеансов после неё; "
                                                   "пустой «Последний сеанс» — сеансов не было."),
                                    this, true));

    auto openCard = [this] {
        const QVariant id = m_grid->currentId();
        if (id.isValid() && !id.isNull())
            ContractDialog(id, this).exec();
    };
    connect(open, &QPushButton::clicked, this, openCard);
    connect(m_grid, &DataGrid::activated, this, openCard);
    connect(refresh, &QPushButton::clicked, this, &IdleContractsPage::reload);
    connect(m_days, &QSpinBox::editingFinished, this, &IdleContractsPage::reload);
    reload();
}

void IdleContractsPage::reload()
{
    m_grid->setFilter({{QStringLiteral("p_days"), m_days->value()}});
    m_grid->reloadFromStart();
}
