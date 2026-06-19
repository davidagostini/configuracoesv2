# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## O que é este projeto

Configurador interativo de **Windows Server / Windows 11** em PowerShell. Um menu
único (`setup.ps1`) carrega módulos por área e instala/configura recursos comuns
(IIS, Hyper-V, Telnet, .NET, MSMQ, WCF), ajustes de base (time zone, IE ESC,
hora/NTP, Server Manager), customizações de UI (dark mode, extensões, ocultos) e
softwares via Chocolatey **ou** winget.

Idioma do projeto: **português**. Logs, mensagens e comentários em PT (sem acentos
nos `.ps1` para evitar problemas de encoding no console). Ambiente alvo: Windows
PowerShell **5.1** (`powershell.exe`).

## Como executar / desenvolver

```powershell
# Rodar o configurador (auto-eleva para Admin):
powershell -ExecutionPolicy Bypass -File .\setup.ps1

# Checar a sintaxe de todos os scripts (faça isto após editar qualquer .ps1):
Get-ChildItem .\setup.ps1, .\build.ps1, .\bootstrap-*.ps1, .\modules\*.ps1 | ForEach-Object {
  $e=$null; [System.Management.Automation.PSParser]::Tokenize((Get-Content $_.FullName -Raw),[ref]$e) | Out-Null
  if ($e.Count) { "ERRO $($_.Name)"; $e | % { $_.Message } } else { "OK $($_.Name)" }
}

# Gerar os artefatos de distribuição (dist/payload.ps1 + dist/bootstrap.ps1 + SHA256):
powershell -ExecutionPolicy Bypass -File .\build.ps1            # -Ref main (teste)
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Ref v1.0.0  # pinado numa tag (publicar)
```

Não há suíte de testes. A validação é: (1) `PSParser` (acima) e (2) execução manual
do menu. O menu é interativo (`Read-Host`), então para rodar na própria sessão use o
prefixo `! ...` em vez de chamar pela ferramenta de shell.

## Arquitetura

`setup.ps1` é o entrypoint: auto-eleva para Admin, faz **dot-source** de `Common.ps1`,
`OSCommon.ps1` e dos módulos de área, e chama **`Start-Gui`** (`GuiWpf.ps1`): abre a janela
**WPF** e, sem WPF (Server Core/headless/não-STA), cai para o menu de console `Start-MainMenu`.
O **mesmo `Start-Gui`** é o ponto de entrada do bundle `irm` (`bootstrap-tail.ps1`). Cada aba/opção
chama funções dos módulos. Como tudo é dot-sourced no escopo do `setup.ps1`, **`$Script:` é um
escopo compartilhado entre todos os módulos** (ex.: `$Script:FeatureResults`, `$Script:OSRole`).

Módulos (em `modules/`):
- **`Common.ps1`** — fundação compartilhada. `Write-Log` (grava em `logs/install.log` +
  console colorido), `Set-RegistryValue` (idempotente), o **controle de reinício/resultado**
  (`Test-PendingReboot`, `Test-CanInstallOrDefer`, `Add-FeatureResult`, `Show-FeaturesSummary`,
  `Enable-OptionalFeatureSafe`) e o **ledger persistente** (`installer-state.json`):
  `Save-FeatureState` / `Get-FeatureStateLedger` / `Clear-FeatureState`. `Add-FeatureResult`
  grava cada resultado no ledger para a aba "Status" saber, ao reabrir (inclusive após reboot),
  o que já foi feito.
- **`OSCommon.ps1`** — `Get-OSRole` (client vs server, Server Core, capacidade de GUI, cacheado em
  `$Script:OSRole`); o **catálogo de capacidades** (`$Script:CapabilityCatalog`) e o dispatch:
  `Get-AvailableCapabilities` (filtra por SO), `Install-Capability`, `Install-CapabilityServerRole`,
  `Invoke-CapabilityInstall`.
- **`Customizations.ps1`** — dark mode, mostrar extensões e ocultos (registro `HKCU`).
- **`WindowsFeatures.ps1`** — Hyper-V (OS-aware), Telnet Client, **NAT Switch** (`New-NatSwitch`) e
  **DHCP para o NAT** (só Server): `Install-DhcpRoleForNat`, `Get-NatNetworkInfo` (detecta a rede NAT
  e o IP do host = gateway), `Set-NatDhcpScope` (scope + gateway/DNS/lease + bind SÓ na interface do
  NAT), `Invoke-NatDhcpPrompt`. Helpers IPv4: `ConvertTo/From-IPv4UInt32`, `Get-IPv4MaskFromPrefix`.
- **`BaseConfig.ps1`** — desativar IE ESC, time zone Brasília, sync NTP, Server Manager no logon.
- **`IIS.ps1`** — lista declarativa `$Script:IISFeatures` (~42 features) + `aspnet_state` + `iisreset`
  (`Install-IISFull`). A GUI lista essas features em checkboxes **na ordem do array**.
- **`Software.ps1`** — catálogo declarativo `$Script:SoftwareCatalog` (app -> id choco + id winget +
  flags) **+ catálogo de usuário editável** (`software-extra.json`): `Import-UserSoftwareCatalog`
  (mescla) e `Add-UserSoftware` (grava) — adicionar apps sem mexer no código. Instala via choco **ou**
  winget; `Install-Chocolatey` faz bootstrap.
- **`Gui.ps1`** — fallback de console e o **menu principal**: `Start-MainMenu` / `Show-MainMenu`,
  `Show-InstallerGui` (WinForms), `Show-InstallerConsole`, `Start-InstallerUi`, `Get-SummaryText`.
