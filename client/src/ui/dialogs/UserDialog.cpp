#include "ui/dialogs/UserDialog.h"

#include <QCheckBox>
#include <QComboBox>
#include <QGridLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QSqlQuery>
#include <QToolButton>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/dialogs/PasswordDialogs.h"
#include "ui/dialogs/PickerDialog.h"
#include "ui/widgets/FormKit.h"

UserDialog::UserDialog(QWidget *parent)
    : QDialog(parent)
{
    setWindowTitle(QStringLiteral("Пользователь (создание) — СуперБД"));
    resize(620, 470);
    QVBoxLayout *layout = FormKit::formLayout(this, QStringLiteral("Пользователь (создание)"));

    FormKit::CommandBar bar(this);
    m_saveClose = bar.button(QStringLiteral("Записать и закрыть"), true);
    m_save = bar.button(QStringLiteral("Записать"));
    bar.stretch();
    bar.more();
    layout->addLayout(bar.layout());

    auto *grid = new QGridLayout;
    grid->setHorizontalSpacing(8);
    grid->setVerticalSpacing(9);
    grid->setColumnMinimumWidth(0, 160);
    int row = 0;

    grid->addWidget(FormKit::caption(QStringLiteral("Логин:"), this), row, 0);
    m_login = new QLineEdit(this);
    m_login->setFixedWidth(180);
    m_login->setMaxLength(31);
    grid->addWidget(m_login, row, 1);
    grid->addWidget(FormKit::hint(QStringLiteral("латинские строчные, цифры, «_»"), this), row++, 2);

    grid->addWidget(FormKit::caption(QStringLiteral("ФИО:"), this), row, 0);
    m_fullName = new QLineEdit(this);
    grid->addWidget(m_fullName, row++, 1, 1, 2);

    grid->addWidget(FormKit::caption(QStringLiteral("Группа:"), this), row, 0);
    m_group = new QComboBox(this);
    m_group->setFixedWidth(220);
    {
        QSqlQuery q;
        QString error;
        if (ApiCall::selectView(QStringLiteral("v_manageable_groups"), QStringLiteral("ord"), 20, 0, &q, &error)) {
            while (q.next())
                m_group->addItem(QStringLiteral("%1 (%2)").arg(q.value(QStringLiteral("title")).toString(),
                                                               q.value(QStringLiteral("group_name")).toString()),
                                 q.value(QStringLiteral("group_name")));
        } else {
            FormKit::error(this, error);
        }
    }
    grid->addWidget(m_group, row++, 1);

    grid->addWidget(FormKit::caption(QStringLiteral("Провайдер:"), this), row, 0);
    QToolButton *pick = nullptr;
    QWidget *providerField = FormKit::pickField(this, &m_provider, &pick);
    providerField->setFixedWidth(220);
    grid->addWidget(providerField, row, 1);
    grid->addWidget(FormKit::hint(QStringLiteral("обязателен для операторов и руководителей"), this, true), row++, 2);
    grid->setColumnStretch(2, 1);
    layout->addLayout(grid);

    // Группа «Пароль» (UserDialog.dc.html, D27): пароль не вводится — после записи сервер выдаёт временный пароль,
    // он показывается окном «Временный пароль».
    auto *password = new QGroupBox(QStringLiteral("Пароль"), this);
    auto *passwordLayout = new QVBoxLayout(password);
    passwordLayout->addWidget(FormKit::hint(QStringLiteral("Пароль не вводится. После записи сервер выдаст временный "
                                                           "пароль на сутки и покажет его один раз; при первом входе "
                                                           "сотрудник задаст свой."),
                                            password, true));
    layout->addSpacing(4);
    layout->addWidget(password);

    m_canLogin = new QCheckBox(QStringLiteral("Вход разрешён"), this);
    m_canLogin->setChecked(true);
    layout->addSpacing(4);
    layout->addWidget(m_canLogin);
    layout->addSpacing(4);
    layout->addWidget(FormKit::hint(QStringLiteral("При записи создаётся роль PostgreSQL с правом входа и включается в "
                                                   "выбранную группу; пароль хранится только в СУБД. Администраторов "
                                                   "приложения создаёт администратор БД (D26)."),
                                    this, true));
    layout->addStretch(1);

    connect(pick, &QToolButton::clicked, this, &UserDialog::pickProvider);
    connect(m_saveClose, &QPushButton::clicked, this, [this] {
        if (save())
            accept();
    });
    connect(m_save, &QPushButton::clicked, this, &UserDialog::save);
}

void UserDialog::pickProvider()
{
    PickerDialog::Spec spec;
    spec.title = QStringLiteral("Выбор провайдера");
    spec.function = QStringLiteral("q_providers");
    spec.columns = {{QStringLiteral("display_name"), QStringLiteral("Наименование"), ColumnSpec::Text, 0, 300},
                    {QStringLiteral("city"), QStringLiteral("Город"), ColumnSpec::Text, 0, 140},
                    {QStringLiteral("contracts_active"), QStringLiteral("Действующих договоров"), ColumnSpec::Integer, 0, 0}};
    spec.displayField = QStringLiteral("display_name");
    PickerDialog dialog(spec, this);
    if (dialog.exec() == QDialog::Accepted) {
        m_providerId = dialog.selectedId();
        m_provider->setText(dialog.selectedText());
        m_provider->setCursorPosition(0);
    }
}

bool UserDialog::save()
{
    if (m_created)
        return true;
    QSqlQuery q;
    QString error;
    const QList<ApiParam> params{{QStringLiteral("p_login"), m_login->text().trimmed()},
                                 {QStringLiteral("p_full_name"), m_fullName->text().trimmed()},
                                 {QStringLiteral("p_group"), m_group->currentData()},
                                 {QStringLiteral("p_provider_id"), m_providerId},
                                 {QStringLiteral("p_can_login"), m_canLogin->isChecked()}};
    if (!ApiCall::select(QStringLiteral("user_create"), params, &q, &error) || !q.next()) {
        FormKit::error(this, error.isEmpty() ? QStringLiteral("Сервер не вернул временный пароль") : error);
        return false;
    }
    QString temp = q.value(QStringLiteral("temp_password")).toString();
    const QDateTime validUntil = q.value(QStringLiteral("valid_until")).toDateTime();
    q = QSqlQuery();                              // результат с паролем больше не держим
    m_created = true;
    TempPasswordDialog::showOnce(this, m_login->text().trimmed(), m_fullName->text().trimmed(), temp, validUntil);
    // Записанного пользователя эта форма не изменяет: поля закрываются, заголовок — без «(создание)».
    setWindowTitle(QStringLiteral("Пользователь — СуперБД"));
    for (QWidget *w : {static_cast<QWidget *>(m_login), static_cast<QWidget *>(m_fullName),
                       static_cast<QWidget *>(m_group), static_cast<QWidget *>(m_canLogin)})
        w->setEnabled(false);
    m_provider->parentWidget()->setEnabled(false);
    m_save->setEnabled(false);
    m_saveClose->setText(QStringLiteral("Закрыть"));
    return true;
}
