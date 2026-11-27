#!/bin/bash
# Backup e restauro de ficheiros/pastas de configuracao antes de os alterar.
#   sudo backup.sh <etiqueta> <caminho> [<caminho>...]   cria o backup e imprime a pasta
#   sudo backup.sh --restore <pasta-do-backup>           repoe tudo e apaga o que foi criado de novo
#   sudo backup.sh --list                                lista os backups
# Caminhos que nao existem hoje ficam registados como "absent": no restauro sao apagados,
# porque foram criados pela etapa que se esta a desfazer.
set -u
ROOT="${HLOG_DIR:-/root/hardening-log}/backups"
[ "$(id -u)" = 0 ] || { echo "corre com sudo"; exit 1; }
mkdir -p "$ROOT" && chmod 700 "$ROOT"

case "${1:-}" in
    --list) ls -1d "$ROOT"/*/ 2>/dev/null || echo "sem backups" ;;
    --restore)
        B="${2:-}"; [ -f "$B/MANIFEST" ] || { echo "backup invalido: $B"; exit 1; }
        [ -f "$B/files.tgz" ] && tar -C / -xpzf "$B/files.tgz"
        while IFS=: read -r kind path; do
            [ "$kind" = absent ] && [ -n "$path" ] && rm -rf -- "$path"
        done < "$B/MANIFEST"
        echo "restaurado a partir de $B" ;;
    "" ) sed -n 2,6p "$0"; exit 1 ;;
    *)
        LABEL="$1"; shift
        [ $# -ge 1 ] || { echo "indica pelo menos um caminho"; exit 1; }
        B="$ROOT/$(date +%Y%m%d-%H%M%S)-$LABEL"; mkdir -p "$B"; : > "$B/MANIFEST"
        EXIST=()
        for p in "$@"; do
            if [ -e "$p" ]; then echo "existed:$p" >> "$B/MANIFEST"; EXIST+=("${p#/}")
            else echo "absent:$p" >> "$B/MANIFEST"; fi
        done
        if [ ${#EXIST[@]} -gt 0 ] && ! tar -C / -cpzf "$B/files.tgz" "${EXIST[@]}"; then
            echo "FALHOU o backup (ver erro do tar acima); nao alteres nada desta etapa"; rm -rf "$B"; exit 1
        fi
        chmod -R go-rwx "$B"
        echo "$B" ;;
esac
