#include "ui/dialogs/SubscriberDialog.h"

#include <QCheckBox>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLineEdit>
#include <QPushButton>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/widgets/FormKit.h"

#include <QLabel>

SubscriberDialog::SubscriberDialog(const QVariant &subscriberId, QWidget *parent)
    : QDialog(parent)
{
    resize(620, 330);
    if (!load(subscriberId))
        QMetaObject::invokeMethod(this, &QDialog::reject, Qt::QueuedConnection);
}

bool SubscriberDialog::load(const QVariant &subscriberId)
{
    QSqlQuery q;
    QString error;
    if (!ApiCall::selectViewRow(QStringLiteral("v_subscribers"), QStringLiteral("id"), subscriberId, &q, &error)
        || !q.next()) {
        FormKit::error(parentWidget(), error.isEmpty() ? QStringLiteral("Абонент не найден или недоступен") : error);
        return false;
    }
    const QSqlRecord r = q.record();
    auto v = [&](const char *f) { return q.value(r.indexOf(QString::fromLatin1(f))).toString(); };

    setWindowTitle(QStringLiteral("Абонент — СуперБД"));
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Абонент"), true);

    auto *grid = new QGridLayout;
    grid->setHorizontalSpacing(8);
    grid->setVerticalSpacing(8);
    grid->setColumnMinimumWidth(0, 150);
    int row = 0;
    auto addRow = [&](const QString &caption, QWidget *field) {
        grid->addWidget(FormKit::caption(caption, this), row, 0);
        grid->addWidget(field, row, 1);
        ++row;
    };
    addRow(QStringLiteral("Наименование:"), FormKit::readOnlyField(v("name"), this));
    addRow(QStringLiteral("Тип абонента:"), FormKit::readOnlyField(v("subscriber_type"), this));
    auto *legal = new QCheckBox(QStringLiteral("Юридическое лицо"), this);
    legal->setChecked(q.value(r.indexOf(QStringLiteral("is_legal"))).toBool());
    legal->setEnabled(false);
    addRow(QString(), legal);
    addRow(QStringLiteral("Город:"), FormKit::readOnlyField(v("city"), this));
    addRow(QStringLiteral("Физический адрес:"), FormKit::readOnlyField(v("address"), this));
    addRow(QStringLiteral("Телефон:"), FormKit::readOnlyField(v("phone"), this));
    grid->setColumnStretch(1, 1);
    layout->addLayout(grid);
    layout->addStretch(1);

    auto *buttons = new QHBoxLayout;
    buttons->addStretch(1);
    auto *close = new QPushButton(QStringLiteral("Закрыть"), this);
    close->setMinimumWidth(90);
    close->setDefault(true);
    connect(close, &QPushButton::clicked, this, &QDialog::accept);
    buttons->addWidget(close);
    layout->addLayout(buttons);
    return true;
}
