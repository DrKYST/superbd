#include "ui/pages/ContractsPage.h"

#include <QCheckBox>
#include <QDateEdit>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLineEdit>
#include <QPushButton>
#include <QShortcut>
#include <QToolButton>
#include <QVBoxLayout>

#include "ui/dialogs/ContractDialog.h"
#include "ui/dialogs/PickerDialog.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

#include <QLabel>

ContractsPage::ContractsPage(const Whoami &me, bool readOnly, QWidget *parent)
    : QWidget(parent)
    , m_showProvider(me.providerName.isEmpty())
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Договоры"), readOnly);

    FormKit::CommandBar bar(this);
    if (!readOnly) {
        connect(bar.button(QStringLiteral("Создать"), true), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Создать договор")); });
        connect(bar.button(QStringLiteral("Изменить")), &QPushButton::clicked, this, [this] {
            if (m_grid->currentId().isValid())
                ContractDialog(m_grid->currentId(), this).exec();
        });
        connect(bar.button(QStringLiteral("Расторгнуть…")), &QPushButton::clicked, this,
                [this] { FormKit::pending(this, QStringLiteral("Расторгнуть договор")); });
        bar.separator();
    }
    QPushButton *find = bar.button(QStringLiteral("Найти…"));
    QPushButton *cancelFind = bar.button(QStringLiteral("Отменить поиск"));
    bar.stretch();
    m_search = bar.search();
    bar.more();
    layout->addLayout(bar.layout());

    auto *box = new QGroupBox(QStringLiteral("Отбор"), this);
    auto *row = new QHBoxLayout(box);
    row->setSpacing(6);
    row->addWidget(FormKit::caption(QStringLiteral("Дата подключения с:"), box));
    m_from = FormKit::dateEdit(QDate(), box);
    row->addWidget(m_from);
    row->addWidget(FormKit::caption(QStringLiteral("по:"), box));
    m_to = FormKit::dateEdit(QDate(), box);
    row->addWidget(m_to);
    row->addSpacing(18);
    row->addWidget(FormKit::caption(QStringLiteral("Абонент:"), box));
    QToolButton *pick = nullptr;
    QWidget *subscriberField = FormKit::pickField(box, &m_subscriber, &pick);
    subscriberField->setFixedWidth(280);
    row->addWidget(subscriberField);
    row->addSpacing(12);
    m_activeOnly = new QCheckBox(QStringLiteral("Только действующие"), box);
    row->addWidget(m_activeOnly);
    auto *applyButton = new QPushButton(QStringLiteral("Применить"), box);
    auto *resetButton = new QPushButton(QStringLiteral("Сбросить"), box);
    row->addWidget(applyButton);
    row->addWidget(resetButton);
    row->addStretch(1);
    layout->addWidget(box);

    // Договоры в периоде — запрос 4; главному аналитику — с колонкой «Провайдер».
    QList<ColumnSpec> columns;
    if (m_showProvider)
        columns << ColumnSpec{QStringLiteral("provider_name"), QStringLiteral("Провайдер"), ColumnSpec::Text, 0, 150};
    columns << ColumnSpec{QStringLiteral("contract_no"), QStringLiteral("Номер"), ColumnSpec::Text, 0, 115}
            << ColumnSpec{QStringLiteral("subscriber_name"), QStringLiteral("Абонент"), ColumnSpec::Text, 0, 280}
            << ColumnSpec{QStringLiteral("subscriber_type"), QStringLiteral("Тип абонента"), ColumnSpec::Text, 0, 165}
            << ColumnSpec{QStringLiteral("connected_on"), QStringLiteral("Дата подкл."), ColumnSpec::Date, 0, 90}
            << ColumnSpec{QStringLiteral("connection_fee"), QStringLiteral("Подключение, руб."), ColumnSpec::Number, 2, 125}
            << ColumnSpec{QStringLiteral("price_per_mb"), QStringLiteral("1 Мб, руб."), ColumnSpec::Number, 4, 85}
            << ColumnSpec{QStringLiteral("ip_address"), QStringLiteral("IP-адрес"), ColumnSpec::Text, 0, 100}
            << ColumnSpec{QStringLiteral("state"), QStringLiteral("Состояние"), ColumnSpec::Text, 0, 0, QStringLiteral("Действует")};
    m_grid = new DataGrid(this, true, 20);
    m_grid->setFunction(QStringLiteral("q_contracts"), columns);
    m_grid->setStretchColumn(QStringLiteral("subscriber_name"));
    layout->addWidget(m_grid, 1);

    connect(pick, &QToolButton::clicked, this, [this] {
        PickerDialog dialog(PickerDialog::subscriberSpec(), this);
        if (dialog.exec() == QDialog::Accepted) {
            m_subscriberId = dialog.selectedId();
            m_subscriber->setText(dialog.selectedText());
            apply();
        }
    });
    connect(applyButton, &QPushButton::clicked, this, &ContractsPage::apply);
    connect(resetButton, &QPushButton::clicked, this, [this] { resetFilter(); apply(); });
    connect(m_activeOnly, &QCheckBox::toggled, this, &ContractsPage::apply);
    connect(m_search, &QLineEdit::returnPressed, this, &ContractsPage::apply);
    connect(find, &QPushButton::clicked, this, [this] { m_search->setFocus(); m_search->selectAll(); });
    connect(cancelFind, &QPushButton::clicked, this, [this] { m_search->clear(); apply(); });
    auto *ctrlF = new QShortcut(QKeySequence::Find, this);
    connect(ctrlF, &QShortcut::activated, this, [this] { m_search->setFocus(); m_search->selectAll(); });
    connect(m_grid, &DataGrid::activated, this, [this](const QVariant &id) { ContractDialog(id, this).exec(); });

    resetFilter();
    apply();
}

void ContractsPage::resetFilter()
{
    const QDate today = QDate::currentDate();
    m_from->setDate(QDate(today.year(), 1, 1));
    m_to->setDate(today);
    m_subscriberId = QVariant();
    m_subscriber->clear();
    m_activeOnly->blockSignals(true);
    m_activeOnly->setChecked(false);
    m_activeOnly->blockSignals(false);
}

void ContractsPage::apply()
{
    const QString text = m_search->text().trimmed();
    m_grid->setFilter({{QStringLiteral("p_from"), m_from->date()},
                       {QStringLiteral("p_to"), m_to->date()},
                       {QStringLiteral("p_subscriber_id"), m_subscriberId},
                       {QStringLiteral("p_active_only"), m_activeOnly->isChecked()},
                       {QStringLiteral("p_search"), text.isEmpty() ? QVariant() : QVariant(text)}});
    m_grid->reloadFromStart();
}

void ContractsPage::applyArgs(const QVariantMap &args)
{
    resetFilter();
    const QDate from = args.value(QStringLiteral("from")).toDate();
    const QDate to = args.value(QStringLiteral("to")).toDate();
    if (from.isValid())
        m_from->setDate(from);
    if (to.isValid())
        m_to->setDate(to);
    apply();
}
