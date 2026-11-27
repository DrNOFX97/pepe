# Lições aprendidas (armadilhas reais)

Cada ponto custou tempo ou quase partiu algo. Lê antes de automatizar.

## Provar que sobrevive a um reinício
- **O que está certo agora pode desfazer-se no arranque.** Corrigi `fs.suid_dumpable` à mão e o
  Lynis deu bem, mas um reinício mostrou `2` outra vez: o `apport` arranca depois do
  `systemd-sysctl` e repõe-no. Nem o ficheiro em `sysctl.d` chega, se outro serviço escreve por
  cima. **Faz um reinício no fim** e compara as definições antes/depois (grava um ficheiro de
  estado com `ufw`, serviços, `sysctl`, montagens e opções do `sshd`, e faz `diff`).
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

## Segredos
- Nunca imprimas passwords (do `.env`, `shadow`, GRUB). Passwords geradas por ti vão para o
  ficheiro de segredos do utilizador, e a cópia no alvo é apagada (`shred -u`).
- Lista contas por tipo de hash só pelo prefixo (`$6$`, `$y$`), nunca o hash.

## Scripts de hardening genéricos
Um script de hardening genérico (o do curso), corrido às cegas neste tipo de servidor: poria `ip_forward=0`,
sobrescreveria o `jail.local`, apagaria as regras do auditd, abriria o SSH ao mundo no UFW,
bloquearia contas com `faillock`, tornaria sessões SSH finitas e aplicaria `aa-enforce` em tudo.
Usa-os como inventário de medidas, não como instalador.
