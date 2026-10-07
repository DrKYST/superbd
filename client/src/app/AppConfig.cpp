#include "app/AppConfig.h"

#include <QCoreApplication>
#include <QDir>
#include <QSettings>

QString AppConfig::filePath()
{
    return QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("config.ini"));
}

AppConfig AppConfig::load()
{
    AppConfig cfg;
    QSettings ini(filePath(), QSettings::IniFormat);
    ini.beginGroup(QStringLiteral("database"));
    cfg.connection.host = ini.value(QStringLiteral("host"), cfg.connection.host).toString();
    cfg.connection.port = ini.value(QStringLiteral("port"), cfg.connection.port).toInt();
    cfg.connection.database = ini.value(QStringLiteral("dbname"), cfg.connection.database).toString();
    cfg.lastLogin = ini.value(QStringLiteral("last_login")).toString();
    cfg.remember = ini.value(QStringLiteral("remember"), true).toBool();
    ini.endGroup();
    return cfg;
}

void AppConfig::save() const
{
    QSettings ini(filePath(), QSettings::IniFormat);
    ini.beginGroup(QStringLiteral("database"));
    ini.setValue(QStringLiteral("remember"), remember);
    if (remember) {
        ini.setValue(QStringLiteral("host"), connection.host);
        ini.setValue(QStringLiteral("port"), connection.port);
        ini.setValue(QStringLiteral("dbname"), connection.database);
        ini.setValue(QStringLiteral("last_login"), lastLogin);
    } else {
        ini.remove(QStringLiteral("last_login"));
    }
    ini.endGroup();
}
