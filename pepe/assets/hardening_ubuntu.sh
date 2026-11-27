#!/bin/bash
# =============================================================================
# Script de Hardening Avançado para Ubuntu Server
# Versão: 3.1 — corrige bugs funcionais da v3.0 (ver notas de correção)
# Uso: sudo ./hardening_ubuntu.sh
#
# ⚠️  ANTES DE CORRER:
#   - Testa numa VM ou tira snapshot antes de aplicar em produção.
#   - As medidas mais "agressivas" (SSH só por chave, password no GRUB,
#     hardening de kernel via GRUB, mounts /tmp noexec, restrição de
#     compiladores, remoção de serviços) estão atrás de variáveis no
#     topo do script, desativadas por omissão. Lê os comentários antes
#     de as ativar — cada uma tem um cenário em que pode partir algo.
#
# NOTAS DE CORREÇÃO (v3.0 -> v3.1):
#   1. O serviço SSH no Ubuntu/Debian chama-se "ssh", não "sshd" (isso é
#      nomenclatura RHEL/CentOS). A v3.0 assumia "sshd" e, com `set -e`,
#      um `systemctl restart sshd` falhado abortava o script a meio.
#      Agora o nome correto é detetado em runtime.
#   2. `set superusers` no GRUB sem `--unrestricted` nas entradas normais
#      pode exigir a password do GRUB para ARRANCAR, não só para editar
#      o menu. Agora o script marca as entradas como --unrestricted.
#   3. pam_faillock precisa também de uma linha em common-account para
#      repor corretamente o contador de tentativas falhadas. Adicionada.
#   4. `aa-enforce /etc/apparmor.d/*` apanhava diretórios (abstractions/,
#      tunables/) como argumentos inválidos. Agora só processa ficheiros.
#   5. `Seal=yes` no journald não faz nada sem `journalctl --setup-keys`.
#      Adicionado. `ForwardToSyslog` passou a configurável (default yes),
#      para não cortar silenciosamente um pipeline rsyslog/SIEM existente.
#   6. `cron.allow` restrito só a root podia quebrar cronjobs de outros
#      utilizadores sem aviso. Agora deteta crontabs existentes e inclui-os.
#   7. `PASS_MAX_DAYS` só afeta utilizadores criados depois. Agora aplica-se
#      também, via chage, aos utilizadores existentes (UID >= 1000).
# =============================================================================
set -e

# --------------------------------------------------------------------------
# CONFIGURAÇÃO — muda para "true" depois de leres o comentário de cada uma.
# --------------------------------------------------------------------------
DISABLE_SSH_PASSWORD_AUTH=false     # só ativa se tiveres chaves SSH configuradas
ENABLE_GRUB_HARDENING=false         # parâmetros de kernel via GRUB (requer reboot)
SET_GRUB_PASSWORD=false             # protege o bootloader com password (pede-a de forma interativa)
RESTRICT_COMPILERS=false            # restringe gcc/cc a root (pode afetar dev tools)
DISABLE_UNCOMMON_FILESYSTEMS=true   # cramfs, freevxfs, jffs2, hfs, hfsplus, udf
HARDEN_TMP_MOUNTS=false             # nodev,nosuid,noexec em /tmp, /var/tmp, /dev/shm — pode partir instaladores
DISABLE_UNUSED_SERVICES=false       # desativa cups/avahi/rpcbind/nfs-server se estiverem ativos (nunca toca em snapd)
FORWARD_JOURNAL_TO_SYSLOG=true      # mantém "yes" no journald; muda para false só se tiveres a certeza que não precisas

echo "=========================================="
echo "  HARDENING AVANÇADO DO UBUNTU SERVER"
echo "=========================================="
echo

# --------------------------------------------------------------------------
# Função auxiliar: define/atualiza uma opção em sshd_config de forma idempotente
# --------------------------------------------------------------------------
set_ssh_option() {
    local key="$1" value="$2"
    if grep -qiE "^\s*${key}\b" /etc/ssh/sshd_config; then
        sed -i -E "s|^\s*${key}\s+.*|${key} ${value}|I" /etc/ssh/sshd_config
    else
        echo "${key} ${value}" >> /etc/ssh/sshd_config
    fi
}

