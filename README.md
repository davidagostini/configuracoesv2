# configuracoesv2

Configurador interativo de **Windows Server / Windows 11** via scripts PowerShell.
Permite instalar e configurar recursos comuns (IIS, Hyper-V, Telnet, .NET, MSMQ, WCF),
ajustes de base (time zone, IE ESC, hora/NTP, Server Manager) e customizações de
interface (dark mode, extensões e arquivos ocultos) por um menu único.

## Como usar

Abra o PowerShell **como Administrador** (o script tenta auto-elevar) e execute:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Escolha no menu o que deseja instalar/configurar.

## Estrutura

```
setup.ps1                 # menu master (auto-eleva, carrega os módulos)
modules/
  Common.ps1              # log, registro idempotente, controle de reinício, resumo
  Customizations.ps1      # dark mode, mostrar extensões, mostrar ocultos
  WindowsFeatures.ps1     # Hyper-V, Telnet Client
  BaseConfig.ps1          # IE ESC, time zone Brasília, hora/NTP, Server Manager
  IIS.ps1                 # IIS completo (ASP.NET, WCF, WAS, MSMQ) + iisreset
logs/                     # logs de execução (gerados em runtime; fora do git)
```

## Princípios de segurança adotados

- **Nunca reinicia automaticamente** — usa `-NoRestart` e avisa quando há reinício pendente.
- **Defere instalações** quando já existe reinício pendente (evita falhas) e mostra um
  **resumo** ao final: instalados / precisam de reinício / não instalados / falhas.
- Operações de registro são **idempotentes** (só alteram quando necessário).

## Em desenvolvimento

- Lançamento via `irm <url> | iex` (GitHub, URL pinada em commit + verificação SHA256).
- Tela clicável (GUI com fallback de console) com **pasta de log configurável**.
- Camada **OS-aware**: detecta Windows 11 (client) vs Windows Server e usa o método
  correto por recurso (ex.: Hyper-V via `Enable-WindowsOptionalFeature Microsoft-Hyper-V-All`
  no client vs `Install-WindowsFeature Hyper-V` no server).
