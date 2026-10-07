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
        QMessageBox::warning(this, windowTitle(), QStringLiteral("Не удалось войти.\n\n%1").arg(error));
        ui->passwordEdit->selectAll();
        ui->passwordEdit->setFocus();
        return;
    }
    ui->passwordEdit->clear();

    m_config.connection = params;
    m_config.lastLogin = user;
    m_config.remember = ui->rememberCheck->isChecked();
    m_config.save();
    accept();
}
