#include "ui/pages/SubscribersPage.h"

#include <QCheckBox>
#include <QComboBox>
#include <QDate>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QShortcut>
#include <QSqlQuery>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/dialogs/ContractDialog.h"
#include "ui/dialogs/SubscriberDialog.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

SubscribersPage::SubscribersPage(const Whoami &me, bool readOnly, QWidget *parent)
    : QWidget(parent)
    , m_me(me)
    , m_readOnly(readOnly)
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Абоненты"), readOnly);

    // Командная панель: у оператора — полная, у ролей просмотра — только поиск.
    FormKit::CommandBar bar(this);
    if (!readOnly) {
        connect(bar.button(QStringLiteral("Создать"), true), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Создать абонента")); });
        connect(bar.button(QStringLiteral("Изменить")), &QPushButton::clicked, this, [this] {
            if (m_subscribers->currentId().isValid())
                SubscriberDialog(m_subscribers->currentId(), this).exec();
        });
        connect(bar.button(QStringLiteral("Удалить")), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Удалить абонента")); });
        bar.separator();
        connect(bar.button(QStringLiteral("Новый договор…")), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Новый договор")); });
        bar.separator();
    }
    QPushButton *find = bar.button(QStringLiteral("Найти…"));
    QPushButton *cancelFind = bar.button(QStringLiteral("Отменить поиск"));
    bar.stretch();
    m_search = bar.search();
    bar.more();
    layout->addLayout(bar.layout());

    // Отбор
    auto *filter = new QHBoxLayout;
    filter->setSpacing(6);
    filter->addWidget(FormKit::caption(QStringLiteral("Тип абонента:"), this));
    m_type = new QComboBox(this);
    m_type->setMinimumWidth(190);
    m_type->addItem(QStringLiteral("<все>"), QVariant());
    {
        QSqlQuery q;
        QString error;
        if (ApiCall::select(QStringLiteral("lookup_subscriber_types"), {}, &q, &error))
            while (q.next())
                m_type->addItem(q.value(1).toString(), q.value(0));
    }
    filter->addWidget(m_type);
    filter->addSpacing(28);
    m_activeOnly = new QCheckBox(QStringLiteral("Только с действующими договорами"), this);
    m_activeOnly->setChecked(true);
    filter->addWidget(m_activeOnly);
    filter->addStretch(1);
    const QString scope = me.providerName.isEmpty()
        ? QStringLiteral("Показаны абоненты всех провайдеров")
        : QStringLiteral("Показаны абоненты с договорами %1").arg(me.providerName);
    filter->addWidget(FormKit::hint(scope, this));
    layout->addLayout(filter);

    // Список абонентов — запрос 8
    m_subscribers = new DataGrid(this, true, 20);
    m_subscribers->setFunction(QStringLiteral("q_subscribers"),
        {{QStringLiteral("name"), QStringLiteral("Наименование"), ColumnSpec::Text, 0, 300},
         {QStringLiteral("subscriber_type"), QStringLiteral("Тип абонента"), ColumnSpec::Text, 0, 290},
         {QStringLiteral("city"), QStringLiteral("Город"), ColumnSpec::Text, 0, 105},
         {QStringLiteral("address"), QStringLiteral("Физический адрес"), ColumnSpec::Text, 0, 250},
         {QStringLiteral("phone"), QStringLiteral("Телефон"), ColumnSpec::Text, 0, 150},
         {QStringLiteral("contracts_total"), QStringLiteral("Договоров"), ColumnSpec::Integer, 0, 90}});
    m_subscribers->setStretchColumn(QStringLiteral("address"));
    layout->addWidget(m_subscribers, 3);

    // Нижняя часть: договоры абонента и сеансы договора
    auto *bottom = new QHBoxLayout;
    bottom->setSpacing(12);

    auto *left = new QVBoxLayout;
    left->setSpacing(4);
    m_contractsCaption = FormKit::gridCaption(QString(), this);
    left->addWidget(m_contractsCaption);
    if (!readOnly) {
        FormKit::CommandBar cbar(this);
        connect(cbar.button(QStringLiteral("Добавить")), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Добавить договор")); });
        connect(cbar.button(QStringLiteral("Изменить")), &QPushButton::clicked, this, [this] {
            if (m_contracts->currentId().isValid())
                ContractDialog(m_contracts->currentId(), this).exec();
        });
        connect(cbar.button(QStringLiteral("Расторгнуть")), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Расторгнуть договор")); });
        cbar.stretch();
        left->addLayout(cbar.layout());
    }
    m_contracts = new DataGrid(this, false, 200);
    m_contracts->setFunction(QStringLiteral("q_contracts"),
        {{QStringLiteral("contract_no"), QStringLiteral("Номер"), ColumnSpec::Text, 0, 105},
         {QStringLiteral("connected_on"), QStringLiteral("Дата подкл."), ColumnSpec::Date, 0, 88},
         {QStringLiteral("connection_fee"), QStringLiteral("Подключение, руб."), ColumnSpec::Number, 2, 128},
         {QStringLiteral("price_per_mb"), QStringLiteral("1 Мб, руб."), ColumnSpec::Number, 4, 82},
         {QStringLiteral("ip_address"), QStringLiteral("IP-адрес"), ColumnSpec::Text, 0, 78},
         {QStringLiteral("state"), QStringLiteral("Состояние"), ColumnSpec::Text, 0, 0, QStringLiteral("Действует")}});
    left->addWidget(m_contracts, 1);
    bottom->addLayout(left, 640);

    auto *right = new QVBoxLayout;
    right->setSpacing(4);
    auto *captionRow = new QHBoxLayout;
    m_sessionsCaption = FormKit::gridCaption(QString(), this);
    captionRow->addWidget(m_sessionsCaption);
    captionRow->addStretch(1);
    QPushButton *allSessions = FormKit::link(QStringLiteral("Все сеансы договора"), this);
    captionRow->addWidget(allSessions);
    right->addLayout(captionRow);
    if (!readOnly)
        right->addSpacing(28);     // выравнивание таблицы с таблицей договоров (у неё командная панель)
    m_sessions = new DataGrid(this, false, 200);
    m_sessions->setFunction(QStringLiteral("q_contract_sessions"),
        {{QStringLiteral("started_at"), QStringLiteral("Начало сеанса"), ColumnSpec::DateTime, 0, 122},
         {QStringLiteral("tariff_name"), QStringLiteral("Тариф"), ColumnSpec::Text, 0, 140},
         {QStringLiteral("volume_mb"), QStringLiteral("Объём, Мб"), ColumnSpec::Number, 3, 95},
         {QStringLiteral("discount_pct"), QStringLiteral("Скидка, %"), ColumnSpec::Number, 0, 82},
         {QStringLiteral("cost"), QStringLiteral("Стоимость, руб."), ColumnSpec::Number, 2, 0}});
    m_sessions->setTotals({{QStringLiteral("started_at"), QStringLiteral("total_count"), QStringLiteral("Итого: %1")},
                           {QStringLiteral("volume_mb"), QStringLiteral("total_volume_mb"), QString()},
                           {QStringLiteral("cost"), QStringLiteral("total_cost"), QString()}});
    right->addWidget(m_sessions, 1);
    bottom->addLayout(right, 550);
    layout->addLayout(bottom, 2);

    // Связи
    connect(m_type, &QComboBox::currentIndexChanged, this, &SubscribersPage::reloadSubscribers);
    connect(m_activeOnly, &QCheckBox::toggled, this, &SubscribersPage::reloadSubscribers);
    connect(m_search, &QLineEdit::returnPressed, this, &SubscribersPage::reloadSubscribers);
    connect(find, &QPushButton::clicked, this, [this] { m_search->setFocus(); m_search->selectAll(); });
    connect(cancelFind, &QPushButton::clicked, this, [this] { m_search->clear(); reloadSubscribers(); });
    auto *ctrlF = new QShortcut(QKeySequence::Find, this);
    connect(ctrlF, &QShortcut::activated, this, [this] { m_search->setFocus(); m_search->selectAll(); });

    connect(m_subscribers, &DataGrid::currentChanged, this, &SubscribersPage::subscriberChanged);
    connect(m_subscribers, &DataGrid::activated, this, [this](const QVariant &id) { SubscriberDialog(id, this).exec(); });
    connect(m_contracts, &DataGrid::currentChanged, this, &SubscribersPage::contractChanged);
    connect(m_contracts, &DataGrid::activated, this, [this](const QVariant &id) { ContractDialog(id, this).exec(); });
    connect(allSessions, &QPushButton::clicked, this, [this] {
        const QVariant id = m_contracts->currentId();
        if (!id.isValid() || id.isNull())
            return;
        emit openFormRequested(QStringLiteral("sessions"),
                               {{QStringLiteral("contract_id"), id},
                                {QStringLiteral("contract_no"), m_contracts->currentValue(QStringLiteral("contract_no"))},
                                {QStringLiteral("from"), m_contracts->currentValue(QStringLiteral("connected_on"))}});
    });

    reloadSubscribers();
}

void SubscribersPage::reloadSubscribers()
{
    const QString text = m_search->text().trimmed();
    m_subscribers->setFilter({{QStringLiteral("p_type_id"), m_type->currentData()},
                              {QStringLiteral("p_active_only"), m_activeOnly->isChecked()},
                              {QStringLiteral("p_search"), text.isEmpty() ? QVariant() : QVariant(text)}});
    m_subscribers->reloadFromStart();
}

void SubscribersPage::applyArgs(const QVariantMap &args)
{
    m_search->setText(args.value(QStringLiteral("search")).toString());
    if (args.contains(QStringLiteral("active_only"))) {
        m_activeOnly->blockSignals(true);
        m_activeOnly->setChecked(args.value(QStringLiteral("active_only")).toBool());
        m_activeOnly->blockSignals(false);
    }
    reloadSubscribers();
}

void SubscribersPage::subscriberChanged(const QVariant &id)
{
    if (!id.isValid() || id.isNull()) {
        m_contractsCaption->setText(QStringLiteral("Договоры абонента"));
        m_contracts->clear();
        return;
    }
    m_contractsCaption->setText(QStringLiteral("Договоры абонента «%1»")
                                    .arg(m_subscribers->currentValue(QStringLiteral("name")).toString()));
    m_contracts->setFilter({{QStringLiteral("p_subscriber_id"), id}});
    m_contracts->reloadFromStart();
}

void SubscribersPage::contractChanged(const QVariant &id)
{
    const QDate today = QDate::currentDate();
    if (!id.isValid() || id.isNull()) {
        m_sessionsCaption->setText(QStringLiteral("Сеансы по договору за %1").arg(FormKit::monthTitle(today)));
        m_sessions->clear();
        return;
    }
    m_sessionsCaption->setText(QStringLiteral("Сеансы по договору %1 за %2")
                                   .arg(m_contracts->currentValue(QStringLiteral("contract_no")).toString(),
                                        FormKit::monthTitle(today)));
    m_sessions->setFilter({{QStringLiteral("p_contract_id"), id},
                           {QStringLiteral("p_from"), QDate(today.year(), today.month(), 1)},
                           {QStringLiteral("p_to"), today}});
    m_sessions->reloadFromStart();
}
