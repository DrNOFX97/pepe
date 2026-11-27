#!/usr/bin/env python3
"""Gera o relatorio final do Pepe como uma pagina HTML autonoma (sem dependencias externas).

Uso (no alvo, com sudo):  sudo python3 gerar_relatorio.py [saida.html]
Le o que o Lynis e o Pepe ja gravaram: /var/log/lynis-report.dat (ultima medicao),
$HLOG_DIR/scores.tsv (historico por etapa) e a tabela de perdas de lynis_perdas.sh.
Por defeito escreve $HLOG_DIR/relatorio.html (HLOG_DIR=/root/hardening-log).
"""
import html, os, re, subprocess, sys

HLOG = os.environ.get("HLOG_DIR", "/root/hardening-log")
REPORT = "/var/log/lynis-report.dat"
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HLOG, "relatorio.html")
HERE = os.path.dirname(os.path.abspath(__file__))

if os.geteuid() != 0:
    sys.exit("corre com sudo")
rep = open(REPORT, encoding="utf-8", errors="replace").read()
tsv = open(os.path.join(HLOG, "scores.tsv"), encoding="utf-8").read()


def kv(key, default="?"):
    m = re.search(r"^%s=(.*)$" % re.escape(key), rep, re.M)
    return m.group(1).strip() if m else default


index = kv("hardening_index")
if not index.isdigit():
    sys.exit("o ultimo Lynis nao terminou (sem hardening_index); corre lynis_medir.sh primeiro")

# motivos conhecidos para os testes que costumam ficar sem pontos (ver references/catalogo-medidas.md);
# para os outros usa o texto da propria sugestao do Lynis
WHY = {
    "SSH-7408": "Mudar a porta do SSH parte acessos existentes",
    "MALW-3280": "Só reconhece antivírus comerciais",
    "FILE-6310": "/home e /var em partições separadas (reinstalar)",
    "DEB-0510": "Cifra de disco (LUKS): só com reinstalação",
    "LOGG-2154": "Log remoto: precisa de um recetor",
    "HRDN-7220": "Só pontua sem compiladores instalados",
    "FIRE-4508": "Política da cadeia INPUT da tabela security",
    "KRNL-6000": "modules_disabled / ip_forward / rp_filter: podem partir rede ou VPN",
    "FILE-6374": "noexec em /tmp ou /dev: pode partir aplicações",
    "USB-2000": "Desautorizar os root hubs desligava teclado e rato",
    "BOOT-5122": "Password no GRUB (decisão do utilizador)",
    "DEB-0810": "apt-listbugs pode não existir no repositório",
    "FILE-6344": "hidepid no /proc (decisão do utilizador)",
}
SUG = {}
for m in re.finditer(r"^suggestion\[\]=([^|]+)\|([^|]*)\|", rep, re.M):
    SUG.setdefault(m.group(1), m.group(2).strip())

rows = [r.split("\t") for r in tsv.strip().splitlines()[1:] if r.strip()]
stages = []
for r in rows:
    try:
        stages.append((r[1].replace("-", " "), int(r[2]), int(r[3]), int(r[4]), int(r[5])))
    except (ValueError, IndexError):
        continue          # linhas incompletas nunca entram no grafico
if not stages:
    sys.exit("scores.tsv sem medicoes validas")

out = subprocess.run(["bash", os.path.join(HERE, "lynis_perdas.sh")], capture_output=True, text=True).stdout
losses = []
for ln in out.splitlines():
    m = re.match(r"\s*(\d+)\s*\|\s*(\S+)\s*\|\s*(\d+)/(\d+)", ln)
    if m:
        losses.append((int(m.group(1)), m.group(2), m.group(3), m.group(4)))

last_line = re.findall(r"Currently having (\d+) points \(out of (\d+)\)", open("/var/log/lynis.log", errors="replace").read())
pts, mx = (int(last_line[-1][0]), int(last_line[-1][1])) if last_line else (stages[-1][2], stages[-1][3])
warn = len(re.findall(r"^warning\[\]=", rep, re.M))
sugg = len(re.findall(r"^suggestion\[\]=", rep, re.M))
tests = len([t for t in kv("tests_executed", "").split("|") if t])
first_index = stages[0][1]
meta = "ATINGIDA" if int(index) >= 80 else "NAO ATINGIDA"

