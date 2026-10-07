#pragma once

#include <QString>
#include <QStringList>

class QAbstractItemModel;
class QWidget;

// «Сохранить в Excel…» (ui-spec.md §3): шапка отчёта и таблица с итоговой строкой → .xlsx (QXlsx).
// Значения — как пришли с сервера: числа пишутся числами (роль ExportRole модели), подписи — текстом;
// строки с жирным шрифтом (FontRole) — жирные и в Excel («Итого»).
namespace ExcelExport {

constexpr int ExportRole = Qt::UserRole + 50;   // исходное значение ячейки (число, дата) для выгрузки

// Спрашивает имя файла и сохраняет; false — отмена или ошибка (сообщение уже показано).
bool save(QWidget *parent, const QString &suggestedName, const QStringList &heading, const QAbstractItemModel *model);

} // namespace ExcelExport
