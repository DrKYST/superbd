#include "ui/pages/ReportPage.h"

#include <QComboBox>
#include <QDateEdit>
#include <QFrame>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QLocale>
#include <QMap>
#include <QMenu>
#include <QPainter>
#include <QPrintDialog>
#include <QPrinter>
#include <QPushButton>
#include <QScrollArea>
#include <QSpinBox>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QStandardItemModel>
#include <QTableView>
#include <QVBoxLayout>

#include "charts/ReportChart.h"
#include "db/ApiCall.h"
#include "export/ExcelExport.h"
#include "ui/Theme.h"
#include "ui/widgets/FormKit.h"

namespace {

const QLocale &ru()
{
    static const QLocale l(QLocale::Russian, QLocale::Russia);
    return l;
}

// Ячейка таблицы документа: текст на экране и значение для Excel (в тех же единицах, что в заголовке колонки).
struct Cell {
    QString text;
    QVariant raw;
    bool right = false;
};

Cell textCell(const QString &text) { return {text, text, false}; }
Cell intCell(qint64 v) { return {ru().toString(v), v, true}; }
Cell numCell(double v, int decimals) { return {ru().toString(v, 'f', decimals), v, true}; }

void appendRow(QStandardItemModel *model, const QList<Cell> &cells, bool total = false)
{
    QList<QStandardItem *> items;
    for (const Cell &c : cells) {
        auto *item = new QStandardItem(c.text);
        item->setData(c.raw, ExcelExport::ExportRole);
        item->setTextAlignment(c.right ? Qt::AlignRight | Qt::AlignVCenter : Qt::AlignLeft | Qt::AlignVCenter);
        item->setEditable(false);
        if (total) {
            QFont f;
            f.setBold(true);
            item->setFont(f);
            item->setBackground(Theme::totalRowBackground());
        }
        items << item;
    }
    model->appendRow(items);
}

void setHeaders(QStandardItemModel *model, const QStringList &titles, int leftColumns = 1)
{
    model->clear();
    model->setColumnCount(int(titles.size()));
    for (int i = 0; i < titles.size(); ++i) {
        model->setHeaderData(i, Qt::Horizontal, titles.at(i));
        model->setHeaderData(i, Qt::Horizontal,
                             int(i < leftColumns ? Qt::AlignLeft | Qt::AlignVCenter : Qt::AlignRight | Qt::AlignVCenter),
                             Qt::TextAlignmentRole);
    }
}

double num(const QSqlQuery &q, const QSqlRecord &r, const char *field)
{
    return q.value(r.indexOf(QString::fromLatin1(field))).toDouble();
}

} // namespace

