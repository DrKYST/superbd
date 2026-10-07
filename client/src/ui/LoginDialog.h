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

    // Ошибка входа красным блоком под паролем (LoginExpired.dc.html). При отказе в проверке пароля — подсказка про
    // истёкший временный пароль (D27): сервер не сообщает, что пароль просрочен, ответ тот же, что на неверный пароль.
    void showError(const QString &serverMessage);

private:
    void tryLogin();
    void hideError();

    Ui::LoginDialog *ui;
    AppConfig m_config;
    int m_baseHeight = 0;
};