# 1. Deteção de ambiente (container/VM/Docker host) + nome real do serviço SSH
echo "[1/27] A detetar o ambiente de execução..."
IS_CONTAINER=false
if command -v systemd-detect-virt &> /dev/null; then
    VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
    if [[ "$VIRT" =~ ^(lxc|docker|container-other|systemd-nspawn)$ ]]; then
        IS_CONTAINER=true
        echo "   ℹ️  Ambiente containerizado detetado ($VIRT) — passos de GRUB/kernel serão ignorados."
    fi
fi
IS_DOCKER_HOST=false
if command -v docker &> /dev/null || systemctl is-active --quiet docker 2>/dev/null; then
    IS_DOCKER_HOST=true
    echo "   ℹ️  Docker detetado — ip_forward vai manter-se ativo para não partir a rede de containers."
fi

# Nome correto do serviço SSH: "ssh" no Debian/Ubuntu, "sshd" no RHEL/CentOS.
SSH_SERVICE="ssh"
if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd"
elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh"
else
    echo "   ⚠️  Não foi possível confirmar o nome do serviço SSH — a assumir '$SSH_SERVICE'."
fi
echo "   ℹ️  Serviço SSH detetado: $SSH_SERVICE"

# 2. Atualizar sistema
echo "[2/27] A atualizar pacotes..."
sudo add-apt-repository universe -y
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y

# 3. Instalar pacotes de segurança
echo "[3/27] A instalar pacotes de segurança..."
sudo apt install -y \
    fail2ban \
    auditd \
    audispd-plugins \
    aide \
    aide-common \
    rkhunter \
    chkrootkit \
    ufw \
    unattended-upgrades \
    apparmor \
    apparmor-utils \
    apparmor-profiles \
    libpam-pwquality \
    acct \
    debsums \
    haveged \
    lynis

# 4. Políticas de password e bloqueio de conta (PAM)
echo "[4/27] A configurar políticas de password..."
sudo sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 90/' /etc/login.defs
sudo sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS 7/' /etc/login.defs
sudo sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE 14/' /etc/login.defs
sudo sed -i 's/^UMASK.*/UMASK 027/' /etc/login.defs

# NOVO: login.defs só afeta utilizadores criados a partir de agora.
# Aplica a mesma política de expiração aos utilizadores humanos já existentes.
echo "   A aplicar expiração de password a utilizadores existentes (UID >= 1000)..."
for u in $(awk -F: '$3>=1000 && $1!="nobody" {print $1}' /etc/passwd); do
    sudo chage --maxdays 90 --mindays 7 --warndays 14 "$u" 2>/dev/null || true
done

sudo tee /etc/security/pwquality.conf > /dev/null << 'EOF'
minlen = 14
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
minclass = 4
maxrepeat = 3
difok = 4
enforce_for_root
EOF

if [ -f /etc/pam.d/common-auth ] && ! grep -q "pam_faillock.so" /etc/pam.d/common-auth; then
    sudo cp /etc/pam.d/common-auth /etc/pam.d/common-auth.bak.$(date +%F)
    sudo sed -i '/pam_unix.so/i auth required pam_faillock.so preauth silent deny=5 unlock_time=900' /etc/pam.d/common-auth
    sudo sed -i '/pam_unix.so/a auth [default=die] pam_faillock.so authfail deny=5 unlock_time=900' /etc/pam.d/common-auth
fi

# NOVO: falta a entrada em common-account para o faillock repor o contador
# corretamente. Sem isto o deny/unlock_time não funciona como esperado.
if [ -f /etc/pam.d/common-account ] && ! grep -q "pam_faillock.so" /etc/pam.d/common-account; then
    sudo cp /etc/pam.d/common-account /etc/pam.d/common-account.bak.$(date +%F)
    echo "account required pam_faillock.so" | sudo tee -a /etc/pam.d/common-account > /dev/null
fi
echo "   ℹ️  Nota: common-auth/common-account são geridos pelo pam-auth-update."
echo "      Se correres 'pam-auth-update --force' mais tarde, confirma que estas linhas se mantêm."

