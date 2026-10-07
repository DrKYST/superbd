#include "db/Db.h"

#include <QSqlError>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QVariant>

#include "db/ApiCall.h"

namespace {
const QString kConnection = QStringLiteral("superbd");
}

QSqlDatabase Db::database()
{
    return QSqlDatabase::database(kConnection, false);
}

bool Db::open(const ConnectionParams &params, const QString &user, const QString &password, QString *error)
{
    close();
    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QPSQL"), kConnection);
    db.setHostName(params.host);
    db.setPort(params.port);
    db.setDatabaseName(params.database);
    db.setUserName(user);
    // Пустой пароль: libpq возьмёт его из pgpass.conf, если он там есть.
    db.setPassword(password);
    db.setConnectOptions(QStringLiteral("connect_timeout=5;application_name=superbd-client"));
    if (!db.open()) {
        if (error)
            *error = userMessage(db.lastError());
        close();
        return false;
    }
    return true;
}

bool Db::setSessionAuthorization(const QString &login, QString *error)
{
    // SET SESSION AUTHORIZATION не принимает параметров; set_config — обычная функция, логин передаётся
    // параметром запроса (без склейки SQL и без проверки шаблоном на клиенте — несуществующую роль отклонит сервер).
    QSqlQuery q(database());
    q.prepare(QStringLiteral("SELECT pg_catalog.set_config('session_authorization', :login, false)"));
    q.bindValue(QStringLiteral(":login"), login);
    if (!q.exec()) {
        if (error)
            *error = userMessage(q.lastError());
        return false;
    }
    return true;
}

bool Db::loadWhoami(Whoami *out, QString *error)
{
    QSqlQuery q(database());
    if (!ApiCall::select(QStringLiteral("whoami"), {}, &q, error))
        return false;
    if (!q.next()) {
        if (error)
            *error = QStringLiteral("Сервер не вернул сведения о пользователе");
        return false;
    }
    const QSqlRecord r = q.record();
    out->login = q.value(r.indexOf(QStringLiteral("login"))).toString();
    out->fullName = q.value(r.indexOf(QStringLiteral("full_name"))).toString();
    out->shortName = q.value(r.indexOf(QStringLiteral("short_name"))).toString();
    out->groupName = q.value(r.indexOf(QStringLiteral("group_name"))).toString();
    out->roleTitle = q.value(r.indexOf(QStringLiteral("role_title"))).toString();
    out->roleShort = q.value(r.indexOf(QStringLiteral("role_short"))).toString();
    out->providerName = q.value(r.indexOf(QStringLiteral("provider_name"))).toString();
    out->organization = q.value(r.indexOf(QStringLiteral("organization"))).toString();
    out->adminContact = q.value(r.indexOf(QStringLiteral("admin_contact"))).toString();
    out->databaseName = q.value(r.indexOf(QStringLiteral("database_name"))).toString();
    out->serverVersion = q.value(r.indexOf(QStringLiteral("server_version"))).toString();
    out->sessionStarted = q.value(r.indexOf(QStringLiteral("server_time"))).toDateTime().toLocalTime();
    const QSqlDatabase db = database();
    out->connection.host = db.hostName();
    out->connection.port = db.port();
    out->connection.database = db.databaseName();
    return true;
}

void Db::close()
{
    {
        QSqlDatabase db = QSqlDatabase::database(kConnection, false);
        if (db.isOpen())
            db.close();
    }
    if (QSqlDatabase::contains(kConnection))
        QSqlDatabase::removeDatabase(kConnection);
}

QString Db::userMessage(const QSqlError &error)
{
    QString text = error.databaseText().trimmed();
    if (text.isEmpty())
        text = error.driverText().trimmed();
    // «ОШИБКА:  Договор не найден\nCONTEXT: …» → «Договор не найден»
    text = text.section(QLatin1Char('\n'), 0, 0);
    static const QStringList levels = {QStringLiteral("ОШИБКА:"), QStringLiteral("ВАЖНО:"), QStringLiteral("ПАНИКА:"),
                                       QStringLiteral("ERROR:"), QStringLiteral("FATAL:"), QStringLiteral("PANIC:")};
    for (const QString &level : levels) {
        if (text.startsWith(level)) {
            text = text.mid(level.size()).trimmed();
            break;
        }
    }
    // Код SQLSTATE, который QPSQL иногда дописывает в конце: «… (42501)».
    if (text.endsWith(QLatin1Char(')')) && text.size() >= 7 && text.at(text.size() - 7) == QLatin1Char('(')) {
        const QStringView code = QStringView(text).sliced(text.size() - 6, 5);
        bool isCode = true;
        for (const QChar ch : code)
            isCode = isCode && ((ch >= QLatin1Char('0') && ch <= QLatin1Char('9')) || (ch >= QLatin1Char('A') && ch <= QLatin1Char('Z')));
        if (isCode)
            text = text.left(text.size() - 7).trimmed();
    }
    return text.isEmpty() ? QStringLiteral("Неизвестная ошибка базы данных") : text;
}
