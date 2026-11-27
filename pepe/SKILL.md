---
name: pepe
description: Pepe: hardening seguro e medido de um servidor Ubuntu/Debian, guiado pelo score do Lynis. Faz um Lynis inicial, inventaria o que está instalado e falta, adapta as medidas do script de hardening avançado ao sistema real, nunca parte ligações nem acessos privados (SSH, VPN/WireGuard, firewall, serviços), aplica sozinho o que é de baixo risco, pede confirmação nas de médio risco e em tudo o que é de raiz, regista o score antes e depois de cada etapa e repete até chegar aos 80 (e planeia os 90). Usar SEMPRE que o utilizador falar em hardening, endurecer/proteger/blindar um servidor ou VM Ubuntu, Lynis, subir o score ou o "hardening index", auditoria de segurança de um Linux, ou pedir para correr/adaptar o hardening_ubuntu.sh, ou chamar pelo Pepe (/pepe), mesmo que não diga "skill" nem "Lynis".
---

# Pepe: hardening de Ubuntu com Lynis

Objetivo: levar o servidor a **pelo menos 80** no Lynis (e a 90 se for possível sem arriscar nada),
sem cortar nenhum acesso que já funcione. O score é o meio; o servidor continuar a servir quem o
usa é a condição. Quando os dois colidem, ganha a condição.

## Princípios (e porquê)

1. **Medir antes e depois de cada etapa.** Sem números não sabes se uma alteração ajudou, nem
   que a etapa seguinte piorou algo. Regista tudo em `scores.tsv` (feito pelos scripts).
2. **Acessos privados são intocáveis.** VPN, SSH de colegas, dashboards internos, túneis, contas
   de serviço e redes de gestão são o que o utilizador tem a perder. Guarda o estado deles antes
   da primeira alteração e verifica-o depois de cada passo.
3. **O script de hardening é uma lista de medidas, não um instalador.** Corrido às cegas num
   servidor real, desfaz configuração que já estava afinada (ver `references/licoes.md`). Extrai
   cada medida, vê se já existe, adapta-a e aplica só o que cabe neste sistema.
4. **O risco decide quem decide.** Baixo: aplicas. Médio: planeias e o utilizador confirma.
   De raiz: o utilizador confirma sempre. Em caso de dúvida sobe uma classe.
5. **Nada se faz sem caminho de volta.** Backup antes de tocar em ficheiros, rollback pronto,
   sessão de segurança aberta em alterações de acesso.
6. **Nunca fiques satisfeito abaixo de 80.** Abaixo de 80 o trabalho não acabou: analisas as
   perdas, propões alternativas e afinas com o utilizador até haver 80, ou até ficar provado
   (e explicado por escrito) o que impede, deixando a decisão ao utilizador.

Responde sempre na língua do utilizador. Nunca imprimas passwords nem o conteúdo de ficheiros de
segredos (`.env`, `shadow`); passwords que geres vão para o ficheiro de segredos dele e a cópia no
alvo é apagada.

## Ferramentas desta skill

Estão em `scripts/` ao lado deste ficheiro. Copia-as para o alvo (pasta do utilizador, não
`/tmp`), dá-lhes `chmod +x` e corre-as com `sudo`.

| Script | Para quê |
|---|---|
| `preflight.sh` | Inventário **só de leitura**: sessões SSH ativas, acesso efetivo (`sshd -T`), firewall, VPN, `NOPASSWD`, serviços e portas, pacotes de segurança instalados/em falta, atualizações, USB, montagens |
| `verificar_acessos.sh --snapshot` / `verificar_acessos.sh` | Grava o estado dos acessos e depois compara. Sai com erro se algo desapareceu ou mudou |
| `instalar_lynis.sh` | Instala ou atualiza o Lynis para a **versão mais recente** (repositório oficial da CISOfy; GitHub como alternativa). Nunca uses o do repositório da distro: fica atrás e o score muda entre versões |
| `lynis_medir.sh "<etiqueta>"` | Corre o Lynis sozinho e limpo, regista o score em `scores.tsv`, mostra variação, avisos e perdas por teste |
| `lynis_perdas.sh` | Só a tabela de perdas do último Lynis (perda \| teste \| obtido/possível) |
| `backup.sh <etiqueta> <caminhos…>` / `--restore <pasta>` | Backup e restauro; o restauro apaga também o que a etapa criou de novo |
| `gerar_relatorio.py` | No fim: página HTML autónoma com o score inicial → final, o gráfico por etapa e as perdas com o motivo. Lê o que os outros scripts gravaram (usa etiquetas curtas no `lynis_medir.sh`, ex.: `e2-config`) |