# 5. Firewall (UFW) com rate-limit no SSH
echo "[5/27] A configurar firewall (UFW)..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 22/tcp   # limit em vez de allow: mitiga brute-force ao nível do firewall
sudo ufw logging on
sudo ufw --force enable
echo "   Firewall ativo, SSH limitado (rate-limited) e logging ligado."

# 6. Ativar serviços
echo "[6/27] A ativar serviços..."
sudo systemctl enable --now fail2ban auditd apparmor acct haveged
sudo systemctl enable --now systemd-timesyncd 2>/dev/null || true

# 7. Configurar sysctl (kernel + rede hardening, expandido)
echo "[7/27] A configurar sysctl..."
sudo tee /etc/sysctl.d/99-hardening.conf > /dev/null << 'EOF'
# --- Segurança de rede (IPv4) ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_local = 0
net.ipv4.conf.all.shared_media = 0
net.ipv4.conf.default.shared_media = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_rfc1337 = 1

# --- Segurança de rede (IPv6) ---
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# --- Segurança do kernel ---
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
kernel.kexec_load_disabled = 1
kernel.perf_event_paranoid = 3
kernel.core_uses_pid = 1
dev.tty.ldisc_autoload = 0
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16

# --- Core dumps ---
fs.suid_dumpable = 0
kernel.core_pattern = |/bin/false

# --- Proteção de ficheiros ---
fs.protected_fifos = 2
fs.protected_regular = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF

# kernel.unprivileged_userns_clone e ip_forward ficam à parte: podem partir
# Docker, Flatpak, snaps com sandboxing (Chromium) ou LXC se aplicados às cegas.
if [ "$IS_DOCKER_HOST" = false ]; then
    sudo tee -a /etc/sysctl.d/99-hardening.conf > /dev/null << 'EOF'
net.ipv4.ip_forward = 0
net.ipv4.conf.all.forwarding = 0
EOF
fi
echo "# kernel.unprivileged_userns_clone = 0  # descomenta manualmente se não usares containers/sandboxing de apps" | sudo tee -a /etc/sysctl.d/99-hardening.conf > /dev/null

sudo sysctl -p /etc/sysctl.d/99-hardening.conf || echo "   ⚠️  Alguns parâmetros não se aplicaram (normal em ambientes containerizados)."

# 8. Hardening do kernel via GRUB (opcional — requer reboot, ignorado em containers)
echo "[8/27] A avaliar hardening do GRUB..."
if [ "$ENABLE_GRUB_HARDENING" = true ] && [ "$IS_CONTAINER" = false ]; then
    sudo cp /etc/default/grub /etc/default/grub.bak.$(date +%F)
    GRUB_PARAMS="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 pti=on randomize_kstack_offset=on vsyscall=none debugfs=off module.sig_enforce=1 lockdown=integrity"
    CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/')
    sudo sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${CURRENT} ${GRUB_PARAMS}\"|" /etc/default/grub
    sudo update-grub
    echo "   ⚠️  Parâmetros de kernel aplicados ao GRUB. Só têm efeito após reiniciar."
else
    echo "   ⏭️  Hardening do GRUB desativado ou ambiente containerizado."
fi

# 9. Password no bootloader GRUB (opcional, interativo, ignorado em containers)
echo "[9/27] A avaliar proteção do GRUB com password..."
if [ "$SET_GRUB_PASSWORD" = true ] && [ "$IS_CONTAINER" = false ]; then
    read -s -p "   Define uma password para o GRUB: " GRUB_PASS; echo
    read -s -p "   Confirma a password: " GRUB_PASS_CONFIRM; echo
    if [ "$GRUB_PASS" != "$GRUB_PASS_CONFIRM" ] || [ -z "$GRUB_PASS" ]; then
        echo "   ⚠️  Passwords não coincidem ou vazias — a saltar proteção do GRUB."
    else
        GRUB_HASH=$(printf '%s\n%s\n' "$GRUB_PASS" "$GRUB_PASS" | grub-mkpasswd-pbkdf2 | grep -oP 'grub\.pbkdf2\.sha512\.\S+')
        sudo tee /etc/grub.d/01_password > /dev/null << EOF
