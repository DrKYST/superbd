---
name: lab-report
description: "Собрать отчёт по выполненной лабораторной N в .docx по ГОСТу (титульный лист, тема, задание, пункты отчёта из методички). Вызов: /lab-report 2"
argument-hint: "[номер лабы 2-8]"
disable-model-invocation: true
allowed-tools: Bash(python ${CLAUDE_PROJECT_DIR}/tools/md2docx/md2docx.py *) Bash(python3 ${CLAUDE_PROJECT_DIR}/tools/md2docx/md2docx.py *)
---

# Отчёт по лабораторной работе № $ARGUMENTS

1. Проверь, что ЛР $ARGUMENTS выполнена (`docs/progress.md`, `labs/lab0$ARGUMENTS/README.md`). Если нет — предложи сначала `/lab $ARGUMENTS`.
2. Проверь `reports/meta.yaml`: если там «Фамилия И. О.» / «ПИ-__» — попроси студента заполнить ФИО, группу, преподавателя (один раз).
3. Требования к содержанию — раздел «ЛР $ARGUMENTS → Отчёт» в `docs/task/labs.md`. Отчёт содержит ровно эти пункты в этом порядке.
4. Если `labs/lab0$ARGUMENTS/report.md` нет — скопируй шаблон `tools/md2docx/templates/lab-report.md`, заполни фронтматтер (`lab: $ARGUMENTS`, `topic` — тема из методички). Если есть — обнови, не теряя правок студента.
5. Наполнение:
   - тема, цель, задание — из `docs/task/labs.md`, адаптировано к варианту Б-16;
   - код и таблицы — из реальных файлов (`db/…`, `labs/lab0$ARGUMENTS/…`, EXPLAIN из `explain/`), таблицы полей — по фактической схеме;
   - на каждый скриншот из списка в `labs/lab0$ARGUMENTS/README.md` — рисунок `![…](screenshots/<имя>.png){#fig:…}` со ссылкой в тексте до него;
   - «Выводы» — 3–6 предложений: что сделано и что это даёт курсовой.
   Синтаксис и стиль — `tools/md2docx/README.md` и правило `.claude/rules/reports.md`.
6. Сборка:
   ```bash
   python ${CLAUDE_PROJECT_DIR}/tools/md2docx/md2docx.py labs/lab0$ARGUMENTS/report.md -o labs/lab0$ARGUMENTS/out/lab0$ARGUMENTS.docx
   ```
   Предупреждения скрипта (нет рисунка, неизвестная ссылка) — перечисли студенту.
7. Проверка: если есть LibreOffice — `soffice --headless --convert-to pdf …`, просмотри страницы; убедись, что нумерация рисунков/таблиц сквозная, подписи на месте, нет пустых разделов.
8. Итог студенту: путь к .docx, список недостающих скриншотов (имя файла → что снять), что проверить перед печатью. Обнови `docs/progress.md` (колонка «Отчёт»).
