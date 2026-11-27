#!/bin/bash
# Mostra onde o Lynis perde pontos, por teste (maior perda primeiro).
# Formato: perda | ID do teste | pontos obtidos/pontos possiveis
#
# Uso (no servidor):  sudo ./lynis_perdas.sh [/var/log/lynis.log]
#
# Notas:
#  - Le o log da ULTIMA execucao do Lynis (sudo lynis audit system).
#  - Nao correr dois "lynis audit" ao mesmo tempo: misturam o log e dao valores
#    duplicados/falsos. Para medir do zero:  sudo sh -c ': > /var/log/lynis.log'
#    e depois  sudo lynis audit system --quick --no-colors
#  - Cada ponto vale cerca de 0,27 do indice (total ~372 pontos).

LOG="${1:-/var/log/lynis.log}"
REPORT=/var/log/lynis-report.dat

[ -r "$LOG" ] || { echo "sem acesso a $LOG (corre com sudo)"; exit 1; }
pgrep -x lynis >/dev/null && echo "(aviso: ha um lynis a correr; os valores podem estar incompletos)"
echo "log de: $(stat -c %y "$LOG" | cut -c1-19) | $(grep -E '^hardening_index=' "$REPORT" 2>/dev/null)"

awk '
/Performing test ID/ {
    id=$0
    sub(/^.*Performing test ID[[:space:]]+/,"",id)
    sub(/[[:space:]].*$/,"",id)
}
/Hardening: assigned/ && /Currently having/ {
    s=$0
    sub(/^.*Currently having /,"",s)
    split(s,p," ")
    atual=p[1]+0
    maximo=p[5]+0

    ganho=atual-anterior
    possivel=maximo-max_anterior

    if (id=="") id="SEM-ID"

    ganhos[id]+=ganho
    maximos[id]+=possivel
    perdas[id]+=possivel-ganho

    anterior=atual
    max_anterior=maximo
}
END {
    for (id in perdas)
        if (perdas[id]>0)
            printf "%3d | %-12s | %d/%d\n",
            perdas[id],id,ganhos[id],maximos[id]
}' "$LOG" | sort -nr
