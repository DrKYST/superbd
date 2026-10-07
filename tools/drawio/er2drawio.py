"""Генерация ER-диаграммы таблиц в формате draw.io из YAML-описания модели.

    python tools/drawio/er2drawio.py docs/diagrams/er_model.yaml

Создаёт рядом с YAML файл er_logical.drawio. Стиль — контрастный чёрно-белый для печати
на ЧБ-принтере: белая заливка, чёрные линии; заголовок таблицы — русское название,
строки — «Название : тип», строки первичного ключа — жирным, отделены линией.
PNG для отчётов:
  draw.io -x -f png -s 2 -b 10 -o labs/lab02/screenshots/er_logical.png docs/diagrams/er_logical.drawio
"""
import argparse
import html
from pathlib import Path

import yaml

HEAD_H = 30
ROW_H = 24
SEP_H = 8
TABLE_W = 280
FONT = "fontFamily=Arial;fontColor=#000000;"


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def cell_id(*parts: str) -> str:
    return "_".join(p.replace(".", "_") for p in parts)


class Page:
    def __init__(self, name: str):
        self.name = name
        self.cells: list[str] = []

    def vertex(self, id_, value, style, x, y, w, h, parent="1"):
        self.cells.append(
            f'<mxCell id="{id_}" value="{esc(value)}" style="{style}" vertex="1" parent="{parent}">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>'
        )

    def edge(self, id_, source, target, style, value=""):
        self.cells.append(
            f'<mxCell id="{id_}" value="{esc(value)}" style="{style}" edge="1" parent="1" '
            f'source="{source}" target="{target}"><mxGeometry relative="1" as="geometry"/></mxCell>'
        )

    def xml(self, page_id: str) -> str:
        return (
            f'<diagram id="{page_id}" name="{esc(self.name)}">'
            '<mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" '
            'connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="1654" '
            'pageHeight="1169" background="#FFFFFF" math="0" shadow="0"><root>'
            '<mxCell id="0"/><mxCell id="1" parent="0"/>'
            f'{"".join(self.cells)}</root></mxGraphModel></diagram>'
        )


def visible(cols, hidden):
    return [c for c in cols if c[1] not in hidden]


def table_height(cols) -> int:
    has_pk = any("PK" in c[0] for c in cols)
    return HEAD_H + ROW_H * len(cols) + (SEP_H if has_pk else 0)


def add_table(page: Page, t: dict, hidden: set) -> int:
    tid = cell_id("t", t["name"])
    x, y = t["pos"]
    cols = visible(t["cols"], hidden)
    h = table_height(cols)
    page.vertex(
        tid,
        t["title"],
        "swimlane;html=1;fontStyle=1;fontSize=13;childLayout=stackLayout;horizontal=1;"
        f"startSize={HEAD_H};horizontalStack=0;resizeParent=1;resizeParentMax=0;resizeLast=0;"
        "collapsible=0;marginBottom=0;whiteSpace=wrap;swimlaneLine=1;"
        "fillColor=#FFFFFF;swimlaneFillColor=#FFFFFF;strokeColor=#000000;strokeWidth=1.5;" + FONT,
        x, y, TABLE_W, h,
    )
    row_y = HEAD_H
    pk_cols = [c for c in cols if "PK" in c[0]]
    other = [c for c in cols if "PK" not in c[0]]
    for group, bold in ((pk_cols, True), (other, False)):
        for key, col, typ, title in group:
            page.vertex(
                cell_id("c", t["name"], col),
                f"{title} : {typ}",
                "text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;"
                "spacingLeft=8;spacingRight=4;overflow=hidden;rotatable=0;"
                "points=[[0,0.5],[1,0.5]];portConstraint=eastwest;whiteSpace=wrap;fontSize=12;"
                f"fontStyle={1 if bold else 0};" + FONT,
                0, row_y, TABLE_W, ROW_H, parent=tid,
            )
            row_y += ROW_H
        if bold and pk_cols:
            page.vertex(
                cell_id("sep", t["name"]),
                "",
                "line;strokeWidth=1;strokeColor=#000000;fillColor=none;align=left;"
                "verticalAlign=middle;spacingTop=-1;spacingLeft=3;spacingRight=3;"
                "rotatable=0;labelPosition=right;points=[];portConstraint=eastwest;",
                0, row_y, TABLE_W, SEP_H, parent=tid,
            )
            row_y += SEP_H
    return y + h


def build_logical(model: dict) -> Page:
    page = Page("Таблицы базы данных")
    hidden = set(model.get("hide_columns", []))
    bottom = max(add_table(page, t, hidden) for t in model["tables"])
    for r in model["relations"]:
        # Ключ родителя скрыт (hide_columns) — линия ведёт к таблице-родителю целиком.
        pk = r.get("pk", "id")
        target = cell_id("t", r["parent"]) if pk in hidden else cell_id("c", r["parent"], pk)
        page.edge(
            cell_id("e", r["id"]),
            cell_id("c", r["child"], r["fk"]),
            target,
            "edgeStyle=entityRelationEdgeStyle;html=1;rounded=0;strokeColor=#000000;strokeWidth=1.2;"
            "startArrow=ERzeroToMany;startFill=0;startSize=10;endFill=0;endSize=10;"
            f"endArrow={'ERzeroToOne' if r.get('optional') else 'ERmandOne'};",
        )
    lines = [l for l in model["legend"].strip().splitlines() if l.strip()]
    page.vertex(
        "legend",
        "<br>".join(esc(l) for l in lines),
        "text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;fontSize=11;"
        "strokeColor=#000000;dashed=1;fillColor=#FFFFFF;spacing=6;" + FONT,
        40, bottom + 40, 760, 20 * len(lines) + 14,
    )
    return page


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model", type=Path)
    args = ap.parse_args()
    model = yaml.safe_load(args.model.read_text(encoding="utf-8"))
    out = args.model.parent / "er_logical.drawio"
    out.write_text(
        '<mxfile host="superbd-er2drawio" type="device">'
        + build_logical(model).xml("er-logical")
        + "</mxfile>\n",
        encoding="utf-8",
    )
    print(f"Создан: {out}")


if __name__ == "__main__":
    main()
