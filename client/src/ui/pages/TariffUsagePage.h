#pragma once

#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QComboBox;
class QDateEdit;

// «Трафик по тарифам» (Статистика; руководитель и главный аналитик): использование тарифов за период —
// api.q_tariff_usage (запрос 9, правое соединение): все тарифы, включая неиспользованные.
// Табличная часть отчёта; диаграмма и выгрузка в Excel добавляются вместе с отчётами (ЛР 6).
class TariffUsagePage : public QWidget {
    Q_OBJECT
public:
    TariffUsagePage(const Whoami &me, QWidget *parent = nullptr);

private:
    void build();

    QDateEdit *m_from;
    QDateEdit *m_to;
    QComboBox *m_provider = nullptr;
    DataGrid *m_grid;
};
