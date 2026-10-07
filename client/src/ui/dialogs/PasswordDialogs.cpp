#include "ui/dialogs/PasswordDialogs.h"

#include <QClipboard>
#include <QGridLayout>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QMessageBox>
#include <QPushButton>
#include <QStyle>
#include <QVBoxLayout>

#include "db/ApiCall.h"
#include "ui/widgets/FormKit.h"

namespace {

// Каркас окон ряда «Сброс пароля»: поля 18/14, промежуток 10, заголовок #formTitle (как в артбордах).
QVBoxLayout *dialogLayout(QDialog *dialog, const QString &windowTitle, const QString &heading, const QSize &size)
{
    dialog->setWindowTitle(windowTitle + QStringLiteral(" — СуперБД"));
    dialog->setFixedSize(size);
    dialog->setWindowFlag(Qt::WindowContextHelpButtonHint, false);
    auto *layout = new QVBoxLayout(dialog);
    layout->setContentsMargins(18, 14, 18, 14);
    layout->setSpacing(10);
    auto *title = new QLabel(heading, dialog);
    title->setObjectName(QStringLiteral("formTitle"));
    layout->addWidget(title);
    return layout;
}

QGridLayout *infoGrid(int captionWidth)
{
    auto *grid = new QGridLayout;
    grid->setHorizontalSpacing(8);
    grid->setVerticalSpacing(8);
    grid->setColumnMinimumWidth(0, captionWidth);
    grid->setColumnStretch(1, 1);
    return grid;
}

QPushButton *dialogButton(const QString &text, bool isDefault, QWidget *parent)
{
    auto *b = new QPushButton(text, parent);
    b->setAutoDefault(false);
    if (isDefault) {
        b->setDefault(true);
        b->setProperty("role", QStringLiteral("default"));
    } else {
        b->setFixedWidth(90);
    }
    return b;
}

// Блок с рамкой (.warn / .err макета): стиль — QLabel[role] в superbd.qss.
QLabel *block(const QString &html, const char *role, QWidget *parent)
{
    auto *l = new QLabel(html, parent);
    l->setProperty("role", QString::fromLatin1(role));
    l->setWordWrap(true);
    l->setTextFormat(Qt::RichText);
    return l;
}

// «Ковалёва Марина Игоревна» → «Ковалёва М. И.» (как короткое имя в заголовке окна, api.whoami).
QString shortName(const QString &fullName)
{
    const QStringList parts = fullName.split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (parts.isEmpty())
        return fullName;
    QString s = parts.first();
    for (int i = 1; i < parts.size() && i < 3; ++i)
        s += QLatin1Char(' ') + parts.at(i).left(1) + QLatin1Char('.');
    return s;
}

} // namespace

// ============================================================================ ResetConfirm

ResetConfirmDialog::ResetConfirmDialog(const QString &login, const QString &fullName, const QString &groupTitle,
                                       const QString &providerName, QWidget *parent)
    : QDialog(parent)
{
    QVBoxLayout *layout = dialogLayout(this, QStringLiteral("Сброс пароля"), QStringLiteral("Сбросить пароль?"),
                                       QSize(500, 260));
    QGridLayout *grid = infoGrid(110);
    grid->setVerticalSpacing(5);
    grid->addWidget(FormKit::caption(QStringLiteral("Пользователь:"), this), 0, 0);
    auto *who = new QLabel(QStringLiteral("<b>%1</b> — %2").arg(login.toHtmlEscaped(), fullName.toHtmlEscaped()), this);
    grid->addWidget(who, 0, 1);
    grid->addWidget(FormKit::caption(QStringLiteral("Группа:"), this), 1, 0);
    grid->addWidget(new QLabel(providerName.isEmpty() ? groupTitle : groupTitle + QStringLiteral(", ") + providerName, this),
                    1, 1);
    layout->addLayout(grid);
    layout->addWidget(FormKit::hint(QStringLiteral("Текущий пароль перестанет действовать сразу. Будет выдан временный "
                                                   "пароль на сутки; при первом входе сотрудник задаст свой. Право входа "
                                                   "не меняется."),
                                    this, true));
    layout->addStretch(1);
    auto *buttons = new QHBoxLayout;
    buttons->setSpacing(4);
    buttons->addStretch(1);
    QPushButton *reset = dialogButton(QStringLiteral("Сбросить пароль"), true, this);
    QPushButton *cancel = dialogButton(QStringLiteral("Отмена"), false, this);
    buttons->addWidget(reset);
    buttons->addWidget(cancel);
    layout->addLayout(buttons);
    connect(reset, &QPushButton::clicked, this, &QDialog::accept);
    connect(cancel, &QPushButton::clicked, this, &QDialog::reject);
    cancel->setFocus();
}

