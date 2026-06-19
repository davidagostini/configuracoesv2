# Design verificado: lançador `irm | iex` com tela clicável (Win11 + Server)

> Resultado de um workflow de design/verificação (13 agentes). Estado: **projetado e
> verificado, ainda NÃO implementado**. Este doc é o plano de implementação da próxima fase.

## 1. Visão geral

Ferramenta única, lançável por `irm <url> | iex`, que abre uma **tela clicável** (WinForms
`CheckedListBox` com `CheckOnClick`, botões "Selecionar tudo"/"Instalar") quando há GUI, e
**cai automaticamente** para um menu de console multi-select quando não há (Server Core,
sessão não-interativa, WinForms indisponível). O mesmo codebase roda em Windows 11 e Windows
Server (full e Core). As regras do motor (`Common.ps1`) ficam intactas: nunca reiniciar,
`-NoRestart`, deferir em reinício pendente, resumo categorizado.

Camadas (decisão em runtime, nesta ordem):

```
[bootstrap.ps1 auto-contido]            <- hospedado; o que 'irm|iex' executa
   | PASSO 1: re-spawn ÚNICO = Admin (RunAs) + STA + ExecutionPolicy Bypass,
   |          sempre via powershell.exe (5.1, sempre presente). Sentinela
   |          $env:WINCFG_RELAUNCHED evita loop de UAC.
   v
[Seletor de front-end]                  <- Get-OSRole: CanUseGui? GUI : console
   v
[Camada de capacidade Server vs Client] <- catálogo + Install-Capability (dispatch)
   v
[Motor Common.ps1 INALTERADO]           <- Test-CanInstallOrDefer / -NoRestart / Add-FeatureResult / Show-FeaturesSummary
```

Decisão: GUI primária WinForms via `powershell.exe -STA` (in-box em Win11 e Server com Desktop
Experience), **com fallback de console obrigatório**. **Não** usar `Out-GridView` como camada
universal (ausente em Server Core / pwsh 7).

## 2. Arquivos a criar/alterar

| Arquivo | Papel |
|---|---|
| `bootstrap.ps1` (hospedado) | Entrypoint do `irm`. Re-spawn (admin+STA+policy) e roteia GUI vs console. Sob `irm\|iex` não há disco → deve ser o **bundle concatenado** (build). |
| `modules/OSCommon.ps1` | **Já criado**: `Get-OSRole`. A criar: `$Script:CapabilityCatalog`, `Install-Capability`, `Install-CapabilityServerRole`, `Get-AvailableCapabilities`, `Invoke-CapabilityInstall`. |
| `modules/Gui.ps1` (novo) | `Show-InstallerGui` (WinForms + runspace de background + resumo em MessageBox), `Show-InstallerConsole` (fallback), `Start-InstallerUi` (escolhe). |
| `build.ps1` (novo) | Concatena `Common.ps1`+`OSCommon.ps1`+`Gui.ps1`+tail num `dist/bootstrap.ps1` e emite o SHA256. |
| `Common.ps1` (alterar) | (a) log-path absoluto quando `$PSScriptRoot` vazio; (b) `Enable-OptionalFeatureSafe` ganha `-Source`/`-LimitAccess` (NetFx3/WCF non-45). |
| `setup.ps1` (alterar) | Corrigir elevação para não depender de `$PSCommandPath` (vazio sob `irm\|iex`). |

## 3. Detecção de SO + tabela de despacho

`Get-OSRole` (já em `modules/OSCommon.ps1`) devolve: `Sku` (Client/Server via `ProductType -ne 1`),
`IsServerCore` (`InstallationType='Server Core'`), `HasServerManager`, `CanUseGui`, `Caption`.

**Dispatch por CAPACIDADE, não por nome de SO.** Das 10 capacidades, **8 são cross-OS sem mudança**
(mesmos ids DISM via `Enable-WindowsOptionalFeature` nos dois SOs). Só **2 bifurcam**:

| Id | Display | AvailableOn | Client (Win11) | Server |
|---|---|---|---|---|
| `HyperV` | Hyper-V | Client, Server | `Enable-OptionalFeatureSafe Microsoft-Hyper-V-All -All` | `Install-WindowsFeature Hyper-V -IncludeManagementTools` |
| `Telnet` | Telnet Client | Both | `TelnetClient` (id idêntico) | idem |
| `IISCore` | IIS WebServer | Both | `IIS-WebServerRole,IIS-WebServer -All` | idem |
| `IISAspNet` | IIS ASP.NET 4.x | Both | `IIS-ASPNET45 -All` | idem |
| `IISMgmt` | IIS Mgmt | Both | `IIS-ManagementConsole,...Scripting,...Service -All` | idem |
| `NetFx3` | .NET 3.5 | Both | `NetFx3 -All [-Source ...sxs -LimitAccess]` | idem |
| `MSMQ` | MSMQ | Both | `MSMQ-Server -All` | idem |
| `WAS` | WAS | Both | `WAS-* -All` | idem |
| `WCFActivation` | WCF Activation | Both | `WCF-*-Activation45 -All` (+ non-45 após NetFx3) | idem |
| `Containers` | Containers | Client, Server | `Containers -All` | `Install-WindowsFeature Containers` |
| `Sandbox` | Windows Sandbox | **Client only** | `Containers-DisposableClientVM -All` | (oculto na UI) |

