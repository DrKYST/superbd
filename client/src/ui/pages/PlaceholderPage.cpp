#include "ui/pages/PlaceholderPage.h"

#include <QLabel>
#include <QVBoxLayout>

// Вместо текста-заглушки — рецепт пельменей (по просьбе студента, 2026-10-05).
// Рецепт пересказан по журналу «Т—Ж»: https://t-j.ru/pelmeni/
PlaceholderPage::PlaceholderPage(const QString &title, const QString &screen, QWidget *parent)
    : QWidget(parent)
{
    Q_UNUSED(screen);
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(14, 8, 14, 10);
    layout->setSpacing(7);
    auto *heading = new QLabel(title, this);
    heading->setObjectName(QStringLiteral("formTitle"));
    layout->addWidget(heading);
    auto *recipe = new QLabel(QStringLiteral(
        "<b>Пельмени домашние</b> (около 10 порций, 140–150 штук)<br><br>"
        "<b>Тесто:</b> мука пшеничная — 500 г; молоко — 200 мл; яйца — 2 шт. (около 120 г); "
        "растительное масло — 1 ст. л.; соль — 1 ч. л.<br>"
        "<b>Фарш:</b> свино-говяжий фарш — 500 г; репчатый лук — 1 шт.; чеснок — 2 зубчика; "
        "молоко — 2 ст. л.; зелень — половина пучка; соль и перец — по вкусу.<br><br>"
        "1. Соедините всё для теста и вымешивайте около 5 минут, пока оно не станет гладким.<br>"
        "2. Заверните тесто в плёнку и дайте ему полежать 40 минут.<br>"
        "3. Мелко нарубите лук и зелень, раздавите чеснок, смешайте с фаршем и молоком, посолите и поперчите.<br>"
        "4. Раскатайте тесто тонким пластом (около 1 мм), разложите фарш и слепите пельмени руками или в пельменнице.<br>"
        "5. Опустите пельмени в кипящую подсоленную воду и варите 6 минут после того, как вода снова закипит.<br><br>"
        "Источник: журнал «Т—Ж», t-j.ru/pelmeni"),
                              this);
    recipe->setWordWrap(true);
    recipe->setTextFormat(Qt::RichText);
    layout->addWidget(recipe);
    layout->addStretch(1);
}
