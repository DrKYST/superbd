#pragma once

// Обход дефекта пакета MSYS2 mingw-w64-ucrt-x86_64-qxlsx 1.5.1-1: установленный xlsxdocument.h подключает
// xlsxreadsax.h, которого в пакете нет. Нужны только объявления типов для QXlsx::Document::read_sheet_sax
// (потоковое чтение листа); клиент файлы Excel не читает и эти функции не вызывает. Имена и сигнатура совпадают
// с экспортом библиотеки (QXlsx::sax_options, QXlsx::sax_cell, std::function<bool(const sax_cell &)>).
// Когда пакет исправят, файл удаляется вместе со строкой target_include_directories в CMakeLists.txt.

#include <functional>

namespace QXlsx {
struct sax_options;
struct sax_cell;
using sax_cell_callback = std::function<bool(const sax_cell &)>;
} // namespace QXlsx
