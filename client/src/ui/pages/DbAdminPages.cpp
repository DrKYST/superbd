#include "ui/pages/DbAdminPages.h"

#include <QComboBox>
#include <QDateEdit>
#include <QDateTime>
#include <QGridLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QLocale>
#include <QMap>
#include <QPainter>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QStandardItemModel>
#include <QStyledItemDelegate>
#include <QTableView>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/Theme.h"
#include "ui/widgets/DataGrid.h"
#include "ui/widgets/FormKit.h"

namespace {

// Фон строки из роли модели (выделение изменённых полей): правило QTableView::item в superbd.qss
// перекрывает Qt::BackgroundRole при стандартной отрисовке, поэтому фон заливается до неё.
class RowBackgroundDelegate : public QStyledItemDelegate {
public:
    using QStyledItemDelegate::QStyledItemDelegate;
    void paint(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const override
    {
        const QVariant background = index.data(Qt::BackgroundRole);
        if (background.canConvert<QBrush>())
            painter->fillRect(option.rect, background.value<QBrush>());
        QStyledItemDelegate::paint(painter, option, index);
    }
};

} // namespace

// ============================================================================ «Журнал изменений»

ChangeLogPage::ChangeLogPage(QWidget *parent)
    : QWidget(parent)
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Журнал изменений"));

    FormKit::CommandBar bar(this);
    QPushButton *refresh = bar.button(QStringLiteral("Обновить"));
    bar.separator();
    QPushButton *find = bar.button(QStringLiteral("Найти…"));
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    // Группа «Отбор»: период, таблица, операция, пользователь
    auto *box = new QGroupBox(QStringLiteral("Отбор"), this);
    auto *row = new QHBoxLayout(box);
    row->setSpacing(6);
    row->addWidget(FormKit::caption(QStringLiteral("Период с:"), box));
    m_from = FormKit::dateEdit(QDate(), box);
    row->addWidget(m_from);
    row->addWidget(FormKit::caption(QStringLiteral("по:"), box));
    m_to = FormKit::dateEdit(QDate(), box);
    row->addWidget(m_to);
    row->addSpacing(10);
    row->addWidget(FormKit::caption(QStringLiteral("Таблица:"), box));
    m_table = new QComboBox(box);
    m_table->setFixedWidth(190);                // как в макете; длинные названия видны в раскрытом списке
    m_table->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
    m_table->addItem(QStringLiteral("<все>"), QVariant());
    {
        // Список таблиц — из той же функции, что экран «Таблицы базы данных»
        QSqlQuery q;
        QString error;
        if (ApiCall::select(QStringLiteral("db_tables"), {}, &q, &error)) {
            const QSqlRecord r = q.record();
            while (q.next()) {
                const QString name = q.value(r.indexOf(QStringLiteral("table_name"))).toString();
                const QString title = q.value(r.indexOf(QStringLiteral("table_title"))).toString();
                m_table->addItem(title.isEmpty() ? name : name + QStringLiteral(" — ") + title.toLower(), name);
            }
        }
    }
    row->addWidget(m_table);
    row->addSpacing(14);
    row->addWidget(FormKit::caption(QStringLiteral("Операция:"), box));
    m_operation = new QComboBox(box);
    m_operation->addItem(QStringLiteral("<все>"), QVariant());
    m_operation->addItem(QStringLiteral("добавление"), QStringLiteral("INSERT"));
    m_operation->addItem(QStringLiteral("изменение"), QStringLiteral("UPDATE"));
    m_operation->addItem(QStringLiteral("удаление"), QStringLiteral("DELETE"));
    row->addWidget(m_operation);
    row->addSpacing(10);
    row->addWidget(FormKit::caption(QStringLiteral("Пользователь:"), box));
    m_user = new QLineEdit(box);
    m_user->setPlaceholderText(QStringLiteral("логин"));
    m_user->setFixedWidth(120);
    row->addWidget(m_user);
    auto *applyButton = new QPushButton(QStringLiteral("Применить"), box);
    applyButton->setProperty("role", QStringLiteral("default"));
    row->addWidget(applyButton);
    auto *resetButton = new QPushButton(QStringLiteral("Сбросить"), box);
    row->addWidget(resetButton);
    row->addStretch(1);
    layout->addWidget(box);

