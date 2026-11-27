# Lições aprendidas (armadilhas reais)

Cada ponto custou tempo ou quase partiu algo. Lê antes de automatizar.

## Provar que sobrevive a um reinício
- **O que está certo agora pode desfazer-se no arranque.** Corrigi `fs.suid_dumpable` à mão e o
  Lynis deu bem, mas um reinício mostrou `2` outra vez: o `apport` arranca depois do
  `systemd-sysctl` e repõe-no. Nem o ficheiro em `sysctl.d` chega, se outro serviço escreve por
  cima. **Faz um reinício no fim** e compara as definições antes/depois (grava um ficheiro de
  estado com `ufw`, serviços, `sysctl`, montagens e opções do `sshd`, e faz `diff`).
- **Um `dpkg` partido pode deixar um initramfs mau que só se vê no reinício.** Na VM Wazuh
  (27/11) o kernel 5.15.0-204 foi instalado no meio de um `unattended-upgrade` interrompido: o
  arranque encravou em "Loading essential drivers" (CPU parado), sem culpa do hardening. Para
  distinguir: Esc no GRUB → kernel anterior; se arranca, `update-initramfs -u -k <novo>`. Para
  testar sem risco: `GRUB_DEFAULT=saved`, `grub-set-default` no kernel bom e `grub-reboot` no
  novo (só uma vez; um reset volta ao bom). No fim repor `GRUB_DEFAULT=0`.
- Faz o reinício com a máquina desligada e um snapshot offline: o *live snapshot* ficou preso
  13 minutos num VirtualBox sobre Hyper-V.
- Em convidados VirtualBox, `systemd-timesyncd` e `vboxadd-service` alternam entre arranques
  (conflito de unidades); `upower` só corre a pedido. O verificador ignora-os, porque não são
  acessos.

## Medir o Lynis
- **Confirma no código do teste antes de prometer pontos.** Prometi "+3 pontos com ClamAV"
  (`MALW-3280`) sem ler o teste: só conta antivírus comerciais. O custo foi um serviço de ~1 GB
  de RAM instalado sem ganho. O código está em `/usr/share/lynis/include/tests_*` e demora um
  `grep` a ler. Um teste novo (ex.: `MALW-3282/3284/3286`) que surge ao instalar algo soma pontos
  obtidos e possíveis ao mesmo tempo: não sobe o índice.
- **Usa sempre o Lynis mais recente** (`scripts/instalar_lynis.sh`). O repositório do Ubuntu 24.04
  traz a 3.0.9 quando a atual é a 3.1.7: testes novos, pesos diferentes e outro score. Medir
  duas máquinas (ou duas alturas) com versões diferentes dá números que não se comparam.
- **Um Lynis interrompido não pode entrar no histórico.** Ao parar um `lynis` a meio, o relatório
  fica sem `hardening_index` e o registo ganhava uma linha falsa (índice vazio, 1/10 pontos).
  `lynis_medir.sh` agora falha nesse caso em vez de gravar.
- **Nunca dois `lynis audit` ao mesmo tempo.** Escrevem no mesmo `/var/log/lynis.log` e
  `/var/log/lynis-report.dat`: o score fica errado (apareceu 85 em vez de 91) e as perdas ficam
  duplicadas (DEB-0510 com 22 em vez de 11). Sinal: avisos repetidos e perdas em dobro.
  `scripts/lynis_medir.sh` espera pelo outro, limpa o log e mede sozinho.
- **Atualizações pendentes custam ~5 pontos** (aviso `PKGS-7392`). O score pode *descer* sem
  teres mexido em nada porque saiu uma atualização de segurança. Vê `apt list --upgradable`
  antes de concluir que uma etapa piorou o sistema.
- O índice é `pontos/total`: cada ponto vale ~0,27 do índice (total ≈ 370). Para subir 1 do
  índice precisas de ~4 pontos reais. Por isso 3 itens de 2 pontos dão menos que 1 do índice.
- Para ver *onde* se perde: `scripts/lynis_perdas.sh` (perda | teste | obtido/possível).

## Não abrir portas sem dar por isso
- **Instalar pacotes também altera a superfície de ataque.** Numa VM Ubuntu limpa, instalar o
  `aide-common` (por causa do `Recommends`) trouxe o **Postfix**, a ouvir em `0.0.0.0:25`. O
  verificador original só dava alarme se algo *desaparecesse*, por isso passou. Agora
  `verificar_acessos.sh` compara o **alcance** das portas (`publica` vs `local`) e sai com código
  2 perante uma porta pública nova. Instala sempre com `--no-install-recommends` e lê o código.
