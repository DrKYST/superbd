#pragma once

#include <QDialog>
#include <QVariant>

#include "models/PagedTableModel.h"

class DataGrid;
class QLineEdit;

// Форма выбора (кнопка «…» у поля): список из функции api с поиском на сервере и страницами.
// Используется для выбора договора (api.q_contracts) и абонента (api.q_subscribers).
class PickerDialog : public QDialog {
    Q_OBJECT
public:
    struct Spec {
        QString title;              // «Выбор договора»
        QString function;           // api-функция списка
        QList<ColumnSpec> columns;
        QString searchParam = QStringLiteral("p_search");
        QString displayField;       // что подставить в поле после выбора
        QList<ApiParam> fixedParams;
    };

    PickerDialog(const Spec &spec, QWidget *parent = nullptr);

    QVariant selectedId() const { return m_id; }
    QString selectedText() const { return m_text; }

    static PickerDialog::Spec contractSpec();
    static PickerDialog::Spec subscriberSpec();

private:
    void search();
    void choose();

    Spec m_spec;
    DataGrid *m_grid;
    QLineEdit *m_search;
    QVariant m_id;
    QString m_text;
};
