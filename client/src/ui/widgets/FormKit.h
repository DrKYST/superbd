#pragma once

#include <QDate>
#include <QString>

class QBoxLayout;
class QDateEdit;
class QHBoxLayout;
class QLabel;
class QLineEdit;
class QMenu;
class QPushButton;
class QToolButton;
class QVBoxLayout;
class QWidget;

// Общие элементы форм по макету (ui-spec.md §3–4): заголовок, командная панель, ссылки, подписи,
// поле с кнопкой выбора «…», сообщения. Стиль — только docs/ui/superbd.qss.
namespace FormKit {

// Корневая раскладка формы: поля 14/8/14/10, промежуток 7; заголовок #formTitle и пометка «(только просмотр)».
QVBoxLayout *formLayout(QWidget *form, const QString &title, bool readOnly = false);

// Командная панель: кнопки высотой 24, первая может быть кнопкой по умолчанию (жёлтой).
class CommandBar {
public:
    explicit CommandBar(QWidget *parent);
    QHBoxLayout *layout() const { return m_layout; }
    QPushButton *button(const QString &text, bool isDefault = false);
    void separator();
    void stretch();
    QLineEdit *search();                    // «Поиск (Ctrl+F)»
    QPushButton *more();                    // «Еще ▾» с меню
private:
    QWidget *m_parent;
    QHBoxLayout *m_layout;
};

QPushButton *link(const QString &text, QWidget *parent, bool strong = false);
QLabel *caption(const QString &text, QWidget *parent);          // подпись поля «Абонент:»
QLabel *gridCaption(const QString &text, QWidget *parent);      // заголовок таблицы (#gridCaption)
QLabel *hint(const QString &text, QWidget *parent, bool wrap = false);
QLineEdit *readOnlyField(const QString &text, QWidget *parent);
QDateEdit *dateEdit(const QDate &date, QWidget *parent);
// Поле с кнопкой выбора «…» вплотную (#pickButton); возвращает контейнер, поле и кнопку.
QWidget *pickField(QWidget *parent, QLineEdit **edit, QToolButton **button);

// Сообщение в строке состояния главного окна (например, «будет на этапе CRUD»).
void status(QWidget *from, const QString &text);
void pending(QWidget *from, const QString &action);
void error(QWidget *from, const QString &text);

QString monthTitle(const QDate &date);                          // «сентябрь 2026»

} // namespace FormKit
