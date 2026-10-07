#pragma once

#include <QColor>

// Цвета, которые нельзя задать через Qt Style Sheets (роли модели, отрисовка ячеек, ряды диаграмм).
// Значения — токены макета docs/ui/mockup/common.css; остальной стиль — только docs/ui/superbd.qss.
namespace Theme {
inline QColor totalRowBackground() { return QColor(0xf2, 0xf2, 0xf2); }   // .g .tr.tot .td
inline QColor okText() { return QColor(0x2c, 0x7a, 0x2c); }               // .okt
inline QColor hintText() { return QColor(0x8a, 0x8a, 0x8a); }             // .ftitle small
inline QColor changedRowBackground() { return QColor(0xff, 0xf3, 0xc4); } // .chg .td (ChangeLog.dc.html)
constexpr int rowHeight = 22;                                             // .g .td height

// Диаграммы отчётов (Stats.dc.html, ui-spec.md §4): ряды #4f81bd, #c0504d, #9bbb59, #8064a2, #bfbfbf;
// дальше — продолжение той же палитры для отчётов с большим числом рядов (типы абонентов).
inline QColor seriesColor(int i)
{
    static const QRgb colors[] = {0x4f81bd, 0xc0504d, 0x9bbb59, 0x8064a2, 0xbfbfbf, 0x4bacc6,
                                  0xf79646, 0x2c4d75, 0x772c2a, 0x5f7530, 0x4d3b62, 0x7f7f7f};
    return QColor(colors[i % int(sizeof(colors) / sizeof(colors[0]))]);
}
// Ряд «Прочие» отчёта долей провайдеров — серый, как в макете Stats_Chief.
inline QColor otherSeriesColor() { return QColor(0xbf, 0xbf, 0xbf); }
inline QColor seriesBorder() { return QColor(0x55, 0x55, 0x55); }        // border: 1px solid #555555
inline QColor chartGrid() { return QColor(0xe3, 0xe3, 0xe3); }           // линии сетки #e3e3e3
inline QColor chartText() { return QColor(0x33, 0x33, 0x33); }
}
