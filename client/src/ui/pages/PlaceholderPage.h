#pragma once

#include <QWidget>

// Временная форма для разделов, которые ещё не перенесены из макета: заголовок формы и рецепт пельменей вместо пометки.
// Исчезает по мере реализации экранов (ui-spec.md §2).
class PlaceholderPage : public QWidget {
    Q_OBJECT
public:
    PlaceholderPage(const QString &title, const QString &screen, QWidget *parent = nullptr);
};
