#pragma once

#include <QVariant>
#include <QWidget>

#include "models/PagedTableModel.h"

class PagerBar;
class QTableView;

// Таблица макета (.grid): QTableView + PagedTableModel + необязательная панель страниц #pagerBar.
// Первая строка выделяется после загрузки; ошибки сервера показываются сообщением.
class DataGrid : public QWidget {
    Q_OBJECT
public:
    explicit DataGrid(QWidget *parent = nullptr, bool withPager = true, int limit = 20);

    PagedTableModel *model() const { return m_model; }
    QTableView *view() const { return m_view; }

    void setFunction(const QString &function, const QList<ColumnSpec> &columns,
                     const QString &idField = QStringLiteral("id"));
    void setView(const QString &view, const QString &orderBy, const QList<ColumnSpec> &columns,
                 const QString &idField = QStringLiteral("id"));
    void setFilter(const QList<ApiParam> &params);
    void setTotals(const QList<TotalCell> &cells);
    void setStretchColumn(const QString &field);

    bool reload();                   // текущая страница
    bool reloadFromStart();          // первая страница (после изменения отбора)
    void clear();

    QVariant currentId() const;
    QVariant currentValue(const QString &field) const;

signals:
    void currentChanged(const QVariant &id);
    void activated(const QVariant &id);     // двойной щелчок / Enter

private:
    void applyColumns();
    void afterLoad();

    PagedTableModel *m_model;
    QTableView *m_view;
    PagerBar *m_pager = nullptr;
    QString m_stretchField;
};
