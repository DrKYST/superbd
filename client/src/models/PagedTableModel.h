#pragma once

#include <QAbstractTableModel>
#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVariantMap>
#include <QVector>

#include "db/ApiCall.h"

// Колонка таблицы: поле результата функции/представления api и его представление на экране.
struct ColumnSpec {
    enum Kind { Text, TextRight, Integer, Number, Date, DateTime, Bool };   // TextRight — год, код
    QString field;
    QString title;
    Kind kind = Text;
    int decimals = 0;       // для Number
    int width = 0;          // начальная ширина, 0 — по содержимому
    QString okValue;        // значение, выделяемое зелёным («Действует»)
};

// Ячейка итоговой строки «Итого…». Значения готовит сервер (оконные суммы в каждой строке результата):
// source — поле результата, text — подпись; «%1» в тексте заменяется значением source.
struct TotalCell {
    QString column;         // поле колонки, под которой стоит ячейка
    QString source;
    QString text;
    QStringList forms;      // формы слова после числа: {"сеанс", "сеанса", "сеансов"}
};

// Модель списка, заполняемая функцией или представлением api по страницам: p_limit / p_offset,
// общее число строк — колонка total_count. Код строки (id) в колонки не выводится, а хранится
// в Qt::UserRole (CLAUDE.md, правило 6). Клиент ничего не суммирует и не фильтрует.
class PagedTableModel : public QAbstractTableModel {
    Q_OBJECT
public:
    explicit PagedTableModel(QObject *parent = nullptr);

    void setSource(const QString &function, const QList<ColumnSpec> &columns,
                   const QString &idField = QStringLiteral("id"));
    void setViewSource(const QString &view, const QString &orderBy, const QList<ColumnSpec> &columns,
                       const QString &idField = QStringLiteral("id"));
    void setFilter(const QList<ApiParam> &params);     // параметры отбора, кроме p_limit / p_offset
    void setTotals(const QList<TotalCell> &cells);
    void setPage(int offset, int limit);
    bool reload();
    void clear();

    const QList<ColumnSpec> &columns() const { return m_columns; }
    int offset() const { return m_offset; }
    int limit() const { return m_limit; }
    qint64 totalCount() const { return m_total; }
    int dataRowCount() const { return int(m_rows.size()); }
    QVariant rowId(int row) const;
    QVariant value(int row, const QString &field) const;   // любое поле строки результата
    QString lastError() const { return m_error; }
    bool isTotalsRow(int row) const;

    int rowCount(const QModelIndex &parent = {}) const override;
    int columnCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role) const override;

    static QString format(const ColumnSpec &col, const QVariant &value);

signals:
    void loaded();
    void failed(const QString &message);

private:
    bool m_isView = false;
    QString m_source;
    QString m_orderBy;
    QList<ColumnSpec> m_columns;
    QString m_idField;
    QList<ApiParam> m_filter;
    QList<TotalCell> m_totalCells;
    int m_offset = 0;
    int m_limit = 20;
    qint64 m_total = 0;
    QVector<QVariantMap> m_rows;
    QHash<QString, QString> m_totalsText;   // поле колонки → текст итоговой ячейки
    QString m_error;
};
