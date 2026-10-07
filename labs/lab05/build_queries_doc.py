"""Подраздел ПЗ «Проектирование запросов к базе данных» (10 запросов ЛР 5) в оформлении раздела 4 старой курсовой.

    python labs/lab05/build_queries_doc.py [--template "Курсовой_проект-новый (2).docx"]
                                          [--section 4.7] [--first-figure 1]
                                          [-o labs/lab05/out/Запросы_ЛР5.docx]

Шаблон — старая курсовая в корне проекта: из неё берутся стили, поля страницы, колонтитулы и образцы
элементов подраздела 4.4 (заголовки 2–4 уровня, абзац, рамка с кодом, подпись рисунка). Тело документа
очищается и собирается заново:
  абзац о запросе → рамка с кодом (фрагмент db/migrations/060_queries_simple.sql) → «Рисунок N – Реализация…»
  → снимок экрана программы (labs/lab05/screenshots/qNN.png) → «Рисунок N – Результат выполнения…».
"""
import argparse
import copy
from pathlib import Path

import docx
from docx.oxml.ns import qn
from docx.shared import Cm
from docx.table import Table
from docx.text.paragraph import Paragraph

ROOT = Path(__file__).resolve().parents[2]
SQL = ROOT / "db/migrations/060_queries_simple.sql"
SHOTS = ROOT / "labs/lab05/screenshots"

# Подписи — формулировки старой курсовой по видам запросов.
KIND = {
    "fk": "с использованием симметричного внутреннего соединения с условием по внешнему ключу",
    "date": "с использованием симметричного внутреннего соединения с условием по датам",
    "plain": "с использованием симметричного внутреннего соединения без условия",
    "left": "с использованием левого внешнего соединения",
    "right": "с использованием правого внешнего соединения",
    "qoq": "на запросе по принципу левого соединения",
}