#!/bin/sh
exec tail -n +3 \$0
set superusers="root"
password_pbkdf2 root ${GRUB_HASH}
EOF
        sudo chmod 755 /etc/grub.d/01_password

        # NOVO: sem --unrestricted nas entradas normais, definir "superusers"
        # pode exigir a password do GRUB para ARRANCAR, não só para editar o
        # menu. Marca as entradas geradas pelo 10_linux como --unrestricted
        # para que só a edição/consola fiquem protegidas.
        if [ -f /etc/grub.d/10_linux ] && ! grep -q -- '--unrestricted' /etc/grub.d/10_linux; then
            sudo cp /etc/grub.d/10_linux /etc/grub.d/10_linux.bak.$(date +%F)
            sudo sed -i -E 's/^(CLASS=".*)"$/\1 --unrestricted"/' /etc/grub.d/10_linux
            echo "   ℹ️  Entradas normais de arranque marcadas como --unrestricted (só a edição do menu pede password)."
        fi

        sudo update-grub
        echo "   🔒 Bootloader protegido. A edição do menu e a consola do GRUB vão pedir esta password."
    fi
    unset GRUB_PASS GRUB_PASS_CONFIRM
else
    echo "   ⏭️  Password do GRUB não configurada (SET_GRUB_PASSWORD=false ou ambiente containerizado)."
fi

# 10. Desativar módulos de kernel desnecessários (filesystems legacy + protocolos raros)
echo "[10/27] A desativar módulos de kernel desnecessários..."
if [ "$DISABLE_UNCOMMON_FILESYSTEMS" = true ]; then
    sudo tee /etc/modprobe.d/hardening-filesystems.conf > /dev/null << 'EOF'
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install udf /bin/false
EOF
    echo "   🔒 cramfs, freevxfs, jffs2, hfs, hfsplus, udf desativados."
    echo "   ℹ️  squashfs não foi desativado de propósito: o snapd do Ubuntu depende dele."
else
    echo "   ⏭️  Filesystems legacy não desativados (DISABLE_UNCOMMON_FILESYSTEMS=false)."
fi
sudo tee /etc/modprobe.d/hardening-network-protocols.conf > /dev/null << 'EOF'
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
EOF

# 11. Hardening do SSH (opções + cifras/algoritmos modernos)
echo "[11/27] A configurar SSH..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F)
set_ssh_option "PermitRootLogin" "no"
set_ssh_option "MaxAuthTries" "3"
set_ssh_option "LoginGraceTime" "30"
set_ssh_option "PermitEmptyPasswords" "no"
set_ssh_option "IgnoreRhosts" "yes"
set_ssh_option "HostbasedAuthentication" "no"
set_ssh_option "PermitUserEnvironment" "no"
set_ssh_option "Compression" "no"
set_ssh_option "UseDNS" "no"
set_ssh_option "ClientAliveInterval" "300"
set_ssh_option "ClientAliveCountMax" "2"
set_ssh_option "X11Forwarding" "no"
set_ssh_option "AllowTcpForwarding" "no"
set_ssh_option "LogLevel" "VERBOSE"
set_ssh_option "Banner" "/etc/issue.net"
set_ssh_option "KexAlgorithms" "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512"
set_ssh_option "Ciphers" "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
set_ssh_option "MACs" "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com"

