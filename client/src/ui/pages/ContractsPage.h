#pragma once

#include <QVariant>
#include <QVariantMap>
#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QCheckBox;
class QDateEdit;
class QLineEdit;

// «Договоры» (навигация «Абоненты и договоры → Договоры»; в макете не нарисован — docs/ui/deviations.md):
// договоры, заключённые в периоде, — api.q_contracts (запрос 4) с отбором по абоненту (форма выбора —
// api.q_subscribers), действующим и поиском. Двойной щелчок — карточка договора (запрос 7).
class ContractsPage : public QWidget {
    Q_OBJECT
public:
    ContractsPage(const Whoami &me, bool readOnly, QWidget *parent = nullptr);

    // from, to (даты), active_only — например, «Договоров заключено на этой неделе».
    Q_INVOKABLE void applyArgs(const QVariantMap &args);

private:
    void apply();
    void resetFilter();

    bool m_showProvider;
    QDateEdit *m_from;
    QDateEdit *m_to;
    QLineEdit *m_subscriber;
    QVariant m_subscriberId;
    QCheckBox *m_activeOnly;
    QLineEdit *m_search;
    DataGrid *m_grid;
};
