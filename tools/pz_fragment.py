"""
Участок пояснительной записки отдельным документом — с той же нумерацией рисунков и оформлением, что в ПЗ.

    python tools/pz_fragment.py --from "4.7.4 " --to "4.8 " -o "coursework/out/Запросы_ЛР6.docx"

Берётся готовая coursework/out/pz.docx (сначала собрать: python tools/pzbuild.py); из тела документа
остаются абзацы и таблицы от заголовка, начинающегося с --from, до заголовка, начинающегося с --to (не включая).
Параметры страницы и колонтитул с номером страницы — от основного раздела ПЗ.
"""
import argparse
import os
import subprocess

from docx import Document
from docx.oxml.ns import qn

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def text_of(el):
    return "".join(t.text or "" for t in el.iter(qn("w:t")))


def is_heading(el, prefix):
    """Заголовок раздела, а не строка содержания: строки содержания содержат табуляцию перед номером страницы."""
    return el.tag == qn("w:p") and text_of(el).startswith(prefix) and el.find(".//" + qn("w:tab")) is None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=os.path.join(ROOT, "coursework", "out", "pz.docx"))
    ap.add_argument("--from", dest="start", required=True, help="начало текста первого заголовка участка")
    ap.add_argument("--to", dest="end", required=True, help="начало текста заголовка, перед которым участок кончается")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--pdf", action="store_true", help="также сконвертировать в PDF (LibreOffice)")
    args = ap.parse_args()

    d = Document(args.src)
    body = d.element.body
    items = [el for el in body if el.tag in (qn("w:p"), qn("w:tbl"))]
    start = next(i for i, el in enumerate(items) if is_heading(el, args.start))
    end = next(i for i, el in enumerate(items) if i > start and is_heading(el, args.end))
    for i, el in enumerate(items):
        if not start <= i < end:
            body.remove(el)
    # разрывы разделов внутри участка (если есть) не нужны — остаётся один основной раздел
    for el in body.iter(qn("w:p")):
        ppr = el.find(qn("w:pPr"))
        if ppr is not None and ppr.find(qn("w:sectPr")) is not None:
            ppr.remove(ppr.find(qn("w:sectPr")))
    first = items[start]
    ppr = first.find(qn("w:pPr"))
    if ppr is not None:
        for e in ppr.findall(qn("w:pageBreakBefore")):
            ppr.remove(e)
    d.save(args.out)
    print("Готово:", args.out, f"(элементов: {end - start})")
    if args.pdf:
        subprocess.run(["soffice", "--headless", "--convert-to", "pdf", "--outdir", os.path.dirname(os.path.abspath(args.out)),
                        args.out], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)


if __name__ == "__main__":
    main()
