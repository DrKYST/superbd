#pragma once

#include <QList>
#include <QString>

// Разделы и панель навигации по ролям — перенос массивов S, nav, adminNav из docs/ui/mockup/*.dc.html
// (ui-spec.md §5). Видимость — только удобство: права проверяет БД.

struct NavLink {
    QString title;
    QString form;       // ключ формы (см. RoleConfig::formTitle)
};

struct NavGroup {
    QString title;
    QList<NavLink> links;
};

struct Section {
    QString key;
    QString title;      // подпись кнопки панели разделов (перенос строки — как в макете)
    QString icon;       // имя файла в :/icons без расширения
    QString defaultForm;
    QList<NavGroup> nav;
};

class RoleConfig {
public:
    static QList<Section> sectionsFor(const QString &group);
    // Заголовок формы / вкладки по ключу; пустая строка — неизвестная форма.
    static QString formTitle(const QString &form);
    // Форма открывается диалогом (создание записи, смена пароля и т. п.), а не вкладкой.
    static bool isDialog(const QString &form);
    // Руководитель и главный аналитик видят данные только для просмотра.
    static bool isReadOnly(const QString &group);
};