Registos no alvo: `/root/hardening-log/` (`scores.tsv`, `acessos.snapshot`, `backups/`,
`report-*.dat`). Se o alvo for remoto, usa uma só ligação SSH ou espera entre comandos: o UFW com
`limit` bloqueia 6 ligações em 30 s e dá timeout.

Referências, lê quando precisares:
- `references/catalogo-medidas.md`: cada medida com teste Lynis, classe **B/M/R**, o que verificar
  antes e como desfazer. É daqui que sai o plano.
- `references/licoes.md`: armadilhas reais (dois Lynis em simultâneo, UFW a repor sysctl, drop-ins
  do SSH, `NOPASSWD`…).
- `assets/hardening_ubuntu.sh`: o script avançado original. Só leitura e inspiração.

## Acesso ao alvo

Esta skill não guarda nem exige credenciais: nem `.env`, nem passwords dentro dela. Como chegas
ao alvo e como ganhas root decide-se na Fase 0:

1. **Máquina local:** corres tudo com `sudo` aqui mesmo.
2. **Servidor remoto:** usa o que o utilizador já tem (`ssh <host>` com chave ou `~/.ssh/config`).
   Se ele indicar um `.env`/ficheiro de acessos do projeto, usa-o sem o mostrar.
3. **`sudo`:** testa primeiro `sudo -n true`. Se passar (`NOPASSWD`), não precisas de password e
   **não** a envies no stdin (iria parar ao comando). Só se falhar é que **pedes a password do
   `sudo` ao utilizador**, e só nessa altura. Avisa-o de que o que escrever na conversa fica no
   histórico, e oferece a alternativa de ele correr ele próprio os comandos com `!` para a
   password nunca passar por ti.
4. Uma password pedida serve **só nesta sessão**: não a escreves em ficheiros, não a repetes em
   respostas e não a incluis em relatórios. Não ofereças guardá-la.

## Fluxo

### Fase 0: reconhecimento (nada se altera)

1. Confirma o alvo (esta máquina ou remoto) e como lá chegas (ver *Acesso ao alvo*). Pergunta só o que o `preflight` não
   consegue saber: há algo que não pode parar nem numa janela curta? Quem se liga e de onde? A
   máquina é física (USB, consola) ou VM? Há janela de manutenção?
2. Corre `preflight.sh`. Escreve ao utilizador, em poucas linhas, os **acessos que vais
   proteger** (sessões SSH, utilizadores/redes permitidas, VPN e peers, portas a ouvir, `sudo`
   sem password) e o que falta instalar.
3. `verificar_acessos.sh --snapshot`. A partir daqui, qualquer "PERDIDO" é um alarme.
4. `instalar_lynis.sh` (sempre a versão mais recente, mesmo que já haja um Lynis instalado: o da
   distro costuma ser antigo), depois `lynis_medir.sh baseline`. Esse é o **score inicial**, e
   todas as medições do trabalho têm de usar a mesma versão (o script mostra-a).
   Vê se há atualizações pendentes: o aviso `PKGS-7392` custa ~5 pontos e engana a leitura.
5. Compara com o `assets/hardening_ubuntu.sh`: que medidas ele aplicaria, quais já estão feitas,
   quais seriam prejudiciais *neste* sistema (ver `licoes.md`).

### Fase 1: plano

Cruza `lynis_perdas.sh` com `references/catalogo-medidas.md` e monta o plano em **etapas**, cada
uma com medidas da mesma classe e do mesmo assunto (pacotes, kernel/sysctl, SSH, montagens…).
Para cada etapa: medidas, classe, pontos esperados (cada ponto ≈ 0,27 do índice), risco, rollback.

Antes de prometer pontos a uma medida, **confirma no código do teste** que ela é o que o Lynis
procura (`grep` em `/usr/share/lynis/include/tests_*`): há testes que só reconhecem produtos
concretos ou palavras-chave concretas (banners em inglês, antivírus comerciais), e instalar a
coisa errada custa um serviço sem ganho. Marca como *estimado* o que não verificaste.

Apresenta o plano numa tabela curta e diz onde se espera chegar. Se o projetado for < 80,
**procura mais antes de apresentar**: itens M que ainda não entraram, medidas alternativas. Se
mesmo assim não chegar, diz-o já e propõe afinar com o utilizador (Fase 3).

### Fase 2: executar etapa a etapa

Para cada etapa, por ordem B → M → R:

