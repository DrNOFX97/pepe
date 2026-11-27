# Relatório final com print (Fase 4)

No fim do trabalho entrega-se o relatório visual do Lynis: uma página HTML e um print dela.
`scripts/gerar_relatorio.py` produz a página a partir do que o Lynis e o Pepe já gravaram; o
print faz-se com o browser que o Claude tiver à mão. Isto serve de prova ao utilizador (e a quem
ele partilhar o trabalho): score inicial → final, progressão por etapa e o que ficou de fora.

## 1. Preparar os dados (as etapas têm de se ler bem no gráfico)

O gráfico usa as etiquetas que deste ao `lynis_medir.sh`. Usa nomes curtos e descritivos,
`baseline`, `e1-ferramentas`, `e2-config`, `e4-ssh`, `e5-ufw`…, porque aparecem no eixo
(cortados aos 14 caracteres). Só entram medições válidas: o `lynis_medir.sh` nunca regista uma
execução interrompida.

## 2. Gerar a página no alvo

```bash
sudo python3 gerar_relatorio.py          # escreve /root/hardening-log/relatorio.html
```

O script é autónomo (só biblioteca padrão do Python 3, presente por defeito no Ubuntu). Corre-o
depois do último `lynis_medir.sh`, para a página mostrar a medição final. Sai com erro se o
último Lynis não terminou. Traz o ficheiro para a máquina do utilizador (`scp`, `sftp` ou
`sudo cat` por SSH) para a pasta do projeto dele (ex.: `evidencias/`).

## 3. Tirar o print

1. **Procura um browser nas tuas ferramentas** (Playwright, Chrome DevTools, Claude in Chrome…).
   Se não houver nenhum, entrega só o `.html` e diz ao utilizador que o abra e use *Imprimir →
   Guardar como PDF* ou uma captura de ecrã.
2. **Os browsers das ferramentas bloqueiam `file:`.** Serve a página por HTTP, só em loopback e
   **a partir de uma pasta temporária que contém apenas esse ficheiro** (nunca a pasta do projeto:
   pode ter PCAPs, `.env` ou relatórios):
   ```powershell
   $p = Start-Process python -ArgumentList '-m','http.server','8901','--bind','127.0.0.1' `
        -WorkingDirectory <pasta-temporaria> -WindowStyle Hidden -PassThru   # guarda $p.Id
   ```
3. Abre `http://127.0.0.1:8901/`, ajusta a janela a ~1040 px de largura e tira o print da
   **página inteira** (`fullPage`), à escala do dispositivo, para um `.png` na pasta do projeto
   (ex.: `evidencias/lynis-report-<alvo>.png`).
4. **Pára o servidor pelo PID guardado** e apaga a pasta temporária. No Git Bash o `pkill` não
   alcança processos do Windows (o servidor continua a responder): usa `Stop-Process -Id` e
   confirma que a porta deixou de responder.
5. **Abre o print e olha-o.** Procura texto cortado, etiquetas tapadas, números que não batem
   certo (kernel, totais). Corrige e repete: um relatório com um erro à vista não serve de prova.

## 4. O que entregar

Diz ao utilizador onde ficaram o `.png` e o `.html`, e resume numa linha: score inicial → final,
meta de 80 e objetivo de 90 (cumpridos ou não) e o que ficou de fora. Se a soma da tabela de
perdas não coincidir com o total do Lynis (a tabela atribui cada variação ao teste que a
precede), o título mostra os dois valores: não escondas a diferença.