# (номер, вид, объект api, снимок, ширина снимка в см, описание — текст до ссылки на рисунки)
QUERIES = [
    (1, "fk", "q_provider_staff", "q01.png", 16.5,
     "По коду провайдера запрос находит сотрудников этого провайдера и соединяет их с системными таблицами "
     "PostgreSQL: учётной записью (pg_roles) и членством в группе (pg_auth_members). Возвращает логин, ФИО, "
     "название группы и признак разрешённого входа. Руководитель получает сотрудников только своего провайдера. "
     "Запрос используется на экранах «Провайдеры» (администратор) и «Мой провайдер» (руководитель)."),
    (2, "fk", "q_contract_sessions", "q02.png", 13.0,
     "По коду договора запрос находит его сеансы за период и подтягивает к каждому обозначение и название "
     "тарифа из справочника. Возвращает по строке на сеанс — время начала, тариф, объём, скидку и стоимость, "
     "а также итоги по всему отбору: число сеансов, суммарный объём и стоимость. Запрос используется на экране "
     "«Абоненты» (сеансы выбранного договора за месяц) и на вкладке «Сеансы» карточки договора."),
    (3, "date", "q_sessions", "q03.png", 16.5,
     "За указанный период запрос выбирает сеансы связи и подтягивает к ним номер договора, абонента, IP-адрес "
     "договора и тариф; дополнительно отбирает сеансы по договору, IP-адресу или подсети и тарифу. Возвращает "
     "журнал сеансов со стоимостью и итоги за период. Запрос используется на экране «Сеансы связи»."),
    (4, "date", "q_contracts", "q04.png", 16.5,
     "Запрос выбирает договоры, заключённые в указанном периоде, и подтягивает к ним абонента, тип абонента и "
     "провайдера; дополнительно отбирает договоры одного абонента, только действующие и по началу номера, "
     "наименования или IP-адреса. Возвращает номер, стоимость подключения и 1 Мб, IP-адрес и состояние договора. "
     "Запрос используется на экране «Договоры» и в списке «Договоры абонента» экрана «Абоненты»."),
    (5, "plain", "v_providers", "q05.png", 16.5,
     "К каждому провайдеру запрос подтягивает название типа собственности и города из справочников. Возвращает "
     "по одной строке на провайдера — его поля с расшифровками справочников. Запрос оформлен представлением; "
     "оператор и руководитель видят в нём только своего провайдера. Используется на экране «Мой провайдер», "
     "в списке выбора провайдера и как основа запроса о числе договоров."),
    (6, "plain", "v_subscribers", "q06.png", 12.0,
     "К каждому абоненту запрос подтягивает тип абонента с признаком юридического лица и город. Возвращает "
     "по одной строке на абонента. Реестр абонентов общий для всех провайдеров: оператор и руководитель видят "
     "абонента, если у их провайдера есть с ним договор, главный аналитик и администратор — весь реестр. "
     "Запрос оформлен представлением и используется в карточке абонента и в форме выбора абонента."),
    (7, "plain", "v_contracts", "q07.png", 13.0,
     "К каждому договору запрос подтягивает абонента, тип абонента, провайдера и тип собственности провайдера. "
     "Возвращает полные сведения о договоре с расшифровками и состоянием, адрес подключения и контакты по этому "
     "договору. Оператор видит только договоры своего провайдера. Запрос оформлен представлением и "
     "используется в карточке договора."),
    (8, "left", "q_subscribers", "q08.png", 16.5,
     "К каждому абоненту запрос присоединяет его договоры (если они есть) и считает общее число договоров и "
     "число действующих; считаются только договоры видимых провайдеров. Абоненты без договоров остаются в "
     "результате с нулём — их видит главный аналитик, оператору абонент виден, пока у его провайдера есть с ним "
     "договор (договоры провайдера читаются по индексу, абоненты отбираются полусоединением с ними). Отбор — по типу абонента, наличию действующих договоров, "
     "началу наименования или цифрам телефона в любом написании. Запрос используется в главном списке "
     "экрана «Абоненты»."),
    (9, "right", "q_tariff_usage", "q09.png", 16.5,
     "Подзапрос группирует сеансы указанного периода по тарифу, после чего результат правым соединением "
     "дотягивается до полного списка тарифов — тарифы, по которым сеансов не было, остаются в выводе с нулями. "
     "Возвращает по строке на тариф — число сеансов, суммарный объём и выручку. Запрос используется в отчёте "
     "«Трафик по тарифам» раздела «Статистика»."),
    (10, "qoq", "q_providers", "q10.png", 16.5,
     "Представление провайдеров соединяется слева с подзапросом, который для каждого провайдера считает "
     "действующие договоры и договоры, заключённые в указанном периоде. Провайдеры без договоров остаются в "
     "списке с нулями. Запрос используется на экране «Провайдеры»."),
]

SUBSECTIONS = [
    # (уровень, заголовок, номера запросов под заголовком)
    (3, "Симметричное внутреннее соединение с условием", []),
    (4, "С условием по внешнему ключу", [1, 2]),
    (4, "С условием по датам", [3, 4]),
    (3, "Симметричное внутреннее соединение без условия", [5, 6, 7]),
    (3, "Левое внешнее соединение", [8]),
    (3, "Правое внешнее соединение", [9]),
    (3, "Запрос на запросе по принципу левого соединения", [10]),
]


def extract_code(name: str) -> list[str]:
    """Только сам запрос из 060_queries_simple.sql: SELECT представления (без CREATE VIEW)
    или выборка RETURN QUERY функции (без заголовка, объявлений и проверок)."""
    text = SQL.read_text(encoding="utf-8")
    if name.startswith("v_"):
        head = text.index(f"CREATE OR REPLACE VIEW api.{name}")
        start = text.index("SELECT", head)
    else:
        head = text.index(f"CREATE OR REPLACE FUNCTION api.{name}(")
        start = text.index("SELECT", text.index("RETURN QUERY", head))
    end = text.index(";", start) + 1
    # начало строки с SELECT — чтобы общий отступ снялся у всех строк одинаково
    lines = text[text.rindex("\n", 0, start) + 1:end].splitlines()
    lines = [l.partition("--")[0].rstrip() for l in lines if not l.strip().startswith("--")]
    indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
    return [l[indent:] for l in lines]


