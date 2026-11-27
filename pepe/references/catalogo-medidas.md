# Catálogo de medidas de hardening (Ubuntu/Debian) com classe de risco

Origem: o script avançado `scripts/hardening_ubuntu.sh` + o que se aprendeu a aplicá-lo num
servidor real (sensor Suricata/Zeek/Arkime com VPN WireGuard, Lynis 76 → 92). **O script serve de
lista de medidas, não de instalador**: cada linha abaixo diz quando se aplica, o que verificar
antes e como desfazer. Antes de qualquer medida, confirma o estado atual — muitas já estão feitas.

Legenda: **B** = baixo risco, aplica sem perguntar (com backup + verificação). **M** = médio,
planeia e pede confirmação avisando dos riscos. **R** = "de raiz": muda a base do sistema ou pode
cortar o acesso; confirma SEMPRE, mesmo que pareça simples. A coluna *Teste* é o ID do Lynis que
sobe.

## B — baixo risco

| Medida | Teste | Antes de aplicar | Desfazer |
|---|---|---|---|
| Instalar ferramentas em falta: `aide aide-common rkhunter chkrootkit debsums acct auditd apparmor-utils apparmor-profiles libpam-pwquality unattended-upgrades needrestart` (o Lynis vem de `instalar_lynis.sh`) | vários | `preflight.sh` mostra `[FALTA]`; confirma que o pacote tem candidato no repositório. **Instala com `--no-install-recommends`**: o `aide` arrasta o **Postfix** (porta 25 em todas as interfaces) e outros pacotes trazem serviços. Corre `verificar_acessos.sh` logo a seguir (código 2 = porta pública nova). Se já entrou: `postconf -e 'inet_interfaces = loopback-only'` ou remove-o. **`fail2ban` fica para a classe M**: instalado, ativa-se logo e pode banir o teu IP | `apt-get purge` |
| `aideinit` (base de dados do AIDE; resolve o aviso FINT-4316) | FINT-4316 | pesado em disco/CPU (minutos): corre em segundo plano e espera antes de medir o Lynis | apagar `/var/lib/aide/aide.db*` |
| `debsums` semanal (`CRON_CHECK=weekly` em `/etc/default/debsums`) | PKGS-7370 | — | restaurar o ficheiro |
| Banners `/etc/issue` e `/etc/issue.net` | BANN-7126/7130 | **O Lynis procura palavras-chave legais em inglês e pede 5 ou mais** (`authorized`, `unauthorized`, `prohibited`, `monitored`, `legal action`…). Um banner só em português ganha 0 pontos. Escreve o texto em inglês (podes juntar uma linha na língua local), ex.: *Authorized access only. Unauthorized use is prohibited and may be subject to legal action. Activity may be monitored and logged. Violators will be prosecuted.* | restaurar do backup |
| Desativar filesystems legacy (`install cramfs /bin/false` etc. para cramfs freevxfs hfs hfsplus jffs2 udf) em `/etc/modprobe.d/` | FILE-6430 | `lsmod` não os mostra. **Não** desativar `squashfs` (snaps) | apagar o ficheiro |
| Desativar protocolos raros (dccp sctp rds tipc) | NETW-3200 | `ss -S` / `lsmod`: ninguém os usa (SCTP em telecom/VoIP!) | apagar o ficheiro |
| Core dumps off: `/etc/systemd/coredump.conf.d/*.conf` (`Storage=none`, `ProcessSizeMax=0`), `* hard core 0` em `limits.d`, `ulimit -c 0` em `/etc/profile.d/`. Troca `hard core infinity` por `0` nos ficheiros de `limits.d` que o tenham | KRNL-5820 | nenhum serviço de diagnóstico depende de cores. **No Ubuntu, desativa também o `apport`** (`enabled=0` em `/etc/default/apport` + `systemctl disable --now apport`): arranca ~7 s depois do `systemd-sysctl`, repõe `fs.suid_dumpable=2` e canaliza o `core_pattern` para si, desfazendo isto e o `sysctl` seguro em cada arranque. Confirma com um reinício | apagar/restaurar; reativar o apport |
| sysctl seguros (ficheiro novo `99-zz-*.conf`, nunca editar os existentes): `kernel.sysrq=0`, `fs.suid_dumpable=0`, `kernel.dmesg_restrict=1`, `kernel.kptr_restrict=2`, `kernel.unprivileged_bpf_disabled=1`, `fs.protected_{fifos,regular,hardlinks,symlinks}`, `net.ipv4.conf.*.{accept_redirects,send_redirects,accept_source_route}=0`, `tcp_syncookies=1`, `log_martians=1` | KRNL-6000 | **Se o UFW estiver ativo, `log_martians` é reposto a 0 por `/etc/ufw/sysctl.conf`**: corrige lá. `send_redirects=0` só se a máquina não for router | apagar o ficheiro |
| `FAILLOG_ENAB yes` em `/etc/login.defs` | AUTH-9408 | — | backup |
| `SHA_CRYPT_{MIN,MAX}_ROUNDS` | AUTH-9230 | só tem efeito em hashes sha-crypt | backup |
| AIDE com checksums explícitos (`Checksums = sha256+sha512`) em `/etc/aide/aide.conf`; validar com `aide --config-check` | FINT-4402 | a base de dados existente continua válida | backup |
| Whitelist no Lynis de achados **justificados** em `/etc/lynis/custom.prf` (ex.: `if_promisc:<iface>:` para sensores de captura) | NETW-3015 | só quando o motivo é real e é dito ao utilizador; nunca para esconder um problema | apagar a linha |
| `ctrl-alt-del.target` mascarado | — | — | `systemctl unmask` |
| `TMOUT=900` + `readonly` em `/etc/profile.d/*.sh` | SHLL-6220 | só afeta shells interativas de login; avisa que sessões SSH paradas 15 min fecham | apagar o ficheiro |
| Bloquear `usb-storage` (`install usb-storage /bin/false`) | USB-1000 | numa máquina física, **pergunta uma vez** se usam pens/discos USB. **Numa VM sem USB** (o `preflight.sh` di-lo: `systemd-detect-virt` ≠ `none` e `lsusb` sem dispositivos) aplica sem perguntar | apagar o ficheiro |
| **USBGuard numa VM sem USB** (`apt-get install --no-install-recommends usbguard`, `usbguard generate-policy`, `PresentControllerPolicy=apply-policy`, `enable --now`) | USB-3000, USB-2000 | Sem teclado/rato USB não há nada que bloquear: **classe B, sem confirmação e sem cautelas** (decisão do utilizador). Só em VM *sem* dispositivos USB; numa máquina física vê a linha M abaixo | `systemctl disable --now usbguard`; `apt-get purge usbguard` |
| `journald` persistente | — | manter `ForwardToSyslog=yes` se houver rsyslog/SIEM | apagar o drop-in |
| Permissões: `/etc/shadow` 640, `/etc/gshadow` 640, `/root` 700, `grub.cfg` 600, `/etc/crontab` 600 | FILE-* | — | backup |