    m_grid = new DataGrid(this, true, 20);
    m_grid->setFunction(QStringLiteral("q_change_log"),
        {{QStringLiteral("changed_at"), QStringLiteral("Дата и время"), ColumnSpec::DateTime, 0, 140},
         {QStringLiteral("db_user"), QStringLiteral("Пользователь"), ColumnSpec::Text, 0, 140},
         {QStringLiteral("table_name"), QStringLiteral("Таблица"), ColumnSpec::Text, 0, 170},
         {QStringLiteral("operation_title"), QStringLiteral("Операция"), ColumnSpec::Text, 0, 120},
         {QStringLiteral("row_pk"), QStringLiteral("Ключ строки"), ColumnSpec::TextRight, 0, 110},
         {QStringLiteral("changed_fields"), QStringLiteral("Изменено полей"), ColumnSpec::Integer, 0, 0}});
    layout->addWidget(m_grid, 1);

    // «Поле / Было / Стало» выбранной записи — api.q_change_log_fields
    m_fieldsCaption = FormKit::gridCaption(QString(), this);
    layout->addWidget(m_fieldsCaption);
    m_fieldsModel = new QStandardItemModel(this);
    m_fields = new QTableView(this);
    m_fields->setModel(m_fieldsModel);
    m_fields->verticalHeader()->hide();
    m_fields->verticalHeader()->setDefaultSectionSize(Theme::rowHeight);
    m_fields->horizontalHeader()->setHighlightSections(false);
    m_fields->horizontalHeader()->setDefaultAlignment(Qt::AlignLeft | Qt::AlignVCenter);
    m_fields->setSelectionMode(QAbstractItemView::NoSelection);
    m_fields->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_fields->setFixedHeight(190);
    m_fields->setItemDelegate(new RowBackgroundDelegate(m_fields));
    layout->addWidget(m_fields);
    layout->addWidget(FormKit::hint(QStringLiteral("Журнал заполняют триггеры таблиц (строка до и после изменения — jsonb). "
                                                   "Записи журнала не изменяются и не удаляются. Изменённые поля выделены."),
                                    this, true));

    connect(applyButton, &QPushButton::clicked, this, &ChangeLogPage::apply);
    connect(resetButton, &QPushButton::clicked, this, [this] { resetFilter(); apply(); });
    connect(refresh, &QPushButton::clicked, this, [this] { m_grid->reload(); });
    connect(m_user, &QLineEdit::returnPressed, this, &ChangeLogPage::apply);
    connect(find, &QPushButton::clicked, this, [this] { m_user->setFocus(); m_user->selectAll(); });
    connect(m_grid, &DataGrid::currentChanged, this, &ChangeLogPage::showFields);

    resetFilter();
    apply();
}

void ChangeLogPage::resetFilter()
{
    const QDate today = QDate::currentDate();
    m_from->setDate(today.addDays(-6));
    m_to->setDate(today);
    m_table->setCurrentIndex(0);
    m_operation->setCurrentIndex(0);
    m_user->clear();
}

void ChangeLogPage::apply()
{
    const QString user = m_user->text().trimmed();
    m_grid->setFilter({{QStringLiteral("p_from"), m_from->date()},
                       {QStringLiteral("p_to"), m_to->date()},
                       {QStringLiteral("p_table"), m_table->currentData()},
                       {QStringLiteral("p_operation"), m_operation->currentData()},
                       {QStringLiteral("p_db_user"), user.isEmpty() ? QVariant() : QVariant(user)}});
    m_grid->reloadFromStart();
    showFields();
}

