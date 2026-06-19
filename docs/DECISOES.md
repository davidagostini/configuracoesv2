# Decisões do projeto

Registro das decisões tomadas com o usuário (David Agostini), para preservar contexto
entre sessões.

## Organização

- **Script master interativo** (`setup.ps1`) que vai chamando módulos por área. O usuário
  escolhe no menu o que instalar/configurar.
- Idioma PT; comentários e logs sem acentos nos `.ps1` (encoding de console 5.1).

## Segurança de reinício (regra central)

- **Nunca reiniciar automaticamente.** `Enable-WindowsOptionalFeature` usa `-NoRestart`;
  `Install-WindowsFeature` (ServerManager) **não tem** `-NoRestart` e já não reinicia por padrão
  (nunca passar `-Restart`). Bug corrigido: `-NoRestart` em `Install-WindowsFeature` dava erro de
  binding e quebrava a instalação de roles (DHCP, Hyper-V, capacidades de Server).
- **Verificar se precisa reiniciar** (`RestartNeeded` + `Test-PendingReboot`).
- **Deferir** componentes que não puderam ser instalados porque há **reinício pendente**, e
  **listar** esses no resumo (instalados / precisa-reinício / **deferidos** / falhas).

## Recursos com opções de versão

- **SQL Server**: oferecer **2022 e 2025** (catálogo de Software), **via Chocolatey, edição
  Developer** (`sql-server-2022` / `sql-server-2025`; sem pacote winget oficial).
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
- **Implementado em v1.0.0** (modelo launcher + payload — ver `DESIGN-irm-gui.md`). Pinagem por
  **git tag** (imutável e resolve o `SelfUrl` do re-spawn): `build.ps1 -Ref vX.Y.Z` -> commit ->
  `git tag -a vX.Y.Z` -> push commit + tag. **Nunca reusar/mover uma tag já publicada;** correção
  vira nova tag (v1.0.1, ...). One-liner publicado aponta para `.../v1.0.0/dist/bootstrap.ps1`.

## Tela (UI) e log

- **UI primária: janela WPF** (`GuiWpf.ps1`, `Start-Gui`) estilo app, tema escuro, com **abas**:
  Status, Features, Softwares, IIS, Rede (NAT/DHCP), Customizações, Config base. **Fallback
  automático para o menu de console** (`Start-MainMenu`) sem WPF (Server Core / headless / sem STA).
  A WinForms (`Show-InstallerGui`) vira a tela de capacidades do menu de console. Mesmo motor
  por baixo (`Common.ps1`).
- **Janela aberta / iterativa**: cada aba tem seu "Aplicar"; a janela não fecha entre ações.
- **Confirmação por ação**: todo "Aplicar" pede Sim/Não e os botões são desabilitados durante a
  execução. Motivo: a execução é **síncrona** (a janela congela em operações longas, com o log no
  console); sem isso, um clique enfileirado disparava ação por engano (chegou a iniciar o IIS sozinho).
  **Pendente:** execução assíncrona (runspace) para não congelar.
- A tela tem um campo **"Pasta de log"** configurável; cada ação grava o resultado lá. Gerar
  **um log por execução com timestamp** + salvar o **resumo final** na pasta escolhida.
  Pasta de log padrão: **`C:\davidagostini\instalador\log\`** (decisão do usuário).
  `Set-LogDirectory` (em `Common.ps1`) torna `$Script:LogFile` configurável. **Implementado.**

## Estado persistente / retomada após reinício

- **Ledger `installer-state.json`** (na pasta de log): `Add-FeatureResult` grava cada resultado
  (Name/Status/Detail/Timestamp, upsert por Name). A aba **"Status"** lê isso ao abrir — inclusive
  **após um reinício** — e mostra o que foi feito / precisa reinício / ficou deferido, com **aviso
  de reinício pendente** (`Test-PendingReboot`). Botões Atualizar e Limpar histórico.
- A retomada de fato continua sendo a **idempotência**: rodar de novo pula o que já está feito; o
  ledger é o "painel" do que aconteceu, não um motor de replay.

## Catálogo de software do usuário

- Arquivo **`software-extra.json`** (em `C:\davidagostini\instalador\`): o usuário adiciona apps
  próprios (ex.: um lançamento novo) **sem mexer no código**. Formato: array de
  `{ Key, Name, Category, Winget, Choco, Notes }` (mínimo: Name + um ID). `Import-UserSoftwareCatalog`
  mescla no catálogo (upsert por Key); `Add-UserSoftware` grava (usado pelo botão "Adicionar
  software..." da GUI). Carregado também no menu de console.

## DHCP para o NAT Switch (só Server)

- Um NAT switch não distribui IP. Decisão: instalar a role **DHCP no host** e criar um scope na
  sub-rede do NAT, com **bind SÓ na interface do NAT** (nunca responde na rede física). A GUI/menu
  **detecta** a rede NAT e o IP do host (gateway), pré-preenche os campos, pede **DNS** (default OVH
  `213.186.33.99`) e **lease** longo (default **7300 dias / 20 anos**, para o IP ficar fixo na prática).
  Runbook portátil em `docs/RUNBOOK-DHCP-NAT-HyperV.md`. Remoção é manual (console do DHCP).

## Correções técnicas de distribuição

- **EOL dos artefatos do `dist/`**: `core.autocrlf=true` normalizava `payload.ps1` para LF e o SHA256
  (assado sobre a versão CRLF) nunca conferia no `irm`. Resolvido com **`.gitattributes`** marcando
  `dist/payload.ps1` e `dist/bootstrap.ps1` como `-text` (bytes verbatim).
- **Validação SHA256 em bypass TEMPORÁRIO** (modo aviso) no `bootstrap-head.ps1`, a pedido, para
  destravar testes. **Reativar antes de pinar uma tag.**

## NetFx3 (.NET 3.5) e payload

- O payload vem **do Windows** (WU/online por padrão). `Enable-OptionalFeatureSafe` aceita
  `-Source`/`-LimitAccess` opcionais para apontar a mídia (`<unidade>\sources\sxs`) caso WU/WSUS
  esteja bloqueado; sem `-Source`, tenta online. **Sem exigir mídia.**

## Assinatura

- Seguir **sem assinar** o `bootstrap.ps1` por ora (decisão do usuário). Bloqueio AMSI é ambiental.

## Repositório

- `https://github.com/davidagostini/configuracoesv2.git`, branch `main`.
- Git instalado via winget. Push exige autenticação (GCM ou PAT) — feito pelo usuário.