## M — médio risco (planeia, confirma, avisa)

| Medida | Risco a explicar | Como mitigar |
|---|---|---|
| `apt-get upgrade` (atualizações de segurança) | reinicia serviços (Apache…) e usa libs novas; serviços de captura/tráfego ficam com a lib antiga até serem reiniciados (`needrestart`) | listar o que sobe; respeitar `apt-mark showhold`; `--force-confold`; backup de `/etc/<serviço>` |
| `fail2ban` (instalar/ativar/`jail.local`) | pode banir o próprio administrador, colegas ou o scanner de testes | **nunca sobrescrever** `jail.local`: merge e `ignoreip` com os IPs/redes do snapshot de acessos |
| UFW (regras novas, `limit`) | o script faz `ufw limit 22/tcp` de qualquer origem: se o SSH estava restrito, **alarga** o acesso. O `limit` também bloqueia 6 ligações/30 s: automação aberta numa ligação por comando fica a dar timeout | só acrescentar regras que não alargam o existente; reutilizar uma ligação SSH |
| Endurecimento do `sshd` (MaxAuthTries, LoginGraceTime, ClientAlive, LogLevel, Banner) | opções em `sshd_config` **perdem** para drop-ins em `sshd_config.d/` (vale o primeiro); confirma com `sshd -T`. `AllowTcpForwarding no` corta túneis `ssh -L` usados para dashboards privados; cifras restritas cortam clientes antigos | editar o drop-in certo; `sshd -t` antes de recarregar; manter uma sessão aberta e testar login novo |
| Política de passwords (`pwquality`, `PASS_MAX_DAYS`, `PASS_MIN_DAYS`, `chage` em contas existentes) | expiração força trocas/bloqueia contas de serviço e automação; `PASS_MIN_DAYS` impede trocas seguidas | só contas humanas (UID ≥ 1000) e só com aviso |
| `pam_faillock` | bloqueia contas após N falhas: testes de brute force ou um colega a errar bloqueiam o admin | `deny` alto, exceção para contas críticas, ou adiar |
| `hidepid=2,gid=adm` em `/proc` | utilizadores normais deixam de ver processos alheios; ferramentas de monitorização que não corram como root/adm deixam de ver tudo. O kernel recente mostra `hidepid=invisible` | incluir o grupo do admin; testar `ps` como utilizador comum e serviços ativos |
| Módulos Apache `security2` (ModSecurity) e `evasive` | **bloqueiam tráfego legítimo e ataques de demonstração** | `SecRuleEngine DetectionOnly`; limiares altos no evasive; avisar que ficam "só carregados" |
| `usbguard` **em máquina física ou com dispositivos USB** (numa VM sem USB é classe B, ver acima) | política mal gerada deixa teclado/rato sem funcionar | `usbguard generate-policy` com os dispositivos ligados; exige ≥ 4 regras; autorizar o que ficou bloqueado; ver `lsusb` depois. NÃO esperar subir `USB-2000` (pede desautorizar os *root hubs*) |
| Antivírus (`clamav`) | MALW-3280 | **Não ganha pontos: não o prometas.** O `MALW-3280` só reconhece antivírus *comerciais* (Avast, Avira, Bitdefender, ESET…); o ClamAV tem testes próprios (`MALW-3282/3284/3286`) que só existem quando está instalado, por isso somam pontos obtidos *e* possíveis e o índice não se mexe (medido: 95,54 → 95,56). O `clamav-daemon` custa ~1 GB de RAM e é um serviço sempre ativo. Só vale por razões de segurança reais (analisar ficheiros), não pelo score. Lê o código do teste (`/usr/share/lynis/include/tests_*`) antes de prometer pontos | `apt-get purge clamav*` |
| Regras `auditd` próprias | `-D` apaga as regras existentes; `-e 2` torna-as imutáveis até reiniciar | nunca usar `-D`/`-e 2` sem confirmação explícita; acrescentar em ficheiro novo |
| Mounts `nodev,nosuid,noexec` em `/boot` e `/dev/shm` | `noexec` quebra quem executa a partir daí | `mount -o remount` + `findmnt`; backup do `fstab`; **não** `/tmp` (ver R) |
| `rsyslog` com destino remoto | só ajuda se houver recetor; destino desligado = logs perdidos em silêncio (UDP) | configurar o recetor (ex.: `<remote>` syslog no Wazuh com `allowed-ips`) |
| Regravar o hash de uma password em yescrypt com **a mesma** password (`chpasswd`) | `AUTH-9229` aponta contas com hash `$6$` (típico das criadas pelo instalador). Com `sudo` `NOPASSWD`, a linha da password do sudo vai para o stdin do `chpasswd`: só a envies se o sudo a pedir. Funcionou também com o `libpam-pwquality` instalado | sessão de segurança aberta; backup do `shadow`; testar login novo + sudo; reverter se falhar |
| `apparmor` enforce em tudo | perfis incompletos bloqueiam serviços | só perfis em *complain* que o utilizador conhece |
| `cron.allow`/`at.allow`, permissões 750 em `/home` | partem cron de outros utilizadores / leitura por servidores web | incluir quem tem crontab; ver quem lê `/home` |

