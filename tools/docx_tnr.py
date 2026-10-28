"""Привести все шрифты .docx к Times New Roman (rFonts, темы, таблица шрифтов). Использование: docx_tnr.py in.docx out.docx"""
import re, sys, zipfile
TNR = 'Times New Roman'
def fix_xml(name, x):
    if not name.startswith('word/') or not name.endswith('.xml'):
        return x
    def rf(m):
        return f'<w:rFonts w:ascii="{TNR}" w:hAnsi="{TNR}" w:eastAsia="{TNR}" w:cs="{TNR}"{"/" if m.group(0).endswith("/>") else ""}>'
    x = re.sub(r'<w:rFonts\b[^>]*?/?>', rf, x)
    if name == 'word/fontTable.xml':
        x = re.sub(r'<w:font w:name="(?!Times New Roman")[^"]*">.*?</w:font>', '', x, flags=re.S)
    if name.startswith('word/theme/'):
        x = re.sub(r'(<a:(?:latin|ea|cs) typeface=")[^"]*"', rf'\1{TNR}"', x)
        x = re.sub(r'(<a:font script="[^"]*" typeface=")[^"]*"', rf'\1{TNR}"', x)
    return x
def main(src, dst):
    zi = zipfile.ZipFile(src)
    with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zo:
        for it in zi.infolist():
            data = zi.read(it.filename)
            if it.filename.endswith('.xml') or it.filename.endswith('.rels'):
                data = fix_xml(it.filename, data.decode('utf8')).encode('utf8')
            zo.writestr(it, data)
if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