- **`--no-install-recommends` não chega sempre:** no Ubuntu 22.04 o `chkrootkit` *depende* (não
  recomenda) de um MTA e trouxe o Postfix em `0.0.0.0:25` mesmo assim (VM Wazuh, 27/11).
  Depois de instalar, `postconf -e 'inet_interfaces = loopback-only'` + `systemctl restart postfix`.
- **Uma atualização pode parar outro serviço por conflito de unidades.** Num convidado
  VirtualBox, o `apt upgrade` pôs o `systemd-timesyncd` a funcionar e este parou o
  `vboxadd-service`. O verificador acusou "PERDIDO"; foi investigado (`journalctl -u`), aceite
  por não afetar nenhum acesso e o snapshot regravado com `--refresh`. Nunca regraves o snapshot
  sem perceber a causa.
- Um serviço que arranca por defeito ao ser instalado (fail2ban, postfix, auditd) pode afetar
  acessos: só entra depois de ver para que serve e com as exceções certas.

## Não partir acessos
- **Ordem do SSH:** em `sshd_config`, o primeiro valor lido vence e o `Include sshd_config.d/*`
  vem no topo. Editar `sshd_config` não adianta se um drop-in já fixa a opção. Vê sempre
  `sshd -T`.
- **UFW `limit`:** 6 ligações em 30 s ao mesmo IP são bloqueadas. Automação que abre uma ligação
  SSH por comando fica com `TimeoutError`. Reutiliza uma ligação (ControlMaster / uma sessão) ou
  espera 30–40 s.
- **fail2ban:** `tee` sobre `jail.local` apaga o `ignoreip`. Faz merge, nunca sobrescrevas.
- **auditd:** `-D` + `-e 2` apagam as regras que existiam e bloqueiam alterações até reiniciar.
- **rp_filter / ip_forward:** o valor "loose" (2) pode ser deliberado (peers VPN com IPs de
  outra rede). O `check` do snapshot guarda estes valores: se mudarem, pára.
- **`sudo -S` + `NOPASSWD`:** se o sudo não pede password, a linha que enviaste para o stdin vai
  para o comando (`chpasswd: line 1: missing new password`). Deteta com `sudo -n true`.
- **Sessão de segurança:** nas alterações a SSH/PAM/passwords, mantém uma sessão aberta e testa
  um login novo antes de fechar. Se falhar, repõe o backup pela sessão antiga.
- **`hidepid`:** o kernel recente mostra `hidepid=invisible` e não `hidepid=2`; uma verificação
  que procura só `hidepid=2` desfaz uma alteração correta.
- **Remover pacotes:** `apt-get -s purge …` primeiro. Remover compiladores desinstalaria o
  ambiente gráfico; o `as` vem do `binutils`, de que o Python depende.
- **UFW repõe sysctl:** `/etc/ufw/sysctl.conf` volta a aplicar `log_martians=0` ao arrancar.
- **needrestart:** depois de atualizar libs, serviços de captura continuam com a lib antiga.
  Reiniciá-los corta tráfego uns segundos: pergunta antes.
- **Pacotes em `hold`** (ex.: agente que não pode ficar mais novo que o servidor) não se
  atualizam; diz isso ao utilizador em vez de "corrigir".

## Empacotar a skill (BOM e fins de linha)
- Ao copiar os `.sh` no Windows, **não uses `Set-Content -Encoding utf8` no PowerShell 5.1**: ele
  escreve um BOM no início e o `#!/bin/bash` deixa de ser reconhecido. Copia com `cp` e tira os
  `\r` com `sed -i 's/\r$//'`. Confirma com `head -c 3 ficheiro | xxd -p` (esperado `23212f`).

## Relatório e print
- Os browsers das ferramentas (Playwright) **bloqueiam `file:`**: serve a página por HTTP em
  `127.0.0.1`, de uma pasta temporária só com o ficheiro, e pára o servidor pelo **PID** (o
  `pkill` do Git Bash não alcança processos do Windows e o servidor fica a responder).
- **Olha o print antes de o entregar.** No primeiro saíram dois defeitos: o kernel mostrava a
  string de compilação em vez da versão (`linux_kernel_release` é a chave certa) e uma barra
  tapava a etiqueta do objetivo de 90.
- A soma das perdas por teste (o `awk`) pode diferir do total do Lynis (medido: 17 vs 15): mostra
  os dois no título em vez de apresentar um número que não bate com o resto.
- No Git Bash, argumentos que começam por `/` (ex.: `/home/x`) são convertidos em caminhos do
  Windows. Corre comandos remotos que comecem por `cd`, ou usa caminhos relativos.

