"""Чистый шаблон оформления ПЗ (tools/md2docx/templates/pz-template.docx) из образца оформления.

    python tools/md2docx/make_pz_template.py --source "<путь к образцу .docx>"

Образец — прошлая работа студента на другую тему; он хранится вне репозитория (C:\\Users\\DrKYST\\Desktop\\superbd\\образцы\\)
и используется только как образец оформления (правило 9 CLAUDE.md). В шаблон переносится только оформление:
  - стили (styles.xml, numbering.xml, тема, шрифты), параметры страницы и колонтитулы последнего раздела (номер страницы);
  - прямое форматирование образцов элементов подраздела запросов — как именованные стили:
      «ПЗ Текст», «ПЗ Подпись рисунка», «ПЗ Код» (строка кода) и табличный стиль «ПЗ Рамка кода».
Текст, рисунки, объекты, сноски, свойства документа (автор, название, организация) и все разделы, кроме последнего,
удаляются. В конце проверяется, что ни в одной части шаблона не осталось текста, кроме полей номера страницы.
"""
import argparse
import copy
import re
from pathlib import Path

import docx
from docx.enum.style import WD_STYLE_TYPE
from docx.oxml import parse_xml
from docx.oxml.ns import nsdecls, qn

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tools/md2docx/templates/pz-template.docx"

# Прямое форматирование образцов (снято с образца 07.10.2026) — переносится в стили, а не копируется из текста.
RPR_TEXT = ('<w:rPr {ns}><w:color w:val="000000"/><w:szCs w:val="28"/>'
            '<w:shd w:val="clear" w:color="auto" w:fill="FFFFFF"/><w:lang w:val="ru-RU"/></w:rPr>')
RPR_CODE = ('<w:rPr {ns}><w:rFonts w:eastAsia="Courier New" w:cs="Courier New"/><w:color w:val="000000"/>'
            '<w:szCs w:val="28"/><w:shd w:val="clear" w:color="auto" w:fill="FFFFFF"/></w:rPr>')
PPR_CAPTION = '<w:pPr {ns}><w:ind w:firstLine="0"/><w:jc w:val="center"/></w:pPr>'
PPR_CODE = ('<w:pPr {ns}><w:spacing w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/>'
            '<w:jc w:val="left"/></w:pPr>')
TBLPR_CODE = ('<w:tblPr {ns}><w:jc w:val="center"/><w:tblBorders>'
              '<w:top w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
              '<w:left w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
              '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
              '<w:right w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
              '</w:tblBorders></w:tblPr>')


def xml(fragment: str):
    return parse_xml(fragment.format(ns=nsdecls("w")))


def add_paragraph_style(doc, style_id: str, name: str, base, ppr: str | None, rpr: str):
    style = doc.styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
    style.element.set(qn("w:styleId"), style_id)
    style.base_style = base
    style.quick_style = True
    if ppr:
        style.element.append(xml(ppr))
    style.element.append(xml(rpr))
    return style


def clean_body(doc):
    """Оставить в теле только параметры последнего раздела (поля, колонтитулы)."""
    body = doc.element.body
    for el in list(body.iterchildren()):
        if el.tag != qn("w:sectPr"):
            body.remove(el)


def drop_orphan_rels(doc):
    """Убрать связи с рисунками, объектами и колонтитулами удалённых разделов; customXml и миниатюру — тоже."""
    r_ns = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
    used = {v for el in doc.element.iter() for k, v in el.attrib.items() if k.startswith(r_ns)}
    keep = ("styles", "numbering", "settings", "fontTable", "theme", "webSettings", "footnotes", "endnotes")
    rels = doc.part.rels
    for rid in list(rels):
        if rid not in used and not rels[rid].reltype.rsplit("/", 1)[-1].startswith(keep):
            del rels[rid]
    pkg_rels = doc.part.package.rels
    for rid in list(pkg_rels):
        if pkg_rels[rid].reltype.rsplit("/", 1)[-1] in ("thumbnail", "custom-properties"):
            del pkg_rels[rid]