void ChangeLogPage::showFields()
{
    m_fieldsModel->clear();
    m_fieldsModel->setHorizontalHeaderLabels({QStringLiteral("Поле"), QStringLiteral("Было"), QStringLiteral("Стало")});
    m_fields->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Fixed);
    m_fields->setColumnWidth(0, 200);
    m_fields->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);
    m_fields->horizontalHeader()->setSectionResizeMode(2, QHeaderView::Stretch);

    const QVariant id = m_grid->currentId();
    if (!id.isValid() || id.isNull()) {
        m_fieldsCaption->setText(m_grid->model()->dataRowCount() == 0
                                     ? QStringLiteral("За выбранный период изменений нет")
                                     : QStringLiteral("Выберите запись журнала"));
        return;
    }
    m_fieldsCaption->setText(QStringLiteral("Изменение: %1, ключ %2, %3, %4")
                                 .arg(m_grid->currentValue(QStringLiteral("table_name")).toString(),
                                      m_grid->currentValue(QStringLiteral("row_pk")).toString(),
                                      m_grid->currentValue(QStringLiteral("db_user")).toString(),
                                      m_grid->currentValue(QStringLiteral("changed_at")).toDateTime().toLocalTime()
                                          .toString(QStringLiteral("dd.MM.yyyy HH:mm:ss"))));
    QSqlQuery q;
    QString error;
    if (!ApiCall::select(QStringLiteral("q_change_log_fields"), {{QStringLiteral("p_id"), id}}, &q, &error)) {
        FormKit::error(this, error);
        return;
    }
    const QSqlRecord r = q.record();
    while (q.next()) {
        QList<QStandardItem *> items;
        for (const char *field : {"field", "old_value", "new_value"}) {
            const QVariant v = q.value(r.indexOf(QLatin1String(field)));
            items << new QStandardItem(v.isNull() ? QString() : v.toString());
        }
        items.at(1)->setFont(QFont(QStringLiteral("Consolas")));
        items.at(2)->setFont(QFont(QStringLiteral("Consolas")));
        if (q.value(r.indexOf(QStringLiteral("changed"))).toBool())
            for (QStandardItem *item : items)
                item->setBackground(Theme::changedRowBackground());
        m_fieldsModel->appendRow(items);
    }
}

// ============================================================================ «Таблицы базы данных»

DbTablesPage::DbTablesPage(const Whoami &me, QWidget *parent)
    : QWidget(parent)
    , m_me(me)
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Таблицы базы данных"));

    FormKit::CommandBar bar(this);
    QPushButton *refresh = bar.button(QStringLiteral("Обновить"));
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    m_summary = new QLabel(this);
    m_summary->setTextFormat(Qt::RichText);
    layout->addWidget(m_summary);

    m_grid = new DataGrid(this, false, 200);
    m_grid->setFunction(QStringLiteral("db_tables"),
        {{QStringLiteral("table_name"), QStringLiteral("Таблица"), ColumnSpec::Text, 0, 170},
         {QStringLiteral("table_title"), QStringLiteral("Назначение"), ColumnSpec::Text, 0, 220},
         {QStringLiteral("rows_estimate"), QStringLiteral("Строк (оценка)"), ColumnSpec::Integer, 0, 120},
         {QStringLiteral("total_size"), QStringLiteral("Размер с индексами"), ColumnSpec::TextRight, 0, 140},
         {QStringLiteral("last_vacuum"), QStringLiteral("Очистка"), ColumnSpec::DateTime, 0, 130},
         {QStringLiteral("last_analyze"), QStringLiteral("Сбор статистики"), ColumnSpec::DateTime, 0, 130},
         {QStringLiteral("seq_scan"), QStringLiteral("Чтений целиком"), ColumnSpec::Integer, 0, 120},
         {QStringLiteral("idx_scan"), QStringLiteral("Чтений по индексу"), ColumnSpec::Integer, 0, 0}},
        QStringLiteral("table_name"));
    m_grid->setStretchColumn(QStringLiteral("table_title"));
    layout->addWidget(m_grid, 1);
    layout->addWidget(FormKit::hint(QStringLiteral("Сведения — из статистики сервера (pg_stat_user_tables), только просмотр. "
                                                   "Очистку и сбор статистики выполняет автоочистка; вручную — VACUUM / "
                                                   "ANALYZE в psql (роль pg_maintain)."),
                                    this, true));

    connect(refresh, &QPushButton::clicked, this, &DbTablesPage::reload);
    reload();
}

