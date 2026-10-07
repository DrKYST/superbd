#pragma once

#include <QDateTime>
#include <QDialog>

class QLabel;
class QLineEdit;
class QPushButton;

// Сброс пароля (D27), артборды ряда «Сброс пароля» холста ЛР 4 (docs/ui/mockup/*.dc.html).
// Пароли проверяет и хранит только сервер; клиент передаёт их параметрами api.* и нигде не сохраняет.

// «Сбросить пароль?» (ResetConfirm, 500×260): кто, группа и провайдер, последствия; «Сбросить пароль» / «Отмена».
class ResetConfirmDialog : public QDialog {
    Q_OBJECT
public:
    ResetConfirmDialog(const QString &login, const QString &fullName, const QString &groupTitle,
                       const QString &providerName, QWidget *parent = nullptr);
};

// «Временный пароль» (TempPassword, 540×360): пароль показан один раз моноширинным шрифтом, «Копировать» —
// в буфер обмена. При закрытии текст пароля стирается из окна; копии нигде не остаются.
class TempPasswordDialog : public QDialog {
    Q_OBJECT
public:
    TempPasswordDialog(const QString &login, const QString &fullName, QString password, const QDateTime &validUntil,
                       QWidget *parent = nullptr);
    ~TempPasswordDialog() override;

    // Показать окно и забыть пароль: строка затирается и очищается.
    static void showOnce(QWidget *parent, const QString &login, const QString &fullName, QString &password,
                         const QDateTime &validUntil);

private:
    QLabel *m_password;
};

// «Смена пароля» (PasswordChange, 520×400). forced — после входа с временным паролем: предупреждение,
// «Сохранить и продолжить» / «Выйти»; иначе — по ссылке «Сменить пароль»: «Записать» / «Отмена».
// Галочки правил — подсказка при вводе; правила проверяет сервер (api.change_own_password), его текст ошибки
// показывается как есть. Совпадение двух полей — проверка ввода, она на клиенте.
class PasswordChangeDialog : public QDialog {
    Q_OBJECT
public:
    PasswordChangeDialog(const QString &login, bool forced, QWidget *parent = nullptr);
    ~PasswordChangeDialog() override;

    // Администратор БД меняет пароль командой \password в psql (у приложения нет права на его роль, D26/D27).
    static void showDbaNotice(QWidget *parent);

private:
    void updateRules();
    void save();

    QString m_login;
    QLineEdit *m_new;
    QLineEdit *m_repeat;
    QLabel *m_ruleLength;
    QLabel *m_ruleLogin;
    QLabel *m_ruleSame;
};
