#pragma once

#include <QVariantMap>
#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QCheckBox;
class QComboBox;
class QLabel;
class QLineEdit;

// «Абоненты» (Subscribers.png, Subscribers_Manager.png): составная форма абонент → договоры → сеансы.
//   список абонентов       — api.q_subscribers    (запрос 8, левое соединение);
//   договоры абонента      — api.q_contracts      (запрос 4, отбор по абоненту);
//   сеансы договора за месяц с итогом — api.q_contract_sessions (запрос 2).
// Руководитель и главный аналитик — только просмотр (без командных панелей).
class SubscribersPage : public QWidget {
    Q_OBJECT
public:
    SubscribersPage(const Whoami &me, bool readOnly, QWidget *parent = nullptr);

    // search (текст поиска), active_only (флажок «Только с действующими договорами»).
    Q_INVOKABLE void applyArgs(const QVariantMap &args);

signals:
    void openFormRequested(const QString &form, const QVariantMap &args);

private:
    void reloadSubscribers();
    void subscriberChanged(const QVariant &id);
    void contractChanged(const QVariant &id);

    Whoami m_me;
    bool m_readOnly;
    QComboBox *m_type;
    QCheckBox *m_activeOnly;
    QLineEdit *m_search;
    DataGrid *m_subscribers;
    QLabel *m_contractsCaption;
    DataGrid *m_contracts;
    QLabel *m_sessionsCaption;
    DataGrid *m_sessions;
};
