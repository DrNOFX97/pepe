#!/bin/bash
# Instala (ou atualiza para) a versao MAIS RECENTE do Lynis em Ubuntu/Debian.
# Uso: sudo instalar_lynis.sh
#
# Porque nao basta "apt install lynis": o repositorio da distribuicao fica meses ou anos atras
# (Ubuntu 24.04 traz 3.0.9, a atual e 3.1.x) e o score muda entre versoes: medir com uma versao
# velha da um numero que nao compara com o de outras maquinas.
#
# Ordem: 1) repositorio oficial da CISOfy (atualiza com o apt); 2) tarball oficial do GitHub
# em /opt/lynis (se o repositorio nao estiver acessivel).
set -u
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 LC_ALL=C
[ "$(id -u)" = 0 ] || { echo "corre com sudo"; exit 1; }
command -v apt-get >/dev/null || { echo "so suporta Ubuntu/Debian (apt)"; exit 1; }

KEY_URL=https://packages.cisofy.com/keys/cisofy-software-public.key
KEYRING=/usr/share/keyrings/cisofy-community.gpg
LIST=/etc/apt/sources.list.d/cisofy-lynis.list
REPO="deb [signed-by=$KEYRING] https://packages.cisofy.com/community/lynis/deb/ stable main"

ver() { lynis --version 2>/dev/null | head -1; }
echo "versao atual: $(ver || true)"; [ -z "$(ver)" ] && echo "(lynis nao instalado)"

via_repo() {
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null 2>&1 || return 1
    curl -fsSL -m 30 "$KEY_URL" | gpg --dearmor --yes -o "$KEYRING" 2>/dev/null || return 1
    [ -s "$KEYRING" ] || return 1
    echo "$REPO" > "$LIST"
    apt-get update -qq >/dev/null 2>&1
    # o candidato tem de vir do repositorio da CISOfy (versao mais alta que a da distro)
    apt-cache policy lynis | grep -q 'packages.cisofy.com' || return 1
    apt-get install -y -qq lynis >/dev/null 2>&1 || return 1
}

via_github() {
    command -v curl >/dev/null || apt-get install -y -qq curl ca-certificates >/dev/null 2>&1
    TAG=$(curl -fsSL -m 30 https://api.github.com/repos/CISOfy/lynis/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [ -n "$TAG" ] || return 1
    T=$(mktemp -d); curl -fsSL -m 120 "https://github.com/CISOfy/lynis/archive/refs/tags/$TAG.tar.gz" -o "$T/l.tgz" || return 1
    rm -rf /opt/lynis && mkdir -p /opt/lynis && tar -xzf "$T/l.tgz" -C /opt/lynis --strip-components=1 || return 1
    chown -R 0:0 /opt/lynis && ln -sf /opt/lynis/lynis /usr/local/bin/lynis && rm -rf "$T"
}

if via_repo; then echo "instalado a partir do repositorio oficial da CISOfy"
elif via_github; then echo "instalado a partir do GitHub (CISOfy/lynis) em /opt/lynis"
else echo "FALHOU: nao consegui instalar o Lynis mais recente (sem rede para packages.cisofy.com e github.com?)"; exit 2; fi

hash -r
echo "versao instalada: $(ver)"
# confirma que e a ultima (o proprio Lynis consulta a CISOfy)
lynis update info 2>/dev/null | grep -iE 'installed|latest|up-to-date|update' | head -4 | sed 's/^ *//'
