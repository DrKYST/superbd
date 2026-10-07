#include "ui/dialogs/PickerDialog.h"

#include <QHBoxLayout>
#include <QLineEdit>
#include <QPushButton>
#include <QVBoxLayout>

#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

PickerDialog::PickerDialog(const Spec &spec, QWidget *parent)
    : QDialog(parent)
    , m_spec(spec)
{
    setWindowTitle(spec.title + QStringLiteral(" — СуперБД"));
    resize(760, 520);
    QVBoxLayout *layout = FormKit::formLayout(this, spec.title);

    FormKit::CommandBar bar(this);
    QPushButton *chooseButton = bar.button(QStringLiteral("Выбрать"), true);
    QPushButton *find = bar.button(QStringLiteral("Найти…"));
    QPushButton *reset = bar.button(QStringLiteral("Отменить поиск"));
    bar.stretch();
    m_search = bar.search();
    layout->addLayout(bar.layout());

    m_grid = new DataGrid(this, true, 20);
    m_grid->setFunction(spec.function, spec.columns);
    layout->addWidget(m_grid, 1);

    auto *buttons = new QHBoxLayout;
    buttons->addStretch(1);
    auto *ok = new QPushButton(QStringLiteral("ОК"), this);
    ok->setDefault(true);
    ok->setMinimumWidth(90);
    auto *cancel = new QPushButton(QStringLiteral("Отмена"), this);
    cancel->setMinimumWidth(90);
    buttons->addWidget(ok);
    buttons->addWidget(cancel);
    layout->addLayout(buttons);

    connect(m_search, &QLineEdit::returnPressed, this, &PickerDialog::search);
    connect(find, &QPushButton::clicked, this, [this] { m_search->setFocus(); m_search->selectAll(); });
    connect(reset, &QPushButton::clicked, this, [this] { m_search->clear(); search(); });
    connect(chooseButton, &QPushButton::clicked, this, &PickerDialog::choose);
    connect(ok, &QPushButton::clicked, this, &PickerDialog::choose);
    connect(cancel, &QPushButton::clicked, this, &QDialog::reject);
    connect(m_grid, &DataGrid::activated, this, &PickerDialog::choose);

    search();
    m_search->setFocus();
}

void PickerDialog::search()
{
    QList<ApiParam> params = m_spec.fixedParams;
    const QString text = m_search->text().trimmed();
    params << ApiParam{m_spec.searchParam, text.isEmpty() ? QVariant() : QVariant(text)};
    m_grid->setFilter(params);
    m_grid->reloadFromStart();
}

void PickerDialog::choose()
{
    const QVariant id = m_grid->currentId();
    if (!id.isValid() || id.isNull())
        return;
    m_id = id;
    m_text = m_grid->currentValue(m_spec.displayField).toString();
    accept();
}

PickerDialog::Spec PickerDialog::contractSpec()
{
    Spec s;
    s.title = QStringLiteral("Выбор договора");
    s.function = QStringLiteral("q_contracts");
    s.columns = {{QStringLiteral("contract_no"), QStringLiteral("Номер"), ColumnSpec::Text, 0, 120},
                 {QStringLiteral("subscriber_name"), QStringLiteral("Абонент"), ColumnSpec::Text, 0, 280},
                 {QStringLiteral("connected_on"), QStringLiteral("Дата подкл."), ColumnSpec::Date, 0, 90},
                 {QStringLiteral("ip_address"), QStringLiteral("IP-адрес"), ColumnSpec::Text, 0, 100},
                 {QStringLiteral("state"), QStringLiteral("Состояние"), ColumnSpec::Text, 0, 0, QStringLiteral("Действует")}};
    s.displayField = QStringLiteral("contract_no");
    return s;
}

PickerDialog::Spec PickerDialog::subscriberSpec()
{
    Spec s;
    s.title = QStringLiteral("Выбор абонента");
    s.function = QStringLiteral("q_subscribers");
    s.columns = {{QStringLiteral("name"), QStringLiteral("Наименование"), ColumnSpec::Text, 0, 280},
                 {QStringLiteral("subscriber_type"), QStringLiteral("Тип абонента"), ColumnSpec::Text, 0, 170},
                 {QStringLiteral("city"), QStringLiteral("Город"), ColumnSpec::Text, 0, 100},
                 {QStringLiteral("phone"), QStringLiteral("Телефон"), ColumnSpec::Text, 0, 0}};
    s.displayField = QStringLiteral("name");
    return s;
}