// ============================================================================ TempPassword

TempPasswordDialog::TempPasswordDialog(const QString &login, const QString &fullName, QString password,
                                       const QDateTime &validUntil, QWidget *parent)
    : QDialog(parent)
{
    QVBoxLayout *layout = dialogLayout(this, QStringLiteral("Временный пароль"), QStringLiteral("Временный пароль"),
                                       QSize(540, 360));
    QGridLayout *grid = infoGrid(130);
    grid->addWidget(FormKit::caption(QStringLiteral("Пользователь:"), this), 0, 0);
    grid->addWidget(new QLabel(QStringLiteral("<b>%1</b> — %2").arg(login.toHtmlEscaped(),
                                                                  shortName(fullName).toHtmlEscaped()),
                               this),
                    0, 1);
    grid->addWidget(FormKit::caption(QStringLiteral("Временный пароль:"), this), 1, 0);
    auto *passwordRow = new QHBoxLayout;
    passwordRow->setSpacing(8);
    m_password = new QLabel(password, this);
    m_password->setObjectName(QStringLiteral("tempPassword"));
    m_password->setTextFormat(Qt::PlainText);
    m_password->setTextInteractionFlags(Qt::TextSelectableByMouse);
    QFont mono = m_password->font();
    mono.setLetterSpacing(QFont::AbsoluteSpacing, 4);       // letter-spacing: 4px — в Qt Style Sheets его нет
    m_password->setFont(mono);
    passwordRow->addWidget(m_password);
    auto *copy = new QPushButton(QStringLiteral("Копировать"), this);
    copy->setAutoDefault(false);
    passwordRow->addWidget(copy);
    passwordRow->addStretch(1);
    grid->addLayout(passwordRow, 1, 1);
    grid->addWidget(FormKit::caption(QStringLiteral("Действует до:"), this), 2, 0);
    grid->addWidget(new QLabel(validUntil.toLocalTime().toString(QStringLiteral("dd.MM.yyyy HH:mm")), this), 2, 1);
    layout->addLayout(grid);
    layout->addWidget(block(QStringLiteral("Пароль показан <b>один раз</b> и в базе не хранится. Передайте его "
                                           "сотруднику лично. При входе с ним программа попросит задать свой пароль. "
                                           "Закрыли окно, не записав пароль, — сбросьте пароль ещё раз."),
                            "warn", this));
    layout->addStretch(1);
    auto *buttons = new QHBoxLayout;
    buttons->addStretch(1);
    QPushButton *close = dialogButton(QStringLiteral("Закрыть"), true, this);
    close->setFixedWidth(90);
    buttons->addWidget(close);
    layout->addLayout(buttons);

    password.fill(QLatin1Char(' '));        // копия-параметр больше не нужна
    connect(copy, &QPushButton::clicked, this, [this] {
        QGuiApplication::clipboard()->setText(m_password->text());
        FormKit::status(parentWidget() ? parentWidget() : this, QStringLiteral("Временный пароль скопирован в буфер обмена."));
    });
    connect(close, &QPushButton::clicked, this, &QDialog::accept);
}

TempPasswordDialog::~TempPasswordDialog()
{
    m_password->clear();
}

void TempPasswordDialog::showOnce(QWidget *parent, const QString &login, const QString &fullName, QString &password,
                                  const QDateTime &validUntil)
{
    {
        TempPasswordDialog dialog(login, fullName, password, validUntil, parent);
        password.fill(QLatin1Char(' '));
        password.clear();
        dialog.exec();
    }
}

// ============================================================================ PasswordChange