Notas críticas (das verificações):
- **Não misturar nomenclaturas**: `Install-WindowsFeature -Name Microsoft-Hyper-V-All` é inválido.
  Server usa `Hyper-V`; client usa `Microsoft-Hyper-V-All`. (Já corrigido em `Install-HyperVRole`.)
- `Enable-WindowsOptionalFeature` **existe também no Server** — o que falta no client é o módulo
  ServerManager. Por isso o dispatch é por `HasServerManager`.
- `WCF-HTTP-Activation`/`WCF-NonHTTP-Activation` (sem `45`) pertencem à subárvore do NetFx3 →
  habilitar **depois** do NetFx3 e herdam o requisito de `-Source`.
- `NetFx3` é FoD sem payload local → falha `0x800F0954/0x800F081F` se WU/WSUS bloqueado. O
  `Enable-OptionalFeatureSafe` estendido faz retry com `-Source <mídia>\sources\sxs -LimitAccess`.

## 4. STA + auto-elevação sob `irm | iex`

Sob `irm|iex`: `$PSCommandPath`/`$MyInvocation.MyCommand.Path` ficam **vazios** (a elevação
atual com `-File "$PSCommandPath"` vira `-File ""` e não faz nada). Resolver os três problemas
(sem-arquivo, não-admin, não-STA) num **único re-spawn**:

```powershell
# topo do bootstrap.ps1 (PASSO 1)
$Script:SelfUrl = 'https://<HOST>/<owner>/<repo>/<SHA>/bootstrap.ps1'  # baked ao publicar
$needAdmin = -not (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needSta   = [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'
if (($needAdmin -or $needSta) -and -not $env:WINCFG_RELAUNCHED) {
    $cmd = "`$env:WINCFG_RELAUNCHED='1'; " +
           "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; " +
           "irm '$Script:SelfUrl' | iex"
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-STA','-ExecutionPolicy','Bypass','-Command',$cmd) }
    catch { Write-Host "Elevacao cancelada (UAC). Abortando." -ForegroundColor Yellow }
    return
}
# daqui em diante: ADMIN + STA + Bypass garantidos
```

**Por que `powershell.exe -STA`** (não pwsh): `powershell.exe` 5.1 está **sempre presente** em
Win11/Server e é STA por padrão. (Correção de um veredicto: pwsh 7 também é **STA por padrão** —
o motivo do relaunch é "powershell.exe sempre presente", não "pwsh é MTA". Mas a checagem
`GetApartmentState()` continua necessária, pois sob `irm|iex` herda-se o apartment do host, que
pode ser MTA — ex.: terminal integrado do VS Code, `powershell -MTA`.)

**Empacotamento obrigatório**: sob `irm|iex` não há `modules\` no disco, e
`$MyInvocation.MyCommand.Definition` só captura o corpo de topo (não os dot-sources). Logo o
`bootstrap.ps1` publicado é o **bundle concatenado** (`build.ps1`). O `setup.ps1` local continua
usando dot-source para desenvolvimento.

## 5. One-liner final

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://<HOST>/<owner>/<repo>/<SHA>/bootstrap.ps1 | iex
```

`Tls12` explícito é **obrigatório no one-liner** (não dentro do script): em PS 5.1/hosts
endurecidos o `irm` falha com "Could not create SSL/TLS secure channel" antes de qualquer código.
Não usar `-bor Tls13` (enum ausente em .NET antigo → lança).

Acrescentar a verificação **SHA256** do bundle (decisão do usuário): o bootstrap baixa o payload,
confere o hash conhecido embutido e só então executa.

## 6. Gotchas (resumo) e mitigações

- **`$PSScriptRoot` vazio** sob `irm|iex` → log no lugar errado. Mitigar: log-path absoluto
  (`%ProgramData%\wincfg\logs\install.log`) quando `$PSScriptRoot` vazio.
- **ExecutionPolicy AllSigned por GPO** sobrepõe `-ExecutionPolicy Bypass` no `-File`. Por isso a
  estratégia A usa `-Command` in-memory (sem `-File`).
- **AMSI/AV** inspecionam a string do `iex` e o conteúdo. Servir HTTPS de host confiável, sem
  ofuscação; idealmente Authenticode-assinar o `bootstrap.ps1`. Bloqueio AMSI é ambiental.
- **Loop de UAC**: sentinela `$env:WINCFG_RELAUNCHED` curto-circuita as checagens no filho.
- **Server Core/headless**: `CanUseGui=$false` → console. Console deve ler de `[Console]::ReadLine()`
  (não `Read-Host`, pois o pipeline carrega o corpo do script sob `irm|iex`) e usar try/catch no
  `SetCursorPosition`.
- **GUI não congelar**: rodar a instalação num runspace de background com form de progresso
  (`ProgressBar Marquee`); resumo via MessageBox a partir de `$Script:FeatureResults`.

## 7. Hospedagem (decidido: GitHub)

`raw.githubusercontent.com/davidagostini/configuracoesv2/<SHA>/bootstrap.ps1` (SHA imutável).
A URL canônica fica **baked** em `$Script:SelfUrl` (sob `irm|iex` o script não descobre a própria
origem). Publicar sempre o **bundle concatenado**, nunca os módulos separados.
