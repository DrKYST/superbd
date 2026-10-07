#pragma once

#include <QDialog>
#include <QVariant>

class QCheckBox;
class QComboBox;
class QLineEdit;
class QPushButton;

// «Пользователь (создание)» (UserDialog.png, 620×470): логин, ФИО, группа, провайдер, «Вход разрешён».
// Группы — только те, которыми управляет текущий администратор (api.v_manageable_groups); запись —
// api.user_create: роль PostgreSQL, членство в группе и строка сотрудника создаёт сервер.
// Группа «Пароль» макета заменена пояснением: пароль при создании не задаётся (D27) — docs/ui/deviations.md.
class UserDialog : public QDialog {
    Q_OBJECT
public:
    explicit UserDialog(QWidget *parent = nullptr);

    bool created() const { return m_created; }

private:
    bool save();
    void pickProvider();

    QLineEdit *m_login;
    QLineEdit *m_fullName;
    QComboBox *m_group;
    QLineEdit *m_provider;
    QVariant m_providerId;
    QCheckBox *m_canLogin;
    QPushButton *m_saveClose;
    QPushButton *m_save;
    bool m_created = false;
};
