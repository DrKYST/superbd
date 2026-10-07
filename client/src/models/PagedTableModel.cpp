#include "models/PagedTableModel.h"

#include <QDate>
#include <QDateTime>
#include <QFont>
#include <QLocale>
#include <QSqlQuery>
#include <QSqlRecord>

#include "export/ExcelExport.h"
#include "ui/Theme.h"

PagedTableModel::PagedTableModel(QObject *parent)
    : QAbstractTableModel(parent)
{
}

void PagedTableModel::setSource(const QString &function, const QList<ColumnSpec> &columns, const QString &idField)
{
    beginResetModel();
    m_isView = false;
    m_source = function;
    m_orderBy.clear();
    m_columns = columns;
    m_idField = idField;
    m_rows.clear();
    m_totalsText.clear();
    m_totalCells.clear();
    m_total = 0;
    m_offset = 0;
    endResetModel();
}

void PagedTableModel::setViewSource(const QString &view, const QString &orderBy, const QList<ColumnSpec> &columns,
                                    const QString &idField)
{
    setSource(view, columns, idField);
    m_isView = true;
    m_orderBy = orderBy;
}

void PagedTableModel::setFilter(const QList<ApiParam> &params)
{
    m_filter = params;
    m_offset = 0;
}

void PagedTableModel::setTotals(const QList<TotalCell> &cells)
{
    m_totalCells = cells;
}

void PagedTableModel::setPage(int offset, int limit)
{
    m_offset = qMax(0, offset);
    m_limit = qBound(1, limit, 200);
}

void PagedTableModel::clear()
{
    beginResetModel();
    m_rows.clear();
    m_totalsText.clear();
    m_total = 0;
    endResetModel();
}

bool PagedTableModel::reload()
{
    QSqlQuery q;
    bool ok;
    if (m_isView) {
        ok = ApiCall::selectView(m_source, m_orderBy, m_limit, m_offset, &q, &m_error);
    } else {
        QList<ApiParam> params = m_filter;
        params << ApiParam{QStringLiteral("p_limit"), m_limit} << ApiParam{QStringLiteral("p_offset"), m_offset};
        ok = ApiCall::select(m_source, params, &q, &m_error);
    }
    if (!ok) {
        clear();
        emit failed(m_error);
        return false;
    }

    beginResetModel();
    m_rows.clear();
    m_totalsText.clear();
    m_total = 0;
    const QSqlRecord rec = q.record();
    while (q.next()) {
        QVariantMap row;
        for (int i = 0; i < rec.count(); ++i)
            row.insert(rec.fieldName(i), q.value(i));
        m_rows << row;
    }
    if (!m_rows.isEmpty()) {
        m_total = m_rows.first().value(QStringLiteral("total_count")).toLongLong();
        // Итоговая строка: значения — из полей результата (посчитаны сервером по всему отбору).
        const QLocale ru(QLocale::Russian, QLocale::Russia);
        for (const TotalCell &cell : m_totalCells) {
            QString text = cell.text;
            if (!cell.source.isEmpty()) {
                const QVariant v = m_rows.first().value(cell.source);
                QString formatted;
                const ColumnSpec *col = nullptr;
                for (const ColumnSpec &c : m_columns)
                    if (c.field == cell.column)
                        col = &c;
                if (text.isEmpty() && col)
                    formatted = format(*col, v);
                else
                    formatted = ru.toString(v.toLongLong());
                text = text.isEmpty() ? formatted : text.arg(formatted);
                if (cell.forms.size() == 3) {
                    const qint64 n = v.toLongLong() % 100;
                    const int form = (n % 10 == 1 && n != 11) ? 0
                                     : (n % 10 >= 2 && n % 10 <= 4 && (n < 12 || n > 14)) ? 1 : 2;
                    text += QLatin1Char(' ') + cell.forms.at(form);
                }
            }
            m_totalsText.insert(cell.column, text);
        }
    }
    endResetModel();
    m_error.clear();
    emit loaded();
    return true;
}

QVariant PagedTableModel::rowId(int row) const
{
    return value(row, m_idField);
}

