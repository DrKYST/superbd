"""Концептуальная модель БД в формате draw.io — в оформлении методички ЛР 2.

    python tools/drawio/concept2drawio.py docs/diagrams/concept_model.yaml

Создаёт рядом с YAML файл concept_model.drawio. Стиль — контрастный чёрно-белый:
белая заливка, чёрные линии; заголовок — русское название таблицы (вид таблицы под ним —
только при show_kind: true в YAML),
строки — поля на русском с пометками ПК/ВК (легенда — по желанию, ключ legend в YAML), поля первичного ключа жирным над линией,
связи — ломаные линии с подписями «1» и «∞» (как на рис. 1–2 методички),
пересечения линий — дугой. Трассировка связей задаётся в YAML (via), поэтому
ручные правки раскладки в draw.io затрутся при перегенерации — править координаты в YAML.
"""
import argparse
import html
import zlib
from pathlib import Path

import yaml

HEAD_H_KIND = 38  # заголовок: название + вид таблицы (show_kind: true)
HEAD_H_NAME = 26  # заголовок: только название
HEAD_H = HEAD_H_NAME
ROW_H = 20
SEP_H = 4        # линия под первичным ключом
KEY_W = 30       # колонка ПК/ВК
FONT = "fontFamily=Arial;fontColor=#000000;"
BLACK = "strokeColor=#000000;"


def esc(s: str) -> str:
    return html.escape(str(s), quote=True)


class Page:
    def __init__(self, name: str):
        self.name = name
        self.cells: list[str] = []

    def vertex(self, id_, value, style, x, y, w, h, parent="1"):
        self.cells.append(
            f'<mxCell id="{id_}" value="{esc(value)}" style="{style}" vertex="1" parent="{parent}">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>'
        )

    def edge(self, id_, source, target, style, points):
        pts = "".join(f'<mxPoint x="{x}" y="{y}"/>' for x, y in points)
        self.cells.append(
            f'<mxCell id="{id_}" value="" style="{style}" edge="1" parent="1" '
            f'source="{source}" target="{target}"><mxGeometry relative="1" as="geometry">'
            f'<Array as="points">{pts}</Array></mxGeometry></mxCell>'
        )

    def edge_label(self, id_, parent, text, at, dx, dy):
        self.cells.append(
            f'<mxCell id="{id_}" value="{esc(text)}" style="edgeLabel;html=1;align=center;'
            f'verticalAlign=middle;resizable=0;points=[];fontSize=13;fontStyle=1;'
            f'labelBackgroundColor=#FFFFFF;{FONT}" vertex="1" connectable="0" parent="{parent}">'
            f'<mxGeometry x="{at}" relative="1" as="geometry"><mxPoint x="{dx}" y="{dy}" as="offset"/>'
            f'</mxGeometry></mxCell>'
        )

    def xml(self, page_id: str, w: int, h: int) -> str:
        return (
            f'<diagram id="{page_id}" name="{esc(self.name)}">'
            f'<mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" '
            f'connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{w}" '
            f'pageHeight="{h}" background="#FFFFFF" math="0" shadow="0"><root>'
            '<mxCell id="0"/><mxCell id="1" parent="0"/>'
            f'{"".join(self.cells)}</root></mxGraphModel></diagram>'
        )


def layout(t: dict) -> dict:
    """Вертикальные смещения строк внутри таблицы и её высота."""
    offs, y = {}, HEAD_H
    pk = [r for r in t["rows"] if r[0] == "ПК"]
    rest = [r for r in t["rows"] if r[0] != "ПК"]
    for r in pk:
        offs[r[1]] = y
        y += ROW_H
    sep = None
    if pk:
        sep = y
        y += SEP_H
    for r in rest:
        offs[r[1]] = y
        y += ROW_H
    return {"offs": offs, "height": y, "sep": sep, "order": pk + rest}


def row_id(tid, name):
    return f"r_{tid}_{zlib.crc32(name.encode()):08x}"


