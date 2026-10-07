from pathlib import Path
import json
import re
import html
from reportlab.pdfgen import canvas
from reportlab.pdfbase.pdfdoc import PDFString
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import Paragraph, Spacer, Table, TableStyle, HRFlowable
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name('report-source.md')
LEDGER = {s['id']: s for s in json.loads(Path(__file__).with_name('claim-source-ledger.json').read_text())}
OUT = ROOT / 'output/pdf/linear-apple-design-research.pdf'
QA = ROOT / 'tmp/pdfs'
OUT.parent.mkdir(parents=True, exist_ok=True)
QA.mkdir(parents=True, exist_ok=True)

SHORT = {
    'L01': '2026 interface refresh', 'L02': 'Linear Method', 'L03': 'Design is more than code',
    'L04': 'Settings essay', 'L05': 'Quality essay', 'L06': 'Remote-work practices',
    'L07': 'Design project guidance', 'L08': 'Quality Wednesdays', 'L09': 'Zero-bugs policy',
    'L10': 'Delta sync engineering', 'L11': 'StyleX engineering', 'L12': '2020 menu release',
    'L13': 'January 2023 release', 'L14': 'December 2022 release', 'L15': 'April 2024 editor release',
    'L16': 'June 2026 release', 'L17': 'July 2026 release', 'L18': 'September 2026 release',
    'A01': 'Apple design principles', 'A02': 'Brand identity on iOS', 'A03': 'Apple design system',
    'A04': 'WWDC26 system updates', 'A05': 'Fluid interfaces', 'A06': 'The Life of a Button',
    'A07': 'Audio-haptic design', 'A08': 'Visual accessibility', 'A09': 'Data-rich VoiceOver',
    'A10': 'SwiftUI performance', 'A11': 'Apple Sports, May 2026', 'A12': 'Apple Sports, September 2025',
    'A13': 'Live Activities guidance', 'A14': 'ActivityKit push guidance',
}

INK = colors.HexColor('#182026')
MUTED = colors.HexColor('#56636B')
ACCENT = colors.HexColor('#17646B')
LINE = colors.HexColor('#D6E0E1')
PAPER = colors.HexColor('#FAFCFC')
W, H = 595.2756, 841.8898
X, WIDTH = 45, 505.2756
TOP, BOTTOM = H - 72, 50

def rich(text):
    text = html.escape(text)
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    def citation(m):
        sid = m.group(1)
        s = LEDGER[sid]
        return f'<font color="#17646B" size="8.3">(<link href="{html.escape(s["url"], quote=True)}">{html.escape(SHORT[sid])}</link>)</font>'
    return re.sub(r'\[([LA]\d{2})\]', citation, text)

def styles(size, leading):
    return {
        'body': ParagraphStyle('body', fontName='Helvetica', fontSize=size, leading=leading, textColor=INK, spaceAfter=8),
        'title': ParagraphStyle('title', fontName='Helvetica-Bold', fontSize=31, leading=35, textColor=INK, spaceAfter=13),
        'chapter': ParagraphStyle('chapter', fontName='Helvetica-Bold', fontSize=23, leading=28, textColor=INK, spaceAfter=14),
        'sub': ParagraphStyle('sub', fontName='Helvetica-Bold', fontSize=12.0, leading=15.6, textColor=INK, spaceBefore=9, spaceAfter=5),
        'quote': ParagraphStyle('quote', fontName='Helvetica-Bold', fontSize=13, leading=18, textColor=ACCENT, spaceBefore=4, spaceAfter=13),
        'note': ParagraphStyle('note', fontName='Helvetica', fontSize=8.1, leading=10.6, textColor=MUTED, spaceAfter=3),
        'notes_title': ParagraphStyle('notes_title', fontName='Helvetica-Bold', fontSize=8.1, leading=10, textColor=MUTED, spaceBefore=5, spaceAfter=4),
        'cell': ParagraphStyle('cell', fontName='Helvetica', fontSize=size - .8, leading=leading - 1.7, textColor=INK),
        'cellhead': ParagraphStyle('cellhead', fontName='Helvetica-Bold', fontSize=size - .8, leading=leading - 1.7, textColor=INK),
    }