- **`GuiWpf.ps1`** — **UI primária**: janela **WPF** estilo app, abas (Status, Features, Softwares,
  IIS, Rede NAT/DHCP, Customizações, Config base). `Start-Gui` tenta WPF e cai para `Start-MainMenu`
  (console) sem WPF (Server Core/headless/não-STA). Janela fica aberta (sessão iterativa); **cada
  "Aplicar" pede confirmação** (Sim/Não) e desabilita os botões durante a execução.

## Convenções e invariantes (NÃO quebrar)

- **Nunca reiniciar automaticamente.** `Enable-WindowsOptionalFeature` usa `-NoRestart`;
  `Install-WindowsFeature` (ServerManager) **não tem** `-NoRestart` e por padrão já não reinicia
  (nunca passar `-Restart`). Em ambos detecta-se `RestartNeeded` e registra-se `PrecisaReinicio`
  — o reinício é manual.
- **Deferir em reinício pendente.** Antes de instalar uma feature, `Test-CanInstallOrDefer`
  checa `Test-PendingReboot`; se houver reinício pendente, o item é **deferido** (não instalado)
  e registrado como `Deferido`. Isso evita falhas em cadeia.
- **Resumo categorizado + ledger.** Cada ação chama `Reset-FeatureSession` na entrada e
  `Show-FeaturesSummary` na saída: Instalados / Precisa Reinício / Deferidos / Falhas. Toda
  ação deve registrar via `Add-FeatureResult` — que também grava no **ledger persistente**
  (`installer-state.json`), lido pela aba "Status" para retomada após reboot. Idempotência
  continua sendo o mecanismo real de "continuar de onde parou" (rodar de novo pula o que já está feito).
- **GUI: confirmação por ação.** Toda aplicação na janela WPF pede confirmação (Sim/Não) e
  desabilita os botões durante a execução. A execução é **síncrona** (a janela congela em
  operações longas; o log ao vivo sai no console). Isso evita disparo acidental por clique enfileirado.
- **Idempotência.** Operações checam estado antes de agir (`Set-RegistryValue`, `Get-WindowsFeature`,
  `Get-WindowsOptionalFeature` etc.) e não repetem trabalho.
- **Dispatch por capacidade, não por nome de SO.** Para escolher a API de feature, cheque a
  presença do módulo ServerManager (`(Get-OSRole).HasServerManager`), não o nome da edição. Só o
  Hyper-V e Containers/Sandbox divergem de verdade entre client e server; as demais features usam
  os mesmos ids DISM nos dois. Ver `docs/DESIGN-irm-gui.md`.

## Distribuição (implementada — v1.0.0 — ver docs/)

Lançamento via one-liner `irm <url> | iex` com **janela WPF** (fallback WinForms/console),
em Win11 e Server. Modelo **launcher + payload** (2 arquivos), para a verificação SHA256 proteger
o que executa sem o problema do "hash de si mesmo":

- `dist/payload.ps1` — módulos concatenados + `bootstrap-tail.ps1` (chama `Start-Gui`). É o que
  roda; tem seu SHA256 calculado pelo build.
- `dist/bootstrap.ps1` — launcher (`bootstrap-head.ps1`) com URLs pinadas e o SHA256 do payload
  **baked**. É o alvo do `irm | iex`. Faz re-spawn único (Admin+STA+Bypass, sentinela
  `WINCFG_RELAUNCHED` anti-loop), baixa o payload, confere o SHA256 e só então executa.

> ⚠️ **EOL dos artefatos:** `dist/payload.ps1` e `dist/bootstrap.ps1` estão marcados como `-text`
> em `.gitattributes`. **Não remover** — sem isso o git normaliza CRLF→LF e o SHA256 do `irm`
> nunca confere (o build assa o hash da versão CRLF; o `raw` serve o blob versionado).
>
> ⚠️ **TEMPORÁRIO:** a validação SHA256 no `bootstrap-head.ps1` está em **modo aviso** (não aborta),
> entre marcadores `==== TEMPORARIO`, para destravar testes. **Reativar (voltar ao `return`) antes
> de pinar uma tag.**

**Publicar uma versão** (pinagem imutável via tag — nunca reusar uma tag já publicada):
1. reativar o SHA256 no head; 2. `build.ps1 -Ref main` + commit (cria o blob); 3. `build.ps1 -Ref vX.Y.Z`
ou `-Ref <commitSHA>`; 4. commit; 5. `git tag -a vX.Y.Z`; 6. push commit + tag. O one-liner aponta para
`.../<ref>/dist/bootstrap.ps1` (precedido de `[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;`).
Durante o desenvolvimento, testa-se com `-Ref main` (mutável).

Decisões e divergências de design estão em `docs/DECISOES.md` e `docs/DESIGN-irm-gui.md`.

## Repositório

Remoto: `https://github.com/davidagostini/configuracoesv2.git` (branch `main`).
Git foi instalado via winget (`Git.Git`). `logs/` fica fora do versionamento; de `dist/` só são
versionados os artefatos publicados (`bootstrap.ps1`, `payload.ps1`, `payload.ps1.sha256`).
`.gitattributes` marca os dois `.ps1` do `dist/` como `-text` (ver Distribuição). Arquivos de
**runtime** ficam em `C:\davidagostini\instalador\` e **não** são versionados: `log\` (logs por
execução), `installer-state.json` (ledger da aba Status) e `software-extra.json` (catálogo de
software do usuário).
