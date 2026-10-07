#include <QApplication>
#include <QFile>
#include <QIcon>
#include <QLocale>
#include <QMessageBox>
#include <QSqlDatabase>
#include <QTimer>

#include "app/AppConfig.h"
#include "app/DevOptions.h"
#include "db/Db.h"
#include "ui/LoginDialog.h"
#include "ui/MainWindow.h"
#include "ui/dialogs/PasswordDialogs.h"

#ifdef SUPERBD_DEV_TOOLS
#include <QTabWidget>

#include <QSqlQuery>

#include "db/ApiCall.h"
#include "ui/dialogs/ContractDialog.h"
#include "ui/dialogs/SubscriberDialog.h"
#endif

namespace {

void applyStyle(QApplication &app)
{
    QFile qss(QStringLiteral(":/style/superbd.qss"));
    if (qss.open(QIODevice::ReadOnly | QIODevice::Text))
        app.setStyleSheet(QString::fromUtf8(qss.readAll()));
}

#ifdef SUPERBD_DEV_TOOLS
void scheduleScreenshot(QWidget *window, const QString &file, int delayMs)
{
    QTimer::singleShot(delayMs, window, [window, file] {
        window->grab().save(file);
        QApplication::exit(0);
    });
}
#endif

} // namespace

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("СуперБД"));
    QApplication::setWindowIcon(QIcon(QStringLiteral(":/icons/app.svg")));
    QLocale::setDefault(QLocale(QLocale::Russian, QLocale::Russia));
    applyStyle(app);

    if (!QSqlDatabase::isDriverAvailable(QStringLiteral("QPSQL"))) {
        QMessageBox::critical(nullptr, QStringLiteral("СуперБД"),
                              QStringLiteral("Не найден драйвер PostgreSQL (QPSQL). "
                                             "Рядом с программой должны лежать libpq.dll и плагин sqldrivers/qsqlpsql.dll."));
        return 1;
    }

    const DevOptions dev = DevOptions::parse(QApplication::arguments());
    AppConfig config = AppConfig::load();

    for (;;) {
        Whoami me;
        QString error;
#ifdef SUPERBD_DEV_TOOLS
        if (!dev.screenshotLogin.isEmpty()) {
            LoginDialog dialog(config);
            dialog.show();
            if (!dev.loginError.isEmpty())
                dialog.showError(dev.loginError);
            scheduleScreenshot(&dialog, dev.screenshotLogin, 300);
            return app.exec();
        }
        if (!dev.devAs.isEmpty()) {
            if (!Db::open(config.connection, dev.devUser, QString(), &error)
                || !Db::setSessionAuthorization(dev.devAs, &error) || !Db::loadWhoami(&me, &error)) {
                QMessageBox::critical(nullptr, QStringLiteral("СуперБД"), error);
                return 1;
            }
        } else
#endif
        {
            LoginDialog dialog(config);
            if (dialog.exec() != QDialog::Accepted)
                return 0;
            config = dialog.config();
            if (!Db::loadWhoami(&me, &error)) {
                QMessageBox::critical(nullptr, QStringLiteral("СуперБД"), error);
                Db::close();
                continue;
            }
        }
        // Временный пароль (D27): до смены пароля сервер откажет во всём, кроме whoami и смены пароля, — форма
        // «Смена пароля» (PasswordChange, forced) открывается до главного окна; «Выйти» — выход из программы.
        if (me.mustChangePassword) {
            if (me.groupName == QLatin1String("grp_dba")) {
                PasswordChangeDialog::showDbaNotice(nullptr);
                Db::close();
                return 0;
            }
            PasswordChangeDialog change(me.login, true);
#ifdef SUPERBD_DEV_TOOLS
            if (!dev.screenshot.isEmpty()) {
                change.show();
                scheduleScreenshot(&change, dev.screenshot, 600);
                const int code = app.exec();
                Db::close();
                return code;
            }
#endif
            if (change.exec() != QDialog::Accepted) {
                Db::close();
                return 0;
            }
            QString reloadError;
            if (!Db::loadWhoami(&me, &reloadError)) {
                QMessageBox::critical(nullptr, QStringLiteral("СуперБД"), reloadError);
                Db::close();
                return 1;
            }
        }

#ifdef SUPERBD_DEV_TOOLS
        // Карточка договора или абонента вместо главного окна — для снимка (--card contract:<код>[:sessions]).
        if (!dev.card.isEmpty()) {
            const QStringList parts = dev.card.split(QLatin1Char(':'));
            QDialog *card = nullptr;
            if (parts.value(0) == QLatin1String("reset") || parts.value(0) == QLatin1String("temp")) {
                // строка пользователя — из api.q_users; temp — настоящий сброс пароля (только тестовая база)
                QSqlQuery q;
                QString err;
                if (!ApiCall::select(QStringLiteral("q_users"), {{QStringLiteral("p_search"), parts.value(1)}}, &q, &err)
                    || !q.next()) {
                    QMessageBox::critical(nullptr, QStringLiteral("СуперБД"), err.isEmpty() ? parts.value(1) : err);
                    return 1;
                }
                const QString login = q.value(QStringLiteral("login")).toString();
                const QString fullName = q.value(QStringLiteral("full_name")).toString();
                if (parts.value(0) == QLatin1String("reset")) {
                    card = new ResetConfirmDialog(login, fullName, q.value(QStringLiteral("group_title")).toString(),
                                                  q.value(QStringLiteral("provider_name")).toString());
                } else {
                    QSqlQuery r;
                    if (!ApiCall::select(QStringLiteral("user_reset_password"), {{QStringLiteral("p_login"), login}}, &r, &err)
                        || !r.next()) {
                        QMessageBox::critical(nullptr, QStringLiteral("СуперБД"), err);
                        return 1;
                    }
                    card = new TempPasswordDialog(login, fullName, r.value(0).toString(), r.value(1).toDateTime());
                }
            } else if (parts.value(0) == QLatin1String("password")) {
                card = new PasswordChangeDialog(me.login, false);
            } else if (parts.value(0) == QLatin1String("contract"))
                card = new ContractDialog(parts.value(1).toInt());
            else if (parts.value(0) == QLatin1String("subscriber"))
                card = new SubscriberDialog(parts.value(1).toInt());
            if (!card)
                return 1;
            card->show();
            if (parts.value(2) == QLatin1String("sessions"))
                if (auto *tabs = card->findChild<QTabWidget *>())
                    tabs->setCurrentIndex(1);
            if (!dev.screenshot.isEmpty())
                scheduleScreenshot(card, dev.screenshot, 900);
            const int code = app.exec();
            delete card;
            Db::close();
            return code;
        }
#endif
        int rc = 0;
        bool logout = false;
        {
            MainWindow window(me);
            window.resize(1440, 900);
            window.show();
#ifdef SUPERBD_DEV_TOOLS
            if (!dev.openForm.isEmpty())
                window.openFormWithArgs(dev.openForm, dev.args);
            if (!dev.screenshot.isEmpty())
                scheduleScreenshot(&window, dev.screenshot, 700);
#endif
            rc = app.exec();
            logout = window.logoutRequested();
        }
        Db::close();
        if (!logout || !dev.devAs.isEmpty())
            return rc;
    }
}
