#pragma once

#include <QString>
#include <QStringList>
#include <QVariantMap>

//   --dev-as <логин>        войти без окна входа: подключение от --dev-user (по умолчанию postgres,
//                           пароль из pgpass), затем SET SESSION AUTHORIZATION <логин>;
//   --dev-user <логин>      учётная запись для подключения (суперпользователь);
//   --open <форма>          после входа открыть форму (ключ из RoleConfig, например subscribers);
//   --arg <ключ>=<значение> параметр отбора для открываемой формы (applyArgs), можно несколько;
//   --card contract:<код>[:sessions] | subscriber:<код>  открыть карточку вместо главного окна;
//   --screenshot <файл.png> сохранить снимок окна 1440×900 и завершиться;
//   --screenshot-login <файл.png> сохранить снимок окна входа и завершиться;
//   --login-error <текст>    в снимке окна входа показать ошибку сервера (LoginExpired);
//   --card reset:<логин> | temp:<логин> | password — окна сброса пароля (D27); temp выполняет настоящий сброс.
struct DevOptions {
    bool enabled = false;
    QString devAs;
    QString devUser = QStringLiteral("postgres");
    QString openForm;
    QVariantMap args;
    QString card;
    QString screenshot;
    QString screenshotLogin;
    QString loginError;

    static DevOptions parse(const QStringList &args);
};
