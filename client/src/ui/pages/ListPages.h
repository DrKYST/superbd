#pragma once

#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QSpinBox;

// Списки ЛР 6, открываемые из навигации или со счётчика начальной страницы. Макетов в ЛР 4 нет — форма по
// образцу «Сеансов связи» (docs/ui/deviations.md).

// «Общие абоненты» (администратор приложения): api.q_shared_subscribers (запрос 13) — абоненты не меньше чем
// N провайдеров, их сведения реестра по D25 меняет только администратор.
class SharedSubscribersPage : public QWidget {
    Q_OBJECT
public:
    explicit SharedSubscribersPage(QWidget *parent = nullptr);

private:
    void reload();

    QSpinBox *m_minProviders;
    DataGrid *m_grid;
};

// «Договоры без сеансов» (оператор, руководитель): api.q_idle_contracts (запрос 14); открывается счётчиком
// «Договоры без сеансов более 30 дней», число в счётчике — total_count этого же запроса.
class IdleContractsPage : public QWidget {
    Q_OBJECT
public:
    IdleContractsPage(const Whoami &me, QWidget *parent = nullptr);

private:
    void reload();

    QSpinBox *m_days;
    DataGrid *m_grid;
};
