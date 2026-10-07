#pragma once

#include <QWidget>

#include "db/Db.h"

namespace Ui { class HomePage; }

// «Начальная страница» (Home.dc.html): один класс для всех ролей, содержимое — по группе пользователя.
// Счётчики «Текущих дел» приходят из api.home_todo() и обновляются при каждом открытии страницы.
class HomePage : public QWidget {
    Q_OBJECT
public:
    explicit HomePage(const Whoami &me, QWidget *parent = nullptr);
    ~HomePage() override;

    void refresh();

signals:
    void openFormRequested(const QString &form);
    void openSectionRequested(const QString &section);

protected:
    void showEvent(QShowEvent *event) override;

private:
    void fillRole();
    void fillSections();
    void fillKeys();
    void fillConnection();
    void fillHelp();

    Ui::HomePage *ui;
    Whoami m_me;
};
