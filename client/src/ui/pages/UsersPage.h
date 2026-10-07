#pragma once

#include <QVariantMap>
#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QLineEdit;
class QPushButton;
class QStandardItemModel;
class QTableView;

// «Пользователи» (Users.png): администратор приложения и администратор БД (D26).
//   панель «Группа / Кол-во» — api.v_user_groups (запрос 11), она же отбор списка;
//   список учётных записей — api.q_users; создание — форма «Пользователь» (api.user_create);
//   «Запретить вход» / «Разрешить вход» — api.user_set_login.
// Какие группы видны и какими учётными записями можно управлять (can_manage), решает сервер.
class UsersPage : public QWidget {
    Q_OBJECT
public:
    UsersPage(const Whoami &me, QWidget *parent = nullptr);

    // refresh = true: пользователь создан из «Создать → Пользователь» начальной страницы.
    Q_INVOKABLE void applyArgs(const QVariantMap &args);

private:
    void loadGroups();
    void reload();
    void updateButtons();
    void toggleLogin();
    void createUser();

    Whoami m_me;
    QTableView *m_groups;
    QStandardItemModel *m_groupModel;
    DataGrid *m_users;
    QLineEdit *m_search;
    QPushButton *m_loginButton;
    QString m_group;            // отбор по группе; пусто — все пользователи
};