def clear_field_results(doc):
    """Кэш значений полей номера страницы в колонтитулах — пустой (Word пересчитывает при выводе)."""
    for rel in doc.part.rels.values():
        if rel.reltype.endswith(("/header", "/footer")):
            for t in rel.target_part.element.iter(qn("w:t")):
                t.text = ""


def clear_notes(doc):
    """Сноски и концевые сноски: оставить только служебные разделители."""
    for rel in doc.part.rels.values():
        if rel.reltype.endswith(("/footnotes", "/endnotes")):
            part = rel.target_part
            root = parse_xml(part.blob)
            for note in list(root):
                if note.get(qn("w:type")) not in ("separator", "continuationSeparator", "continuationNotice"):
                    root.remove(note)
            part._blob = root.xml.encode("utf-8") if hasattr(root, "xml") else part.blob


def clear_properties(doc):
    cp = doc.core_properties
    cp.author = cp.last_modified_by = cp.title = cp.subject = cp.keywords = cp.comments = cp.category = ""
    cp.content_status = cp.identifier = cp.version = ""
    cp.revision = 1
    settings = doc.settings.element
    for tag in ("w:attachedTemplate", "w:docVars", "w:rsids"):
        for el in settings.findall(qn(tag)):
            settings.remove(el)
    for part in doc.part.package.iter_parts():
        if str(part.partname) == "/docProps/app.xml":
            blob = part.blob.decode("utf-8")
            blob = re.sub(r"<(Company|Manager|Template|HyperlinkBase)>[^<]*</\1>", r"<\1></\1>", blob)
            blob = re.sub(r"<(Pages|Words|Characters|CharactersWithSpaces|Lines|Paragraphs)>\d+</\1>", r"<\1>0</\1>", blob)
            part._blob = blob.encode("utf-8")


def check_no_text(path: Path):
    import zipfile
    leftovers = []
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            if name.endswith(".xml"):
                found = [t for t in re.findall(r"<w:t(?:\s[^>]*)?>([^<]*)</w:t>", z.read(name).decode("utf-8")) if t.strip()]
                if found:
                    leftovers.append(f"{name}: {found[:5]}")
            elif name.startswith("word/media/") or name.startswith("word/embeddings/"):
                leftovers.append(name)
    if leftovers:
        raise SystemExit("В шаблоне остался текст или объекты:\n" + "\n".join(leftovers))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("-o", "--out", type=Path, default=OUT)
    args = ap.parse_args()

    doc = docx.Document(str(args.source))
    normal = doc.styles["Normal"]
    clean_body(doc)
    add_paragraph_style(doc, "PZText", "ПЗ Текст", normal, None, RPR_TEXT)
    add_paragraph_style(doc, "PZCaption", "ПЗ Подпись рисунка", doc.styles["ПЗ Текст"], PPR_CAPTION, RPR_TEXT)
    add_paragraph_style(doc, "PZCode", "ПЗ Код", normal, PPR_CODE, RPR_CODE)
    frame = doc.styles.add_style("ПЗ Рамка кода", WD_STYLE_TYPE.TABLE)
    frame.element.set(qn("w:styleId"), "PZCodeFrame")
    # на основе таблицы по умолчанию (поля ячеек 108 twips, как у образца рамки)
    frame.base_style = next(st for st in doc.styles
                            if st.type == WD_STYLE_TYPE.TABLE and st.element.get(qn("w:default")) == "1")
    frame.element.append(xml(TBLPR_CODE))
    drop_orphan_rels(doc)
    clear_field_results(doc)
    clear_notes(doc)
    clear_properties(doc)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(args.out))
    check_no_text(args.out)
    print(f"Готово: {args.out} ({args.out.stat().st_size // 1024} КБ)")


if __name__ == "__main__":
    main()
