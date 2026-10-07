#pragma once

#include <QDateTime>
#include <QSqlDatabase>
#include <QString>

#include "app/AppConfig.h"

class QSqlError;

// Сведения о пользователе из api.whoami() — по ним строится интерфейс (разделы, заголовок окна).
struct Whoami {
    QString login;
    QString fullName;
    QString shortName;      // «Ковалёва М. И.»
    QString groupName;      // grp_operator …
    QString roleTitle;      // «Оператор провайдера»
    QString roleShort;      // «оператор»
    QString providerName;   // «ООО «Степной провод»», пусто у администратора и аналитика
    QString organization;   // строка «Организация:» начальной страницы
    QString adminContact;   // ФИО администраторов системы (блок «Справка»)
    QString databaseName;
    QString serverVersion;  // «PostgreSQL 18.3»
    QDateTime sessionStarted;
    bool mustChangePassword = false;   // вход с временным паролем (D27): работа недоступна до смены пароля
    ConnectionParams connection;
};

// Единственное подключение клиента к PostgreSQL под учётной записью пользователя (драйвер QPSQL).
class Db {
public:
    static bool open(const ConnectionParams &params, const QString &user, const QString &password,
                     QString *error);
    // Только для разработки (SUPERBD_DEV_TOOLS): работать от имени другой роли, подключившись суперпользователем.
    static bool setSessionAuthorization(const QString &login, QString *error);
    static bool loadWhoami(Whoami *out, QString *error);
    static void close();
    static QSqlDatabase database();

    // Текст ошибки для пользователя: сообщение RAISE EXCEPTION сервера без служебных префиксов.
    static QString userMessage(const QSqlError &error);
};