# ---- grafico (SVG inline): vermelho < 80, ambar 80-89, verde >= 90
H, pad, bw, gap = 250, 86, 62, 28
W = pad + len(stages) * (bw + gap) + 10
def y_of(v): return H - 40 - int((H - 70) * v / 100)
bars = ""
for i, (name, idx, _, _, _) in enumerate(stages):
    x = pad + i * (bw + gap); y = y_of(idx)
    fill = "#2f6f4f" if idx >= 90 else ("#c58b1b" if idx >= 80 else "#b5483a")
    short = html.escape(name if len(name) <= 14 else name[:13] + "…")
    bars += ('<rect x="%d" y="%d" width="%d" height="%d" rx="4" fill="%s"/>'
             '<text x="%d" y="%d" text-anchor="middle" font-size="15" font-weight="700" fill="#1f2933">%d</text>'
             '<text x="%d" y="%d" text-anchor="middle" font-size="11" fill="#52606d">%s</text>'
             % (x, y, bw, H - 40 - y, fill, x + bw // 2, y - 6, idx, x + bw // 2, H - 22, short))
svg = ('<svg viewBox="0 0 %d %d" width="100%%" role="img" aria-label="Score do Lynis por etapa">'
       '<line x1="%d" x2="%d" y1="%d" y2="%d" stroke="#c58b1b" stroke-dasharray="5 4"/>'
       '<text x="2" y="%d" font-size="11" fill="#c58b1b">meta 80</text>'
       '<line x1="%d" x2="%d" y1="%d" y2="%d" stroke="#2f6f4f" stroke-dasharray="5 4"/>'
       '<text x="2" y="%d" font-size="11" fill="#2f6f4f">objetivo 90</text>%s</svg>'
       % (W, H, pad - 14, W - 10, y_of(80), y_of(80), y_of(80) + 4,
          pad - 14, W - 10, y_of(90), y_of(90), y_of(90) + 4, bars))

lost_lynis, lost_table = mx - pts, sum(l[0] for l in losses)
trs = "".join('<tr><td class="mono">%s</td><td class="num">%d</td><td class="num">%s/%s</td><td>%s</td></tr>'
              % (html.escape(t), p, o, m_, html.escape(WHY.get(t) or SUG.get(t, "")))
              for p, t, o, m_ in losses) or '<tr><td colspan="4">Sem perdas por teste.</td></tr>'
score_color = "#2f6f4f" if int(index) >= 90 else ("#c58b1b" if int(index) >= 80 else "#b5483a")

page = """<!doctype html><html lang="pt"><head><meta charset="utf-8"><title>Relatório Lynis · Pepe</title>
<style>
body{margin:0;background:#f4f1ea;color:#1f2933;font:15px/1.45 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:980px;margin:0 auto;padding:30px 28px}
header{display:flex;align-items:center;gap:30px;border-bottom:2px solid #1f2933;padding-bottom:20px}
.score{font-size:92px;font-weight:800;line-height:1;color:%(color)s}.score small{font-size:28px;color:#52606d;font-weight:600}
h1{margin:0 0 6px;font-size:24px}.meta{color:#52606d;font-size:13.5px}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:22px 0}
.k{background:#fff;border:1px solid #d9d2c3;border-radius:8px;padding:12px 14px}.k b{display:block;font-size:24px}.k span{color:#52606d;font-size:12.5px}
h2{font-size:17px;margin:26px 0 8px}section{background:#fff;border:1px solid #d9d2c3;border-radius:8px;padding:16px 18px}
table{width:100%%;border-collapse:collapse;font-size:14px}th{text-align:left;color:#52606d;font-size:12px;text-transform:uppercase;border-bottom:1px solid #d9d2c3;padding:6px 8px}
td{padding:7px 8px;border-bottom:1px solid #eee8da}.num{text-align:right;font-variant-numeric:tabular-nums}.mono{font-family:Consolas,monospace}
footer{margin-top:18px;color:#7b8794;font-size:12px}
</style></head><body><div class="wrap">
<header><div class="score">%(index)s<small>/100</small></div><div>
<h1>Hardening index · Lynis %(ver)s</h1>
<div class="meta">%(os)s · kernel %(kernel)s · host %(host)s<br>Relatório de %(dt)s · skill <b>Pepe</b> · meta de 80: %(meta)s</div></div></header>
<div class="kpis">
<div class="k"><b>%(first)d → %(index)s</b><span>Score inicial → final</span></div>
<div class="k"><b>%(pts)d/%(mx)d</b><span>Pontos obtidos / possíveis</span></div>
<div class="k"><b>%(warn)d</b><span>Avisos (início: %(warn0)d)</span></div>
<div class="k"><b>%(tests)d</b><span>Testes executados · %(sugg)d sugestões</span></div></div>
<h2>Progressão por etapa</h2><section>%(svg)s</section>
<h2>Onde ainda se perdem pontos (Lynis: %(lost)d de %(mx)d · soma da tabela: %(lost_table)d)</h2><section><table>
<tr><th>Teste</th><th class="num">Perda</th><th class="num">Obtido</th><th>Porque fica</th></tr>%(trs)s</table></section>
<footer>Gerado a partir de %(report)s e do histórico scores.tsv. A soma da tabela pode diferir do total do Lynis porque a tabela atribui cada variação ao teste que a precede.</footer>
</div></body></html>""" % dict(
    color=score_color, index=index, ver=html.escape(kv("lynis_version")), os=html.escape(kv("os_fullname")),
    kernel=html.escape(kv("linux_kernel_release")), host=html.escape(kv("hostname")), dt=html.escape(kv("report_datetime_end")),
    meta=meta, first=first_index, pts=pts, mx=mx, warn=warn, warn0=stages[0][4], tests=tests, sugg=sugg, svg=svg,
    lost=lost_lynis, lost_table=lost_table, trs=trs, report=REPORT)

os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    f.write(page)
os.chmod(OUT, 0o644)
print("relatorio escrito em %s | indice %s | %d etapas | %d testes com perdas" % (OUT, index, len(stages), len(losses)))