## Alvos sem SSH e alvos que não se endurecem
- **Ver o que a máquina serve antes do plano.** O `Lab26` parecia "VM de captura" e era um lab
  de apps web vulneráveis de propósito (DVWA, bWAPP, `/var/www` 777) em Debian 9 sem suporte.
  Endurecer partia o exercício: fez-se só a auditoria (baseline + relatório) e repôs-se o snapshot.
- **VM sem SSH:** `VBoxManage guestcontrol` corre comandos com utilizador/password (via
  `--passwordfile`, nunca na linha de comandos). Com Guest Additions antigas (5.1) num VirtualBox
  7: não passar `argv0` depois de `--` (o `--exe` já o é); `copyto` grava o ficheiro mas dá
  `VERR_NOT_SUPPORTED` (confirmar com hash); `copyfrom` falha: ler ficheiros com `cat`; o PATH
  não tem `/usr/local/bin`.
- **Python antigo:** Debian 9 traz Python 3.5 (sem `capture_output`/`text=`); o
  `gerar_relatorio.py` usa só `stdout=PIPE, universal_newlines=True`.

## Sistemas fora de suporte e últimos pontos (Lab26, Debian 9: 65 → 98)
- **Repositórios de uma versão em fim de vida:** apontar para `archive.debian.org` com
  `Check-Valid-Until "false"`. As chaves do 9 expiraram (`EXPKEYSIG` = assinatura válida, chave
  fora de prazo). O `debian-security` é assinado com chaves novas: importá-las por ID longo do
  keyserver para `trusted.gpg.d/*.gpg` **com permissão 644** (com 600 o `_apt` ignora-as em
  silêncio). O `main` só tem `InRelease` com chaves velhas: verificar o `Release.gpg` à mão com
  `gpgv` (aceita chaves expiradas) e o hash do `Packages` em cache; só então `[trusted=yes]`.
  Não confiar num teste de autenticação com um pacote que já está em cache.
- **`/tmp` com `noexec` parte o apt** (scripts do debconf) e com ele as atualizações automáticas:
  `DPkg::Pre-Invoke {"mount -o remount,exec /tmp";}` + `Post-Invoke` com `noexec` +
  `APT::ExtractTemplates::TempDir "/var/cache/apt/tmp"`.
- **Guest Additions antigas encravam com argumentos longos** no `guestcontrol run`: enviar
  scripts (`copyto`) e correr os demorados com `nohup … &`, consultando um ficheiro de saída.
- **`FIRE-4508` conta alvos, não só a política:** regras `-A INPUT … -j ACCEPT` diretas na tabela
  `security` dão pontuação parcial. Pôr as aceitações numa chain própria (`-A INPUT -j PEPE-IN`)
  e política DROP, em IPv4 **e** IPv6 (o `ip6table_security` tem de carregar antes do
  `modules_disabled`).
- **`modules_disabled=1`** só com uma unidade systemd no fim do arranque (`After=` UFW, usbguard,
  auditd, tabelas, loop): aplicado cedo impede o arranque dessas peças.
- **Partições separadas sem reinstalar:** `/home` e `/var` em ficheiros *loop* (`/srv/*.img`,
  `loop,nodev,nosuid` no `fstab`; `/var` sem `noexec` por causa do dpkg), copiados com os
  serviços parados e ativos no reinício. Só em máquinas descartáveis.
- **`dpkg-divert` em vez de purgar:** purgar o `binutils` levava o `rkhunter`, o `chkrootkit` e o
  Xorg; desviar o `/usr/bin/as` tira o "compilador" ao Lynis e deixa tudo o resto.
- `LOGG-2154` aceita qualquer `@destino` no rsyslog, até `127.0.0.1`: não o fazer sem recetor
  real (é maquilhagem). `MALW-3280` fica sempre de fora sem antivírus comercial.

## Segredos
- Nunca imprimas passwords (do `.env`, `shadow`, GRUB). Passwords geradas por ti vão para o
  ficheiro de segredos do utilizador, e a cópia no alvo é apagada (`shred -u`).
- Lista contas por tipo de hash só pelo prefixo (`$6$`, `$y$`), nunca o hash.

## Scripts de hardening genéricos
O `hardening_ubuntu.sh`, corrido às cegas neste tipo de servidor: poria `ip_forward=0`,
sobrescreveria o `jail.local`, apagaria as regras do auditd, abriria o SSH ao mundo no UFW,
bloquearia contas com `faillock`, tornaria sessões SSH finitas e aplicaria `aa-enforce` em tudo.
Usa-o como inventário de medidas, não como instalador.
