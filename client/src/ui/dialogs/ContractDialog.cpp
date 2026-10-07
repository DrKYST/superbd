#include "ui/dialogs/ContractDialog.h"

#include <QCheckBox>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QLocale>
#include <QPushButton>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QTabWidget>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

ContractDialog::ContractDialog(const QVariant &contractId, QWidget *parent)
    : QDialog(parent)
{
    resize(760, 520);
    if (!load(contractId))
        QMetaObject::invokeMethod(this, &QDialog::reject, Qt::QueuedConnection);
}

bool ContractDialog::load(const QVariant &contractId)
{
    QSqlQuery q;
    QString error;
    if (!ApiCall::selectViewRow(QStringLiteral("v_contracts"), QStringLiteral("id"), contractId, &q, &error)
        || !q.next()) {
        FormKit::error(parentWidget(), error.isEmpty() ? QStringLiteral("Договор не найден или недоступен") : error);
        return false;
    }
    const QSqlRecord r = q.record();
    auto v = [&](const char *f) { return q.value(r.indexOf(QString::fromLatin1(f))); };
    const QLocale ru(QLocale::Russian, QLocale::Russia);
    const QString number = v("contract_no").toString();

    setWindowTitle(QStringLiteral("Договор %1 — СуперБД").arg(number));
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Договор %1").arg(number), true);

    FormKit::CommandBar bar(this);
    QPushButton *saveClose = bar.button(QStringLiteral("Записать и закрыть"), true);
    QPushButton *save = bar.button(QStringLiteral("Записать"));
    bar.separator();
    QPushButton *terminate = bar.button(QStringLiteral("Расторгнуть…"));
    bar.stretch();
    bar.more();
    for (QPushButton *b : {saveClose, save, terminate})
        b->setEnabled(false);
    layout->addLayout(bar.layout());

    auto *tabs = new QTabWidget(this);
    layout->addWidget(tabs, 1);

    // Основное
    auto *main = new QWidget(tabs);
    auto *grid = new QGridLayout(main);
    grid->setContentsMargins(0, 12, 0, 0);
    grid->setHorizontalSpacing(8);
    grid->setVerticalSpacing(8);
    grid->setColumnMinimumWidth(0, 170);
    int row = 0;
    // Поле и пояснение справа от него («руб.», тип абонента) — в одной строке, как в макете.
    auto addRow = [&](const QString &caption, QWidget *field, QWidget *extra = nullptr) {
        grid->addWidget(FormKit::caption(caption, main), row, 0);
        auto *line = new QHBoxLayout;
        line->setSpacing(6);
        const bool fixed = field->maximumWidth() < QWIDGETSIZE_MAX;
        line->addWidget(field, fixed ? 0 : 1);
        if (extra)
            line->addWidget(extra);
        if (fixed)
            line->addStretch(1);
        grid->addLayout(line, row, 1);
        ++row;
    };
    auto money = [&](const QVariant &x, int d) {
        auto *e = FormKit::readOnlyField(ru.toString(x.toDouble(), 'f', d), main);
        e->setAlignment(Qt::AlignRight);
        e->setFixedWidth(110);
        return e;
    };
    auto narrow = [&](const QString &text, int w) {
        auto *e = FormKit::readOnlyField(text, main);
        e->setFixedWidth(w);
        return e;
    };
    addRow(QStringLiteral("Провайдер:"), FormKit::readOnlyField(v("provider_name").toString(), main));
    addRow(QStringLiteral("Абонент:"), FormKit::readOnlyField(v("subscriber_name").toString(), main),
           FormKit::hint(QStringLiteral("%1, тел. %2").arg(v("subscriber_type").toString(), v("subscriber_phone").toString()), main));
    addRow(QStringLiteral("Номер договора:"), narrow(number, 150));
    addRow(QStringLiteral("Дата подключения:"), narrow(v("connected_on").toDate().toString(QStringLiteral("dd.MM.yyyy")), 110));
    addRow(QStringLiteral("Стоимость подключения:"), money(v("connection_fee"), 2), FormKit::caption(QStringLiteral("руб."), main));
    addRow(QStringLiteral("Стоимость 1 Мб:"), money(v("price_per_mb"), 4), FormKit::caption(QStringLiteral("руб."), main));
    addRow(QStringLiteral("IP-адрес:"), narrow(v("ip_address").toString(), 150));
    addRow(QStringLiteral("Дата расторжения:"),
           narrow(v("closed_on").isNull() ? QString() : v("closed_on").toDate().toString(QStringLiteral("dd.MM.yyyy")), 110),
           FormKit::hint(v("state").toString(), main));
    addRow(QStringLiteral("Комментарий:"), FormKit::readOnlyField(v("note").toString(), main));
    grid->setColumnStretch(1, 1);
    grid->setRowStretch(row, 1);
    tabs->addTab(main, QStringLiteral("Основное"));

    // Сеансы — запрос 2 за весь срок договора, с итогами.
    auto *sessions = new DataGrid(tabs, true, 20);
    sessions->setFunction(QStringLiteral("q_contract_sessions"),
                          {{QStringLiteral("started_at"), QStringLiteral("Начало сеанса"), ColumnSpec::DateTime, 0, 130},
                           {QStringLiteral("tariff_name"), QStringLiteral("Тариф"), ColumnSpec::Text, 0, 160},
                           {QStringLiteral("volume_mb"), QStringLiteral("Объём, Мб"), ColumnSpec::Number, 3, 110},
                           {QStringLiteral("discount_pct"), QStringLiteral("Скидка, %"), ColumnSpec::Number, 0, 80},
                           {QStringLiteral("cost"), QStringLiteral("Стоимость, руб."), ColumnSpec::Number, 2, 0}});
    sessions->setTotals({{QStringLiteral("started_at"), QStringLiteral("total_count"), QStringLiteral("Итого: %1")},
                         {QStringLiteral("volume_mb"), QStringLiteral("total_volume_mb"), QString()},
                         {QStringLiteral("cost"), QStringLiteral("total_cost"), QString()}});
    sessions->setFilter({{QStringLiteral("p_contract_id"), contractId}});
    tabs->addTab(sessions, QStringLiteral("Сеансы"));
    connect(tabs, &QTabWidget::currentChanged, this, [tabs, sessions, loaded = false](int) mutable {
        if (!loaded && tabs->currentWidget() == sessions) {
            loaded = true;
            sessions->reload();
        }
    });

    // История изменений — журнал audit.change_log (D10) появится вместе с триггерами.
    auto *history = new QWidget(tabs);
    auto *hl = new QVBoxLayout(history);
    hl->addWidget(FormKit::hint(QStringLiteral("История изменений договора появится вместе с журналом изменений "
                                               "(триггеры аудита)."), history, true));
    hl->addStretch(1);
    tabs->addTab(history, QStringLiteral("История изменений"));

    layout->addWidget(FormKit::hint(QStringLiteral("Номер формируется сервером из последовательности. Провайдер и абонент "
                                                   "после записи не меняются — при смене условий договор расторгается и "
                                                   "заключается новый."), this, true));
    auto *buttons = new QHBoxLayout;
    buttons->addStretch(1);
    auto *close = new QPushButton(QStringLiteral("Закрыть"), this);
    close->setMinimumWidth(90);
    connect(close, &QPushButton::clicked, this, &QDialog::accept);
    buttons->addWidget(close);
    layout->addLayout(buttons);
    return true;
}
