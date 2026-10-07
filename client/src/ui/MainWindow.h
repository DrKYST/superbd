#pragma once

#include <QList>
#include <QMainWindow>
#include <QVariantMap>

#include "app/RoleConfig.h"
#include "db/Db.h"

namespace Ui { class MainWindow; }
class QButtonGroup;
class QTabBar;
class QPushButton;
class QWidget;

// Главное окно: панель разделов роли, панель навигации раздела, вкладки открытых форм, строка состояния.
class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow(const Whoami &me, QWidget *parent = nullptr);
    ~MainWindow() override;

    bool logoutRequested() const { return m_logout; }

public slots:
    void openSection(const QString &sectionKey);
    void openForm(const QString &form);
    // Открыть форму с параметрами отбора: страница получает их в Q_INVOKABLE applyArgs(QVariantMap).
    void openFormWithArgs(const QString &form, const QVariantMap &args);

private:
    void buildSections();
    void activateSection(const Section &section);
    const Section *sectionForForm(const QString &form) const;
    void buildNav(const Section &section);
    void syncNavWithCurrentTab();
    void closeTab(int index);
    QWidget *pageAt(int index) const;
    QWidget *createPage(const QString &form);
    void openDialog(const QString &form);

    Ui::MainWindow *ui;
    Whoami m_me;
    QList<Section> m_sections;
    QString m_currentSection;
    QButtonGroup *m_sectionButtons;
    QTabBar *m_tabs;             // вкладки открытых окон; страницы — ui->pages в том же порядке
    QList<QPushButton *> m_navLinks;
    bool m_logout = false;
};
