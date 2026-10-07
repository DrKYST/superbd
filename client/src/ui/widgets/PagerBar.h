#pragma once

#include <QWidget>

class QComboBox;
class QLabel;
class QPushButton;
class QSpinBox;

// Панель страниц под таблицей (#pagerBar, ui-spec.md §4):
// «Показывать по: [20]  |◄ ◄ Страница [N] из M ► ►|        Записи A–B из N».
class PagerBar : public QWidget {
    Q_OBJECT
public:
    explicit PagerBar(QWidget *parent = nullptr);

    int limit() const;
    // Обновить состояние по результату загрузки: смещение, размер страницы, всего записей (total_count).
    void setState(int offset, int limit, qint64 total, int rowsOnPage);

signals:
    // Запрошена другая страница или другой размер страницы.
    void pageRequested(int offset, int limit);

private:
    void goToPage(int page);

    QComboBox *m_limit;
    QPushButton *m_first;
    QPushButton *m_prev;
    QSpinBox *m_page;
    QLabel *m_pages;
    QPushButton *m_next;
    QPushButton *m_last;
    QLabel *m_records;
    int m_offset = 0;
    qint64 m_total = 0;
};