QVariant PagedTableModel::value(int row, const QString &field) const
{
    return (row >= 0 && row < m_rows.size()) ? m_rows.at(row).value(field) : QVariant();
}

bool PagedTableModel::isTotalsRow(int row) const
{
    return !m_totalsText.isEmpty() && row == m_rows.size();
}

int PagedTableModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_rows.size()) + (m_totalsText.isEmpty() ? 0 : 1);
}

int PagedTableModel::columnCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_columns.size());
}

QString PagedTableModel::format(const ColumnSpec &col, const QVariant &value)
{
    if (value.isNull())
        return QString();
    const QLocale ru(QLocale::Russian, QLocale::Russia);
    switch (col.kind) {
    case ColumnSpec::Integer:
        return ru.toString(value.toLongLong());
    case ColumnSpec::Number:
        return ru.toString(value.toDouble(), 'f', col.decimals);
    case ColumnSpec::Date:
        return value.toDate().toString(QStringLiteral("dd.MM.yyyy"));
    case ColumnSpec::DateTime:
        return value.toDateTime().toLocalTime().toString(QStringLiteral("dd.MM.yyyy HH:mm"));
    case ColumnSpec::Bool:
        return value.toBool() ? QStringLiteral("✓") : QStringLiteral("—");     // Users.dc.html: ok ? '✓' : '—'
    case ColumnSpec::Text:
    case ColumnSpec::TextRight:
        break;
    }
    return value.toString();
}

QVariant PagedTableModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.column() >= m_columns.size())
        return {};
    const ColumnSpec &col = m_columns.at(index.column());
    const bool totals = isTotalsRow(index.row());

    switch (role) {
    case Qt::DisplayRole:
        if (totals)
            return m_totalsText.value(col.field);
        if (!col.flagField.isEmpty() && m_rows.at(index.row()).value(col.flagField).toBool()) {
            const QString text = format(col, m_rows.at(index.row()).value(col.field));
            return text.isEmpty() ? text : text + col.flagSuffix;
        }
        return format(col, m_rows.at(index.row()).value(col.field));
    case Qt::TextAlignmentRole:
        if (col.kind == ColumnSpec::Bool)
            return int(Qt::AlignCenter);
        return int((col.kind == ColumnSpec::Integer || col.kind == ColumnSpec::Number || col.kind == ColumnSpec::TextRight)
                       ? Qt::AlignRight | Qt::AlignVCenter
                       : Qt::AlignLeft | Qt::AlignVCenter);
    case Qt::UserRole:
        return totals ? QVariant() : rowId(index.row());
    case ExcelExport::ExportRole:      // значение как пришло с сервера — для «Сохранить в Excel…»
        if (totals || col.kind == ColumnSpec::Bool)
            break;
        return m_rows.at(index.row()).value(col.field);
    case Qt::ForegroundRole:
        if (!totals && !col.okValue.isEmpty()
            && m_rows.at(index.row()).value(col.field).toString() == col.okValue)
            return Theme::okText();
        break;
    case Qt::FontRole:
        if (totals) {
            QFont f;
            f.setBold(true);
            return f;
        }
        break;
    case Qt::BackgroundRole:
        if (totals)
            return Theme::totalRowBackground();
        break;
    default:
        break;
    }
    return {};
}

QVariant PagedTableModel::headerData(int section, Qt::Orientation orientation, int role) const
{
    if (orientation != Qt::Horizontal || section < 0 || section >= m_columns.size())
        return {};
    if (role == Qt::DisplayRole)
        return m_columns.at(section).title;
    if (role == Qt::TextAlignmentRole) {
        const ColumnSpec &c = m_columns.at(section);
        if (c.kind == ColumnSpec::Bool)
            return int(Qt::AlignCenter);
        return int((c.kind == ColumnSpec::Integer || c.kind == ColumnSpec::Number || c.kind == ColumnSpec::TextRight)
                       ? Qt::AlignRight | Qt::AlignVCenter : Qt::AlignLeft | Qt::AlignVCenter);
    }
    return {};
}
