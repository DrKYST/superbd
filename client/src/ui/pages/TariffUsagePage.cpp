#include "ui/pages/TariffUsagePage.h"

#include <QComboBox>
#include <QDate>
#include <QDateEdit>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QSqlQuery>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "export/ExcelExport.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

TariffUsagePage::TariffUsagePage(const Whoami &me, QWidget *parent)
    : QWidget(parent)
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Трафик по тарифам"));

    FormKit::CommandBar bar(this);
    QPushButton *make = bar.button(QStringLiteral("Сформировать"), true);
    connect(bar.button(QStringLiteral("Сохранить в Excel…")), &QPushButton::clicked, this, &TariffUsagePage::exportExcel);
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    auto *box = new QGroupBox(QStringLiteral("Параметры отчёта"), this);
    auto *row = new QHBoxLayout(box);
    row->setSpacing(6);
    const QDate today = QDate::currentDate();
    row->addWidget(FormKit::caption(QStringLiteral("Период с:"), box));
    m_from = FormKit::dateEdit(QDate(today.year(), today.month(), 1), box);
    row->addWidget(m_from);
    row->addWidget(FormKit::caption(QStringLiteral("по:"), box));
    m_to = FormKit::dateEdit(today, box);
    row->addWidget(m_to);
    row->addSpacing(18);
    row->addWidget(FormKit::caption(QStringLiteral("Провайдер:"), box));
    if (me.providerName.isEmpty()) {
        // Главный аналитик: все провайдеры или выбранный (список — представление api.v_providers, запрос 5).
        m_provider = new QComboBox(box);
        m_provider->setMinimumWidth(240);
        m_provider->addItem(QStringLiteral("<все провайдеры>"), QVariant());
        QSqlQuery q;
        QString error;
        if (ApiCall::selectView(QStringLiteral("v_providers"), QStringLiteral("name"), 200, 0, &q, &error))
            while (q.next())
                m_provider->addItem(q.value(QStringLiteral("display_name")).toString(), q.value(QStringLiteral("id")));
        row->addWidget(m_provider);
    } else {
        // Руководитель: отбор по провайдеру зафиксирован (ограничение — в функции на сервере).
        m_providerName = me.providerName;
        auto *fixed = FormKit::readOnlyField(me.providerName, box);
        fixed->setFixedWidth(240);
        row->addWidget(fixed);
    }
    row->addStretch(1);
    layout->addWidget(box);

    m_grid = new DataGrid(this, false, 50);
    m_grid->setFunction(QStringLiteral("q_tariff_usage"),
        {{QStringLiteral("tariff_code"), QStringLiteral("Код"), ColumnSpec::Text, 0, 60},
         {QStringLiteral("tariff_name"), QStringLiteral("Тариф"), ColumnSpec::Text, 0, 220},
         {QStringLiteral("discount_pct"), QStringLiteral("Скидка, %"), ColumnSpec::Number, 0, 90},
         {QStringLiteral("sessions_count"), QStringLiteral("Сеансов"), ColumnSpec::Integer, 0, 110},
         {QStringLiteral("volume_mb"), QStringLiteral("Объём, Мб"), ColumnSpec::Number, 3, 150},
         {QStringLiteral("revenue"), QStringLiteral("Выручка, руб."), ColumnSpec::Number, 2, 0}});
    m_grid->setMaximumWidth(800);
    auto *gridRow = new QHBoxLayout;
    gridRow->addWidget(m_grid, 1);
    gridRow->addStretch(0);
    layout->addLayout(gridRow, 1);
    layout->addWidget(FormKit::hint(QStringLiteral("В отчёт входят все тарифы: не использованные за период показаны с нулями."),
                                    this));

    connect(make, &QPushButton::clicked, this, &TariffUsagePage::build);
    build();
}

void TariffUsagePage::build()
{
    QList<ApiParam> params{{QStringLiteral("p_from"), m_from->date()}, {QStringLiteral("p_to"), m_to->date()}};
    if (m_provider)
        params << ApiParam{QStringLiteral("p_provider_id"), m_provider->currentData()};
    m_grid->setFilter(params);
    m_grid->reloadFromStart();
}

void TariffUsagePage::exportExcel()
{
    const QString provider = m_provider ? m_provider->currentText() : m_providerName;
    ExcelExport::save(this, QStringLiteral("Трафик по тарифам"),
                      {QStringLiteral("Трафик по тарифам"),
                       QStringLiteral("Период: %1 – %2").arg(m_from->date().toString(QStringLiteral("dd.MM.yyyy")),
                                                             m_to->date().toString(QStringLiteral("dd.MM.yyyy"))),
                       QStringLiteral("Отбор: провайдер — %1").arg(provider)},
                      m_grid->model());
}
