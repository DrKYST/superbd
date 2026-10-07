#pragma once

#include <QVariant>
#include <QVariantMap>
#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QComboBox;
class QDateEdit;
class QLineEdit;

// «Сеансы связи» (Sessions.png): журнал сеансов за период — api.q_sessions (запрос 3)
// с отбором по договору (форма выбора — api.q_contracts), IP-адресу или подсети, тарифу и строкой
// «Итого за период». Руководитель и главный аналитик — только просмотр.
class SessionsPage : public QWidget {
    Q_OBJECT
public:
    SessionsPage(const Whoami &me, bool readOnly, QWidget *parent = nullptr);

    // Открытие с отбором (например, «Все сеансы договора» на странице «Абоненты»):
    // contract_id, contract_no, from (дата), to (дата).
    Q_INVOKABLE void applyArgs(const QVariantMap &args);

private:
    void apply();
    void resetFilter();
    void setPeriod(const QDate &from, const QDate &to);

    QDateEdit *m_from;
    QDateEdit *m_to;
    QLineEdit *m_contract;
    QVariant m_contractId;
    QLineEdit *m_ip;
    QComboBox *m_tariff;
    DataGrid *m_grid;
};
