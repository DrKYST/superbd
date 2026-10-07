#include "export/ExcelExport.h"

#include <QAbstractItemModel>
#include <QDate>
#include <QDir>
#include <QFileDialog>
#include <QFont>
#include <QStandardPaths>

#include "xlsxdocument.h"
#include "xlsxformat.h"

#include "ui/widgets/FormKit.h"

namespace ExcelExport {

bool save(QWidget *parent, const QString &suggestedName, const QStringList &heading, const QAbstractItemModel *model)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    QString path = QFileDialog::getSaveFileName(parent, QStringLiteral("Сохранить в Excel"),
                                                QDir(dir).filePath(suggestedName + QStringLiteral(".xlsx")),
                                                QStringLiteral("Книга Excel (*.xlsx)"));
    if (path.isEmpty())
        return false;
    if (!path.endsWith(QStringLiteral(".xlsx"), Qt::CaseInsensitive))
        path += QStringLiteral(".xlsx");

    QXlsx::Document xlsx;
    QXlsx::Format title;
    title.setFontBold(true);
    title.setFontSize(13);
    QXlsx::Format header;
    header.setFontBold(true);
    header.setPatternBackgroundColor(QColor(0xe6, 0xe6, 0xe6));
    header.setBorderStyle(QXlsx::Format::BorderThin);
    QXlsx::Format cell;
    cell.setBorderStyle(QXlsx::Format::BorderThin);
    QXlsx::Format total = cell;
    total.setFontBold(true);
    total.setPatternBackgroundColor(QColor(0xf2, 0xf2, 0xf2));

    int row = 1;
    for (int i = 0; i < heading.size(); ++i)
        xlsx.write(row++, 1, heading.at(i), i == 0 ? title : QXlsx::Format());
    ++row;

    const int columns = model->columnCount();
    for (int c = 0; c < columns; ++c) {
        xlsx.write(row, c + 1, model->headerData(c, Qt::Horizontal, Qt::DisplayRole).toString(), header);
        xlsx.setColumnWidth(c + 1, c == 0 ? 34 : 18);
    }
    ++row;
    for (int r = 0; r < model->rowCount(); ++r, ++row) {
        const bool bold = model->data(model->index(r, 0), Qt::FontRole).value<QFont>().bold();
        for (int c = 0; c < columns; ++c) {
            const QModelIndex idx = model->index(r, c);
            QVariant v = model->data(idx, ExportRole);
            if (!v.isValid())
                v = model->data(idx, Qt::DisplayRole);
            QXlsx::Format f = bold ? total : cell;
            if (v.typeId() == QMetaType::Double)
                f.setNumberFormat(QStringLiteral("#,##0.0##"));     // разделители — по языку Excel
            else if (v.typeId() == QMetaType::LongLong || v.typeId() == QMetaType::Int)
                f.setNumberFormat(QStringLiteral("#,##0"));
            else if (v.typeId() == QMetaType::QDate)
                f.setNumberFormat(QStringLiteral("dd.mm.yyyy"));
            xlsx.write(row, c + 1, v, f);
        }
    }
    if (!xlsx.saveAs(path)) {
        FormKit::error(parent, QStringLiteral("Не удалось сохранить файл %1").arg(QDir::toNativeSeparators(path)));
        return false;
    }
    FormKit::status(parent, QStringLiteral("Отчёт сохранён: %1").arg(QDir::toNativeSeparators(path)));
    return true;
}

} // namespace ExcelExport
