#pragma once

#include <QDate>
#include <QWidget>

#include "db/Db.h"

class QComboBox;
class QDateEdit;
class QFrame;
class QLabel;
class QSpinBox;
class QStandardItemModel;
class QTableView;
class ReportChart;

// «Статистика» (Stats.png, Stats_Chief.png; ui-spec.md §2 — ReportPage): параметры отчёта и табличный документ —
// шапка, диаграмма с легендой, таблица с «Итого»; «Сохранить в Excel…», «Печать». Один класс на отчёты раздела:
//   Revenue        — «Выручка по периодам»: api.report_revenue (запрос 15); у главного аналитика без отбора
//                    по провайдеру — доли провайдеров api.report_provider_shares (запрос 22);
//   NewContracts   — «Новые договоры по типам абонентов»: api.report_new_contracts (запрос 12);
//   TopSubscribers — «Крупнейшие абоненты»: api.report_top_subscribers.
// Числа, итоги и доли считает сервер; клиент переводит единицы (тыс. руб., млн Мб) и раскладывает ряды диаграммы.
class ReportPage : public QWidget {
    Q_OBJECT
public:
    enum Kind { Revenue, NewContracts, TopSubscribers };

    ReportPage(const Whoami &me, Kind kind, QWidget *parent = nullptr);

private:
    void build();
    void buildRevenue();
    void buildShares();
    void buildNewContracts();
    void buildTop();
    void setPeriod(const QDate &from, const QDate &to);
    void setHeading(const QString &title, const QString &filter);
    void exportExcel();
    void print();

    QString grain() const;                  // month / quarter / year
    QString grainTitle() const;             // «месяц»
    QString byGrain() const;                // «по месяцам»
    QString periodLabel(const QDate &period) const;   // подпись категории диаграммы: «янв», «III кв.», «2026»
    QVariant providerId() const;
    QString providerTitle() const;          // «ООО «Степной провод»» или пусто — все провайдеры
    QString typeFilter() const;             // «тип абонента — все» / «тип абонента = Вуз»

    Whoami m_me;
    Kind m_kind;
    QDateEdit *m_from;
    QDateEdit *m_to;
    QComboBox *m_grain = nullptr;
    QComboBox *m_provider = nullptr;        // главный аналитик; руководителю провайдер не выбирается
    QComboBox *m_type = nullptr;
    QSpinBox *m_top = nullptr;
    QFrame *m_doc;
    QLabel *m_title;
    QLabel *m_periodLine;
    QLabel *m_filterLine;
    ReportChart *m_chart;
    QTableView *m_table;
    QStandardItemModel *m_model;
};
