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
Get-ChildItem .\setup.ps1, .\modules\*.ps1 | ForEach-Object {
  $e=$null; [System.Management.Automation.PSParser]::Tokenize((Get-Content $_.FullName -Raw),[ref]$e) | Out-Null
  if ($e.Count) { "ERRO $($_.Name)"; $e | % { $_.Message } } else { "OK $($_.Name)" }
}
```

Não há suíte de testes. A validação é: (1) `PSParser` (acima) e (2) execução manual
do menu. O menu é interativo (`Read-Host`), então para rodar na própria sessão use o
prefixo `! ...` em vez de chamar pela ferramenta de shell.

## Arquitetura

`setup.ps1` é o entrypoint: auto-eleva para Admin, faz **dot-source** de `Common.ps1`,
`OSCommon.ps1` e dos módulos de área, e roda um loop de menu. Cada opção do menu chama
uma função `Invoke-*Menu` de um módulo. Como tudo é dot-sourced no escopo do `setup.ps1`,
**`$Script:` é um escopo compartilhado entre todos os módulos** (ex.: `$Script:FeatureResults`,
`$Script:OSRole` são vistos por todos).

Módulos (em `modules/`):
- **`Common.ps1`** — fundação compartilhada. `Write-Log` (grava em `logs/install.log` +
  console colorido), `Set-RegistryValue` (idempotente), e o **controle de reinício/resultado**:
  `Test-PendingReboot`, `Test-CanInstallOrDefer`, `Add-FeatureResult`, `Show-FeaturesSummary`,
  e `Enable-OptionalFeatureSafe` (wrapper de `Enable-WindowsOptionalFeature`).
- **`OSCommon.ps1`** — `Get-OSRole`: detecta client vs server, Server Core e capacidade de GUI
  (cacheado em `$Script:OSRole`). Base do dispatch por capacidade e da tela híbrida.
- **`Customizations.ps1`** — dark mode, mostrar extensões e ocultos (registro `HKCU`).
- **`WindowsFeatures.ps1`** — Hyper-V (OS-aware) e Telnet Client.
- **`BaseConfig.ps1`** — desativar IE ESC, time zone Brasília, sync NTP, Server Manager no logon.
- **`IIS.ps1`** — lista declarativa `$Script:IISFeatures` (~45 features) + `aspnet_state` + `iisreset`.
- **`Software.ps1`** — catálogo declarativo `$Script:SoftwareCatalog` (app -> id choco + id winget +
  flags). Instala via choco **ou** winget (escolha do usuário); `Install-Chocolatey` faz bootstrap.

## Convenções e invariantes (NÃO quebrar)

- **Nunca reiniciar automaticamente.** Toda instalação usa `-NoRestart`. Quando um recurso
  exige reinício, registra-se `PrecisaReinicio` e avisa-se — o reinício é manual.
- **Deferir em reinício pendente.** Antes de instalar uma feature, `Test-CanInstallOrDefer`
  checa `Test-PendingReboot`; se houver reinício pendente, o item é **deferido** (não instalado)
  e registrado como `Deferido`. Isso evita falhas em cadeia.
- **Resumo categorizado.** Cada submenu chama `Reset-FeatureSession` na entrada e
  `Show-FeaturesSummary` na saída: Instalados / Precisa Reinício / Deferidos / Falhas. Toda
  ação de feature/software deve registrar via `Add-FeatureResult`.
- **Idempotência.** Operações checam estado antes de agir (`Set-RegistryValue`, `Get-WindowsFeature`,
  `Get-WindowsOptionalFeature` etc.) e não repetem trabalho.
- **Dispatch por capacidade, não por nome de SO.** Para escolher a API de feature, cheque a
  presença do módulo ServerManager (`(Get-OSRole).HasServerManager`), não o nome da edição. Só o
  Hyper-V e Containers/Sandbox divergem de verdade entre client e server; as demais features usam
  os mesmos ids DISM nos dois. Ver `docs/DESIGN-irm-gui.md`.

## Distribuição (em andamento — ver docs/)

Objetivo: lançar via one-liner `irm <url> | iex` com uma **tela clicável** (WinForms com
fallback de console) que roda em Win11 e Server. Decisões e o design verificado estão em
`docs/DECISOES.md` e `docs/DESIGN-irm-gui.md`. Hospedagem: GitHub, URL pinada em commit SHA +
verificação SHA256 de um bundle único (gerado por um passo de build que concatena os módulos).

## Repositório

Remoto: `https://github.com/davidagostini/configuracoesv2.git` (branch `main`).
Git foi instalado via winget (`Git.Git`). `logs/` e `dist/` ficam fora do versionamento (`.gitignore`).
