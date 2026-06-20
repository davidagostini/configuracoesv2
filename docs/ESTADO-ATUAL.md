# Estado atual do projeto (handoff)

> Documento de retomada. Atualizado em 2026-06-19. Use isto + `CLAUDE.md` +
> `docs/DECISOES.md` para continuar de onde paramos (inclusive em outra maquina).

## Como retomar depois de formatar a maquina

1. Instalar o **Git** (winget: `winget install Git.Git`) e o VS Code/editor.
2. Clonar: `git clone https://github.com/davidagostini/configuracoesv2.git`
   (todo o codigo + docs estao no remoto — nada se perde com o format).
3. Para **testar o instalador** numa VM/host (Windows Server com Desktop):
   ```powershell
   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/davidagostini/configuracoesv2/main/dist/bootstrap.ps1 | iex
   ```
4. Para **desenvolver**: editar `modules\*.ps1`, checar sintaxe (PSParser, ver
   `CLAUDE.md`), `build.ps1 -Ref main`, commit, push. O `irm` de `main` reflete na hora
   (fora o cache do raw, ~2-5 min).
5. **Memoria do Claude** (opcional, para continuidade de sessao): fica FORA do
   projeto, em `C:\Users\<voce>\.claude\projects\C--projetos-install\memory\`.
   Copie essa pasta se quiser preservar o contexto das conversas.

## O que ja esta pronto (em `main`)

- **Configurador Windows** (Server/11) em PowerShell 5.1, modular (`modules\*.ps1`),
  com auto-elevacao e log.
- **Lancamento via `irm | iex`** (modelo launcher + payload, ver `CLAUDE.md`/`DECISOES.md`).
- **UI primaria: janela WPF** (`GuiWpf.ps1`, `Start-Gui`) estilo app, tema escuro,
  **icone proprio** (avatar desenhado em runtime). Fallback para menu de console
  (`Start-MainMenu`) sem WPF (Server Core/headless/nao-STA). Abas:
  - **Status** — le o ledger e mostra o que ja foi feito (com data/duracao) +
    cabecalho ao vivo (maquina/OS/IPs) + aviso de reinicio pendente.
  - **Features** — capacidades do Windows (Hyper-V, Telnet, Containers, MSMQ...).
  - **Softwares** — catalogo + catalogo de usuario; filtro todos/winget/choco;
    "Adicionar software...".
  - **IIS** — lista completa de features (ordem do `$IISFeatures`) + aspnet_state + iisreset.
  - **Rede (NAT/DHCP)** — cria NAT Switch e configura DHCP (detecta IP/lente/lease).
  - **Customizacoes** e **Config base**.
- **Confirmacao (Sim/Nao) em toda aplicacao** + botoes desabilitados durante a
  execucao; **lista repopulada apos cada Aplicar** (limpa selecao); itens ja
  instalados aparecem **"[instalado <data>]" em verde** ao lado.
- **Ledger persistente** `installer-state.json` (1 entrada por item com snapshot da
  maquina: nome/OS/IPs/reinicio + inicio/fim/duracao). Auto-cura de arquivos
  aninhados por bug antigo.
- **DHCP do NAT** (Server): role + scope + gateway/DNS/lease + bind so no NAT.
  Runbook em `docs/RUNBOOK-DHCP-NAT-HyperV.md` + script `configurar-dhcp-nat.ps1`.
- **Detalhe de erro** de choco/winget gravado no log + resumo.
- **Novidades (jun/2026):** ajuste de hora **por HTTP** (cabecalho Date, sem NTP); deteccao
  **fisica/virtual** no ledger (`Get-MachineKind`); aba **Sistema** (Customizacoes + Config base
  unificadas) com marca **"[feito em <data>]" clicavel -> popup do JSON** do item (em todas as abas);
  aba **Atualizacoes** (winget upgrade / choco outdated + atualizar tudo, inclui apps externos);
  **OpenSSH Server** (sshd + firewall 22), **`wsl --update`**, **PowerShell 7** no catalogo,
  desativar **Print Screen** do Snipping e abrir as pastas **Startup**. **Hyper-V por DISM** nos dois
  SOs (`Microsoft-Hyper-V-All`) — no Server o `Install-WindowsFeature` trava no Server Manager. Ao
  esvaziar a fila, se algum item pediu reinicio, a GUI **avisa e reinicia** com contagem cancelavel
  (`Invoke-RebootOffer`).

## Arquivos de runtime (NAO versionados; ficam na maquina alvo)

Em `C:\davidagostini\instalador\`:
- `log\` — um `install.log` por execucao.
- `installer-state.json` — ledger (aba Status).
- `software-extra.json` — catalogo de software do usuario (editavel).

## Pendencias (combinadas, ainda NAO feitas)

1. **Reativar a validacao SHA256** do launcher e **pinar numa tag** (publicacao
   imutavel). Hoje o `bootstrap-head.ps1` esta em **bypass TEMPORARIO** (so avisa),
   entre marcadores `==== TEMPORARIO`. Passos em `CLAUDE.md` (secao Distribuicao).
2. **(FEITO) Async na GUI**: worker em runspace + **fila serial** (varios "Aplicar"
   enfileiram) + aba **"Log ao vivo"** (DispatcherTimer drena o log do worker) +
   **fallback sincrono**. O bootstrap-head expoe a fonte (`$global:WINCFG_PAYLOAD_SRC`)
   e o tail pula o Start-Gui no worker (`$env:WINCFG_NOUI`).
3. **SQL Server (choco, Developer)**: a escolha esta certa; se o `ExitCode -1`
   voltar, investigar pre-requisitos do pacote (o detalhe agora vai pro log).
4. (Opcional) Abas separadas em Features; tamanhos extras do icone.

## Avisos para nao quebrar

- **`.gitattributes`** marca `dist/payload.ps1` e `dist/bootstrap.ps1` como `-text`.
  NAO remover — senao o git converte CRLF→LF e o SHA256 do `irm` nao confere.
- `Install-WindowsFeature` **nao** tem `-NoRestart` (so `Enable-WindowsOptionalFeature`).
- Ler o ledger sempre via `Get-FeatureStateLedger` (trata o gotcha do `ConvertFrom-Json`
  com 2+ itens no PS 5.1).
