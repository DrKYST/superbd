#!/usr/bin/env python3
"""
Отчёт по ЛР 1 — буквально в оформлении образца reports/template_lab.docx.
Меняются только: вариант и данные студента на титульном листе, 6 картинок в таблице
(строки с параметрами из postgresql.auto.conf) и 6 строк пояснений.

  python labs/lab01/build_report.py      ->  labs/lab01/out/lab01.docx
"""
import io
import os

import yaml
from docx import Document
from docx.oxml.ns import qn
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(ROOT, "reports", "template_lab.docx")
OUT = os.path.join(HERE, "out", "lab01.docx")
SHOT = os.path.join(HERE, "screenshots")

STRIPS = [
    "conf_1_shared_buffers.png",
    "conf_2_work_mem.png",
    "conf_3_temp_buffers.png",
    "conf_4_max_prepared_transactions.png",
    "conf_5_max_files_per_process.png",
    "conf_6_track_counts.png",
]
EXPLAIN = [
    "У меня 32 GB RAM и Windows, значит shared_buffers = 512MB",
    "work_mem = 64MB (4,5 GB / (35 запросов × 2 операции) ≈ 64MB)",
    "temp_buffers = 32MB (верхнее значение из рекомендуемых 16–32MB)",
    "max_prepared_transactions = 5 (по умолчанию было 0)",
    "max_files_per_process = 1000 (по умолчанию)",
    "track_counts = on (включён по умолчанию, необходим для autovacuum)",
]

meta = yaml.safe_load(open(os.path.join(ROOT, "reports", "meta.yaml"), encoding="utf-8"))
d = Document(TEMPLATE)
P = d.paragraphs


def set_text(p, text):
    runs = p.runs
    runs[0].text = text
    for r in runs[1:]:
        r._r.getparent().remove(r._r)


# титульный лист
set_text(P[13], f"Вариант {meta['variant_short']}")
set_text(P[22], f"студент гр. {meta['group']}")
P[23].runs[0].text = meta["student"]
set_text(P[25], meta["teacher_senior"])
set_text(P[27], meta["teacher_lab"])

# картинки в таблице: заменить содержимое каждого изображения, подогнать высоту под пропорции
blips = d.tables[0]._tbl.findall(".//" + qn("a:blip"))
assert len(blips) == len(STRIPS), len(blips)
cx_full = None
for blip, name in zip(blips, STRIPS):
    path = os.path.join(SHOT, name)
    part = d.part.related_parts[blip.get(qn("r:embed"))]
    buf = io.BytesIO()
    img = Image.open(path).convert("RGB")
    img.save(buf, format="PNG")
    part._blob = buf.getvalue()
    inline = blip.getparent()
    while inline.tag != qn("wp:inline"):
        inline = inline.getparent()
    extent = inline.find(qn("wp:extent"))
    if cx_full is None:
        cx_full = int(extent.get("cx"))  # ширина первой картинки образца — у всех строк одинаковая
    cx = cx_full
    extent.set("cx", str(cx))
    cy = int(cx * img.height / img.width)
    extent.set("cy", str(cy))
    for ext in inline.iter(qn("a:ext")):
        ext.set("cx", str(cx))
        ext.set("cy", str(cy))

# пояснения (абзацы 65–70 образца)
for p, text in zip(P[65:71], EXPLAIN):
    set_text(p, text)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
d.save(OUT)
print("Готово:", OUT)
