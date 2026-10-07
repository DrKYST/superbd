#pragma once

#include <QDialog>
#include <QVariant>

class DataGrid;

// Карточка договора (макет ContractDialog.png): вкладки «Основное / Сеансы / История изменений».
// Сейчас — просмотр: сведения из api.v_contracts (запрос 7), сеансы — api.q_contract_sessions (запрос 2).
// Создание и изменение появятся на этапе CRUD (кнопки записи пока недоступны).
class ContractDialog : public QDialog {
    Q_OBJECT
public:
    ContractDialog(const QVariant &contractId, QWidget *parent = nullptr);

private:
    bool load(const QVariant &contractId);
};
