#include "ui/widgets/PagerBar.h"

#include <QComboBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLocale>
#include <QPushButton>
#include <QSignalBlocker>
#include <QSpinBox>

PagerBar::PagerBar(QWidget *parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("pagerBar"));
    setAttribute(Qt::WA_StyledBackground, true);

    auto *layout = new QHBoxLayout(this);
    layout->setContentsMargins(6, 0, 6, 0);
    layout->setSpacing(6);

    layout->addWidget(new QLabel(QStringLiteral("Показывать по:"), this));
    m_limit = new QComboBox(this);
    m_limit->addItems({QStringLiteral("20"), QStringLiteral("100"), QStringLiteral("200")});
    m_limit->setFixedWidth(58);
    layout->addWidget(m_limit);
    layout->addSpacing(8);

    m_first = new QPushButton(QStringLiteral("|◄"), this);
    m_prev = new QPushButton(QStringLiteral("◄"), this);
    m_next = new QPushButton(QStringLiteral("►"), this);
    m_last = new QPushButton(QStringLiteral("►|"), this);
    for (QPushButton *b : {m_first, m_prev, m_next, m_last}) {
        b->setFixedWidth(36);
        b->setFocusPolicy(Qt::NoFocus);
    }
    m_page = new QSpinBox(this);
    m_page->setButtonSymbols(QAbstractSpinBox::NoButtons);
    m_page->setAlignment(Qt::AlignCenter);
    m_page->setFixedWidth(40);
    m_page->setMinimum(1);
    m_pages = new QLabel(this);

    layout->addWidget(m_first);
    layout->addWidget(m_prev);
    layout->addWidget(new QLabel(QStringLiteral("Страница"), this));
    layout->addWidget(m_page);
    layout->addWidget(m_pages);
    layout->addWidget(m_next);
    layout->addWidget(m_last);
    layout->addStretch(1);
    m_records = new QLabel(this);
    layout->addWidget(m_records);

    connect(m_limit, &QComboBox::currentIndexChanged, this, [this] { emit pageRequested(0, limit()); });
    connect(m_first, &QPushButton::clicked, this, [this] { goToPage(1); });
    connect(m_prev, &QPushButton::clicked, this, [this] { goToPage(m_page->value() - 1); });
    connect(m_next, &QPushButton::clicked, this, [this] { goToPage(m_page->value() + 1); });
    connect(m_last, &QPushButton::clicked, this, [this] { goToPage(m_page->maximum()); });
    connect(m_page, &QSpinBox::editingFinished, this, [this] { goToPage(m_page->value()); });

    setState(0, 20, 0, 0);
}

int PagerBar::limit() const
{
    return m_limit->currentText().toInt();
}

void PagerBar::goToPage(int page)
{
    const int pages = m_page->maximum();
    page = qBound(1, page, pages);
    const int offset = (page - 1) * limit();
    if (offset != m_offset)
        emit pageRequested(offset, limit());
}

void PagerBar::setState(int offset, int limitValue, qint64 total, int rowsOnPage)
{
    m_offset = offset;
    m_total = total;
    const int pages = qMax<qint64>(1, (total + limitValue - 1) / limitValue);
    const int page = offset / limitValue + 1;
    {
        const QSignalBlocker block(m_page);
        m_page->setMaximum(pages);
        m_page->setValue(page);
    }
    {
        const QSignalBlocker block(m_limit);
        const int idx = m_limit->findText(QString::number(limitValue));
        if (idx >= 0)
            m_limit->setCurrentIndex(idx);
    }
    const QLocale ru(QLocale::Russian, QLocale::Russia);
    m_pages->setText(QStringLiteral("из %1").arg(ru.toString(pages)));
    m_first->setEnabled(page > 1);
    m_prev->setEnabled(page > 1);
    m_next->setEnabled(page < pages);
    m_last->setEnabled(page < pages);
    if (total == 0 || rowsOnPage == 0)
        m_records->setText(QStringLiteral("Записей нет"));
    else
        m_records->setText(QStringLiteral("Записи %1–%2 из %3")
                               .arg(ru.toString(offset + 1), ru.toString(offset + rowsOnPage), ru.toString(total)));
}
