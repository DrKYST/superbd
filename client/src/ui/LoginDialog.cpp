#include "ui/LoginDialog.h"
#include "ui_LoginDialog.h"

#include <QIntValidator>
#include <QMessageBox>

#include "db/Db.h"

LoginDialog::LoginDialog(const AppConfig &config, QWidget *parent)
    : QDialog(parent)
    , ui(new Ui::LoginDialog)
    , m_config(config)
{
    ui->setupUi(this);
    setFixedSize(size());
    m_baseHeight = height();
    setWindowFlag(Qt::WindowContextHelpButtonHint, false);

    ui->portEdit->setValidator(new QIntValidator(1, 65535, this));
    ui->userEdit->setText(config.lastLogin);
    ui->hostEdit->setText(config.connection.host);
    ui->portEdit->setText(QString::number(config.connection.port));
    ui->databaseEdit->setText(config.connection.database);
    ui->rememberCheck->setChecked(config.remember);
    (config.lastLogin.isEmpty() ? ui->userEdit : ui->passwordEdit)->setFocus();

    connect(ui->okButton, &QPushButton::clicked, this, &LoginDialog::tryLogin);
    connect(ui->cancelButton, &QPushButton::clicked, this, &QDialog::reject);
}

LoginDialog::~LoginDialog()
{
    delete ui;
}

AppConfig LoginDialog::config() const
{
    return m_config;
}

void LoginDialog::showError(const QString &serverMessage)
{
    // «пользователь "…" не прошёл проверку подлинности (по паролю)» / «password authentication failed …»
    const bool badPassword = serverMessage.contains(QStringLiteral("(по паролю)"))
                             || serverMessage.contains(QStringLiteral("password authentication failed"));
    const QString text = badPassword
        ? QStringLiteral("Неверный пользователь или пароль.<br>Если вам выдали временный пароль больше суток назад, "
                         "он больше не действует — попросите администратора сбросить пароль ещё раз.")
        : QStringLiteral("Не удалось войти.<br>%1").arg(serverMessage.toHtmlEscaped());
    ui->errorLabel->setText(text);
    if (ui->errorLabel->isHidden()) {
        ui->errorLabel->setVisible(true);
        setFixedSize(width(), m_baseHeight + 60);        // артборд LoginExpired: 520×420 вместо 520×360
    }
}

void LoginDialog::hideError()
{
    ui->errorLabel->setVisible(false);
    setFixedSize(width(), m_baseHeight);
}

void LoginDialog::tryLogin()
{
    const QString user = ui->userEdit->text().trimmed();
    if (user.isEmpty()) {
        QMessageBox::warning(this, windowTitle(), QStringLiteral("Укажите пользователя."));
        ui->userEdit->setFocus();
        return;
    }
    ConnectionParams params;
    params.host = ui->hostEdit->text().trimmed();
    params.port = ui->portEdit->text().toInt();
    params.database = ui->databaseEdit->text().trimmed();

    QString error;
    Whoami me;
    if (!Db::open(params, user, ui->passwordEdit->text(), &error) || !Db::loadWhoami(&me, &error)) {
        Db::close();
        showError(error);
        ui->passwordEdit->selectAll();
        ui->passwordEdit->setFocus();
        return;
    }
    ui->passwordEdit->clear();
    hideError();

    m_config.connection = params;
    m_config.lastLogin = user;
    m_config.remember = ui->rememberCheck->isChecked();
    m_config.save();
    accept();
}
