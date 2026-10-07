#include "ui/pages/SessionsPage.h"

#include <QComboBox>
#include <QDateEdit>
#include <QGridLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLineEdit>
#include <QMenu>
#include <QPushButton>
#include <QSqlQuery>
#include <QToolButton>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/dialogs/ContractDialog.h"
#include "ui/dialogs/PickerDialog.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

#include <QLabel>

SessionsPage::SessionsPage(const Whoami &me, bool readOnly, QWidget *parent)
    : QWidget(parent)
{
    Q_UNUSED(me);
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Сеансы связи"), readOnly);

    FormKit::CommandBar bar(this);
    if (!readOnly) {
        connect(bar.button(QStringLiteral("Зарегистрировать сеанс…"), true), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Зарегистрировать сеанс")); });
        connect(bar.button(QStringLiteral("Удалить")), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Удалить сеанс")); });
        bar.separator();
    }
    QPushButton *find = bar.button(QStringLiteral("Найти…"));
    QPushButton *cancelFind = bar.button(QStringLiteral("Отменить поиск"));
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    // Группа «Отбор»
    auto *box = new QGroupBox(QStringLiteral("Отбор"), this);
    auto *grid = new QGridLayout(box);
    grid->setHorizontalSpacing(6);
    grid->setVerticalSpacing(8);
    auto *row1 = new QHBoxLayout;
    row1->setSpacing(6);
    row1->addWidget(FormKit::caption(QStringLiteral("Период с:"), box));
    m_from = FormKit::dateEdit(QDate(), box);
    row1->addWidget(m_from);
    row1->addWidget(FormKit::caption(QStringLiteral("по:"), box));
    m_to = FormKit::dateEdit(QDate(), box);
    row1->addWidget(m_to);
    auto *periodButton = new QPushButton(QStringLiteral("…"), box);
    periodButton->setFixedWidth(32);
    periodButton->setObjectName(QStringLiteral("periodButton"));
    auto *periodMenu = new QMenu(periodButton);
    const QDate today = QDate::currentDate();
    const QDate monthStart(today.year(), today.month(), 1);
    periodMenu->addAction(QStringLiteral("Сегодня"), this, [this, today] { setPeriod(today, today); apply(); });
    periodMenu->addAction(QStringLiteral("Эта неделя"), this,
                          [this, today] { setPeriod(today.addDays(1 - today.dayOfWeek()), today); apply(); });
    periodMenu->addAction(QStringLiteral("Этот месяц"), this, [this, monthStart, today] { setPeriod(monthStart, today); apply(); });
    periodMenu->addAction(QStringLiteral("Прошлый месяц"), this,
                          [this, monthStart] { setPeriod(monthStart.addMonths(-1), monthStart.addDays(-1)); apply(); });
    periodMenu->addAction(QStringLiteral("Этот год"), this,
                          [this, today] { setPeriod(QDate(today.year(), 1, 1), today); apply(); });
    periodButton->setMenu(periodMenu);
    row1->addWidget(periodButton);
    row1->addSpacing(18);
    row1->addWidget(FormKit::caption(QStringLiteral("Договор:"), box));
    QToolButton *pick = nullptr;
    QWidget *contractField = FormKit::pickField(box, &m_contract, &pick);
    contractField->setFixedWidth(172);
    row1->addWidget(contractField);
    row1->addSpacing(4);
    row1->addWidget(FormKit::caption(QStringLiteral("IP-адрес:"), box));
    m_ip = new QLineEdit(box);
    m_ip->setFixedWidth(110);
    m_ip->setPlaceholderText(QStringLiteral("адрес или подсеть"));
    row1->addWidget(m_ip);
    row1->addSpacing(4);
    row1->addWidget(FormKit::caption(QStringLiteral("Тариф:"), box));
    m_tariff = new QComboBox(box);
    m_tariff->setMinimumWidth(150);
    m_tariff->addItem(QStringLiteral("<все>"), QVariant());
    {
        QSqlQuery q;
        QString error;
        if (ApiCall::select(QStringLiteral("lookup_tariffs"), {}, &q, &error))
            while (q.next())
                m_tariff->addItem(q.value(2).toString(), q.value(0));
    }
    row1->addWidget(m_tariff);
    auto *applyButton = new QPushButton(QStringLiteral("Применить"), box);
    row1->addWidget(applyButton);
    row1->addStretch(1);
    grid->addLayout(row1, 0, 0);
    auto *row2 = new QHBoxLayout;
    auto *resetButton = new QPushButton(QStringLiteral("Сбросить"), box);
    row2->addWidget(resetButton);
    row2->addStretch(1);
    grid->addLayout(row2, 1, 0);
    layout->addWidget(box);

    // Журнал — запрос 3
    m_grid = new DataGrid(this, true, 20);
    m_grid->setFunction(QStringLiteral("q_sessions"),
        {{QStringLiteral("started_at"), QStringLiteral("Начало сеанса"), ColumnSpec::DateTime, 0, 138},
         {QStringLiteral("contract_no"), QStringLiteral("Договор"), ColumnSpec::Text, 0, 120},
         {QStringLiteral("subscriber_name"), QStringLiteral("Абонент"), ColumnSpec::Text, 0, 263},
         {QStringLiteral("ip_address"), QStringLiteral("IP-адрес"), ColumnSpec::Text, 0, 96},
         {QStringLiteral("tariff_name"), QStringLiteral("Тариф"), ColumnSpec::Text, 0, 158},
         {QStringLiteral("volume_mb"), QStringLiteral("Объём, Мб"), ColumnSpec::Number, 3, 114},
         {QStringLiteral("discount_pct"), QStringLiteral("Скидка, %"), ColumnSpec::Number, 0, 91},
         {QStringLiteral("price_per_mb"), QStringLiteral("Цена 1 Мб"), ColumnSpec::Number, 4, 91},
         {QStringLiteral("cost"), QStringLiteral("Стоимость, руб."), ColumnSpec::Number, 2, 0}});
    m_grid->setTotals({{QStringLiteral("started_at"), QString(), QStringLiteral("Итого за период")},
                       {QStringLiteral("contract_no"), QStringLiteral("total_count"), QStringLiteral("%1"),
                        {QStringLiteral("сеанс"), QStringLiteral("сеанса"), QStringLiteral("сеансов")}},
                       {QStringLiteral("volume_mb"), QStringLiteral("total_volume_mb"), QString()},
                       {QStringLiteral("cost"), QStringLiteral("total_cost"), QString()}});
    m_grid->setStretchColumn(QStringLiteral("subscriber_name"));
    layout->addWidget(m_grid, 1);

    connect(pick, &QToolButton::clicked, this, [this] {
        PickerDialog dialog(PickerDialog::contractSpec(), this);
        if (dialog.exec() == QDialog::Accepted) {
            m_contractId = dialog.selectedId();
            m_contract->setText(dialog.selectedText());
        }
    });
    connect(applyButton, &QPushButton::clicked, this, &SessionsPage::apply);
    connect(m_ip, &QLineEdit::returnPressed, this, &SessionsPage::apply);
    connect(resetButton, &QPushButton::clicked, this, [this] { resetFilter(); apply(); });
    connect(find, &QPushButton::clicked, this, [this] { m_ip->setFocus(); m_ip->selectAll(); });
    connect(cancelFind, &QPushButton::clicked, this, [this] { resetFilter(); apply(); });
    connect(m_grid, &DataGrid::activated, this, [this](const QVariant &) {
        const QVariant contractId = m_grid->currentValue(QStringLiteral("contract_id"));
        if (contractId.isValid())
            ContractDialog(contractId, this).exec();
    });

    resetFilter();
    apply();
}

void SessionsPage::setPeriod(const QDate &from, const QDate &to)
{
    m_from->setDate(from);
    m_to->setDate(to);
}

void SessionsPage::resetFilter()
{
    const QDate today = QDate::currentDate();
    setPeriod(QDate(today.year(), today.month(), 1), today);
    m_contractId = QVariant();
    m_contract->clear();
    m_ip->clear();
    m_tariff->setCurrentIndex(0);
}

void SessionsPage::apply()
{
    const QString ip = m_ip->text().trimmed();
    m_grid->setFilter({{QStringLiteral("p_from"), m_from->date()},
                       {QStringLiteral("p_to"), m_to->date()},
                       {QStringLiteral("p_contract_id"), m_contractId},
                       {QStringLiteral("p_ip"), ip.isEmpty() ? QVariant() : QVariant(ip)},
                       {QStringLiteral("p_tariff_id"), m_tariff->currentData()}});
    m_grid->reloadFromStart();
}

void SessionsPage::applyArgs(const QVariantMap &args)
{
    resetFilter();
    if (args.contains(QStringLiteral("contract_id"))) {
        m_contractId = args.value(QStringLiteral("contract_id"));
        m_contract->setText(args.value(QStringLiteral("contract_no")).toString());
    }
    const QDate from = args.value(QStringLiteral("from")).toDate();
    const QDate to = args.value(QStringLiteral("to")).toDate();
    setPeriod(from.isValid() ? from : m_from->date(), to.isValid() ? to : m_to->date());
    apply();
}
