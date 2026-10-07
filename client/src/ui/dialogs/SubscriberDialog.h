#pragma once

#include <QDialog>
#include <QVariant>

// Карточка абонента: сведения из api.v_subscribers (запрос 6). Сейчас — просмотр;
// регистрация и изменение абонента появятся на этапе CRUD.
class SubscriberDialog : public QDialog {
    Q_OBJECT
public:
    SubscriberDialog(const QVariant &subscriberId, QWidget *parent = nullptr);

private:
    bool load(const QVariant &subscriberId);
};
