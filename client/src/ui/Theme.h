#pragma once

#include <QColor>

// Цвета, которые нельзя задать через Qt Style Sheets (роли модели, отрисовка ячеек).
// Значения — токены макета docs/ui/mockup/common.css; остальной стиль — только docs/ui/superbd.qss.
namespace Theme {
inline QColor totalRowBackground() { return QColor(0xf2, 0xf2, 0xf2); }   // .g .tr.tot .td
inline QColor okText() { return QColor(0x2c, 0x7a, 0x2c); }               // .okt
inline QColor hintText() { return QColor(0x8a, 0x8a, 0x8a); }             // .ftitle small
constexpr int rowHeight = 22;                                             // .g .td height
}
