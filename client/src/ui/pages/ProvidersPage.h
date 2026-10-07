#pragma once

#include <QVariantMap>
#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QCheckBox;
class QLabel;
class QLineEdit;

// «Провайдеры» (Providers.png): администратор и главный аналитик.
//   список провайдеров с числом действующих договоров — api.q_providers (запрос 10);
//   «Сотрудники провайдера «…»» — api.q_provider_staff (запрос 1).
// У главного аналитика — только просмотр.
class ProvidersPage : public QWidget {
    Q_OBJECT
public:
    ProvidersPage(const Whoami &me, bool readOnly, QWidget *parent = nullptr);

    // without_new = true: «Провайдеры без новых договоров в …» (начальная страница аналитика);
    // without_staff = true: «Провайдеры без сотрудников» (начальная страница администратора, запрос 16).
    Q_INVOKABLE void applyArgs(const QVariantMap &args);

signals:
    void openFormRequested(const QString &form, const QVariantMap &args);

private:
    void reload();

    bool m_withoutNew = false;
    QCheckBox *m_withoutStaff = nullptr;    // отбор «Без сотрудников» (администратор)
    QLineEdit *m_search;
    DataGrid *m_providers;
    QLabel *m_staffCaption;
    DataGrid *m_staff;
};

// «Мой провайдер»: карточка своего провайдера из api.v_providers (запрос 5), только просмотр;
// у руководителя — сотрудники провайдера (запрос 1).
class MyProviderPage : public QWidget {
    Q_OBJECT
public:
    MyProviderPage(const Whoami &me, QWidget *parent = nullptr);
};