if [ "$DISABLE_SSH_PASSWORD_AUTH" = true ]; then
    if find /root/.ssh /home/*/.ssh -maxdepth 1 -name authorized_keys -size +0c 2>/dev/null | grep -q .; then
        set_ssh_option "PasswordAuthentication" "no"
        set_ssh_option "KbdInteractiveAuthentication" "no"
        echo "   🔒 Autenticação por password SSH desativada (chaves públicas detetadas)."
    else
        echo "   ⚠️  Nenhuma chave pública SSH encontrada — a manter password ativa para evitar bloqueio."
    fi
else
    echo "   ⏭️  Autenticação por password SSH mantida (DISABLE_SSH_PASSWORD_AUTH=false)."
fi

# CORRIGIDO: o serviço chama-se "ssh" no Ubuntu/Debian, não "sshd".
# Usa o nome detetado no passo 1 em vez de assumir "sshd".
sudo sshd -t && sudo systemctl restart "$SSH_SERVICE"

# 12. Banners de aviso + timeout de shell + umask
echo "[12/27] A configurar banners e timeout de sessão..."
sudo tee /etc/issue > /dev/null << 'EOF'
=====================================================
  AVISO - Sistema restrito a utilizadores autorizados
  O acesso não autorizado é crime (Lei n.º 109/2009)
  Todas as atividades são monitorizadas.
=====================================================
EOF
sudo cp /etc/issue /etc/issue.net

sudo tee /etc/profile.d/tmout.sh > /dev/null << 'EOF'
TMOUT=600
readonly TMOUT
export TMOUT
EOF
sudo chmod +x /etc/profile.d/tmout.sh
grep -q "^umask 027" /etc/bash.bashrc || echo "umask 027" | sudo tee -a /etc/bash.bashrc > /dev/null

# 13. Regras de auditoria (auditd)
echo "[13/27] A configurar regras do auditd..."
sudo tee /etc/audit/rules.d/hardening.rules > /dev/null << 'EOF'
-D
-b 8192
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change
-w /etc/localtime -p wa -k time-change
-w /etc/hosts -p wa -k network-changes
-w /etc/issue -p wa -k network-changes
-a always,exit -F arch=b64 -S sethostname,setdomainname -k network-changes
-w /var/log/lastlog -p wa -k logins
-w /var/log/faillog -p wa -k logins
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
-a always,exit -F arch=b64 -S init_module,delete_module -k modules
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-e 2
EOF
sudo augenrules --load 2>/dev/null || true
sudo systemctl restart auditd

# 14. Fail2ban — jail.local dedicado ao SSH
echo "[14/27] A configurar fail2ban..."
sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
sudo systemctl restart fail2ban

# 15. Restringir cron/at a utilizadores autorizados
echo "[15/27] A restringir cron/at..."
sudo rm -f /etc/cron.deny /etc/at.deny

# CORRIGIDO: restringir cegamente a "root" podia quebrar cronjobs de outros
# utilizadores/serviços já existentes. Agora deteta crontabs existentes e
# inclui-os em cron.allow, avisando quais foram mantidos.
EXISTING_CRON_USERS=$(find /var/spool/cron/crontabs -maxdepth 1 -type f 2>/dev/null -printf '%f\n' || true)
{
    echo root
    if [ -n "$EXISTING_CRON_USERS" ]; then
        echo "$EXISTING_CRON_USERS"
    fi
} | sort -u | sudo tee /etc/cron.allow > /dev/null

if [ -n "$EXISTING_CRON_USERS" ]; then
    echo "   ℹ️  Utilizadores com crontab existente mantidos em cron.allow: $(echo "$EXISTING_CRON_USERS" | tr '\n' ' ')"
fi

echo root | sudo tee /etc/at.allow > /dev/null
sudo chmod 600 /etc/cron.allow /etc/at.allow
sudo chown root:root /etc/crontab /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d 2>/dev/null || true
sudo chmod og-rwx /etc/crontab /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d 2>/dev/null || true

# 16. Permissões de ficheiros sensíveis
echo "[16/27] A corrigir permissões de ficheiros sensíveis..."
sudo chmod 640 /etc/shadow /etc/gshadow 2>/dev/null || true
sudo chmod 644 /etc/passwd /etc/group
sudo chmod 600 /etc/crontab
sudo chmod 600 /etc/ssh/sshd_config
sudo chmod 700 /root
[ -f /boot/grub/grub.cfg ] && sudo chmod 600 /boot/grub/grub.cfg
sudo find /home -maxdepth 1 -mindepth 1 -type d -exec chmod 750 {} \; 2>/dev/null || true

# 17. Restringir acesso a compiladores (opcional)
echo "[17/27] A avaliar restrição de compiladores..."
if [ "$RESTRICT_COMPILERS" = true ]; then
    for c in /usr/bin/gcc* /usr/bin/cc /usr/bin/g++* /usr/bin/make; do
        [ -e "$c" ] && sudo chmod o-rx "$c"
    done
    echo "   🔒 Acesso a compiladores restringido a root/grupo."
else
    echo "   ⏭️  Restrição de compiladores desativada (RESTRICT_COMPILERS=false)."
fi

# 18. Hardening de mounts temporários (opcional)
echo "[18/27] A avaliar hardening de /tmp, /var/tmp e /dev/shm..."
if [ "$HARDEN_TMP_MOUNTS" = true ]; then
    sudo cp /etc/fstab /etc/fstab.bak.$(date +%F)
    grep -q "^tmpfs /dev/shm" /etc/fstab || echo "tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0" | sudo tee -a /etc/fstab > /dev/null
    grep -qE "^/tmp\s" /etc/fstab || echo "/tmp /tmp none bind,nodev,nosuid,noexec 0 0" | sudo tee -a /etc/fstab > /dev/null
    grep -qE "^/var/tmp\s" /etc/fstab || echo "/var/tmp /var/tmp none bind,nodev,nosuid,noexec 0 0" | sudo tee -a /etc/fstab > /dev/null
    sudo mount -o remount /dev/shm 2>/dev/null || true
    echo "   🔒 /tmp, /var/tmp e /dev/shm com nodev,nosuid,noexec no fstab (aplicação total após reiniciar)."
    echo "   ⚠️  noexec em /tmp pode partir instaladores ou scripts que corram binários a partir daí."
else
    echo "   ⏭️  Hardening de mounts temporários desativado (HARDEN_TMP_MOUNTS=false)."
fi

# 19. AppArmor em modo enforce
echo "[19/27] A colocar perfis AppArmor em modo enforce..."
# CORRIGIDO: "/etc/apparmor.d/*" incluía diretórios (abstractions/, tunables/,
# local/, disable/, force-complain/) como argumentos inválidos para aa-enforce.
# Agora só processa ficheiros de perfil no topo do diretório.
if command -v aa-enforce &> /dev/null; then
    find /etc/apparmor.d -maxdepth 1 -type f -print0 2>/dev/null | sudo xargs -0 -r aa-enforce 2>/dev/null || true
fi
echo "   ℹ️  Se algum perfil ainda estiver a ser afinado com aa-genprof/aa-logprof,"
echo "      revê com 'aa-status' antes de confiar cegamente neste passo — "
echo "      forçar enforce num perfil incompleto pode bloquear a aplicação."

# 20. Hardening do journald
echo "[20/27] A configurar journald..."
sudo mkdir -p /etc/systemd/journald.conf.d
JOURNALD_FORWARD=$( [ "$FORWARD_JOURNAL_TO_SYSLOG" = true ] && echo yes || echo no )
sudo tee /etc/systemd/journald.conf.d/99-hardening.conf > /dev/null << EOF
[Journal]
Storage=persistent
Compress=yes
Seal=yes
ForwardToSyslog=${JOURNALD_FORWARD}
EOF
sudo systemctl restart systemd-journald

# CORRIGIDO: "Seal=yes" sozinho não ativa a Forward Secure Sealing — são
# precisas as chaves. Gera-as agora (silenciosamente, se ainda não existirem).
sudo journalctl --setup-keys > /dev/null 2>&1 || true
echo "   ℹ️  ForwardToSyslog=${JOURNALD_FORWARD} — se tiveres rsyslog/Wazuh a depender"
echo "      do encaminhamento via syslog, confirma que esta opção corresponde ao que precisas."

# 21. Serviços desnecessários — lista sempre, só desativa se pedido
echo "[21/27] A verificar serviços candidatos a desativação..."
for svc in cups avahi-daemon rpcbind nfs-server; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        if [ "$DISABLE_UNUSED_SERVICES" = true ]; then
            sudo systemctl disable --now "$svc"
            echo "   🔒 $svc desativado."
        else
            echo "   ℹ️  $svc está ativo — revê se é necessário (DISABLE_UNUSED_SERVICES=true desativa-o automaticamente)."
        fi
    fi
done
echo "   ℹ️  snapd nunca é tocado automaticamente — desativá-lo pode partir pacotes Ubuntu que dependem dele."

# 22. Contabilização de processos (acct)
echo "[22/27] A confirmar accounting de processos..."
sudo systemctl enable --now acct 2>/dev/null || true

# 23. Desativar reinício por Ctrl+Alt+Del
echo "[23/27] A desativar Ctrl+Alt+Del..."
sudo systemctl mask ctrl-alt-del.target 2>/dev/null || true

# 24. Configurar AIDE (integridade de ficheiros) + verificação diária
echo "[24/27] A configurar AIDE..."
sudo aideinit 2>/dev/null || echo "   AIDE já estava inicializado."
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null || true
echo "0 5 * * * root /usr/bin/aide.wrapper --check" | sudo tee /etc/cron.d/aide-check > /dev/null
echo "   ⚠️  Lembra-te de copiar /var/lib/aide/aide.db para fora desta máquina."
echo "      Se um atacante ganhar root, pode regenerar a baseline e esconder alterações."

# 25. Atualizar rkhunter + verificação diária
echo "[25/27] A atualizar rkhunter..."
sudo rkhunter --propupd
echo "0 4 * * * root /usr/bin/rkhunter --check --cronjob --report-warnings-only" | sudo tee /etc/cron.d/rkhunter-check > /dev/null

# 26. Configurar unattended-upgrades
echo "[26/27] A configurar atualizações automáticas..."
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# 27. Auditoria final com Lynis
echo "[27/27] A correr auditoria Lynis final..."
if command -v lynis &> /dev/null; then
    sudo lynis audit system --quick
    if [ -f /var/log/lynis-report.dat ]; then
        INDEX=$(grep "hardening_index=" /var/log/lynis-report.dat | cut -d= -f2)
        WARNINGS=$(grep -c "^warning\[\]=" /var/log/lynis-report.dat 2>/dev/null || echo "0")
        SUGGESTIONS=$(grep -c "^suggestion\[\]=" /var/log/lynis-report.dat 2>/dev/null || echo "0")
        echo "   📊 Índice de Hardening Lynis: ${INDEX}%"
        echo "   📋 Warnings: ${WARNINGS} | Suggestions: ${SUGGESTIONS} (ver /var/log/lynis-report.dat)"
    fi
else
    echo "   ⚠️ Lynis não encontrado, salta este passo."
fi

echo
echo "=========================================="
echo "  ✅ HARDENING CONCLUÍDO!"
echo "=========================================="
echo
echo "📋 Verificações recomendadas:"
echo "  - Firewall:   sudo ufw status verbose"
echo "  - Fail2ban:   sudo fail2ban-client status sshd"
echo "  - Auditd:     sudo auditctl -l"
echo "  - AIDE:       sudo aide.wrapper --check"
echo "  - rkhunter:   sudo rkhunter --check"
echo "  - Lynis:      sudo lynis audit system"
echo "  - SSH:        sudo systemctl status ${SSH_SERVICE}"
echo
echo "🔧 Para fechar mais gap até 80%+, revê manualmente:"
echo "  - Ativar DISABLE_SSH_PASSWORD_AUTH=true depois de confirmar chaves SSH"
echo "  - Ativar ENABLE_GRUB_HARDENING=true e SET_GRUB_PASSWORD=true, depois reiniciar"
echo "    (testa o arranque normal sem password antes de confiares nisto em produção)"
echo "  - Ativar HARDEN_TMP_MOUNTS=true se não precisares de executar binários a partir de /tmp"
echo "  - Configurar 2FA para SSH/sudo (pam_google_authenticator ou equivalente)"
echo "  - Rever secção 'Suggestions' do relatório Lynis: /var/log/lynis-report.dat"
echo "  - Copiar a baseline do AIDE (/var/lib/aide/aide.db) para fora desta máquina"
echo "  - Se aplicável, configurar cifragem de disco (LUKS)"
echo
echo "⚠️  Recomenda-se reiniciar o servidor."
