#pragma once

#include <QList>
#include <QString>
#include <QVariant>

class QSqlQuery;

// Именованный параметр функции api: {"p_search", "Иван"} → api.f(p_search => :p_search).
struct ApiParam {
    QString name;
    QVariant value;
};

// Вызов функций и представлений схемы api — единственный путь клиента к данным (CLAUDE.md, правило 3).
// Имена функций, представлений и колонок задаются в коде клиента и проверяются; значения — только
// через prepare + bindValue, пользовательский ввод в текст SQL не попадает.
class ApiCall {
public:
    // SELECT * FROM api.<function>(p1 => :p1, …); результат — в *query, позиция перед первой строкой.
    static bool select(const QString &function, const QList<ApiParam> &params, QSqlQuery *query,
                       QString *error);
    // Вызов без результата (или с игнорируемым результатом).
    static bool exec(const QString &function, const QList<ApiParam> &params, QString *error);

    // Страница представления (запрос без параметров, ТЗ п. 6):
    // SELECT *, count(*) OVER () AS total_count FROM api.<view> ORDER BY <orderBy> LIMIT :limit OFFSET :offset.
    static bool selectView(const QString &view, const QString &orderBy, int limit, int offset,
                           QSqlQuery *query, QString *error);
    // Одна строка представления по коду: SELECT * FROM api.<view> WHERE <keyField> = :key.
    static bool selectViewRow(const QString &view, const QString &keyField, const QVariant &key,
                              QSqlQuery *query, QString *error);
};
