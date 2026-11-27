#!/bin/bash
# Corre o Lynis do zero, regista o score e mostra onde se perdem pontos.
# Uso: sudo lynis_medir.sh "<etiqueta>"     ex.: "baseline", "etapa2-depois"
#
# Porque limpa o log e espera por outro lynis: duas execucoes em simultaneo escrevem no
# mesmo /var/log/lynis.log e dao scores falsos (e perdas duplicadas).
# Registo persistente: $HLOG_DIR/scores.tsv  (defeito /root/hardening-log)
set -u
LABEL="${1:-sem-etiqueta}"
DIR="${HLOG_DIR:-/root/hardening-log}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "corre com sudo"; exit 1; }
command -v lynis >/dev/null || { echo "lynis nao esta instalado: sudo apt-get install -y lynis"; exit 2; }
mkdir -p "$DIR" && chmod 700 "$DIR"

for i in $(seq 1 60); do
    pgrep -x lynis >/dev/null || break
    [ "$i" = 1 ] && echo "ha outro lynis a correr; a esperar (max 5 min)..."
    sleep 5
done
pgrep -x lynis >/dev/null && { echo "outro lynis continua a correr; a abortar para nao misturar logs"; exit 3; }

: > /var/log/lynis.log
lynis audit system --quick --no-colors > "$DIR/lynis-$LABEL.out" 2>&1

REPORT=/var/log/lynis-report.dat
[ -r "$REPORT" ] || { echo "lynis nao gerou $REPORT; ver $DIR/lynis-$LABEL.out"; exit 4; }
INDEX=$(grep -m1 '^hardening_index=' "$REPORT" | cut -d= -f2)
# Sem indice = o Lynis nao chegou ao fim (interrompido, erro, relatorio antigo). Nao registar lixo.
case "$INDEX" in ''|*[!0-9]*) echo "o Lynis nao terminou (sem hardening_index); nada foi registado. Ver $DIR/lynis-$LABEL.out"; exit 5;; esac
LYNVER=$(grep -m1 '^lynis_version=' "$REPORT" | cut -d= -f2)
LAST=$(grep 'Currently having' /var/log/lynis.log | tail -1)
PTS=$(echo "$LAST" | grep -oE 'having [0-9]+' | grep -oE '[0-9]+')
MAX=$(echo "$LAST" | grep -oE 'out of [0-9]+' | grep -oE '[0-9]+')
WARN=$(grep -c '^warning\[\]=' "$REPORT")
SUGG=$(grep -c '^suggestion\[\]=' "$REPORT")
cp "$REPORT" "$DIR/report-$LABEL.dat"

TSV="$DIR/scores.tsv"
[ -f "$TSV" ] || printf 'data\tetiqueta\tindice\tpontos\tmaximo\tavisos\tsugestoes\n' > "$TSV"
PREV=$(tail -n 1 "$TSV" | awk -F'\t' 'NR>0 && $3 ~ /^[0-9]+$/ {print $3}')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$LABEL" "$INDEX" "${PTS:-?}" "${MAX:-?}" "$WARN" "$SUGG" >> "$TSV"

echo "=== Lynis ${LYNVER:-?} [$LABEL] ==="
echo "indice: $INDEX  (pontos ${PTS:-?}/${MAX:-?}, avisos: $WARN, sugestoes: $SUGG)"
if [ -n "${PREV:-}" ]; then echo "anterior: $PREV  ->  variacao: $((INDEX - PREV))"; fi
if [ "$WARN" -gt 0 ]; then echo "--- avisos"; grep '^warning\[\]=' "$REPORT" | cut -d'|' -f1,2 | sed 's/^warning\[\]=//' | sort -u; fi
echo "--- perdas por teste (perda | teste | obtido/possivel)"
if [ -x "$HERE/lynis_perdas.sh" ]; then "$HERE/lynis_perdas.sh" | tail -n +2; else bash "$HERE/lynis_perdas.sh" | tail -n +2; fi
echo "--- historico ($TSV)"
column -t -s "$(printf '\t')" "$TSV" 2>/dev/null || cat "$TSV"