def add_table(page: Page, t: dict, lay: dict):
    tid = f"t_{t['id']}"
    x, y = t["pos"]
    w, h = t["width"], lay["height"]
    title = f"<b>{esc(t['title'])}</b>"
    if HEAD_H == HEAD_H_KIND and t.get("kind"):
        title += f"<br><i><font style=\"font-size:10px\">{esc(t['kind'])}</font></i>"
    page.cells.append(
        f'<mxCell id="{tid}" value="{esc(title)}" style="swimlane;html=1;whiteSpace=wrap;'
        f'fontSize=13;fontStyle=0;startSize={HEAD_H};horizontal=1;collapsible=0;'
        f'swimlaneLine=1;fillColor=#FFFFFF;swimlaneFillColor=#FFFFFF;{BLACK}strokeWidth=1.5;{FONT}" '
        f'vertex="1" parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>'
    )
    # вертикальная линия между колонкой ключей и названиями полей
    page.vertex(f"{tid}_vl", "", f"line;direction=south;strokeWidth=1;{BLACK}fillColor=none;html=1;",
                KEY_W - 5, HEAD_H, 10, h - HEAD_H, parent=tid)
    for key, name in lay["order"]:
        oy = lay["offs"][name]
        bold = 1 if key == "ПК" else 0
        # строка на всю ширину: к её краям крепятся линии связей
        page.vertex(row_id(t["id"], name), name,
                    "text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;"
                    f"spacingLeft={KEY_W + 5};spacingRight=4;overflow=hidden;rotatable=0;whiteSpace=wrap;"
                    f"points=[[0,0.5],[1,0.5]];portConstraint=eastwest;fontSize=13;fontStyle={bold};{FONT}",
                    0, oy, w, ROW_H, parent=tid)
        if key:
            page.vertex(f"{row_id(t['id'], name)}_k", key,
                        "text;html=1;strokeColor=none;fillColor=none;align=center;verticalAlign=middle;"
                        f"connectable=0;fontSize=11;fontStyle={bold};{FONT}",
                        0, oy, KEY_W, ROW_H, parent=tid)
    if lay["sep"] is not None:
        page.vertex(f"{tid}_sep", "", f"line;strokeWidth=1;{BLACK}fillColor=none;html=1;",
                    0, lay["sep"], w, SEP_H, parent=tid)


def build(model: dict) -> tuple[Page, int, int]:
    global HEAD_H
    HEAD_H = HEAD_H_KIND if model.get("show_kind", False) else HEAD_H_NAME
    page = Page("Концептуальная модель")
    tabs = {t["id"]: t for t in model["tables"]}
    lays = {t["id"]: layout(t) for t in model["tables"]}
    for t in model["tables"]:
        add_table(page, t, lays[t["id"]])

    for r in model["relations"]:
        p, c = tabs[r["parent"]], tabs[r["child"]]
        prow = r.get("prow") or next(n for k, n in p["rows"] if k == "ПК")
        crow = r["crow"]
        py_ = p["pos"][1] + lays[p["id"]]["offs"][prow] + ROW_H / 2
        cy_ = c["pos"][1] + lays[c["id"]]["offs"][crow] + ROW_H / 2
        via = r["via"]
        p_right = via > p["pos"][0] + p["width"] / 2   # выход справа от родителя
        c_left = via < c["pos"][0] + c["width"] / 2    # вход слева в потомка
        style = (
            "edgeStyle=none;rounded=0;html=1;endArrow=none;startArrow=none;"
            f"{BLACK}strokeWidth=1.3;jumpStyle=arc;jumpSize=10;"
            f"exitX={1 if p_right else 0};exitY=0.5;exitDx=0;exitDy=0;exitPerimeter=0;"
            f"entryX={0 if c_left else 1};entryY=0.5;entryDx=0;entryDy=0;entryPerimeter=0;"
            + ("dashed=1;dashPattern=6 4;" if r.get("dashed") else "")
        )
        eid = f"e_{r['id']}"
        page.edge(eid, row_id(p["id"], prow), row_id(c["id"], crow), style,
                  [(via, py_), (via, cy_)])
        card = r.get("card", ["1", "∞"])
        page.edge_label(f"{eid}_p", eid, card[0], -1, 9 if p_right else -9, -9)
        page.edge_label(f"{eid}_c", eid, card[1], 1, -10 if c_left else 10, -9)

    right = max(max(t["pos"][0] + t["width"] for t in model["tables"]),
                max(r["via"] for r in model["relations"]))
    bottom = max(t["pos"][1] + lays[t["id"]]["height"] for t in model["tables"])
    if model.get("legend"):
        lines = [l for l in model["legend"].strip().splitlines() if l.strip()]
        lh = 18 * len(lines) + 16
        page.vertex("legend", "<br>".join(esc(l) for l in lines),
                    "text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;fontSize=11;"
                    f"{BLACK}dashed=1;fillColor=#FFFFFF;spacing=6;{FONT}",
                    0, bottom + 30, right, lh)
        bottom += 30 + lh
    return page, right + 20, bottom + 20


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model", type=Path)
    args = ap.parse_args()
    model = yaml.safe_load(args.model.read_text(encoding="utf-8"))
    page, w, h = build(model)
    out = args.model.with_suffix(".drawio")
    out.write_text('<mxfile host="superbd-concept2drawio" type="device">'
                   + page.xml("concept", w, h) + "</mxfile>\n", encoding="utf-8")
    print(f"Создан: {out}")


if __name__ == "__main__":
    main()
