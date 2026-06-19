# Decisões do projeto

Registro das decisões tomadas com o usuário (David Agostini), para preservar contexto
entre sessões.

## Organização

- **Script master interativo** (`setup.ps1`) que vai chamando módulos por área. O usuário
  escolhe no menu o que instalar/configurar.
- Idioma PT; comentários e logs sem acentos nos `.ps1` (encoding de console 5.1).

## Segurança de reinício (regra central)

- **Nunca reiniciar automaticamente.** Trocamos qualquer `-Restart` por `-NoRestart`.
- Se usar `-NoRestart`, **verificar se precisa reiniciar** (`RestartNeeded` + `Test-PendingReboot`).
- **Deferir** componentes que não puderam ser instalados porque há **reinício pendente**, e
  **listar** esses no resumo (instalados / precisa-reinício / **deferidos** / falhas).

## Recursos com opções de versão

- **SQL Server**: oferecer **2022 e 2025** como opções (catálogo de Software).
- **.NET SDK**: oferecer **8 e 10** (SDK e Hosting Bundle).

## Softwares (choco + winget)

- Suportar **os dois** gerenciadores: o usuário escolhe winget, Chocolatey ou auto.
- Catálogo declarativo em `modules/Software.ps1`. IDs do winget **verificados na fonte**
  (`winget` deste servidor). Apps sem pacote winget (FortiClient VPN, Maven, choco-upgrade-all,
  SQL Server full) ficam **só no choco**.
- `Install-Chocolatey` faz o bootstrap oficial do Chocolatey de forma idempotente.

## Distribuição via `irm | iex`

- **Host: GitHub.** URL do bootstrap **pinada num commit SHA** (imutável), nunca `main`.
- **Integridade: SHA256.** O `bootstrap.ps1` baixa um **bundle único**, confere o SHA256 contra
  um hash conhecido embutido e só então auto-eleva e executa. Sempre HTTPS + TLS 1.2.
- **Build**: passo que concatena os módulos num único `dist/bootstrap.ps1` e emite o hash; os
  módulos separados continuam sendo a fonte de manutenção.

## Tela (UI) e log

- Tela **clicável** (WinForms `CheckedListBox`) com **fallback automático para menu de console**
  (Server Core / headless / sem STA). Mesmo motor por baixo (`Common.ps1`).
- A tela tem um campo **"Pasta de log"** configurável; cada ação grava o resultado lá. Gerar
  **um log por execução com timestamp** + salvar o **resumo final** na pasta escolhida.
  (Implementação pendente: tornar `$Script:LogFile` configurável via `Set-LogDirectory`.)

## Repositório

- `https://github.com/davidagostini/configuracoesv2.git`, branch `main`.
- Git instalado via winget. Push exige autenticação (GCM ou PAT) — feito pelo usuário.