1. **Classe B:** avança sem perguntar. A classe pode descer com o contexto: numa **VM sem
   dispositivos USB** (o `preflight.sh` di-lo), as medidas de USB (USBGuard, `usb-storage`) são B,
   porque não há teclado nem rato USB que se possa bloquear.
   **Classe M:** mostra o que vais fazer, os riscos concretos e o que fica de fora; espera
   confirmação (uma por etapa chega, se os riscos forem os mesmos).
   **Classe R (de raiz):** confirma **sempre**, uma a uma, mesmo que o utilizador já tenha
   aprovado o plano. De raiz = muda a base do sistema ou pode cortar o acesso: porta/autenticação
   do SSH, política da firewall, GRUB/kernel, remover pacotes, partições/cifra, PAM, `sudoers`,
   `ip_forward`/`rp_filter`, `/tmp` `noexec`, mudar passwords.
2. `backup.sh <etapa> <ficheiros que vais tocar>` (guarda a pasta que ele imprime).
3. Aplica a alteração. Prefere ficheiros novos (`/etc/sysctl.d/99-zz-*.conf`, drop-ins) a editar
   os existentes; valida a sintaxe antes de recarregar (`sshd -t`, `apache2ctl configtest`,
   `rsyslogd -N1`, `aide --config-check`).
4. `verificar_acessos.sh`. Se aparecer **PERDIDO** (código 1): pára, **repõe o backup**, volta a
   verificar, conta ao utilizador o que aconteceu. Só continuas se ele aceitar a mudança
   (`--refresh` regrava o snapshot) ou se encontrares uma variante que não corte nada.
   Se sair com **código 2** (nada se perdeu mas há portas públicas novas), a etapa abriu
   superfície de ataque, tipicamente um pacote que arrastou um serviço: fecha-o (ex.: Postfix só
   em loopback) ou remove-o, e só depois segues. Instala pacotes com `--no-install-recommends`.
5. Em alterações a SSH/PAM/passwords/firewall: antes de as dares por boas, abre um **login novo**
   (e o `sudo`) com a sessão antiga ainda aberta.
6. `lynis_medir.sh "<etapa>-depois"`. O score "antes" da etapa é o "depois" da anterior.
7. Escreve uma linha ao utilizador: `Etapa N | medidas | antes → depois (Δ) | acessos OK`.
   Se o score **desceu** ou o Δ ficou muito abaixo do esperado, investiga (pacotes pendentes?
   Lynis duplo? medida que reverteu?) antes de seguir.

### Fase 3: o ciclo até aos 80 (e aos 90)

Depois de cada etapa:

- **Score ≥ 80**: monta e mostra o plano para **≥ 90** se ainda for possível (itens que sobram e
  o seu risco). Aplica o que for B, pede confirmação no M e R. Pára quando só restarem itens que
  partem acessos, exigem reinstalar ou não têm candidato (ver o fim do catálogo), e diz porquê.
- **Score < 80**: não dês a tarefa por feita. `lynis_perdas.sh` → o que mais pesa → catálogo →
  próxima etapa. Se só faltar M/R, **faz fine-tuning com o utilizador**: explica o ganho e o
  risco de cada item, propõe variantes mais suaves (ex.: ModSecurity em `DetectionOnly`, `usbguard`
  com política gerada, `hidepid` com o grupo do admin) e deixa-o escolher. Se uma medida for
  recusada, procura outra que valha pontos equivalentes.
- Repete até ≥ 80, ou até seres capaz de mostrar que o resto só se alcança partindo algo que o
  utilizador recusou. Nesse caso o resultado é "bloqueado, aqui está porquê, decide tu".

## Fase 4: fecho

**Primeiro, o relatório visual:** depois do último `lynis_medir.sh`, corre
`sudo python3 gerar_relatorio.py`, traz o HTML para a pasta do utilizador e tira-lhe um **print**
com o browser que tiveres (procedimento completo, com os cuidados que poupam tempo, em
`references/relatorio.md`). Olha o print antes de o entregar. Sem browser, entrega o `.html`.

Depois entrega um relatório curto no chat (e guarda `scores.tsv`):

```
Score: <inicial> → <final>   (meta 80 ✔/✘, objetivo 90 ✔/✘)
| Etapa | Medidas | Classe | Antes | Depois | Δ |
Aplicado | Recusado/adiado e porquê | Impossível sem partir acessos (lista curta)
Pendentes: reinícios de serviços (needrestart), reboot, passwords por trocar, recetores de logs
Rollback: comando por etapa (backup.sh --restore …)
```

Diz o que deixou de fora de propósito (VPN, captura, `/tmp`…) para o utilizador não o refazer
depois a pensar que foi esquecimento. Se descobriste algo útil para o futuro, junta-o a
`references/licoes.md`.
