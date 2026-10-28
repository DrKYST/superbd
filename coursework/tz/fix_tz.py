import re, sys, os, zipfile
src = sys.argv[1]; out = sys.argv[2]
c = open(f'{src}/content.xml', encoding='utf8').read()
st = open(f'{src}/styles.xml', encoding='utf8').read()

# 1. Описание предметной области: вариант Б-16 вместо А-16 (текст — docs/task/variant.md, дословно из методички)
B16 = ('Для автоматизации учета предоставления услуг связи фирмами-провайдерами Internet необходима '
       'информация о фирмах-провайдерах (название, тип собственности (государственный, частный, ЗАО, ОАО,…), '
       'адрес, телефон, год начала работы), о заключенных с ними договорах (абонент (ФИО или название '
       'предприятия, тип (частное лицо, школа, ВУЗ, предприятие,…), физический адрес, IP-адрес, телефон), '
       'дата подключения, стоимость подключения, стоимость 1 Мб информации) и о сеансах модемной связи '
       '(дата и время сеанса, количество Мб, тариф (бизнес-время — 100% оплата, вечерний тариф — скидка 20%, '
       'ночной тариф — скидка 50%,…)).')
NOTE = 'Примечание: один абонент может заключать несколько договоров.'
i = c.find('кондитерских')
a = c.rfind('<text:list text:style-name="WWNum10">', 0, i)
b = c.find('</text:list>', i) + len('</text:list>')
assert a > 0 and b > a
# номер варианта — текстом, а не автонумерацией списка: при вставке в ПЗ нумерация списка сбрасывается на «1.»
new = (f'<text:p text:style-name="PB16N"><text:span text:style-name="T14">16. {B16}</text:span></text:p>'
       f'<text:p text:style-name="PB16N"><text:span text:style-name="T14">{NOTE}</text:span></text:p>'
       '<text:p text:style-name="P13"/>')
c = c[:a] + new + c[b:]
# стиль абзаца «Примечание»: как P17, без списка
p17 = re.search(r'<style:style style:name="P17".*?</style:style>', c).group(0)
pn = p17.replace('style:name="P17"', 'style:name="PB16N"').replace(' style:list-style-name="WWNum10"', '')
c = c.replace(p17, p17 + pn, 1)
# текст Б-16 длиннее А-16: чтобы титульный лист ТЗ остался на одной странице — одинарный интервал в этом абзаце
c = c.replace(p17, p17.replace('fo:line-height="150%"', 'fo:line-height="100%"'), 1)
c = c.replace(pn, pn.replace('fo:line-height="150%"', 'fo:line-height="100%"'), 1)

# 2. Опечатки шаблона: «х» вместо «ж», латиница в русских словах
fixes = [('рилохен', 'риложен'), ('одерхан', 'одержан'), ('одерхим', 'одержим'), ('озмохност', 'озможност'),
         ('кахд', 'кажд'), ('отобрах', 'отображ'), ('редлохен', 'редложен'), ('рехим', 'режим'),
         ('Eхсеl', 'Excel'), ('ОAО', 'ОАО'), ('ЗAО', 'ЗАО'), ('Aнализ', 'Анализ')]
for f, t in fixes:
    n = c.count(f); c = c.replace(f, t); print(f'{f!r} -> {t!r}: {n}')

# 3. Шрифты: всё — Times New Roman (в том числе маркеры списков)
FONTS = ['Arial', 'Calibri', 'FreeSans', 'FreeSans1', 'Symbol', 'OpenSymbol', 'Times New Roman1', 'Liberation Serif']
def tnr(x):
    for f in FONTS:
        x = re.sub(rf'(style:font-name(?:-asian|-complex)?)="{re.escape(f)}"', r'\1="Times New Roman"', x)
    # все объявления шрифтов — Times New Roman; маркер «-» из шрифта Symbol (U+F02D) — тире
    x = re.sub(r'<style:font-face style:name="([^"]+)"[^>]*/>',
               r'<style:font-face style:name="\1" svg:font-family="&apos;Times New Roman&apos;" style:font-family-generic="roman" style:font-pitch="variable"/>', x)
    x = re.sub(r'(style:font-name(?:-asian|-complex)?)="[^"]*"', r'\1="Times New Roman"', x)
    x = re.sub(r'fo:font-family="[^"]*"', 'fo:font-family="&apos;Times New Roman&apos;"', x)
    x = x.replace('\uf02d', '\u2013')
    return x
c = tnr(c); st = tnr(st)
open(f'{src}/content.xml', 'w', encoding='utf8').write(c)
open(f'{src}/styles.xml', 'w', encoding='utf8').write(st)

# пересобрать ODT: mimetype первым и без сжатия
with zipfile.ZipFile(out, 'w') as z:
    z.write(f'{src}/mimetype', 'mimetype', compress_type=zipfile.ZIP_STORED)
    for root, _, files in os.walk(src):
        for fn in files:
            p = os.path.join(root, fn); rel = os.path.relpath(p, src)
            if rel != 'mimetype': z.write(p, rel, compress_type=zipfile.ZIP_DEFLATED)
print('ok', out)
