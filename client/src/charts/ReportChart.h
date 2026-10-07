#pragma once

#include <QColor>
#include <QList>
#include <QStringList>
#include <QWidget>

class QChartView;
class QFrame;
class QVBoxLayout;

// Диаграмма табличного документа отчёта (Stats.dc.html, ui-spec.md §4): рамка с диаграммой 632×298 и справа —
// легенда в отдельной рамке. Значения рядов готовит сервер; клиент только раскладывает их по точкам
// (пара «период, ряд» без строки в результате — ноль на диаграмме).
class ReportChart : public QWidget {
    Q_OBJECT
public:
    enum Kind { StackedBars, Lines, HorizontalBars };
    struct Series {
        QString name;
        QList<double> values;      // по одному значению на категорию
        QColor color;
    };

    explicit ReportChart(QWidget *parent = nullptr);

    void setData(Kind kind, const QString &title, const QStringList &categories, const QList<Series> &series);
    void clear();

private:
    void fillLegend(const QList<Series> &series);

    QChartView *m_view;
    QFrame *m_legend;
    QVBoxLayout *m_legendLayout;
};
