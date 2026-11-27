#!/bin/bash
# Guarda o estado dos acessos/servicos e verifica depois de cada alteracao que NADA se perdeu.
#   sudo verificar_acessos.sh --snapshot   grava o estado atual (fazer ANTES da primeira alteracao)
#   sudo verificar_acessos.sh              compara o estado atual com o snapshot
#   sudo verificar_acessos.sh --refresh    regrava o snapshot (so depois de o utilizador aceitar uma mudanca)
# Opcional: $HLOG_DIR/urls.conf com linhas "URL CODIGO_HTTP_ESPERADO" (ex.: "http://127.0.0.1/ 200").
#
# Regra: tudo o que existia no snapshot (servico ativo, porta a ouvir, valor de sysctl de rede,
# interface WireGuard, opcoes SSH de acesso, firewall) tem de continuar igual. Uma linha "PERDIDO"
# nao e necessariamente um erro (pode ser uma mudanca pedida), mas tem de ser explicada ao
# utilizador antes de continuar.
# Codigos de saida: 0 = tudo igual; 1 = algo se perdeu/mudou; 2 = nada se perdeu mas surgiram
# portas PUBLICAS novas (ex.: um pacote arrastou um MTA que ouve em 0.0.0.0:25); 3 = sem snapshot.
set -u
export LC_ALL=C   # sort e comm tem de usar a mesma ordenacao
DIR="${HLOG_DIR:-/root/hardening-log}"
SNAP="$DIR/acessos.snapshot"
[ "$(id -u)" = 0 ] || { echo "corre com sudo"; exit 1; }
mkdir -p "$DIR" && chmod 700 "$DIR"

estado() {
    # servicos a correr, sem os que mudam sozinhos: a pedido (upower, packagekit, fwupd...) e a
    # sincronizacao de hora, que em convidados VirtualBox alterna entre systemd-timesyncd e
    # vboxadd-service (as unidades entram em conflito; arranca uma ou outra). Nao sao acessos.
    systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null \
        | awk '{print $1}' | grep -Ev '^(user@|user-runtime-dir@|getty@|apt-daily|fwupd|packagekit|upower|networkd-dispatcher|vboxadd-service|systemd-(tmpfiles|hostnamed|localed|timedated|timesyncd))' \
        | sed 's/^/svc:/'
    # portas a ouvir (ignora as efemeras >= 32768), com o ALCANCE: "publica" (qualquer interface ou
    # IP de rede) ou "local" (so loopback). Um servico que passe de local a publica, ou uma porta
    # publica nova, e uma regressao de seguranca mesmo que nada se tenha perdido.
    for proto in tcp udp; do
        flag=-tln; [ $proto = udp ] && flag=-uln
        ss -H $flag 2>/dev/null | awk -v pr=$proto '{
            la=$4; n=split(la,a,":"); p=a[n]; addr=substr(la,1,length(la)-length(p)-1);
            if (p+0 >= 32768 || p == "*") next;
            sc=(addr ~ /^127\./ || addr == "[::1]" || addr ~ /^\[?::1\]?$/) ? "local" : "publica";
            print pr ":" p ":" sc }'
    done
    # sysctl que quebram VPN/routing/containers se mudarem
    for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter; do
        v=$(sysctl -n "$k" 2>/dev/null) && echo "sysctl:$k=$v"
    done
    # WireGuard
    command -v wg >/dev/null && wg show interfaces 2>/dev/null | tr ' ' '\n' | grep . | sed 's/^/wg:/'
    # firewall
    command -v ufw >/dev/null && ufw status 2>/dev/null | head -1 | sed 's/^/ufw:/'
    # SSH: validade e opcoes que decidem quem entra
    sshd -t 2>/dev/null && echo "sshd:config-valida"
    sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|allowgroups|denyusers|denygroups|listenaddress) ' | sed 's/^/sshd:/'
    # URLs esperadas
    if [ -f "$DIR/urls.conf" ]; then
        while read -r url code; do
            [ -z "${url:-}" ] && continue
            got=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url")
            echo "url:$url=$got"
        done < "$DIR/urls.conf"
    fi
}

case "${1:-}" in
    --snapshot|--refresh)
        estado | sort -u > "$SNAP"
        echo "snapshot gravado: $SNAP ($(wc -l < "$SNAP") itens)"
        echo "servicos: $(grep -c '^svc:' "$SNAP") | portas: $(grep -cE '^(tcp|udp):' "$SNAP") | wg: $(grep -c '^wg:' "$SNAP")"
        ;;
    "")
        [ -f "$SNAP" ] || { echo "sem snapshot; corre primeiro: $0 --snapshot"; exit 3; }
        NOW=$(mktemp); estado | sort -u > "$NOW"
        LOST=$(comm -23 "$SNAP" "$NOW")
        NEWALL=$(comm -13 "$SNAP" "$NOW")
        NEWPUB=$(echo "$NEWALL" | grep -E '^(tcp|udp):[0-9]+:publica$' || true)
        NEWSVC=$(echo "$NEWALL" | grep -E '^svc:' || true)
        [ -n "$NEWSVC" ] && { echo "servicos novos desde o snapshot (informativo):"; echo "$NEWSVC" | sed 's/^/  * /'; }
        if [ -n "$LOST" ]; then
            echo "PERDIDO / ALTERADO desde o snapshot:"
            echo "$LOST" | sed 's/^/  - /'
            NEW=$(echo "$NEWALL" | grep -E '^(sysctl|sshd|ufw|url):' || true)
            [ -n "$NEW" ] && { echo "valores atuais correspondentes:"; echo "$NEW" | sed 's/^/  + /'; }
            [ -n "$NEWPUB" ] && { echo "NOVAS PORTAS PUBLICAS:"; echo "$NEWPUB" | sed 's/^/  ! /'; }
            rm -f "$NOW"; exit 1
        fi
        if [ -n "$NEWPUB" ]; then
            echo "NOVA SUPERFICIE DE ATAQUE: portas publicas que nao existiam no snapshot (algo foi instalado ou aberto):"
            echo "$NEWPUB" | sed 's/^/  ! /'
            echo "(nada se perdeu, mas confirma se isto e desejado; pacotes novos costumam arrastar servicos, ex.: MTA)"
            rm -f "$NOW"; exit 2
        fi
        echo "ACESSOS OK: nada se perdeu nem se abriu em relacao ao snapshot ($(wc -l < "$SNAP") itens)"
        rm -f "$NOW"; exit 0
        ;;
    *) sed -n 2,6p "$0"; exit 1 ;;
esac
