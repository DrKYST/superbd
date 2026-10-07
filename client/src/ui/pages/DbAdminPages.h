#pragma once

#include <QWidget>

#include "db/Db.h"

class DataGrid;
class QComboBox;
class QDateEdit;
class QLabel;
class QLineEdit;
class QPlainTextEdit;
class QStandardItemModel;
class QTableView;

// Экраны администратора БД (D26), макеты ChangeLog.dc.html, DbTables.dc.html, DbConnections.dc.html.
// Только просмотр: данные дают функции api.q_change_log / q_change_log_fields, db_tables, db_connections.

// «Журнал изменений»: отбор (период, таблица, операция, пользователь) → записи журнала → «Поле / Было / Стало».
class ChangeLogPage : public QWidget {
    Q_OBJECT
public:
    explicit ChangeLogPage(QWidget *parent = nullptr);

private:
    void apply();
    void resetFilter();
    void showFields();

    QDateEdit *m_from;
    QDateEdit *m_to;
    QComboBox *m_table;
    QComboBox *m_operation;
    QLineEdit *m_user;
    DataGrid *m_grid;
    QLabel *m_fieldsCaption;
    QTableView *m_fields;
    QStandardItemModel *m_fieldsModel;
};

// «Таблицы базы данных»: сводка по базе (счётчики начальной страницы администратора БД) и таблицы проекта.
class DbTablesPage : public QWidget {
    Q_OBJECT
public:
    DbTablesPage(const Whoami &me, QWidget *parent = nullptr);

private:
    void reload();

    Whoami m_me;
    QLabel *m_summary;
    DataGrid *m_grid;
};

// «Подключения к базе»: сеансы клиентов и текст текущего запроса выбранного сеанса.
class DbConnectionsPage : public QWidget {
    Q_OBJECT
public:
    explicit DbConnectionsPage(QWidget *parent = nullptr);

private:
    void reload();
    void showQuery();

    DataGrid *m_grid;
    QLabel *m_queryCaption;
    QPlainTextEdit *m_query;
};