class Builder:
    def __init__(self, template: Path):
        self.doc = docx.Document(str(template))
        ps = self.doc.paragraphs
        find = lambda text: next(p for p in ps if p.text.strip().startswith(text))
        self.tpl_h2 = copy.deepcopy(find("4.4 Проектирование запросов")._p)
        self.tpl_h3 = copy.deepcopy(find("4.4.1 Симметричное внутреннее")._p)
        self.tpl_h4 = copy.deepcopy(find("4.4.1.1 С условием по внешнему")._p)
        self.tpl_text = copy.deepcopy(find("По указанному номеру проекта запрос находит сам")._p)
        self.tpl_caption = copy.deepcopy(find("Рисунок 4.9 –")._p)
        body = self.doc.element.body
        tbl = next(el for el in body.iterchildren() if el.tag == qn("w:tbl")
                   and Table(el, self.doc).rows[0].cells[0].text.startswith("SELECT p.LeaderEmployeeID"))
        self.tpl_code = copy.deepcopy(tbl)
        # очистить тело, оставив параметры раздела (поля, колонтитулы)
        for el in list(body.iterchildren()):
            if el.tag != qn("w:sectPr"):
                body.remove(el)
        self.body = body
        self.sectPr = body.find(qn("w:sectPr"))

    def _append(self, el):
        self.sectPr.addprevious(el)
        return el

    @staticmethod
    def _set_text(p_el, text: str, empty: bool = False):
        """Оставить свойства абзаца и формат первого фрагмента, заменить текст."""
        runs = p_el.findall(qn("w:r"))
        rpr = copy.deepcopy(runs[0].find(qn("w:rPr"))) if runs and runs[0].find(qn("w:rPr")) is not None else None
        for child in list(p_el):
            if child.tag != qn("w:pPr"):
                p_el.remove(child)
        if empty:
            return p_el
        r = p_el.makeelement(qn("w:r"), {})
        if rpr is not None:
            r.append(rpr)
        t = r.makeelement(qn("w:t"), {})
        t.text = text
        t.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        r.append(t)
        p_el.append(r)
        return p_el

    def heading(self, level: int, text: str):
        tpl = {2: self.tpl_h2, 3: self.tpl_h3, 4: self.tpl_h4}[level]
        self._append(self._set_text(copy.deepcopy(tpl), text))
        self.empty()

    def text(self, text: str):
        self._append(self._set_text(copy.deepcopy(self.tpl_text), text))

    def empty(self):
        self._append(self._set_text(copy.deepcopy(self.tpl_text), "", empty=True))

    def empty_centered(self):
        self._append(self._set_text(copy.deepcopy(self.tpl_caption), "", empty=True))

    def caption(self, text: str):
        self._append(self._set_text(copy.deepcopy(self.tpl_caption), text))

    def code(self, lines: list[str]):
        tbl = copy.deepcopy(self.tpl_code)
        tc = tbl.find(".//" + qn("w:tc"))
        paras = tc.findall(qn("w:p"))
        tpl_p = copy.deepcopy(paras[0])
        for p in paras:
            tc.remove(p)
        for line in lines:
            tc.append(self._set_text(copy.deepcopy(tpl_p), line.rstrip() or " "))
        self._append(tbl)

    def picture(self, path: Path, width_cm: float):
        p_el = self._set_text(copy.deepcopy(self.tpl_caption), "", empty=True)
        self._append(p_el)
        Paragraph(p_el, self.doc).add_run().add_picture(str(path), width=Cm(width_cm))

    def _drop_orphans(self):
        """Убрать связи основного документа (рисунки, диаграммы, объекты старой курсовой), на которые не ссылается новое тело."""
        r_ns = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
        used = {v for el in self.doc.element.iter() for k, v in el.attrib.items() if k.startswith(r_ns)}
        keep = ("styles", "numbering", "settings", "fontTable", "theme", "webSettings",
                "footnotes", "endnotes", "comments", "customXml", "stylesWithEffects", "glossaryDocument")
        rels = self.doc.part.rels
        for rid in list(rels):
            rel = rels[rid]
            if rid not in used and not rel.reltype.rsplit("/", 1)[-1].startswith(keep):
                del rels[rid]

    def save(self, out: Path):
        self._drop_orphans()
        cp = self.doc.core_properties      # свойства старого файла (автор, название) не переносить
        cp.author = cp.last_modified_by = cp.title = cp.subject = cp.keywords = cp.comments = ""
        out.parent.mkdir(parents=True, exist_ok=True)
        self.doc.save(str(out))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--template", type=Path, default=ROOT / "Курсовой_проект-новый (2).docx")
    ap.add_argument("--section", default="4.7")
    ap.add_argument("--first-figure", type=int, default=1)
    ap.add_argument("-o", "--out", type=Path, default=ROOT / "labs/lab05/out/Запросы_ЛР5.docx")
    args = ap.parse_args()

    b = Builder(args.template)
    sec = args.section
    fig = args.first_figure
    chapter = sec.split(".")[0]
    by_no = {q[0]: q for q in QUERIES}

    b.heading(2, f"{sec} Проектирование запросов к базе данных")
    b.text("Запросы к базе данных спроектированы как источники данных экранов клиентского приложения: для каждого "
           "запроса определены экран, на котором он используется, роли пользователей и параметры отбора. Запросы без "
           "параметров оформлены представлениями схемы api, запросы с параметрами — функциями этой схемы, которые "
           "выполняются с правами владельца, проверяют группу пользователя и ограничивают строки его провайдером. "
           "Функции, возвращающие списки, принимают размер и смещение страницы и возвращают общее число строк "
           "отбора. В подразделе приведены запросы с симметричным внутренним соединением с условием и без условия, "
           "с левым и правым внешним соединением и запрос на запросе. Для каждого запроса приведены текст самого "
           "запроса и экран программы, на котором выводится результат его выполнения. У запросов, оформленных "
           "функциями, приведена только выборка из тела функции; значения, которые в ней используются, вычисляются "
           "один раз при входе в функцию: имена с префиксом p_ — параметры функции, v_scope — массив кодов "
           "провайдеров, данные которых видит пользователь (свой провайдер или все), v_like — шаблон поиска по "
           "началу строки, v_no_like — тот же шаблон в верхнем регистре для номера договора, v_ip_like — шаблон "
           "поиска по IP-адресу (задан, только если ввод начинается с цифры), v_phone_like — шаблон поиска по "
           "цифрам телефона, v_ip — IP-адрес или подсеть из параметра отбора.")
    b.empty()

    n3 = n4 = 0
    for level, title, numbers in SUBSECTIONS:
        if level == 3:
            n3 += 1
            n4 = 0
            b.heading(3, f"{sec}.{n3} {title}")
        else:
            n4 += 1
            b.heading(4, f"{sec}.{n3}.{n4} {title}")
        for no in numbers:
            _, kind, obj, shot, width, descr = by_no[no]
            code_fig, result_fig = fig, fig + 1
            fig += 2
            b.text(f"{descr} Код запроса приведён на рисунке {chapter}.{code_fig}, результат выполнения — "
                   f"на рисунке {chapter}.{result_fig}.")
            b.empty()
            b.code(extract_code(obj))
            b.caption(f"Рисунок {chapter}.{code_fig} – Реализация запроса {KIND[kind]}")
            b.empty_centered()
            b.picture(SHOTS / shot, width)
            b.caption(f"Рисунок {chapter}.{result_fig} – Результат выполнения запроса {KIND[kind]}")
            b.empty()

    b.save(args.out)
    print(f"Готово: {args.out} (рисунки {chapter}.{args.first_figure}–{chapter}.{fig - 1})")


if __name__ == "__main__":
    main()