ReportPage::ReportPage(const Whoami &me, Kind kind, QWidget *parent)
    : QWidget(parent)
    , m_me(me)
    , m_kind(kind)
{
    static const char *titles[] = {"Выручка по периодам", "Новые договоры по типам абонентов", "Крупнейшие абоненты"};
    QVBoxLayout *layout = FormKit::formLayout(this, QString::fromUtf8(titles[kind]));

    FormKit::CommandBar bar(this);
    QPushButton *make = bar.button(QStringLiteral("Сформировать"), true);
    connect(bar.button(QStringLiteral("Выбрать вариант…")), &QPushButton::clicked, this,
            [this] { FormKit::status(this, QStringLiteral("Сохранённых вариантов отчёта нет: параметры задаются в строке над документом.")); });
    connect(bar.button(QStringLiteral("Настройки…")), &QPushButton::clicked, this,
            [this] { FormKit::status(this, QStringLiteral("Настройки отчёта не предусмотрены: состав колонок задан отчётом.")); });
    bar.separator();
    connect(bar.button(QStringLiteral("Сохранить в Excel…")), &QPushButton::clicked, this, &ReportPage::exportExcel);
    connect(bar.button(QStringLiteral("Печать")), &QPushButton::clicked, this, &ReportPage::print);
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    // Параметры отчёта — одной строкой, как в макете
    auto *params = new QHBoxLayout;
    params->setSpacing(6);
    params->addWidget(FormKit::caption(QStringLiteral("Период:"), this));
    const QDate today = QDate::currentDate();
    m_from = FormKit::dateEdit(QDate(today.year(), 1, 1), this);
    params->addWidget(m_from);
    params->addWidget(FormKit::caption(QStringLiteral("–"), this));
    m_to = FormKit::dateEdit(today, this);
    params->addWidget(m_to);
    auto *periodButton = new QPushButton(QStringLiteral("…"), this);
    periodButton->setObjectName(QStringLiteral("periodButton"));
    periodButton->setFixedWidth(32);
    auto *periodMenu = new QMenu(periodButton);
    const QDate monthStart(today.year(), today.month(), 1);
    const QDate quarterStart(today.year(), (today.month() - 1) / 3 * 3 + 1, 1);
    periodMenu->addAction(QStringLiteral("Этот месяц"), this, [this, monthStart, today] { setPeriod(monthStart, today); });
    periodMenu->addAction(QStringLiteral("Прошлый месяц"), this,
                          [this, monthStart] { setPeriod(monthStart.addMonths(-1), monthStart.addDays(-1)); });
    periodMenu->addAction(QStringLiteral("Этот квартал"), this, [this, quarterStart, today] { setPeriod(quarterStart, today); });
    periodMenu->addAction(QStringLiteral("Прошлый квартал"), this,
                          [this, quarterStart] { setPeriod(quarterStart.addMonths(-3), quarterStart.addDays(-1)); });
    periodMenu->addAction(QStringLiteral("С начала года"), this,
                          [this, today] { setPeriod(QDate(today.year(), 1, 1), today); });
    periodMenu->addAction(QStringLiteral("Прошлый год"), this, [this, today] {
        setPeriod(QDate(today.year() - 1, 1, 1), QDate(today.year() - 1, 12, 31));
    });
    periodButton->setMenu(periodMenu);
    params->addWidget(periodButton);
    params->addSpacing(28);

    if (kind == TopSubscribers) {
        params->addWidget(FormKit::caption(QStringLiteral("Абонентов:"), this));
        m_top = new QSpinBox(this);
        m_top->setRange(1, 100);
        m_top->setValue(10);
        m_top->setFixedWidth(70);
        params->addWidget(m_top);
    } else {
        params->addWidget(FormKit::caption(QStringLiteral("Периодичность:"), this));
        m_grain = new QComboBox(this);
        m_grain->addItem(QStringLiteral("Месяц"), QStringLiteral("month"));
        m_grain->addItem(QStringLiteral("Квартал"), QStringLiteral("quarter"));
        m_grain->addItem(QStringLiteral("Год"), QStringLiteral("year"));
        m_grain->setFixedWidth(100);
        params->addWidget(m_grain);
        // «Периодичность меняется без повторного ввода периода» (справка начальной страницы аналитика)
        connect(m_grain, &QComboBox::currentIndexChanged, this, &ReportPage::build);
    }
    params->addSpacing(28);
    params->addWidget(FormKit::caption(QStringLiteral("Провайдер:"), this));
    if (me.providerName.isEmpty()) {
        // Главный аналитик: все провайдеры или выбранный (запрос 5 — api.v_providers).
        m_provider = new QComboBox(this);
        m_provider->addItem(QStringLiteral("<все провайдеры>"), QVariant());
        QSqlQuery q;
        QString error;
        if (ApiCall::selectView(QStringLiteral("v_providers"), QStringLiteral("name"), 200, 0, &q, &error))
            while (q.next())
                m_provider->addItem(q.value(QStringLiteral("display_name")).toString(), q.value(QStringLiteral("id")));
        m_provider->setFixedWidth(220);
        params->addWidget(m_provider);
    } else {
        // Руководитель: «В отчётах всегда только ваш провайдер» — отбор задаёт сервер.
        auto *fixed = FormKit::readOnlyField(me.providerName, this);
        fixed->setFixedWidth(220);
        params->addWidget(fixed);
    }
    if (kind == Revenue) {
        params->addSpacing(28);
        params->addWidget(FormKit::caption(QStringLiteral("Тип абонента:"), this));
        m_type = new QComboBox(this);
        m_type->addItem(QStringLiteral("<все>"), QVariant());
        QSqlQuery q;
        QString error;
        if (ApiCall::select(QStringLiteral("lookup_subscriber_types"), {}, &q, &error))
            while (q.next())
                m_type->addItem(q.value(1).toString(), q.value(0));
        m_type->setFixedWidth(140);
        params->addWidget(m_type);
    }
    params->addStretch(1);
    layout->addLayout(params);

    // Табличный документ: белая область с шапкой, диаграммой и таблицей
    auto *scroll = new QScrollArea(this);
    scroll->setObjectName(QStringLiteral("reportArea"));
    scroll->setWidgetResizable(true);
    m_doc = new QFrame(scroll);
    m_doc->setObjectName(QStringLiteral("reportDocument"));
    auto *doc = new QVBoxLayout(m_doc);
    doc->setContentsMargins(18, 14, 18, 14);
    doc->setSpacing(2);
    m_title = new QLabel(m_doc);
    m_title->setObjectName(QStringLiteral("reportTitle"));
    m_periodLine = new QLabel(m_doc);
    m_periodLine->setObjectName(QStringLiteral("reportLine"));
    m_filterLine = new QLabel(m_doc);
    m_filterLine->setObjectName(QStringLiteral("reportLine"));
    doc->addWidget(m_title);
    doc->addWidget(m_periodLine);
    doc->addWidget(m_filterLine);
    doc->addSpacing(10);
    m_chart = new ReportChart(m_doc);
    doc->addWidget(m_chart);
    doc->addSpacing(10);
    m_model = new QStandardItemModel(this);
    m_table = new QTableView(m_doc);
    m_table->setModel(m_model);
    m_table->verticalHeader()->hide();
    m_table->verticalHeader()->setDefaultSectionSize(Theme::rowHeight);
    m_table->horizontalHeader()->setHighlightSections(false);
    m_table->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_table->setSelectionMode(QAbstractItemView::SingleSelection);
    m_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_table->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_table->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_table->setFocusPolicy(Qt::NoFocus);
    doc->addWidget(m_table);
    doc->addStretch(1);
    scroll->setWidget(m_doc);
    layout->addWidget(scroll, 1);

    connect(make, &QPushButton::clicked, this, &ReportPage::build);
    build();
}

