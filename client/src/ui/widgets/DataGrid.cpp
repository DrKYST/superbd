#include "ui/widgets/DataGrid.h"

#include <QHeaderView>
#include <QItemSelectionModel>
#include <QKeyEvent>
#include <QTableView>
#include <QVBoxLayout>

#include "ui/Theme.h"
#include "ui/widgets/FormKit.h"
#include "ui/widgets/PagerBar.h"

DataGrid::DataGrid(QWidget *parent, bool withPager, int limit)
    : QWidget(parent)
    , m_model(new PagedTableModel(this))
    , m_view(new QTableView(this))
{
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    m_view->setModel(m_model);
    m_view->verticalHeader()->hide();
    m_view->verticalHeader()->setDefaultSectionSize(Theme::rowHeight);
    m_view->verticalHeader()->setMinimumSectionSize(Theme::rowHeight);
    m_view->horizontalHeader()->setHighlightSections(false);
    m_view->horizontalHeader()->setDefaultAlignment(Qt::AlignLeft | Qt::AlignVCenter);
    m_view->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_view->setSelectionMode(QAbstractItemView::SingleSelection);
    m_view->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_view->setShowGrid(true);
    m_view->setWordWrap(false);
    m_view->setAlternatingRowColors(false);
    m_view->setFocusPolicy(Qt::StrongFocus);
    layout->addWidget(m_view, 1);

    if (withPager) {
        m_pager = new PagerBar(this);
        layout->addWidget(m_pager);
        connect(m_pager, &PagerBar::pageRequested, this, [this](int offset, int lim) {
            m_model->setPage(offset, lim);
            reload();
        });
    }
    m_model->setPage(0, limit);

    connect(m_model, &PagedTableModel::failed, this, [this](const QString &message) {
        FormKit::error(this, message);
    });
    connect(m_view->selectionModel(), &QItemSelectionModel::currentRowChanged, this,
            [this](const QModelIndex &current) {
                emit currentChanged(current.isValid() ? m_model->rowId(current.row()) : QVariant());
            });
    connect(m_view, &QTableView::doubleClicked, this, [this](const QModelIndex &index) {
        if (index.isValid() && !m_model->isTotalsRow(index.row()))
            emit activated(m_model->rowId(index.row()));
    });
}

void DataGrid::setFunction(const QString &function, const QList<ColumnSpec> &columns, const QString &idField)
{
    const int limit = m_model->limit();
    m_model->setSource(function, columns, idField);
    m_model->setPage(0, limit);
    applyColumns();
}

void DataGrid::setView(const QString &view, const QString &orderBy, const QList<ColumnSpec> &columns,
                       const QString &idField)
{
    const int limit = m_model->limit();
    m_model->setViewSource(view, orderBy, columns, idField);
    m_model->setPage(0, limit);
    applyColumns();
}

void DataGrid::setFilter(const QList<ApiParam> &params)
{
    m_model->setFilter(params);
}

void DataGrid::setTotals(const QList<TotalCell> &cells)
{
    m_model->setTotals(cells);
}

void DataGrid::setStretchColumn(const QString &field)
{
    m_stretchField = field;
    applyColumns();
}

void DataGrid::applyColumns()
{
    QHeaderView *h = m_view->horizontalHeader();
    h->setStretchLastSection(false);
    const QList<ColumnSpec> &cols = m_model->columns();
    for (int i = 0; i < cols.size(); ++i) {
        if (cols.at(i).field == m_stretchField) {
            h->setSectionResizeMode(i, QHeaderView::Stretch);
        } else if (cols.at(i).width > 0) {
            h->setSectionResizeMode(i, QHeaderView::Interactive);
            h->resizeSection(i, cols.at(i).width);
        } else {
            h->setSectionResizeMode(i, QHeaderView::ResizeToContents);   // ширина не задана — по заголовку и данным
        }
    }
    h->setStretchLastSection(m_stretchField.isEmpty());                  // без пустого поля справа
}

bool DataGrid::reload()
{
    const bool ok = m_model->reload();
    afterLoad();
    return ok;
}

bool DataGrid::reloadFromStart()
{
    m_model->setPage(0, m_pager ? m_pager->limit() : m_model->limit());
    return reload();
}

void DataGrid::clear()
{
    m_model->clear();
    afterLoad();
}

void DataGrid::afterLoad()
{
    if (m_pager)
        m_pager->setState(m_model->offset(), m_model->limit(), m_model->totalCount(), m_model->dataRowCount());
    if (m_model->dataRowCount() > 0)
        m_view->selectRow(0);
    else
        emit currentChanged(QVariant());
}

QVariant DataGrid::currentId() const
{
    const QModelIndex i = m_view->currentIndex();
    return i.isValid() ? m_model->rowId(i.row()) : QVariant();
}

QVariant DataGrid::currentValue(const QString &field) const
{
    const QModelIndex i = m_view->currentIndex();
    return i.isValid() ? m_model->value(i.row(), field) : QVariant();
}