def page_flows(part, size, leading, first=False):
    s = styles(size, leading)
    flows, refs = [], []
    for match in re.finditer(r'\[([LA]\d{2})\]', part):
        if match.group(1) not in refs:
            refs.append(match.group(1))
    blocks = re.split(r'\n\s*\n', part.strip())
    for block in blocks:
        block = block.strip()
        if block.startswith('|'):
            rows = []
            for idx, line in enumerate(block.splitlines()):
                cells = [c.strip() for c in line.strip().strip('|').split('|')]
                if all(re.fullmatch(r'[-: ]+', c) for c in cells):
                    continue
                style = s['cellhead'] if not rows else s['cell']
                rows.append([Paragraph(rich(c), style) for c in cells])
            table = Table(rows, colWidths=[155, WIDTH - 155], hAlign='LEFT')
            table.setStyle(TableStyle([
                ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#E8EFF0')),
                ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, PAPER]),
                ('VALIGN', (0, 0), (-1, -1), 'TOP'),
                ('LEFTPADDING', (0, 0), (-1, -1), 8),
                ('RIGHTPADDING', (0, 0), (-1, -1), 8),
                ('TOPPADDING', (0, 0), (-1, -1), 7),
                ('BOTTOMPADDING', (0, 0), (-1, -1), 7),
                ('LINEBELOW', (0, 0), (-1, 0), .6, LINE),
                ('LINEBELOW', (0, 1), (-1, -1), .25, LINE),
            ]))
            table.spaceAfter = 10
            flows.append(table)
        elif block.startswith('### '):
            flows.append(Paragraph(rich(block[4:]), s['sub']))
        elif block.startswith('## '):
            if first:
                flows.append(Paragraph(rich(block[3:]), s['quote']))
            else:
                flows.append(Paragraph(rich(block[3:]), s['chapter']))
        elif block.startswith('# '):
            flows.append(Paragraph(rich(block[2:]), s['title']))
        elif block.startswith('> '):
            flows.append(Paragraph(rich(block[2:]), s['quote']))
        else:
            flows.append(Paragraph(rich(' '.join(block.splitlines())), s['body']))
    if refs:
        flows += [Spacer(1, 4), HRFlowable(width='100%', thickness=.5, color=LINE, spaceBefore=2, spaceAfter=1), Paragraph('Source notes', s['notes_title'])]
        for sid in refs:
            r = LEDGER[sid]
            who = r['publisher'] if r['author'] in ('Apple', 'Linear') else r['publisher'] + ', ' + r['author']
            note = f'{html.escape(who)}. <link href="{html.escape(r["url"], quote=True)}" color="#17646B">{html.escape(r["title"])}</link>. {html.escape(r["date"])}.'
            if r['date'].startswith('Undated'):
                note += ' Accessed September 7, 2026.'
            if r['access'].startswith('indexed'):
                note += ' Official indexed excerpt.'
            flows.append(Paragraph(note, s['note']))
    return flows, refs

def measure(flows):
    total = 0
    for f in flows:
        _, h = f.wrap(WIDTH, H)
        total += f.getSpaceBefore() + h + f.getSpaceAfter()
    return total

text = SOURCE.read_text()
parts = text.split('\n---\n')
if set(re.findall(r'\[([LA]\d{2})\]', text)) != set(LEDGER):
    raise ValueError('Source ledger and cited source set differ')

