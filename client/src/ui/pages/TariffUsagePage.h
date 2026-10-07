#pragma once

#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QComboBox;
class QDateEdit;

// «Трафик по тарифам» (Статистика; руководитель и главный аналитик): использование тарифов за период —
// api.q_tariff_usage (запрос 9, правое соединение): все тарифы, включая неиспользованные.
// Табличная часть отчёта и «Сохранить в Excel…».
class TariffUsagePage : public QWidget {
    Q_OBJECT
public:
    TariffUsagePage(const Whoami &me, QWidget *parent = nullptr);

private:
    void build();
    void exportExcel();

    QDateEdit *m_from;
    QDateEdit *m_to;
    QComboBox *m_provider = nullptr;
    QString m_providerName;     // руководитель: свой провайдер
    DataGrid *m_grid;
};