void ReportPage::setPeriod(const QDate &from, const QDate &to)
{
    m_from->setDate(from);
    m_to->setDate(to);
    build();
}

QString ReportPage::grain() const
{
    return m_grain ? m_grain->currentData().toString() : QString();
}

QString ReportPage::grainTitle() const
{
    return m_grain ? m_grain->currentText().toLower() : QString();
}

QString ReportPage::byGrain() const
{
    const QString g = grain();
    return g == QLatin1String("year") ? QStringLiteral("по годам")
           : g == QLatin1String("quarter") ? QStringLiteral("по кварталам") : QStringLiteral("по месяцам");
}

QString ReportPage::periodLabel(const QDate &period) const
{
    static const char *months[] = {"янв", "фев", "мар", "апр", "май", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"};
    static const char *quarters[] = {"I", "II", "III", "IV"};
    const bool manyYears = m_from->date().year() != m_to->date().year();
    const QString year = QString::number(period.year());
    const QString g = grain();
    if (g == QLatin1String("year"))
        return year;
    if (g == QLatin1String("quarter"))
        return QStringLiteral("%1 кв.").arg(QString::fromLatin1(quarters[(period.month() - 1) / 3]))
               + (manyYears ? QLatin1Char(' ') + year : QString());
    return QString::fromUtf8(months[period.month() - 1]) + (manyYears ? QLatin1Char(' ') + year.right(2) : QString());
}

QVariant ReportPage::providerId() const
{
    return m_provider ? m_provider->currentData() : QVariant();
}

QString ReportPage::providerTitle() const
{
    if (!m_provider)
        return m_me.providerName;
    return m_provider->currentData().isValid() ? m_provider->currentText() : QString();
}

QString ReportPage::typeFilter() const
{
    if (!m_type || !m_type->currentData().isValid())
        return QStringLiteral("тип абонента — все");
    return QStringLiteral("тип абонента = %1").arg(m_type->currentText());
}

void ReportPage::setHeading(const QString &title, const QString &filter)
{
    m_title->setText(title);
    QString period = QStringLiteral("Период: %1 – %2")
                         .arg(m_from->date().toString(QStringLiteral("dd.MM.yyyy")),
                              m_to->date().toString(QStringLiteral("dd.MM.yyyy")));
    if (m_grain)
        period += QStringLiteral(" · Периодичность: %1").arg(grainTitle());
    m_periodLine->setText(period);
    m_filterLine->setText(QStringLiteral("Отбор: ") + filter);
}

void ReportPage::build()
{
    m_model->clear();
    m_chart->clear();
    switch (m_kind) {
    case Revenue:
        if (m_provider && !providerId().isValid())
            buildShares();
        else
            buildRevenue();
        break;
    case NewContracts:
        buildNewContracts();
        break;
    case TopSubscribers:
        buildTop();
        break;
    }
    // Колонки — по ширине документа (первая — по содержимому у «Новых договоров», «№» — узкая у «Крупнейших»);
    // таблица — во всю высоту документа, без своей прокрутки
    QHeaderView *h = m_table->horizontalHeader();
    h->setSectionResizeMode(QHeaderView::Stretch);
    if (m_kind == NewContracts && m_model->columnCount() > 0)
        h->setSectionResizeMode(0, QHeaderView::ResizeToContents);
    if (m_kind == TopSubscribers && m_model->columnCount() > 0) {
        h->setSectionResizeMode(0, QHeaderView::Fixed);
        m_table->setColumnWidth(0, 40);
    }
    m_table->setFixedHeight(h->sizeHint().height() + m_table->verticalHeader()->length() + 2 * m_table->frameWidth());
}

// 15: выручка по периодам одного провайдера (руководитель; аналитик с отбором по провайдеру)
void ReportPage::buildRevenue()
{
    const QString provider = providerTitle();
    setHeading(QStringLiteral("Выручка %1 %2").arg(provider, byGrain()),
               QStringLiteral("провайдер = %1; %2").arg(provider, typeFilter()));
    QSqlQuery q;
    QString error;
    const QList<ApiParam> params{{QStringLiteral("p_from"), m_from->date()},
                                 {QStringLiteral("p_to"), m_to->date()},
                                 {QStringLiteral("p_grain"), grain()},
                                 {QStringLiteral("p_provider_id"), providerId()},
                                 {QStringLiteral("p_subscriber_type_id"), m_type->currentData()}};
    if (!ApiCall::select(QStringLiteral("report_revenue"), params, &q, &error)) {
        FormKit::error(this, error);
        return;
    }
    setHeaders(m_model, {m_grain->currentText(), QStringLiteral("Новых договоров"), QStringLiteral("Трафик, млн Мб"),
                         QStringLiteral("Подключения, тыс. руб."), QStringLiteral("Выручка, тыс. руб.")});
    QStringList categories;
    ReportChart::Series traffic{QStringLiteral("Оплата трафика"), {}, Theme::seriesColor(0)};
    ReportChart::Series connections{QStringLiteral("Подключения"), {}, Theme::seriesColor(1)};
    while (q.next()) {
        const QSqlRecord r = q.record();
        const QVariant period = q.value(r.indexOf(QStringLiteral("period")));
        const bool total = period.isNull();
        appendRow(m_model,
                  {textCell(q.value(r.indexOf(QStringLiteral("period_title"))).toString()),
                   intCell(q.value(r.indexOf(QStringLiteral("new_contracts"))).toLongLong()),
                   numCell(num(q, r, "volume_mb") / 1e6, 1),
                   numCell(num(q, r, "connection_fees") / 1000, 0),
                   numCell(num(q, r, "revenue") / 1000, 0)},
                  total);
        if (!total) {
            categories << periodLabel(period.toDate());
            traffic.values << num(q, r, "traffic_fees") / 1000;
            connections.values << num(q, r, "connection_fees") / 1000;
        }
    }
    if (!categories.isEmpty())
        m_chart->setData(ReportChart::StackedBars, QStringLiteral("Выручка, тыс. руб."), categories, {traffic, connections});
}

// 17: выручка провайдеров объединения — первые 4 и «Прочие» (главный аналитик без отбора по провайдеру)
void ReportPage::buildShares()
{
    setHeading(QStringLiteral("Выручка провайдеров объединения %1").arg(byGrain()),
               QStringLiteral("все провайдеры; %1").arg(typeFilter()));
    QSqlQuery q;
    QString error;
    const QList<ApiParam> params{{QStringLiteral("p_from"), m_from->date()},
                                 {QStringLiteral("p_to"), m_to->date()},
                                 {QStringLiteral("p_top"), 4},
                                 {QStringLiteral("p_grain"), grain()},
                                 {QStringLiteral("p_subscriber_type_id"), m_type->currentData()}};
    if (!ApiCall::select(QStringLiteral("report_provider_shares"), params, &q, &error)) {
        FormKit::error(this, error);
        return;
    }
    setHeaders(m_model, {QStringLiteral("Провайдер"), QStringLiteral("Договоров"), QStringLiteral("Трафик, млн Мб"),
                         QStringLiteral("Выручка, тыс. руб."), QStringLiteral("Доля, %")});
    QList<QDate> periods;                       // категории диаграммы — периоды по порядку
    QMap<int, ReportChart::Series> series;      // ряд — группа провайдеров (ord)
    QMap<int, QMap<QDate, double>> points;
    while (q.next()) {
        const QSqlRecord r = q.record();
        const QVariant period = q.value(r.indexOf(QStringLiteral("period")));
        const int ord = q.value(r.indexOf(QStringLiteral("ord"))).toInt();
        const QString group = q.value(r.indexOf(QStringLiteral("provider_group"))).toString();
        if (period.isNull()) {
            appendRow(m_model,
                      {textCell(group), intCell(q.value(r.indexOf(QStringLiteral("contracts"))).toLongLong()),
                       numCell(num(q, r, "volume_mb") / 1e6, 1), numCell(num(q, r, "revenue") / 1000, 0),
                       numCell(num(q, r, "share_pct"), 1)},
                      q.value(r.indexOf(QStringLiteral("is_total"))).toBool());
            continue;
        }
        const QDate d = period.toDate();
        if (!periods.contains(d))
            periods << d;
        if (!series.contains(ord))
            series.insert(ord, {group, {}, ord <= 4 ? Theme::seriesColor(ord - 1) : Theme::otherSeriesColor()});
        points[ord][d] = num(q, r, "revenue") / 1000;
    }
    std::sort(periods.begin(), periods.end());
    QStringList categories;
    for (const QDate &d : periods)
        categories << periodLabel(d);
    QList<ReportChart::Series> list;
    for (auto it = series.begin(); it != series.end(); ++it) {
        ReportChart::Series s = it.value();
        for (const QDate &d : periods)
            s.values << points.value(it.key()).value(d, 0.0);
        list << s;
    }
    if (!categories.isEmpty())
        m_chart->setData(ReportChart::StackedBars, QStringLiteral("Выручка по провайдерам, тыс. руб."), categories, list);
}

// 12: новые договоры по периодам и типам абонентов — строки таблицы — периоды, колонки — типы
void ReportPage::buildNewContracts()
{
    const QString provider = providerTitle();
    setHeading(QStringLiteral("Новые договоры %1 по типам абонентов %2")
                   .arg(provider.isEmpty() ? QStringLiteral("провайдеров объединения") : provider, byGrain()),
               provider.isEmpty() ? QStringLiteral("все провайдеры") : QStringLiteral("провайдер = %1").arg(provider));
    QSqlQuery q;
    QString error;
    const QList<ApiParam> params{{QStringLiteral("p_from"), m_from->date()},
                                 {QStringLiteral("p_to"), m_to->date()},
                                 {QStringLiteral("p_grain"), grain()},
                                 {QStringLiteral("p_provider_id"), providerId()}};
    if (!ApiCall::select(QStringLiteral("report_new_contracts"), params, &q, &error)) {
        FormKit::error(this, error);
        return;
    }
    QList<QDate> periods;
    QList<int> types;
    QMap<int, QString> typeTitles;
    QMap<QDate, QMap<int, qint64>> values;
    while (q.next()) {
        const QSqlRecord r = q.record();
        const QDate d = q.value(r.indexOf(QStringLiteral("period"))).toDate();
        const int type = q.value(r.indexOf(QStringLiteral("subscriber_type_id"))).toInt();
        if (!periods.contains(d))
            periods << d;
        if (!types.contains(type)) {
            types << type;
            typeTitles.insert(type, q.value(r.indexOf(QStringLiteral("subscriber_type"))).toString());
        }
        values[d][type] = q.value(r.indexOf(QStringLiteral("contracts"))).toLongLong();
    }
    std::sort(types.begin(), types.end());
    // Строки — типы абонентов (ряды диаграммы), колонки — периоды: типов до 11, их названия длинные
    QStringList categories;
    QStringList headers{QStringLiteral("Тип абонента")};
    for (const QDate &d : periods) {
        categories << periodLabel(d);
        headers << categories.last();
    }
    setHeaders(m_model, headers);
    for (int t : types) {
        QList<Cell> row{textCell(typeTitles.value(t))};
        for (const QDate &d : periods) {
            if (values.value(d).contains(t))
                row << intCell(values.value(d).value(t));
            else
                row << Cell{QString(), QVariant(), true};      // договоров нет — пусто (на диаграмме ноль)
        }
        appendRow(m_model, row);
    }
    QList<ReportChart::Series> list;
    for (int i = 0; i < types.size(); ++i) {
        ReportChart::Series s{typeTitles.value(types.at(i)), {}, Theme::seriesColor(i)};
        for (const QDate &d : periods)
            s.values << double(values.value(d).value(types.at(i), 0));
        list << s;
    }
    if (!categories.isEmpty())
        m_chart->setData(ReportChart::Lines, QStringLiteral("Новые договоры"), categories, list);
}

// Крупнейшие абоненты по выручке за период
void ReportPage::buildTop()
{
    const QString provider = providerTitle();
    setHeading(QStringLiteral("Крупнейшие абоненты %1 по выручке")
                   .arg(provider.isEmpty() ? QStringLiteral("провайдеров объединения") : provider),
               provider.isEmpty() ? QStringLiteral("все провайдеры; первые %1").arg(m_top->value())
                                  : QStringLiteral("провайдер = %1; первые %2").arg(provider).arg(m_top->value()));
    QSqlQuery q;
    QString error;
    const QList<ApiParam> params{{QStringLiteral("p_from"), m_from->date()},
                                 {QStringLiteral("p_to"), m_to->date()},
                                 {QStringLiteral("p_top"), m_top->value()},
                                 {QStringLiteral("p_provider_id"), providerId()}};
    if (!ApiCall::select(QStringLiteral("report_top_subscribers"), params, &q, &error)) {
        FormKit::error(this, error);
        return;
    }
    setHeaders(m_model, {QStringLiteral("№"), QStringLiteral("Абонент"), QStringLiteral("Тип абонента"),
                         QStringLiteral("Трафик, Мб"), QStringLiteral("Выручка, руб."), QStringLiteral("Доля, %")},
               3);
    QStringList categories;
    ReportChart::Series revenue{QStringLiteral("Выручка, тыс. руб."), {}, Theme::seriesColor(0)};
    while (q.next()) {
        const QSqlRecord r = q.record();
        const QString name = q.value(r.indexOf(QStringLiteral("subscriber_name"))).toString();
        appendRow(m_model,
                  {textCell(q.value(r.indexOf(QStringLiteral("ord"))).toString()), textCell(name),
                   textCell(q.value(r.indexOf(QStringLiteral("subscriber_type"))).toString()),
                   numCell(num(q, r, "volume_mb"), 0), numCell(num(q, r, "revenue"), 2), numCell(num(q, r, "share_pct"), 1)});
        // горизонтальные столбцы рисуются снизу вверх — первый абонент наверху; номер места делает подписи
        // категорий различными (наименования абонентов могут совпадать)
        const QString shortName = name.size() > 30 ? name.left(29) + QStringLiteral("…") : name;
        categories.prepend(q.value(r.indexOf(QStringLiteral("ord"))).toString() + QStringLiteral(". ") + shortName);
        revenue.values.prepend(num(q, r, "revenue") / 1000);
    }
    m_table->setColumnWidth(0, 40);
    if (!categories.isEmpty())
        m_chart->setData(ReportChart::HorizontalBars, QStringLiteral("Выручка, тыс. руб."), categories, {revenue});
}

void ReportPage::exportExcel()
{
    if (m_model->rowCount() == 0) {
        FormKit::status(this, QStringLiteral("Сначала сформируйте отчёт."));
        return;
    }
    QString name = m_title->text();
    for (const QChar bad : QStringLiteral("\\/:*?\"<>|«»"))
        name.remove(bad);
    ExcelExport::save(this, name.simplified(), {m_title->text(), m_periodLine->text(), m_filterLine->text()}, m_model);
}

void ReportPage::print()
{
    QPrinter printer(QPrinter::HighResolution);
    printer.setPageOrientation(QPageLayout::Landscape);
    QPrintDialog dialog(&printer, this);
    dialog.setWindowTitle(QStringLiteral("Печать отчёта"));
    if (dialog.exec() != QDialog::Accepted)
        return;
    QPainter painter(&printer);
    const QRect page = printer.pageLayout().paintRectPixels(printer.resolution());
    const double scale = qMin(double(page.width()) / m_doc->width(), double(page.height()) / m_doc->height());
    painter.scale(scale, scale);
    m_doc->render(&painter);
}