layout = []
for idx, part in enumerate(parts):
    fitted = None
    for size, leading in [(10.7, 15.0), (10.4, 14.6), (10.2, 14.1)]:
        flows, refs = page_flows(part, size, leading, first=idx == 0)
        height = measure(flows)
        if height <= TOP - BOTTOM:
            fitted = (flows, refs, size, leading, height)
            break
    if fitted is None:
        print(f'Page {idx + 1} exceeds available height: {height:.1f} > {TOP - BOTTOM}')
        fitted = (flows, refs, size, leading, height)
    layout.append(fitted)

if any(item[4] > TOP - BOTTOM for item in layout):
    raise ValueError('One or more pages need layout adjustment before export')

c = canvas.Canvas(str(OUT), pagesize=(W, H), pageCompression=1)
c.setTitle('Depth without friction: Linear and Apple design research for a live F1 companion')
c.setAuthor('F1 app research')
c.setSubject('Primary-source research, documented interactions, engineering practices, and proposed product principles')
c.setKeywords('F1, Linear, Apple, design, live coverage, interaction, accessibility, research')
c._doc.Catalog.Lang = PDFString('en-US')
records = []
for idx, (flows, refs, size, leading, height) in enumerate(layout):
    c.setFillColor(colors.white)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    c.setFillColor(ACCENT)
    c.setFont('Helvetica-Bold', 8.1)
    c.drawString(X, H - 40, 'F1 COMPANION  /  DESIGN RESEARCH')
    c.setFillColor(MUTED)
    c.setFont('Helvetica', 8.1)
    c.drawRightString(W - X, H - 40, 'SEPTEMBER 2026')
    c.setStrokeColor(LINE)
    c.setLineWidth(.6)
    c.line(X, H - 54, W - X, H - 54)
    title = re.search(r'^## (.+)', parts[idx], flags=re.M).group(1)
    c.bookmarkPage(f'page-{idx + 1}')
    c.addOutlineEntry(title, f'page-{idx + 1}', level=0, closed=False)
    y = TOP
    for f in flows:
        _, h = f.wrap(WIDTH, H)
        y -= f.getSpaceBefore() + h
        f.drawOn(c, X, y)
        y -= f.getSpaceAfter()
    if y < BOTTOM - .01:
        raise ValueError(f'Content outside frame on page {idx + 1}')
    c.setFillColor(MUTED)
    c.setFont('Helvetica', 8)
    c.drawString(X, 32, 'Depth without friction')
    c.drawRightString(W - X, 32, f'{idx + 1:02d} / {len(parts):02d}')
    records.append({'page': idx + 1, 'title': title, 'body_font_pt': size, 'leading_pt': leading, 'content_height': round(height, 2), 'bottom_y': round(y, 2), 'sources': refs})
    c.showPage()
c.save()

reader = PdfReader(OUT)
extracted = '\n'.join(p.extract_text() for p in reader.pages)
if len(reader.pages) != len(parts):
    raise ValueError('Unexpected page count')
if re.search(r'\[[LA]\d{2}\]', extracted):
    raise ValueError('Unresolved source placeholder')
if '\ufffd' in extracted:
    raise ValueError('Replacement glyph in PDF')
urls = []
for p in reader.pages:
    for a in p.get('/Annots', []):
        action = a.get_object().get('/A', {})
        if action.get('/URI'):
            urls.append(str(action['/URI']))
missing = set(s['url'] for s in LEDGER.values()) - set(urls)
if missing:
    raise ValueError(f'Source hyperlinks missing: {missing}')
(QA / 'report-layout.json').write_text(json.dumps({'pages': records, 'source_count': len(LEDGER), 'hyperlinks': len(urls), 'unique_source_urls': len(set(urls)), 'word_count': len(extracted.split()), 'pdf_bytes': OUT.stat().st_size}, indent=2))
(QA / 'report-extracted.txt').write_text(extracted)
print(json.dumps({'output': str(OUT), 'pages': len(reader.pages), 'sources': len(LEDGER), 'hyperlinks': len(urls), 'words': len(extracted.split()), 'minimum_body_font_pt': min(r['body_font_pt'] for r in records), 'bytes': OUT.stat().st_size}))
