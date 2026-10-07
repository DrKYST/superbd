#include "ui/widgets/FormKit.h"

#include <QDateEdit>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QMenu>
#include <QMessageBox>
#include <QPushButton>
#include <QStatusBar>
#include <QToolButton>
#include <QVBoxLayout>

namespace FormKit {

QVBoxLayout *formLayout(QWidget *form, const QString &title, bool readOnly)
{
    auto *layout = new QVBoxLayout(form);
    layout->setContentsMargins(14, 8, 14, 10);
    layout->setSpacing(7);
    auto *titleRow = new QHBoxLayout;
    titleRow->setSpacing(6);
    auto *heading = new QLabel(title, form);
    heading->setObjectName(QStringLiteral("formTitle"));
    titleRow->addWidget(heading);
    if (readOnly) {
        auto *note = new QLabel(QStringLiteral("(только просмотр)"), form);
        note->setObjectName(QStringLiteral("formTitleNote"));
        titleRow->addWidget(note, 0, Qt::AlignBottom);
    }
    titleRow->addStretch(1);
    layout->addLayout(titleRow);
    return layout;
}

CommandBar::CommandBar(QWidget *parent)
    : m_parent(parent)
    , m_layout(new QHBoxLayout)
{
    m_layout->setSpacing(4);
    m_layout->setContentsMargins(0, 0, 0, 0);
}

QPushButton *CommandBar::button(const QString &text, bool isDefault)
{
    auto *b = new QPushButton(text, m_parent);
    b->setFocusPolicy(Qt::TabFocus);
    b->setAutoDefault(false);   // в диалоге кнопкой по умолчанию не становится («Еще», «Записать»)
    if (isDefault)
        b->setProperty("role", QStringLiteral("default"));
    m_layout->addWidget(b);
    return b;
}

void CommandBar::separator()
{
    auto *line = new QFrame(m_parent);
    line->setObjectName(QStringLiteral("commandSeparator"));
    line->setFrameShape(QFrame::VLine);
    m_layout->addSpacing(3);
    m_layout->addWidget(line);
    m_layout->addSpacing(3);
}

void CommandBar::stretch()
{
    m_layout->addStretch(1);
}

QLineEdit *CommandBar::search()
{
    auto *edit = new QLineEdit(m_parent);
    edit->setPlaceholderText(QStringLiteral("Поиск (Ctrl+F)"));
    edit->setClearButtonEnabled(true);
    edit->setFixedWidth(220);
    m_layout->addWidget(edit);
    return edit;
}

QPushButton *CommandBar::more()
{
    auto *b = new QPushButton(QStringLiteral("Еще ▾"), m_parent);
    b->setMenu(new QMenu(b));
    b->setAutoDefault(false);
    b->setObjectName(QStringLiteral("moreButton"));
    m_layout->addWidget(b);
    return b;
}

QPushButton *link(const QString &text, QWidget *parent, bool strong)
{
    auto *b = new QPushButton(text, parent);
    b->setProperty("role", QStringLiteral("link"));
    if (strong)
        b->setProperty("strong", true);
    b->setCursor(Qt::PointingHandCursor);
    b->setFocusPolicy(Qt::NoFocus);
    b->setSizePolicy(QSizePolicy::Maximum, QSizePolicy::Fixed);
    return b;
}

QLabel *caption(const QString &text, QWidget *parent)
{
    auto *l = new QLabel(text, parent);
    l->setProperty("role", QStringLiteral("caption"));
    return l;
}

QLabel *gridCaption(const QString &text, QWidget *parent)
{
    auto *l = new QLabel(text, parent);
    l->setObjectName(QStringLiteral("gridCaption"));
    return l;
}

QLabel *hint(const QString &text, QWidget *parent, bool wrap)
{
    auto *l = new QLabel(text, parent);
    l->setProperty("role", QStringLiteral("hint"));
    l->setWordWrap(wrap);
    return l;
}

QLineEdit *readOnlyField(const QString &text, QWidget *parent)
{
    auto *e = new QLineEdit(text, parent);
    e->setReadOnly(true);
    e->setCursorPosition(0);
    return e;
}

QDateEdit *dateEdit(const QDate &date, QWidget *parent)
{
    auto *d = new QDateEdit(date, parent);
    d->setCalendarPopup(true);
    d->setDisplayFormat(QStringLiteral("dd.MM.yyyy"));
    d->setFixedWidth(110);
    return d;
}

QWidget *pickField(QWidget *parent, QLineEdit **edit, QToolButton **button)
{
    auto *box = new QWidget(parent);
    auto *l = new QHBoxLayout(box);
    l->setContentsMargins(0, 0, 0, 0);
    l->setSpacing(0);
    *edit = new QLineEdit(box);
    (*edit)->setReadOnly(true);
    *button = new QToolButton(box);
    (*button)->setObjectName(QStringLiteral("pickButton"));
    (*button)->setText(QStringLiteral("…"));
    (*button)->setFocusPolicy(Qt::TabFocus);
    l->addWidget(*edit, 1);
    l->addWidget(*button);
    return box;
}

void status(QWidget *from, const QString &text)
{
    if (auto *w = qobject_cast<QMainWindow *>(from->window()))
        w->statusBar()->showMessage(text, 6000);
}

void pending(QWidget *from, const QString &action)
{
    status(from, QStringLiteral("«%1» появится на этапе изменения данных (функции api создания и изменения записей).")
                     .arg(action));
}

void error(QWidget *from, const QString &text)
{
    QMessageBox::warning(from, QStringLiteral("СуперБД"), text);
}

QString monthTitle(const QDate &date)
{
    static const char *names[] = {"январь", "февраль", "март", "апрель", "май", "июнь", "июль",
                                  "август", "сентябрь", "октябрь", "ноябрь", "декабрь"};
    return QStringLiteral("%1 %2").arg(QString::fromUtf8(names[date.month() - 1])).arg(date.year());
}

} // namespace FormKit