## R — de raiz (confirmar sempre; normalmente não aplicar)

| Medida | Porque costuma ficar de fora |
|---|---|
| `net.ipv4.ip_forward=0` / `forwarding=0` | quebra WireGuard, routers, Docker/LXD |
| `net.ipv4.conf.all.rp_filter=1` (estrito) | derruba tráfego de peers VPN que chegam com IPs de outra rede (ex.: `192.168.x` por `wg0`) |
| `kernel.modules_disabled=1` | impede carregar módulos até reiniciar (WireGuard, nf_tables, USB) |
| Mudar a porta do SSH, `PasswordAuthentication no`, `PermitRootLogin` | quem usa a porta/password antiga fica de fora; só com chaves testadas e todos avisados |
| Remover pacotes (compiladores, serviços) | **simular antes**: `apt-get -s purge …` — remover `gcc` puxou o ambiente gráfico (xfce4) e o `as` vem do `binutils` de que o python depende |
| `/tmp` com `noexec` | Java/OpenSearch, instaladores e `apt` executam a partir daí |
| Password no GRUB | só para editar o menu; as entradas de arranque têm de ficar `--unrestricted` e a primeira entrada confirmada em `grub.cfg`, ou o arranque pede password. Guardar a password no ficheiro de segredos do utilizador, nunca no ecrã |
| Parâmetros de kernel no GRUB (`init_on_free`, `lockdown=…`) | exigem reinício e podem impedir drivers |
| LUKS, partições separadas (`/home`, `/var`) | só com reinstalação do disco |
| Desativar serviços (cups, avahi, snapd…) | outros serviços podem depender deles |
| Mudar passwords de contas partilhadas/serviço | afeta pessoas; avisar e atualizar quem as usa |
| Alterações ao `sudoers` (retirar `NOPASSWD`) | pode retirar a automação do próprio utilizador |

## O que normalmente fica sem pontos (e é aceitável)

`DEB-0510` (LUKS), `FILE-6310` (partições), `MALW-3280` (só antivírus comerciais),
`USB-2000` (root hubs: só em máquina física; numa VM sem USB o USBGuard resolve-o), `HRDN-7220` (compiladores
instalados: só pontua sem nenhum), `DEB-0810` (`apt-listbugs` pode nem existir no repositório),
`SSH-7408` com `Port`, e os `sysctl` de rede/módulos acima. Em servidores com VPN/captura o teto
prático costuma ser **92–93**; sem VPN/containers pode chegar mais alto.
