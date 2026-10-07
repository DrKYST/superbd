#pragma once

#include <QString>

// Параметры подключения из config.ini рядом с exe (образец — client/config.ini.example).
// Пароль не хранится никогда.
struct ConnectionParams {
    QString host = QStringLiteral("127.0.0.1");
    int port = 5432;
    QString database = QStringLiteral("superbd");
};

class AppConfig {
public:
    static AppConfig load();
    void save() const;

    ConnectionParams connection;
    QString lastLogin;
    bool remember = true;   // «Запомнить сервер, базу и пользователя»

private:
    static QString filePath();
};
