# configuracoesv2

Configurador interativo de **Windows Server / Windows 11** em PowerShell, com
**janela WPF** (tema escuro, abas) e fallback para menu de console. Instala e
configura recursos comuns — Hyper-V, Containers, OpenSSH, WSL, IIS completo
(ASP.NET / WCF / WAS / MSMQ), Telnet — além de **softwares** (via Chocolatey ou
winget), **rede NAT/DHCP**, customizações de UI e hardening base. Tudo registrado
em log e num **histórico persistente** (aba Status).

## Como usar

### 1) One-liner (recomendado) — `irm | iex`

No servidor/host (Windows com Desktop), no PowerShell — ele **auto-eleva** (UAC):

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/davidagostini/configuracoesv2/main/dist/bootstrap.ps1 | iex
```

Baixa o launcher → re-spawn elevado (Admin + STA) → baixa o payload → abre a janela.

### 2) Local (desenvolvimento)

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Sem WPF (Server Core / headless / não-STA) cai para o **menu de console**.

## A janela (abas)

- **Status** — lê o histórico (`installer-state.json`) e mostra o que já foi feito,
  com data/duração; cabeçalho ao vivo (máquina, **tipo físico/virtual**, OS, IPs) e
  aviso de reinício pendente. Clicar num item abre o **registro (JSON)**.
- **Features** — recursos do Windows: Hyper-V, Containers, **WSL** (`wsl --update`),
  Telnet, **OpenSSH Server** (serviço sshd + firewall 22), MSMQ.
- **Softwares** — catálogo (Chocolatey **ou** winget) + catálogo de usuário
  (`software-extra.json`); **padrão = Chocolatey** (fallback winget se o app não tiver
  pacote choco); botão "Adicionar software...".
- **IIS** — lista completa de features na ordem padrão + `aspnet_state` + `iisreset`,
  ou "IIS COMPLETO" de uma vez.
- **Rede (NAT / DHCP)** — cria NAT Switch (Hyper-V) e configura DHCP do NAT (detecta
  a sub-rede/gateway, faixa, DNS, lease; faz bind só na interface do NAT).
- **Sistema** — Customizações (dark mode, extensões, ocultos, desativar Print Screen
  do Snipping) + Config base (IE ESC, time zone Brasília, **data/hora via internet**,
  Server Manager no logon); botões para abrir as pastas **Startup** (usuário/todos).
- **Atualizações** — pendências do **winget** e do **Chocolatey** (inclusive de apps
  que não foram instalados por aqui) + "Atualizar tudo".
- **Log ao vivo** — andamento em tempo real, indicador de fila e "Cancelar fila".

## Como funciona

- **Execução assíncrona com fila.** Cada "Aplicar" pede confirmação e **enfileira** o
  trabalho num **worker em runspace** (fila serial — nunca dois ao mesmo tempo). A
  janela **não congela**; o progresso aparece em "Log ao vivo" e cada aba mostra
  **"Concluído"** ao fim. Se o worker não iniciar, há **fallback síncrono**.
- **Histórico + marcas.** Cada ação grava no `installer-state.json` (1 entrada por
  item, com snapshot da máquina). Itens já feitos aparecem com **"[feito em <data>]"**
  (verde) ao lado; clicar abre o JSON daquele registro.
- **Idempotência** — as operações checam o estado antes de agir; rodar de novo pula o
  que já está feito (mecanismo real de "continuar de onde parou").

## Princípios de segurança

- **Defere instalações** quando já há reinício pendente (evita falha em cadeia) e
  mostra um **resumo** ao final: instalados / precisam de reinício / deferidos / falhas.
- **Reinício avisado, nunca silencioso** — as features usam `-NoRestart`; ao esvaziar a
  fila, se ficou reinício pendente, a janela **avisa e oferece reiniciar** com uma
  **contagem regressiva cancelável**. (Exceção pedida pelo usuário: no Server, o Hyper-V
  usa `Install-WindowsFeature -Restart`, que reinicia ao concluir.)
- Operações de registro são **idempotentes**.

## Estrutura

```
setup.ps1                 # entrypoint: auto-eleva, dot-source dos módulos, Start-Gui
build.ps1                 # gera dist/ (payload + bootstrap + sha256) para o irm
bootstrap-head/tail.ps1   # launcher + cauda do payload (one-liner irm | iex)
modules/
  Common.ps1              # log, registro idempotente, reinício/defer, ledger, físico/virtual
  OSCommon.ps1            # detecção client/server + catálogo de capacidades + dispatch
  Customizations.ps1      # dark mode, extensões, ocultos, Print Screen, pastas Startup
  WindowsFeatures.ps1     # Hyper-V, Telnet, OpenSSH, WSL, NAT Switch, DHCP do NAT
  BaseConfig.ps1          # IE ESC, time zone Brasília, data/hora (HTTP), Server Manager
  IIS.ps1                 # IIS completo + aspnet_state + iisreset
  Software.ps1            # catálogo choco/winget + catálogo de usuário + atualizações
  Gui.ps1                 # fallback de console + menu principal + resumo
  GuiWpf.ps1              # UI primária (WPF): abas, worker assíncrono, fila, log ao vivo
docs/                     # CLAUDE.md, DECISOES, DESIGN-irm-gui, ESTADO-ATUAL, RUNBOOK
```

## Arquivos de runtime (não versionados)

Em `C:\davidagostini\instalador\`: `log\` (um `install.log` por execução),
`installer-state.json` (histórico da aba Status) e `software-extra.json` (catálogo de
software do usuário, editável).

## Documentação

- `CLAUDE.md` — arquitetura, convenções e **invariantes** (guia de manutenção).
- `docs/ESTADO-ATUAL.md` — estado atual, pendências e como retomar.
- `docs/DECISOES.md` / `docs/DESIGN-irm-gui.md` — decisões e design do `irm`/GUI.
- `docs/RUNBOOK-DHCP-NAT-HyperV.md` — passo a passo do NAT + DHCP no Hyper-V.