PasswordChangeDialog::PasswordChangeDialog(const QString &login, bool forced, QWidget *parent)
    : QDialog(parent)
    , m_login(login)
{
    QVBoxLayout *layout = dialogLayout(this, QStringLiteral("Смена пароля"),
                                       forced ? QStringLiteral("Задайте свой пароль") : QStringLiteral("Смена пароля"),
                                       QSize(520, 400));
    if (forced)
        layout->addWidget(block(QStringLiteral("Вы вошли с временным паролем. Пока пароль не изменён, работа в "
                                               "программе недоступна."),
                                "warn", this));
    QGridLayout *grid = infoGrid(130);
    auto addRow = [&](int row, const QString &caption, QLineEdit *edit) {
        grid->addWidget(FormKit::caption(caption, this), row, 0);
        edit->setFixedWidth(200);
        grid->addWidget(edit, row, 1, Qt::AlignLeft);
    };
    auto *user = FormKit::readOnlyField(login, this);
    addRow(0, QStringLiteral("Пользователь:"), user);
    m_new = new QLineEdit(this);
    m_new->setEchoMode(QLineEdit::Password);
    addRow(1, QStringLiteral("Новый пароль:"), m_new);
    m_repeat = new QLineEdit(this);
    m_repeat->setEchoMode(QLineEdit::Password);
    addRow(2, QStringLiteral("Повтор пароля:"), m_repeat);
    layout->addLayout(grid);

    auto *rules = new QVBoxLayout;
    rules->setContentsMargins(138, 0, 0, 0);
    rules->setSpacing(3);
    m_ruleLength = new QLabel(this);
    m_ruleLogin = new QLabel(this);
    m_ruleSame = new QLabel(this);
    for (QLabel *l : {m_ruleLength, m_ruleLogin, m_ruleSame})
        rules->addWidget(l);
    layout->addLayout(rules);
    layout->addWidget(FormKit::hint(QStringLiteral("Пароль хранит только СУБД. Проверку правил делает сервер; галочки — "
                                                   "подсказка при вводе."),
                                    this, true));
    layout->addStretch(1);
    auto *buttons = new QHBoxLayout;
    buttons->setSpacing(4);
    buttons->addStretch(1);
    QPushButton *ok = dialogButton(forced ? QStringLiteral("Сохранить и продолжить") : QStringLiteral("Записать"), true, this);
    QPushButton *cancel = dialogButton(forced ? QStringLiteral("Выйти") : QStringLiteral("Отмена"), false, this);
    buttons->addWidget(ok);
    buttons->addWidget(cancel);
    layout->addLayout(buttons);

    connect(m_new, &QLineEdit::textChanged, this, &PasswordChangeDialog::updateRules);
    connect(m_repeat, &QLineEdit::textChanged, this, &PasswordChangeDialog::updateRules);
    connect(ok, &QPushButton::clicked, this, &PasswordChangeDialog::save);
    connect(cancel, &QPushButton::clicked, this, &QDialog::reject);
    updateRules();
    m_new->setFocus();
}

PasswordChangeDialog::~PasswordChangeDialog()
{
    m_new->clear();
    m_repeat->clear();
}

void PasswordChangeDialog::updateRules()
{
    // Подсказка при вводе: ✓ — правило выполнено, ✗ — нет; пока поле пустое — без отметки.
    const QString p = m_new->text();
    auto mark = [](QLabel *label, const QString &text, bool empty, bool ok) {
        label->setText((empty ? QStringLiteral("• ") : ok ? QStringLiteral("✓ ") : QStringLiteral("✗ ")) + text);
        label->setProperty("role", empty ? QStringLiteral("hint") : ok ? QStringLiteral("ok") : QStringLiteral("bad"));
        label->style()->unpolish(label);
        label->style()->polish(label);
    };
    mark(m_ruleLength, QStringLiteral("не короче 8 символов"), p.isEmpty(), p.size() >= 8);
    mark(m_ruleLogin, QStringLiteral("не совпадает с логином"), p.isEmpty(), p.compare(m_login, Qt::CaseInsensitive) != 0);
    mark(m_ruleSame, QStringLiteral("пароли совпадают"), m_repeat->text().isEmpty(), p == m_repeat->text());
}

void PasswordChangeDialog::save()
{
    if (m_new->text() != m_repeat->text()) {
        FormKit::error(this, QStringLiteral("Пароли не совпадают."));
        m_repeat->setFocus();
        return;
    }
    QString error;
    if (!ApiCall::exec(QStringLiteral("change_own_password"), {{QStringLiteral("p_new"), m_new->text()}}, &error)) {
        FormKit::error(this, error);         // текст правила с сервера — как есть
        m_new->setFocus();
        m_new->selectAll();
        return;
    }
    m_new->clear();
    m_repeat->clear();
    accept();
}

void PasswordChangeDialog::showDbaNotice(QWidget *parent)
{
    QMessageBox::information(parent, QStringLiteral("Смена пароля — СуперБД"),
                             QStringLiteral("Администратор базы данных меняет свой пароль не в программе, а командой "
                                            "<b>\\password</b> в psql: она передаёт серверу только хеш пароля."));
}