void DbTablesPage::reload()
{
    m_grid->reload();
    // Сводка — счётчики «Текущих дел» администратора БД (api.home_todo) и число таблиц списка
    QStringList parts{QStringLiteral("База: <b>%1</b>").arg(m_me.databaseName.toHtmlEscaped())};
    QSqlQuery q;
    QString error;
    if (ApiCall::select(QStringLiteral("home_todo"), {}, &q, &error)) {
        const QLocale ru(QLocale::Russian, QLocale::Russia);
        const QSqlRecord r = q.record();
        QMap<int, QString> byOrd;
        while (q.next())
            byOrd.insert(q.value(r.indexOf(QStringLiteral("ord"))).toInt(),
                         ru.toString(q.value(r.indexOf(QStringLiteral("value"))).toDouble(), 'f', 0));
        parts << QStringLiteral("Размер данных проекта: <b>%1 МБ</b>").arg(byOrd.value(1))
              << QStringLiteral("Таблиц: <b>%1</b>").arg(m_grid->model()->totalCount())
              << QStringLiteral("Подключений сейчас: <b>%1</b>").arg(byOrd.value(2))
              << QStringLiteral("Таблиц без сбора статистики больше 7 дней: <b>%1</b>").arg(byOrd.value(4));
    }
    m_summary->setText(parts.join(QStringLiteral("&nbsp;&nbsp;&nbsp;&nbsp;")));
}

// ============================================================================ «Подключения к базе»

DbConnectionsPage::DbConnectionsPage(QWidget *parent)
    : QWidget(parent)
{
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Подключения к базе"));

    FormKit::CommandBar bar(this);
    QPushButton *refresh = bar.button(QStringLiteral("Обновить"));
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    m_grid = new DataGrid(this, false, 200);
    m_grid->setFunction(QStringLiteral("db_connections"),
        {{QStringLiteral("pid"), QStringLiteral("PID"), ColumnSpec::TextRight, 0, 70},
         {QStringLiteral("user_name"), QStringLiteral("Пользователь"), ColumnSpec::Text, 0, 120},
         {QStringLiteral("application_name"), QStringLiteral("Программа"), ColumnSpec::Text, 0, 170},
         {QStringLiteral("client_addr"), QStringLiteral("Адрес"), ColumnSpec::Text, 0, 110},
         {QStringLiteral("backend_start"), QStringLiteral("Начало сеанса"), ColumnSpec::DateTime, 0, 130},
         {QStringLiteral("state_title"), QStringLiteral("Состояние"), ColumnSpec::Text, 0, 140},
         {QStringLiteral("wait_event"), QStringLiteral("Ожидание"), ColumnSpec::Text, 0, 140},
         {QStringLiteral("query"), QStringLiteral("Запрос"), ColumnSpec::Text, 0, 0}},
        QStringLiteral("pid"));
    m_grid->setStretchColumn(QStringLiteral("query"));
    layout->addWidget(m_grid, 1);

    m_queryCaption = FormKit::gridCaption(QString(), this);
    layout->addWidget(m_queryCaption);
    m_query = new QPlainTextEdit(this);
    m_query->setReadOnly(true);
    m_query->setFont(QFont(QStringLiteral("Consolas")));
    m_query->setFixedHeight(120);
    layout->addWidget(m_query);
    layout->addWidget(FormKit::hint(QStringLiteral("Тексты запросов других пользователей видны благодаря роли pg_monitor; "
                                                   "значения параметров (в том числе паролей) не показываются. Завершить "
                                                   "чужой сеанс из программы нельзя."),
                                    this, true));

    connect(refresh, &QPushButton::clicked, this, &DbConnectionsPage::reload);
    connect(m_grid, &DataGrid::currentChanged, this, &DbConnectionsPage::showQuery);
    reload();
}

void DbConnectionsPage::reload()
{
    m_grid->reload();
    showQuery();
}

void DbConnectionsPage::showQuery()
{
    const QVariant pid = m_grid->currentId();
    if (!pid.isValid() || pid.isNull()) {
        m_queryCaption->setText(QStringLiteral("Выберите сеанс"));
        m_query->clear();
        return;
    }
    m_queryCaption->setText(QStringLiteral("Запрос сеанса %1 (%2), %3")
                                .arg(pid.toString(),
                                     m_grid->currentValue(QStringLiteral("user_name")).toString(),
                                     m_grid->currentValue(QStringLiteral("state_title")).toString()));
    m_query->setPlainText(m_grid->currentValue(QStringLiteral("query")).toString().trimmed());
}
