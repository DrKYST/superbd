#include "db/ApiCall.h"

#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>

#include "db/Db.h"

namespace {

// Имя функции или представления api: латиница в нижнем регистре, цифры, «_», не с цифры, до 63 символов.
bool validIdentifier(const QString &name)
{
    if (name.isEmpty() || name.size() > 63 || name.front().isDigit())
        return false;
    for (const QChar ch : name) {
        const bool ok = (ch >= QLatin1Char('a') && ch <= QLatin1Char('z'))
                        || (ch >= QLatin1Char('0') && ch <= QLatin1Char('9')) || ch == QLatin1Char('_');
        if (!ok)
            return false;
    }
    return true;
}

bool checkIdentifiers(const QStringList &names, QString *error)
{
    for (const QString &n : names) {
        if (!validIdentifier(n)) {
            if (error)
                *error = QStringLiteral("Недопустимое имя объекта: %1").arg(n);
            return false;
        }
    }
    return true;
}

bool run(const QString &sql, const QList<ApiParam> &params, QSqlQuery *query, QString *error)
{
    *query = QSqlQuery(Db::database());
    query->setForwardOnly(true);
    if (!query->prepare(sql)) {
        if (error)
            *error = Db::userMessage(query->lastError());
        return false;
    }
    for (const ApiParam &p : params)
        query->bindValue(QLatin1Char(':') + p.name, p.value);
    if (!query->exec()) {
        if (error)
            *error = Db::userMessage(query->lastError());
        return false;
    }
    return true;
}

} // namespace

bool ApiCall::select(const QString &function, const QList<ApiParam> &params, QSqlQuery *query, QString *error)
{
    QStringList names{function};
    QStringList args;
    for (const ApiParam &p : params) {
        names << p.name;
        args << QStringLiteral("%1 => :%1").arg(p.name);
    }
    if (!checkIdentifiers(names, error))
        return false;
    return run(QStringLiteral("SELECT * FROM api.%1(%2)").arg(function, args.join(QStringLiteral(", "))),
               params, query, error);
}

bool ApiCall::exec(const QString &function, const QList<ApiParam> &params, QString *error)
{
    QSqlQuery q;
    return select(function, params, &q, error);
}

bool ApiCall::selectView(const QString &view, const QString &orderBy, int limit, int offset,
                         QSqlQuery *query, QString *error)
{
    if (!checkIdentifiers({view, orderBy}, error))
        return false;
    return run(QStringLiteral("SELECT *, count(*) OVER () AS total_count FROM api.%1 "
                              "ORDER BY %2 LIMIT :p_limit OFFSET :p_offset").arg(view, orderBy),
               {{QStringLiteral("p_limit"), qBound(1, limit, 200)}, {QStringLiteral("p_offset"), qMax(0, offset)}},
               query, error);
}

bool ApiCall::selectViewRow(const QString &view, const QString &keyField, const QVariant &key,
                            QSqlQuery *query, QString *error)
{
    if (!checkIdentifiers({view, keyField}, error))
        return false;
    return run(QStringLiteral("SELECT * FROM api.%1 WHERE %2 = :p_key").arg(view, keyField),
               {{QStringLiteral("p_key"), key}}, query, error);
}
