#pragma once

#include <QDialog>

#include "app/AppConfig.h"

namespace Ui { class LoginDialog; }

// «Доступ к информационной базе»: логин и пароль вводит пользователь, пароль нигде не сохраняется.
// При успешном подключении проверяет группу пользователя вызовом api.whoami().
class LoginDialog : public QDialog {
    Q_OBJECT
public:
    explicit LoginDialog(const AppConfig &config, QWidget *parent = nullptr);
    ~LoginDialog() override;

    AppConfig config() const;

private:
    void tryLogin();

    Ui::LoginDialog *ui;
    AppConfig m_config;
};
