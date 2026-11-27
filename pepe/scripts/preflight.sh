#!/bin/bash
# Inventario SO DE LEITURA antes de qualquer hardening. Nao altera nada.
# Uso: sudo preflight.sh
# Serve para decidir o que e seguro mexer: que acessos privados existem, o que esta instalado,
# o que falta e que condicoes do sistema tornam certas medidas perigosas.
set -u
[ "$(id -u)" = 0 ] || { echo "corre com sudo"; exit 1; }
export LC_ALL=C
sec() { printf '\n##### %s\n' "$1"; }

sec "SISTEMA"
. /etc/os-release 2>/dev/null; echo "SO: ${PRETTY_NAME:-?} | kernel: $(uname -r) | virt: $(systemd-detect-virt 2>/dev/null; true) | uptime: $(uptime -p)"
echo "ambiente grafico: $(dpkg -l 2>/dev/null | awk '/^ii +(xfce4|gnome-shell|kde-plasma-desktop|ubuntu-desktop|lightdm|gdm3)( |$)/{print $2}' | tr '\n' ' ')"
echo "disco: $(lsblk -dno NAME,SIZE,TYPE 2>/dev/null | tr '\n' ';') | cifrado(LUKS): $(lsblk -no TYPE 2>/dev/null | grep -c crypt)"

sec "QUEM ESTA LIGADO AGORA (nao cortar estas sessoes)"
ss -Htn state established '( sport = :22 )' 2>/dev/null | awk '{print "ssh ativo de:", $4, "->", $3}'
who 2>/dev/null; echo "ultimos logins:"; last -n 8 -w 2>/dev/null | head -8

sec "ACESSO SSH EFETIVO (sshd -T, inclui drop-ins)"
sshd -T 2>/dev/null | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|allowgroups|denyusers|maxauthtries|allowtcpforwarding|x11forwarding|banner|kexalgorithms|ciphers) ' | cut -c1-140
ls /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/drop-in: /'
echo "authorized_keys: $(find /root /home -maxdepth 3 -name authorized_keys -size +0c 2>/dev/null | tr '\n' ' ')"

sec "SUDO"
grep -rhE 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -v '^#' | sed 's/^/NOPASSWD: /' | head -5

sec "FIREWALL"
ufw status numbered 2>/dev/null | head -40 || echo "ufw ausente"
command -v nft >/dev/null && echo "nft regras: $(nft list ruleset 2>/dev/null | grep -c .)"
echo "iptables regras: $(iptables -S 2>/dev/null | wc -l)"

sec "VPN / ROTEAMENTO / CONTAINERS (medidas que quebram isto: ip_forward=0, rp_filter=1, modules_disabled)"
command -v wg >/dev/null && { wg show 2>/dev/null | grep -E '^(interface|  endpoint|  allowed ips)' | head -20; ip -br addr show type wireguard 2>/dev/null; } || echo "wireguard: ausente"
echo "ip_forward=$(sysctl -n net.ipv4.ip_forward) rp_filter(all)=$(sysctl -n net.ipv4.conf.all.rp_filter) ipv6_forward=$(sysctl -n net.ipv6.conf.all.forwarding)"
command -v docker >/dev/null && echo "docker: presente ($(docker ps -q 2>/dev/null | wc -l) containers a correr)"
command -v lxc >/dev/null && echo "lxd/lxc: presente"
ip -o link 2>/dev/null | grep -i promisc | awk '{print "interface promiscua (sensor/captura?):", $2}'

sec "SERVICOS A OUVIR (o que nao pode deixar de responder)"
ss -tulnp 2>/dev/null | awk 'NR==1 || $5 !~ /^(127\.|\[::1\])/' | awk '{print $1, $5, $7}' | cut -c1-90 | head -40

sec "SERVICOS A CORRER (nao relacionados com o sistema base)"
systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' \
  | grep -Ev '^(systemd-|dbus|getty|user@|polkit|cron|rsyslog|ssh|networkd-dispatcher|unattended|accounts-daemon|udisks2|upower|rtkit|thermald|irqbalance|multipathd|snapd|packagekit|ModemManager|wpa_supplicant|NetworkManager|avahi|colord|cups|switcheroo)' | tr '\n' ' '; echo

sec "FAIL2BAN / AUDITD / APPARMOR"
command -v fail2ban-client >/dev/null && { fail2ban-client status 2>/dev/null | tail -2; grep -hE '^(ignoreip|bantime|maxretry)' /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.local 2>/dev/null | head -6; } || echo "fail2ban: ausente"
command -v auditctl >/dev/null && { echo "auditd: $(auditctl -s 2>/dev/null | grep -E '^enabled')"; ls /etc/audit/rules.d/ 2>/dev/null | tr '\n' ' '; echo; } || echo "auditd: ausente"
command -v aa-status >/dev/null && aa-status 2>/dev/null | head -3 || echo "apparmor-utils: ausente"

sec "PACOTES DE SEGURANCA (instalado / FALTA)"
for p in lynis fail2ban auditd audispd-plugins aide aide-common rkhunter chkrootkit ufw unattended-upgrades apparmor apparmor-utils apparmor-profiles libpam-pwquality acct debsums haveged usbguard needrestart; do
    if dpkg -s "$p" >/dev/null 2>&1; then printf '  [ok]    %s\n' "$p"; else printf '  [FALTA] %s %s\n' "$p" "$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate/{print ($2=="(none)"||$2=="(nenhum)")?"(sem candidato no repositorio)":""}')"; fi
done

sec "ATUALIZACOES PENDENTES (afetam o score: aviso PKGS-7392 custa ~5 pontos)"
echo "atualizaveis: $(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l) | em hold: $(apt-mark showhold | tr '\n' ' ')"
apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1 | tr '\n' ' '; echo
[ -f /var/run/reboot-required ] && echo "REBOOT necessario"

sec "USB / TECLADO (usbguard e usb-storage: nao desligar o que se usa)"
lsusb 2>/dev/null | cut -c1-90
VIRT=$(systemd-detect-virt 2>/dev/null; true)
NUSB=$(lsusb 2>/dev/null | grep -vc 'root hub')
if [ -n "$VIRT" ] && [ "$VIRT" != none ] && [ "${NUSB:-0}" -eq 0 ]; then
    echo "=> VM ($VIRT) sem dispositivos USB: as medidas de USB (usbguard, usb-storage, apply-policy) sao classe B (nao ha teclado/rato USB a bloquear)"
else
    echo "=> maquina fisica ou com dispositivos USB: as medidas de USB sao classe M (uma politica mal feita pode deixar teclado/rato sem funcionar)"
fi

sec "MONTAGENS / CRON"
for m in /boot /tmp /dev/shm /proc; do findmnt -no TARGET,FSTYPE,OPTIONS "$m" 2>/dev/null | cut -c1-100 || true; done
echo "crontabs de utilizador: $(ls /var/spool/cron/crontabs 2>/dev/null | tr '\n' ' ')"
echo; echo "preflight concluido (nada foi alterado)"
