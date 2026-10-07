#include "charts/ReportChart.h"

#include <QBarCategoryAxis>
#include <QBarSet>
#include <QChart>
#include <QChartView>
#include <QHBoxLayout>
#include <QHorizontalBarSeries>
#include <QLabel>
#include <QLineSeries>
#include <QPainter>
#include <QStackedBarSeries>
#include <QValueAxis>

#include <cmath>

#include "ui/Theme.h"

namespace {

// Цветной квадрат легенды (в макете — 14×10 с рамкой #555555).
class Swatch : public QWidget {
public:
    Swatch(const QColor &color, QWidget *parent)
        : QWidget(parent)
        , m_color(color)
    {
        setFixedSize(14, 10);
    }

protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this);
        p.fillRect(rect(), m_color);
        p.setPen(Theme::seriesBorder());
        p.drawRect(rect().adjusted(0, 0, -1, -1));
    }

private:
    QColor m_color;
};

QFont chartFont(int pointSize, bool bold = false)
{
    QFont f(QStringLiteral("Arial"));
    f.setPointSizeF(pointSize);
    f.setBold(bold);
    return f;
}

void styleAxis(QAbstractAxis *axis)
{
    axis->setLabelsFont(chartFont(8));
    axis->setLabelsColor(Theme::chartText());
    axis->setLinePenColor(Theme::seriesBorder());
    axis->setGridLineColor(Theme::chartGrid());
}

} // namespace

ReportChart::ReportChart(QWidget *parent)
    : QWidget(parent)
    , m_view(new QChartView(this))
    , m_legend(new QFrame(this))
    , m_legendLayout(new QVBoxLayout(m_legend))
{
    auto *row = new QHBoxLayout(this);
    row->setContentsMargins(0, 0, 0, 0);
    row->setSpacing(14);

    auto *frame = new QFrame(this);
    frame->setObjectName(QStringLiteral("chartFrame"));
    auto *frameLayout = new QVBoxLayout(frame);
    frameLayout->setContentsMargins(1, 1, 1, 1);
    m_view->setRenderHint(QPainter::Antialiasing, false);
    m_view->setFixedSize(630, 296);
    frameLayout->addWidget(m_view);
    row->addWidget(frame, 0, Qt::AlignTop);

    m_legend->setObjectName(QStringLiteral("legendFrame"));
    m_legend->setMinimumWidth(212);       // в макете 212; длинные названия рядов — шире
    m_legendLayout->setContentsMargins(10, 6, 10, 6);
    m_legendLayout->setSpacing(4);
    row->addWidget(m_legend, 0, Qt::AlignTop);
    row->addStretch(1);
    clear();
}

void ReportChart::clear()
{
    auto *chart = new QChart;
    chart->legend()->hide();
    chart->setBackgroundRoundness(0);
    m_view->setChart(chart);       // предыдущая диаграмма удаляется представлением
    fillLegend({});
}

void ReportChart::setData(Kind kind, const QString &title, const QStringList &categories, const QList<Series> &series)
{
    auto *chart = new QChart;
    chart->setTitle(title);
    chart->setTitleFont(chartFont(9, true));
    chart->setTitleBrush(Theme::chartText());
    chart->legend()->hide();
    chart->setBackgroundRoundness(0);
    chart->setMargins(QMargins(6, 4, 10, 4));
    chart->setAnimationOptions(QChart::NoAnimation);

    auto *axisValues = new QValueAxis;
    axisValues->setLabelFormat(QStringLiteral("%.0f"));
    axisValues->setMin(0);
    styleAxis(axisValues);
    auto *axisCategories = new QBarCategoryAxis;
    styleAxis(axisCategories);
    axisCategories->setGridLineVisible(false);

    double maxValue = 0;
    if (kind == Lines) {
        axisCategories->append(categories);
        chart->addAxis(axisCategories, Qt::AlignBottom);
        chart->addAxis(axisValues, Qt::AlignLeft);
        for (const Series &s : series) {
            auto *line = new QLineSeries;
            line->setName(s.name);
            QPen pen(s.color);
            pen.setWidth(2);
            line->setPen(pen);
            for (int i = 0; i < s.values.size(); ++i) {
                line->append(i, s.values.at(i));
                maxValue = qMax(maxValue, s.values.at(i));
            }
            chart->addSeries(line);
            line->attachAxis(axisCategories);
            line->attachAxis(axisValues);
        }
    } else {
        QAbstractBarSeries *bars = nullptr;
        if (kind == HorizontalBars)
            bars = new QHorizontalBarSeries;
        else
            bars = new QStackedBarSeries;
        bars->setBarWidth(0.6);
        QList<double> totals(categories.size(), 0.0);
        for (const Series &s : series) {
            auto *set = new QBarSet(s.name);
            set->setColor(s.color);
            set->setBorderColor(Theme::seriesBorder());
            for (int i = 0; i < categories.size(); ++i) {
                const double v = i < s.values.size() ? s.values.at(i) : 0.0;
                set->append(v);
                totals[i] += kind == StackedBars ? v : 0.0;
                maxValue = qMax(maxValue, kind == StackedBars ? totals.at(i) : v);
            }
            bars->append(set);
        }
        chart->addSeries(bars);
        axisCategories->append(categories);
        if (kind == HorizontalBars) {
            chart->addAxis(axisCategories, Qt::AlignLeft);
            chart->addAxis(axisValues, Qt::AlignBottom);
        } else {
            chart->addAxis(axisCategories, Qt::AlignBottom);
            chart->addAxis(axisValues, Qt::AlignLeft);
        }
        bars->attachAxis(axisCategories);
        bars->attachAxis(axisValues);
    }
    // Ось от нуля с «круглым» шагом 1, 2 или 5 × 10ⁿ и примерно пятью делениями (в макете — 100 или 1 000)
    const double rough = (maxValue > 0 ? maxValue : 1) / 5;
    const double magnitude = std::pow(10.0, std::floor(std::log10(rough)));
    const double step = rough <= magnitude ? magnitude : rough <= 2 * magnitude ? 2 * magnitude
                      : rough <= 5 * magnitude ? 5 * magnitude : 10 * magnitude;
    const int ticks = int(std::ceil((maxValue > 0 ? maxValue : 1) / step - 1e-9));
    axisValues->setRange(0, ticks * step);
    axisValues->setTickCount(ticks + 1);
    axisValues->setLabelFormat(step < 1 ? QStringLiteral("%.1f") : QStringLiteral("%.0f"));
    m_view->setChart(chart);
    fillLegend(series);
}

void ReportChart::fillLegend(const QList<Series> &series)
{
    while (QLayoutItem *item = m_legendLayout->takeAt(0)) {
        delete item->widget();
        delete item->layout();
        delete item;
    }
    m_legend->setVisible(!series.isEmpty());
    for (const Series &s : series) {
        auto *line = new QWidget(m_legend);
        auto *l = new QHBoxLayout(line);
        l->setContentsMargins(0, 0, 0, 0);
        l->setSpacing(7);
        l->addWidget(new Swatch(s.color, line));
        l->addWidget(new QLabel(s.name, line), 1);
        m_legendLayout->addWidget(line);
    }
}
