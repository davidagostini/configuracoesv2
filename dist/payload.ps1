#Requires -Version 5.1
# === PAYLOAD GERADO POR build.ps1 - NAO EDITAR A MAO ===
# Fonte: modules\*.ps1 + bootstrap-tail.ps1. Para alterar, edite as fontes e rode build.ps1.

# ===== INICIO modules\Common.ps1 =====
# ============================================================================
#  Common.ps1  -  Funcoes compartilhadas usadas por todos os modulos
#  Carregado (dot-sourced) pelo setup.ps1. Nao executar diretamente.
# ============================================================================

# --- Logging ---------------------------------------------------------------

# Pasta de log padrao do projeto (decisao do usuario). Usada quando rodando
# via 'irm | iex' (sem disco/$PSScriptRoot) ou quando o usuario nao define outra.
$Script:DefaultLogDir = 'C:\davidagostini\instalador\log'

# Resolve a pasta de log inicial:
#  - se $PSScriptRoot existe (dev local com modulos no disco) -> ..\logs
#  - senao (irm|iex, bundle em memoria)                       -> pasta padrao
if ($PSScriptRoot) {
    $Script:LogFile = Join-Path $PSScriptRoot '..\logs\install.log'
} else {
    $Script:LogFile = Join-Path $Script:DefaultLogDir 'install.log'
}

# Arquivo de ESTADO (ledger) persistente: registra o que ja foi feito, com status
# e timestamp, para que ao reabrir (inclusive apos um reinicio) seja possivel
# mostrar o que ja rodou / o que precisa de reinicio / o que ficou deferido.
$Script:StateFile = Join-Path (Split-Path $Script:LogFile -Parent) 'installer-state.json'

# Define a pasta onde os logs serao gravados (campo "Pasta de log" da tela).
# Gera um arquivo por execucao com timestamp passado pelo chamador, ou o
# install.log padrao quando -FileName nao e informado.
function Set-LogDirectory {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $FileName = 'install.log'
    )
    if (-not $Path) { return }
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $Script:LogFile   = Join-Path $Path $FileName
    $Script:StateFile = Join-Path $Path 'installer-state.json'
    Write-Log "Pasta de log definida: $Path" -Level INFO
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERRO', 'STEP')] [string] $Level = 'INFO'
    )

    $stamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line   = "[$stamp] [$Level] $Message"

    # Garante a pasta de logs
    $logDir = Split-Path $Script:LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8

    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERRO' { 'Red' }
        'STEP' { 'Cyan' }
        default { 'Gray' }
    }
    $prefix = switch ($Level) {
        'OK'   { '  [OK]  ' }
        'WARN' { '  [!]   ' }
        'ERRO' { '  [X]   ' }
        'STEP' { '==> ' }
        default { '  -    ' }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

# --- Verificacao de privilegios -------------------------------------------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Helpers de Registro (idempotentes) -----------------------------------

# Define um valor de registro, criando a chave se necessario.
# Retorna $true se mudou algo, $false se ja estava no valor desejado.
function Set-RegistryValue {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Value,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string] $Type = 'DWord'
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
        Write-Log "Criada chave de registro: $Path" -Level INFO
    }

    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name

    if ($null -ne $current -and $current -eq $Value) {
        Write-Log "Registro ja configurado: $Name = $Value" -Level OK
        return $false
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Log "Registro definido: $Name = $Value" -Level OK
    return $true
}

# --- Confirmacao do usuario -------------------------------------------------

function Confirm-Action {
    param([string] $Message = 'Deseja continuar?')
    $resp = Read-Host "$Message [S/N]"
    return ($resp -match '^[SsYy]')
}

# ============================================================================
#  Controle de reinicio e resultados (compartilhado por Features e IIS)
# ============================================================================

# Lista acumulada de resultados da sessao: PSCustomObject Name/Status/Detail.
# $Script: aqui = escopo do setup.ps1 (todos os modulos dot-sourced compartilham).
$Script:FeatureResults = @()
$Script:FeatureTimers  = @{}   # Name -> [DateTime] de inicio (para medir duracao)

function Reset-FeatureSession {
    $Script:FeatureResults = @()
    $Script:FeatureTimers  = @{}
}

# Marca o inicio de uma operacao; Add-FeatureResult usa para calcular a duracao.
function Start-FeatureTimer {
    param([Parameter(Mandatory)] [string] $Name)
    $Script:FeatureTimers[$Name] = (Get-Date)
}

# Nome/OS da maquina (cacheados) para o cabecalho do ledger.
$Script:MachineInfo = $null
function Get-MachineInfo {
    if (-not $Script:MachineInfo) {
        $os = ''
        try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
        $Script:MachineInfo = [PSCustomObject]@{ Machine = $env:COMPUTERNAME; OS = $os }
    }
    return $Script:MachineInfo
}

# IPv4 reais do host (sem loopback/link-local) - lidos a cada gravacao do estado.
function Get-HostIPv4 {
    try {
        return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                 Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                 Select-Object -ExpandProperty IPAddress)
    } catch { return @() }
}

function Add-FeatureResult {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Instalado','PrecisaReinicio','Deferido','JaPresente','Falha')] [string] $Status,
        [string] $Detail = ''
    )
    $Script:FeatureResults += [PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail }

    # Inicio/fim/duracao, se houve Start-FeatureTimer para este Name.
    $start = ''; $end = ''; $dur = $null
    if ($Script:FeatureTimers.ContainsKey($Name)) {
        $t0 = $Script:FeatureTimers[$Name]; $t1 = Get-Date
        $start = $t0.ToString('yyyy-MM-dd HH:mm:ss')
        $end   = $t1.ToString('yyyy-MM-dd HH:mm:ss')
        $dur   = [math]::Round(($t1 - $t0).TotalSeconds, 1)
        $Script:FeatureTimers.Remove($Name)
    }
    Save-FeatureState -Name $Name -Status $Status -Detail $Detail -Start $start -End $end -DurationSec $dur
}

# --- Ledger persistente (1 entrada por item, com SNAPSHOT da maquina) -------
# Cada item guarda o estado da maquina NAQUELE momento (nome, OS, IPs, reinicio
# pendente) + inicio/fim/duracao -> material de diagnostico mesmo se o nome ou IP
# mudarem entre execucoes. A tela "Status" le isso ao abrir.
function Get-FeatureStateLedger {
    if (-not (Test-Path $Script:StateFile)) { return @() }
    try {
        $raw = Get-Content -Path $Script:StateFile -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw) { return @() }
        return @($raw | ConvertFrom-Json)
    } catch { return @() }
}

# Upsert (por Name). Falha de IO so avisa (nao interrompe a instalacao).
function Save-FeatureState {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Status,
        [string] $Detail = '',
        [string] $Start = '',
        [string] $End = '',
        $DurationSec = $null
    )
    try {
        $items = @(Get-FeatureStateLedger | Where-Object { $_.Name -ne $Name })
        $mi = Get-MachineInfo
        $items += [PSCustomObject]@{
            Name          = $Name
            Status        = $Status
            Detail        = $Detail
            Start         = $Start
            End           = $End
            DurationSec   = $DurationSec
            Timestamp     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Machine       = $mi.Machine
            OS            = $mi.OS
            IPv4          = @(Get-HostIPv4)
            RebootPending = [bool](Test-PendingReboot)
        }
        $dir = Split-Path $Script:StateFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # PS 5.1: array de 1 item vira objeto no JSON; forca array.
        $json = $items | ConvertTo-Json -Depth 5
        if (@($items).Count -eq 1) { $json = "[$json]" }
        $json | Set-Content -Path $Script:StateFile -Encoding UTF8
    } catch {
        Write-Log "Nao foi possivel gravar o estado: $($_.Exception.Message)" -Level WARN
    }
}

# Zera o ledger (botao "Limpar historico" na tela Status).
function Clear-FeatureState {
    if (Test-Path $Script:StateFile) { Remove-Item -Path $Script:StateFile -Force -ErrorAction SilentlyContinue }
}

# Detecta reinicio pendente por varias fontes conhecidas do Windows.
function Test-PendingReboot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }

    $pfro = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                             -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pfro) { return $true }

    return $false
}

# Guarda de entrada: se ha reinicio pendente, defere o componente e retorna $false.
function Test-CanInstallOrDefer {
    param([Parameter(Mandatory)] [string] $Name)

    if (Test-PendingReboot) {
        Write-Log "'$Name' NAO sera instalado agora: ha reinicio pendente." -Level WARN
        Write-Log "Reinicie o servidor e rode o setup novamente para instalar '$Name'." -Level WARN
        Add-FeatureResult -Name $Name -Status 'Deferido' -Detail 'Reinicio pendente antes da instalacao'
        return $false
    }
    return $true
}

# Habilita uma Feature opcional (DISM/Enable-WindowsOptionalFeature) com:
#  - checagem de "ja habilitada"
#  - guarda de reinicio pendente (defere)
#  - -NoRestart sempre
#  - deteccao de reinicio exigido pela propria feature
#  - registro do resultado
function Enable-OptionalFeatureSafe {
    param(
        [Parameter(Mandatory)] [string] $FeatureName,
        [string] $DisplayName,
        [switch] $All,
        # NetFx3 e WCF non-45 sao FoD sem payload local: se a feature exigir e
        # WU/WSUS estiver bloqueado, pode-se apontar -Source para a midia do
        # Windows (ex.: D:\sources\sxs) com -LimitAccess. Sem -Source, tenta online.
        [string] $Source,
        [switch] $LimitAccess
    )
    if (-not $DisplayName) { $DisplayName = $FeatureName }

    $f = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    if (-not $f) {
        Write-Log "Feature '$FeatureName' nao existe neste SO - ignorando." -Level WARN
        Add-FeatureResult -Name $DisplayName -Status 'Falha' -Detail 'Feature inexistente neste SO'
        return
    }
    if ($f.State -eq 'Enabled') {
        Write-Log "'$DisplayName' ja esta habilitada." -Level OK
        Add-FeatureResult -Name $DisplayName -Status 'JaPresente'
        return
    }

    if (-not (Test-CanInstallOrDefer -Name $DisplayName)) { return }

    try {
        Write-Log "Habilitando '$DisplayName' ($FeatureName)..." -Level STEP
        Start-FeatureTimer -Name $DisplayName
        $eparams = @{
            Online      = $true
            FeatureName = $FeatureName
            All         = $All
            NoRestart   = $true
            ErrorAction = 'Stop'
        }
        if ($Source)      { $eparams['Source']      = $Source }
        if ($LimitAccess) { $eparams['LimitAccess'] = $true }
        $r = Enable-WindowsOptionalFeature @eparams
        if ($r.RestartNeeded) {
            Write-Log "'$DisplayName' habilitada - REINICIO necessario para concluir." -Level WARN
            Add-FeatureResult -Name $DisplayName -Status 'PrecisaReinicio'
        } else {
            Write-Log "'$DisplayName' habilitada." -Level OK
            Add-FeatureResult -Name $DisplayName -Status 'Instalado'
        }
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log "Falha ao habilitar '$DisplayName': $msg" -Level ERRO
        # 0x800F0954 / 0x800F081F: payload (FoD/NetFx3) ausente e WU/WSUS bloqueado.
        if ($msg -match '0x800F0954|0x800F081F|0x800f0906') {
            Write-Log "Dica: '$DisplayName' precisa do payload do Windows. Rode com a midia de instalacao: -Source <unidade>\sources\sxs -LimitAccess" -Level WARN
        }
        Add-FeatureResult -Name $DisplayName -Status 'Falha' -Detail $msg
    }
}

# Resumo categorizado da sessao (instalados / reinicio / deferidos / falhas).
function Show-FeaturesSummary {
    if ($Script:FeatureResults.Count -eq 0) { return }

    Write-Host ""
    Write-Host "  ============== RESUMO DA SESSAO ==============" -ForegroundColor Cyan

    $ok       = $Script:FeatureResults | Where-Object Status -in 'Instalado','JaPresente'
    $reboot   = $Script:FeatureResults | Where-Object Status -eq 'PrecisaReinicio'
    $deferred = $Script:FeatureResults | Where-Object Status -eq 'Deferido'
    $failed   = $Script:FeatureResults | Where-Object Status -eq 'Falha'

    if ($ok)       { Write-Host "  [OK] Instalados / ja presentes:" -ForegroundColor Green
                     $ok | ForEach-Object { Write-Host "       - $($_.Name)" -ForegroundColor Green } }

    if ($reboot)   { Write-Host "  [!] Precisam de REINICIO para concluir:" -ForegroundColor Yellow
                     $reboot | ForEach-Object { Write-Host "       - $($_.Name)" -ForegroundColor Yellow } }

    if ($deferred) { Write-Host "  [>] NAO instalados (aguardando reinicio pendente):" -ForegroundColor Magenta
                     $deferred | ForEach-Object { Write-Host "       - $($_.Name)" -ForegroundColor Magenta }
                     Write-Host "       => Reinicie o servidor e rode o setup novamente." -ForegroundColor Magenta }

    if ($failed)   { Write-Host "  [X] Falhas:" -ForegroundColor Red
                     $failed | ForEach-Object { Write-Host "       - $($_.Name)  ($($_.Detail))" -ForegroundColor Red } }

    if ($reboot -or $deferred) {
        Write-Host ""
        Write-Host "  Reinicie manualmente quando puder:  Restart-Computer" -ForegroundColor Yellow
    }
    Write-Host "  ==============================================" -ForegroundColor Cyan
    Write-Host ""
}
# ===== FIM modules\Common.ps1 =====

# ===== INICIO modules\OSCommon.ps1 =====
# ============================================================================
#  OSCommon.ps1  -  Deteccao de SO (client vs server) e capacidade de GUI
#  Depende do Common.ps1. Base para o dispatch por capacidade e para a tela
#  hibrida (GUI/console) do lancador via 'irm | iex' (ver docs/DESIGN-irm-gui.md).
# ============================================================================

# Deteccao cacheada. Regras (verificadas pelo workflow de design):
#  - SKU por ProductType -ne 1 (1=client/workstation, 2=DC, 3=server).
#    Usar -ne 1 (nao -eq 3) para nao tratar um Domain Controller como nao-servidor.
#  - API de feature por CAPACIDADE, nao por nome: se o modulo ServerManager existe
#    (Install-WindowsFeature) e Server; senao usa Enable-WindowsOptionalFeature.
#  - GUI: Server Core nunca; senao exige WinForms carregavel + sessao interativa.
function Get-OSRole {
    if ($Script:OSRole) { return $Script:OSRole }

    $os = Get-CimInstance Win32_OperatingSystem
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $it = (Get-ItemProperty $cv -Name InstallationType -ErrorAction SilentlyContinue).InstallationType  # Client | Server | Server Core

    $isServer     = $os.ProductType -ne 1
    $isCore       = $it -eq 'Server Core'
    $hasServerMgr = [bool](Get-Module -ListAvailable -Name ServerManager)

    $canGui = $false
    if (-not $isCore -and [Environment]::UserInteractive) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $canGui = $true
        } catch { $canGui = $false }
    }

    $Script:OSRole = [PSCustomObject]@{
        Sku              = if ($isServer) { 'Server' } else { 'Client' }
        ProductType      = $os.ProductType
        InstallationType = $it
        IsServer         = $isServer
        IsServerCore     = $isCore
        HasServerManager = $hasServerMgr
        CanUseGui        = $canGui
        Caption          = $os.Caption
    }
    return $Script:OSRole
}

# ============================================================================
#  Catalogo de capacidades + dispatch por capacidade (nao por nome de SO)
#  Ver docs/DESIGN-irm-gui.md secao 3. Das ~10 capacidades, so HyperV e
#  Containers BIFURCAM (Install-WindowsFeature no Server vs DISM no Client);
#  as demais usam os mesmos ids DISM nos dois SOs. Sandbox e client-only.
# ============================================================================

# AvailableOn: 'Both' | 'ClientOnly' | 'ServerOnly'.
# ServerRole != '' => quando ha ServerManager, instala via Install-WindowsFeature
#   com esse nome de role; senao cai no caminho DISM (Features).
# NeedsSource => FoD sem payload local (NetFx3): aceita -Source/-LimitAccess.
function New-Capability {
    param(
        $Id, $Display, $Category, $AvailableOn = 'Both',
        $Features = @(), $ServerRole = '',
        [switch] $IncludeManagementTools, [switch] $NeedsSource, $Notes = ''
    )
    [PSCustomObject]@{
        Id          = $Id; Display = $Display; Category = $Category
        AvailableOn = $AvailableOn; Features = @($Features); ServerRole = $ServerRole
        IncludeManagementTools = [bool]$IncludeManagementTools
        NeedsSource = [bool]$NeedsSource; Notes = $Notes
    }
}

$Script:CapabilityCatalog = @(
    (New-Capability 'HyperV'        'Hyper-V'                         'Virtualizacao' 'Both'       @('Microsoft-Hyper-V-All') 'Hyper-V' -IncludeManagementTools -Notes 'Requer reinicio')
    (New-Capability 'Containers'    'Containers'                     'Virtualizacao' 'Both'       @('Containers') 'Containers')
    (New-Capability 'Sandbox'       'Windows Sandbox'                'Virtualizacao' 'ClientOnly' @('Containers-DisposableClientVM'))
    (New-Capability 'Telnet'        'Telnet Client'                  'Rede'          'Both'       @('TelnetClient'))
    (New-Capability 'IISCore'       'IIS - Servidor Web'             'Web/IIS'       'Both'       @('IIS-WebServerRole','IIS-WebServer'))
    (New-Capability 'IISAspNet'     'IIS - ASP.NET 4.x'              'Web/IIS'       'Both'       @('IIS-ASPNET45'))
    (New-Capability 'IISMgmt'       'IIS - Console de Gerenciamento' 'Web/IIS'       'Both'       @('IIS-ManagementConsole','IIS-ManagementScriptingTools','IIS-ManagementService'))
    (New-Capability 'NetFx3'        '.NET Framework 3.5'             '.NET'          'Both'       @('NetFx3') '' -NeedsSource -Notes 'Payload via WU/online; -Source aponta a midia')
    (New-Capability 'WAS'           'Windows Process Activation'     '.NET'          'Both'       @('WAS-WindowsActivationService','WAS-ProcessModel','WAS-NetFxEnvironment','WAS-ConfigurationAPI'))
    (New-Capability 'WCFActivation' 'WCF Activation (4.x)'           '.NET'          'Both'       @('WCF-HTTP-Activation45','WCF-MSMQ-Activation45','WCF-Pipe-Activation45','WCF-TCP-Activation45') '' -Notes 'WCF non-45 pertence a subarvore do NetFx3 (ver Install-IISFull)')
    (New-Capability 'MSMQ'          'MSMQ'                           'Mensageria'    'Both'       @('MSMQ-Server'))
)

# Lista as capacidades validas para o SO atual (filtra Sandbox no Server etc).
function Get-AvailableCapabilities {
    $role = Get-OSRole
    $Script:CapabilityCatalog | Where-Object {
        switch ($_.AvailableOn) {
            'ClientOnly' { -not $role.IsServer }
            'ServerOnly' { $role.IsServer }
            default      { $true }
        }
    }
}

# Instala UMA capacidade do catalogo, decidindo a API em runtime.
function Install-Capability {
    param(
        [Parameter(Mandatory)] $Capability,
        [string] $Source   # midia opcional p/ NetFx3 (FoD)
    )
    $role = Get-OSRole

    # Bifurcacao: role de Server quando ha ServerManager (Hyper-V, Containers).
    if ($Capability.ServerRole -and $role.HasServerManager) {
        Install-CapabilityServerRole -RoleName $Capability.ServerRole `
            -Display $Capability.Display -IncludeManagementTools:$Capability.IncludeManagementTools
        return
    }

    # Caminho DISM: client, e tambem server p/ as features cross-OS.
    foreach ($f in $Capability.Features) {
        $dn = if ($Capability.Features.Count -eq 1) { $Capability.Display } else { $f }
        if ($Capability.NeedsSource -and $Source) {
            Enable-OptionalFeatureSafe -FeatureName $f -DisplayName $dn -All -Source $Source -LimitAccess
        } else {
            Enable-OptionalFeatureSafe -FeatureName $f -DisplayName $dn -All
        }
    }
}

# Instala uma role de Server (Install-WindowsFeature) com as mesmas garantias
# do motor: ja-presente, defere em reinicio pendente, -NoRestart, registro.
function Install-CapabilityServerRole {
    param(
        [Parameter(Mandatory)] [string] $RoleName,
        [Parameter(Mandatory)] [string] $Display,
        [switch] $IncludeManagementTools
    )
    $state = Get-WindowsFeature -Name $RoleName -ErrorAction SilentlyContinue
    if ($state -and $state.Installed) {
        Write-Log "'$Display' ja instalado." -Level OK
        Add-FeatureResult -Name $Display -Status 'JaPresente'
        return
    }
    if (-not (Test-CanInstallOrDefer -Name $Display)) { return }

    try {
        Write-Log "Instalando '$Display' (role $RoleName)..." -Level STEP
        Start-FeatureTimer -Name $Display
        # Install-WindowsFeature NAO tem -NoRestart; por padrao ja nao reinicia (so com -Restart).
        $r = Install-WindowsFeature -Name $RoleName -IncludeManagementTools:$IncludeManagementTools -ErrorAction Stop
        if ($r.Success) {
            if ($r.RestartNeeded -ne 'No') {
                Write-Log "'$Display' instalado - REINICIO necessario." -Level WARN
                Add-FeatureResult -Name $Display -Status 'PrecisaReinicio'
            } else {
                Write-Log "'$Display' instalado." -Level OK
                Add-FeatureResult -Name $Display -Status 'Instalado'
            }
        } else {
            Write-Log "Falha ao instalar '$Display'. ExitCode: $($r.ExitCode)" -Level ERRO
            Add-FeatureResult -Name $Display -Status 'Falha' -Detail "ExitCode $($r.ExitCode)"
        }
    }
    catch {
        Write-Log "Falha ao instalar '$Display': $($_.Exception.Message)" -Level ERRO
        Add-FeatureResult -Name $Display -Status 'Falha' -Detail $_.Exception.Message
    }
}

# Instala um conjunto de capacidades por Id. Ordena NetFx3 antes de WCF
# (WCF non-45 herda do NetFx3) e abre/fecha a sessao de resumo.
function Invoke-CapabilityInstall {
    param(
        [Parameter(Mandatory)] [string[]] $Ids,
        [string] $Source
    )
    Reset-FeatureSession

    $selected = $Script:CapabilityCatalog | Where-Object { $Ids -contains $_.Id }
    $sorted = $selected | Sort-Object {
        switch ($_.Id) { 'NetFx3' { 0 } 'WCFActivation' { 2 } default { 1 } }
    }
    foreach ($cap in $sorted) {
        Install-Capability -Capability $cap -Source $Source
    }

    Show-FeaturesSummary
}
# ===== FIM modules\OSCommon.ps1 =====

# ===== INICIO modules\Customizations.ps1 =====
# ============================================================================
#  Customizations.ps1  -  Ajustes de interface / Explorer para o usuario atual
#  Funcoes chamadas pelo setup.ps1. Dependem do Common.ps1 (Write-Log etc).
# ============================================================================

$Script:ExplorerAdvanced = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$Script:Personalize      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'

# Reinicia o explorer.exe para aplicar mudancas de UI (so quando necessario).
function Restart-Explorer {
    Write-Log "Reiniciando o Explorer para aplicar as mudancas..." -Level STEP
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Write-Log "Explorer reiniciado." -Level OK
}

# --- Dark Mode (tema escuro para apps e sistema) ---------------------------
function Enable-DarkMode {
    Write-Log "Ativando Dark Mode (apps e sistema)..." -Level STEP
    $c1 = Set-RegistryValue -Path $Script:Personalize -Name 'AppsUseLightTheme'   -Value 0 -Type DWord
    $c2 = Set-RegistryValue -Path $Script:Personalize -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
    return ($c1 -or $c2)
}

# --- Mostrar extensoes de arquivos conhecidos ------------------------------
function Show-FileExtensions {
    Write-Log "Habilitando exibicao das extensoes de arquivo..." -Level STEP
    # HideFileExt = 0  => mostra as extensoes
    return (Set-RegistryValue -Path $Script:ExplorerAdvanced -Name 'HideFileExt' -Value 0 -Type DWord)
}

# --- Mostrar arquivos e pastas ocultos -------------------------------------
function Show-HiddenFiles {
    param([switch] $IncludeProtectedOsFiles)
    Write-Log "Habilitando exibicao de arquivos ocultos..." -Level STEP
    # Hidden = 1 => mostra ocultos ; 2 => nao mostra
    $changed = Set-RegistryValue -Path $Script:ExplorerAdvanced -Name 'Hidden' -Value 1 -Type DWord

    if ($IncludeProtectedOsFiles) {
        Write-Log "Habilitando arquivos protegidos do sistema (ShowSuperHidden)..." -Level STEP
        $c2 = Set-RegistryValue -Path $Script:ExplorerAdvanced -Name 'ShowSuperHidden' -Value 1 -Type DWord
        $changed = $changed -or $c2
    }
    return $changed
}

# --- Aplica todas as customizacoes de uma vez ------------------------------
function Invoke-AllCustomizations {
    $changed = $false
    if (Enable-DarkMode)        { $changed = $true }
    if (Show-FileExtensions)    { $changed = $true }
    if (Show-HiddenFiles)       { $changed = $true }

    if ($changed) {
        Restart-Explorer
    } else {
        Write-Log "Nenhuma mudanca necessaria - tudo ja estava configurado." -Level OK
    }
}
# ===== FIM modules\Customizations.ps1 =====

# ===== INICIO modules\WindowsFeatures.ps1 =====
# ============================================================================
#  WindowsFeatures.ps1  -  Roles e Features do Windows
#  Funcoes chamadas pelo setup.ps1. Dependem do Common.ps1.
#
#  REGRAS DE SEGURANCA (ver Common.ps1):
#   1. Nunca reinicia automaticamente (sempre -NoRestart).
#   2. ANTES de instalar checa reinicio pendente -> defere se houver.
#   3. DEPOIS detecta se a instalacao exige reinicio.
#   4. Resumo final via Show-FeaturesSummary.
# ============================================================================

# --- Hyper-V (Role) - REQUER REINICIO --------------------------------------
# OS-aware: no Windows 11 (sem ServerManager) usa Enable-WindowsOptionalFeature
# com o feature 'Microsoft-Hyper-V-All'; no Windows Server usa Install-WindowsFeature.
function Install-HyperVRole {
    $name = 'Hyper-V'
    Write-Log "Verificando a role Hyper-V..." -Level STEP

    # Windows client (Win11 Pro/Ent/Edu): caminho DISM. Install-WindowsFeature nao existe aqui.
    if (-not (Get-OSRole).HasServerManager) {
        Write-Log "SO client detectado - usando Enable-WindowsOptionalFeature (Microsoft-Hyper-V-All)." -Level INFO
        Enable-OptionalFeatureSafe -FeatureName 'Microsoft-Hyper-V-All' -DisplayName 'Hyper-V' -All
        return
    }

    $state = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
    if ($state -and $state.Installed) {
        Write-Log "Hyper-V ja esta instalado." -Level OK
        Add-FeatureResult -Name $name -Status 'JaPresente'
        return
    }

    if (-not (Test-CanInstallOrDefer -Name $name)) { return }

    Write-Log "Instalando Hyper-V (com ferramentas de gerenciamento)..." -Level STEP
    Start-FeatureTimer -Name $name
    # Install-WindowsFeature NAO tem -NoRestart; por padrao ja nao reinicia (so com -Restart).
    $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools

    if ($result.Success) {
        if ($result.RestartNeeded -ne 'No') {
            Write-Log "Hyper-V instalado - REINICIO necessario para concluir." -Level WARN
            Add-FeatureResult -Name $name -Status 'PrecisaReinicio' -Detail 'Concluir instalacao do Hyper-V'
        } else {
            Write-Log "Hyper-V instalado." -Level OK
            Add-FeatureResult -Name $name -Status 'Instalado'
        }
    } else {
        Write-Log "Falha ao instalar o Hyper-V. ExitCode: $($result.ExitCode)" -Level ERRO
        Add-FeatureResult -Name $name -Status 'Falha' -Detail "ExitCode $($result.ExitCode)"
    }
}

# --- Telnet Client ----------------------------------------------------------
function Enable-TelnetClientFeature {
    Enable-OptionalFeatureSafe -FeatureName 'TelnetClient' -DisplayName 'Telnet Client'
}

# --- NAT Switch (Hyper-V) ---------------------------------------------------
# Cria: (1) switch virtual Interno, (2) IP de gateway na vEthernet do switch,
# (3) NAT na sub-rede. Nome, sub-rede (CIDR) e gateway sao informados pelo
# usuario (NAO fixos). Idempotente: nao recria o que ja existe. Nao reinicia.
function New-NatSwitch {
    param(
        [Parameter(Mandatory)] [string] $SwitchName,   # ex.: NATSwitch
        [Parameter(Mandatory)] [string] $Subnet,       # ex.: 172.16.3.0/24 (CIDR)
        [Parameter(Mandatory)] [string] $GatewayIP,    # ex.: 172.16.3.1
        [string] $NatName                              # ENTER = "<SwitchName>-NAT"
    )
    if (-not $NatName) { $NatName = "$SwitchName-NAT" }
    $display = "NAT Switch '$SwitchName'"
    Write-Log "Configurando $display ($Subnet, gateway $GatewayIP)..." -Level STEP

    # Hyper-V precisa estar disponivel (New-VMSwitch vem do modulo Hyper-V).
    if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) {
        Write-Log "Cmdlets de Hyper-V indisponiveis. Instale o Hyper-V (e reinicie) antes." -Level ERRO
        Add-FeatureResult -Name $display -Status 'Falha' -Detail 'Hyper-V / New-VMSwitch ausente'
        return
    }

    # Deriva o PrefixLength da sub-rede em CIDR (nao fixa em /24).
    if ($Subnet -notmatch '^\s*\d{1,3}(\.\d{1,3}){3}\s*/\s*(\d{1,2})\s*$') {
        Write-Log "Sub-rede invalida: '$Subnet'. Use CIDR, ex.: 172.16.3.0/24" -Level ERRO
        Add-FeatureResult -Name $display -Status 'Falha' -Detail 'CIDR invalido'
        return
    }
    $prefixLen = [int]$Matches[2]
    $ifAlias   = "vEthernet ($SwitchName)"

    try {
        Start-FeatureTimer -Name $display
        # 1) Switch virtual interno
        if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
            Write-Log "Switch '$SwitchName' ja existe - mantido." -Level OK
        } else {
            New-VMSwitch -SwitchName $SwitchName -SwitchType Internal -ErrorAction Stop | Out-Null
            Write-Log "Switch interno '$SwitchName' criado." -Level OK
        }

        # 2) IP de gateway na interface vEthernet do switch
        $hasIp = Get-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $GatewayIP -ErrorAction SilentlyContinue
        if ($hasIp) {
            Write-Log "IP $GatewayIP ja atribuido a '$ifAlias' - mantido." -Level OK
        } else {
            New-NetIPAddress -IPAddress $GatewayIP -PrefixLength $prefixLen -InterfaceAlias $ifAlias -ErrorAction Stop | Out-Null
            Write-Log "IP $GatewayIP/$prefixLen atribuido a '$ifAlias'." -Level OK
        }

        # 3) NAT na sub-rede
        if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue) {
            Write-Log "NAT '$NatName' ja existe - mantido." -Level OK
        } else {
            New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $Subnet -ErrorAction Stop | Out-Null
            Write-Log "NAT '$NatName' criado para $Subnet." -Level OK
        }

        Add-FeatureResult -Name $display -Status 'Instalado' -Detail "$Subnet / gw $GatewayIP / nat $NatName"
    }
    catch {
        Write-Log "Falha ao configurar ${display}: $($_.Exception.Message)" -Level ERRO
        Add-FeatureResult -Name $display -Status 'Falha' -Detail $_.Exception.Message
    }
}

# Prompt interativo: pergunta nome / sub-rede / gateway (nada fixo).
function Invoke-NatSwitchPrompt {
    Write-Host ""
    Write-Host "  --- Criar NAT Switch (Hyper-V) ---" -ForegroundColor Cyan
    # Nome tem default NATSwitch (ENTER aceita). IP/sub-rede vem como exemplo.
    $name = (Read-Host "Nome do switch (ENTER = NATSwitch)").Trim()
    if (-not $name) { $name = 'NATSwitch' }

    $subnet = (Read-Host "Sub-rede em CIDR (ex.: 172.16.99.0/24)").Trim()
    if (-not $subnet) { Write-Host "Sub-rede obrigatoria. Cancelado." -ForegroundColor Yellow; return }

    $gw = (Read-Host "IP do gateway (ex.: 172.16.99.1)").Trim()
    if (-not $gw) { Write-Host "Gateway obrigatorio. Cancelado." -ForegroundColor Yellow; return }

    $nat = (Read-Host "Nome da rede NAT (ENTER = $name-NAT)").Trim()
    if ($nat) { New-NatSwitch -SwitchName $name -Subnet $subnet -GatewayIP $gw -NatName $nat }
    else      { New-NatSwitch -SwitchName $name -Subnet $subnet -GatewayIP $gw }
}

# --- DHCP para o NAT Switch (somente Windows Server) ------------------------
# Um NAT switch NAO distribui IP. Para as VMs pegarem IP automatico, instala-se
# a role DHCP no proprio host e cria-se um scope na sub-rede do NAT, com bind
# SOMENTE na interface do NAT (nunca responde na rede fisica). Detalhes e
# diagnostico em docs/RUNBOOK-DHCP-NAT-HyperV.md.

# DNS sugerido como default (editavel no prompt). 213.186.33.99 = DNS da OVH.
$Script:DefaultNatDns = '213.186.33.99'

# --- Helpers de IPv4 (calculo de mascara e faixas) -------------------------
# Converte um IPv4 (string) para UInt32 (ordem logica big-endian).
function ConvertTo-IPv4UInt32 {
    param([Parameter(Mandatory)] [string] $IP)
    $b = ([System.Net.IPAddress]::Parse($IP)).GetAddressBytes()
    [array]::Reverse($b)
    return [System.BitConverter]::ToUInt32($b, 0)
}

# Converte um UInt32 de volta para IPv4 (string).
function ConvertFrom-IPv4UInt32 {
    param([Parameter(Mandatory)] [uint32] $Value)
    $b = [System.BitConverter]::GetBytes($Value)
    [array]::Reverse($b)
    return ([System.Net.IPAddress]::new($b)).ToString()
}

# Mascara pontilhada (ex.: 255.255.255.0) a partir do prefixo CIDR (ex.: 24).
function Get-IPv4MaskFromPrefix {
    param([Parameter(Mandatory)] [int] $PrefixLength)
    if ($PrefixLength -le 0)  { return '0.0.0.0' }
    if ($PrefixLength -ge 32) { return '255.255.255.255' }
    # 0xFFFFFFFFL com sufixo L = Int64 positivo (sem L, PS le 0xFFFFFFFF como Int32 = -1).
    $allOnes   = 0xFFFFFFFFL
    $hostCount = [int64][math]::Pow(2, (32 - $PrefixLength))    # 2^hostBits
    $mask = [uint32]($allOnes - ($hostCount - 1))
    return (ConvertFrom-IPv4UInt32 -Value $mask)
}

# Descobre as redes NAT do Hyper-V e o IP do host (gateway) em cada uma.
# Para cada Get-NetNat, parseia a sub-rede (InternalIPInterfaceAddressPrefix,
# ex.: 172.16.3.0/24) e procura a interface do host cujo IP cai nessa sub-rede:
# esse IP e o gateway que as VMs usam. Retorna candidatos com tudo pronto p/ o
# scope (ScopeId, Mask, GatewayIP, InterfaceAlias).
function Get-NatNetworkInfo {
    if (-not (Get-Command Get-NetNat -ErrorAction SilentlyContinue)) { return @() }

    $hostIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $result = @()
    foreach ($nat in (Get-NetNat -ErrorAction SilentlyContinue)) {
        $prefix = $nat.InternalIPInterfaceAddressPrefix     # ex.: 172.16.3.0/24
        if ($prefix -notmatch '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*/\s*(\d{1,2})\s*$') { continue }
        $scopeId   = $Matches[1]
        $prefixLen = [int]$Matches[2]
        $mask      = Get-IPv4MaskFromPrefix -PrefixLength $prefixLen

        $net = ConvertTo-IPv4UInt32 -IP $scopeId
        $msk = ConvertTo-IPv4UInt32 -IP $mask
        $gwIp = $null; $ifAlias = $null
        foreach ($a in $hostIps) {
            $ipU = ConvertTo-IPv4UInt32 -IP $a.IPAddress
            if (($ipU -band $msk) -eq ($net -band $msk)) {
                $gwIp = $a.IPAddress; $ifAlias = $a.InterfaceAlias; break
            }
        }

        $result += [PSCustomObject]@{
            NatName        = $nat.Name
            ScopeId        = $scopeId
            PrefixLength   = $prefixLen
            Mask           = $mask
            GatewayIP      = $gwIp
            InterfaceAlias = $ifAlias
        }
    }
    return $result
}

# Garante a role DHCP no host (somente Server). Retorna $true se ja esta pronta
# para configurar (cmdlets disponiveis); $false se exigiu instalacao/reinicio ou
# se o SO nao e Server. Segue as regras do projeto (-NoRestart, defere, registra).
function Install-DhcpRoleForNat {
    $name = 'DHCP Server'
    if (-not (Get-OSRole).HasServerManager) {
        Write-Log "DHCP para NAT so e suportado em Windows Server (role DHCP ausente neste SO)." -Level WARN
        Add-FeatureResult -Name $name -Status 'Falha' -Detail 'Recurso somente para Windows Server'
        return $false
    }

    $state = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    if (-not ($state -and $state.Installed)) {
        if (-not (Test-CanInstallOrDefer -Name $name)) { return $false }
        Write-Log "Instalando a role DHCP (com ferramentas de gerenciamento)..." -Level STEP
        Start-FeatureTimer -Name $name
        # Install-WindowsFeature NAO tem -NoRestart; por padrao ja nao reinicia (so com -Restart).
        $r = Install-WindowsFeature -Name DHCP -IncludeManagementTools
        if (-not $r.Success) {
            Write-Log "Falha ao instalar a role DHCP. ExitCode: $($r.ExitCode)" -Level ERRO
            Add-FeatureResult -Name $name -Status 'Falha' -Detail "ExitCode $($r.ExitCode)"
            return $false
        }
        # O proprio cmdlet sinaliza se exige reinicio (DHCP costuma retornar SuccessRestartRequired).
        if ($r.RestartNeeded -ne 'No') {
            Write-Log "Role DHCP instalada - REINICIO necessario para ativar cmdlets e servico." -Level WARN
            Add-FeatureResult -Name $name -Status 'PrecisaReinicio' -Detail 'Reinicie e rode de novo para configurar o scope'
            return $false
        }
        Write-Log "Role DHCP instalada." -Level OK
    }

    # Mesmo instalada, na 1a vez os cmdlets/servico podem so subir apos o reinicio.
    if (-not (Get-Command Add-DhcpServerv4Scope -ErrorAction SilentlyContinue) -or
        -not (Get-Service DHCPServer -ErrorAction SilentlyContinue)) {
        Write-Log "Role DHCP presente mas cmdlets/servico ainda nao disponiveis - reinicie e rode de novo." -Level WARN
        Add-FeatureResult -Name $name -Status 'PrecisaReinicio' -Detail 'Reinicie para ativar os cmdlets/servico do DHCP'
        return $false
    }

    Add-FeatureResult -Name $name -Status 'JaPresente'
    return $true
}

# Configura o DHCP para uma rede NAT: servico Automatic + scope + exclusao do
# gateway + opcoes 003 (gateway) e 006 (DNS) + bind SOMENTE na interface do NAT.
# Idempotente. Ver docs/RUNBOOK-DHCP-NAT-HyperV.md.
function Set-NatDhcpScope {
    param(
        [Parameter(Mandatory)] [string] $ScopeId,
        [Parameter(Mandatory)] [string] $Mask,
        [Parameter(Mandatory)] [string] $RangeFrom,
        [Parameter(Mandatory)] [string] $RangeTo,
        [Parameter(Mandatory)] [string] $Gateway,
        [Parameter(Mandatory)] [string] $Dns,
        [Parameter(Mandatory)] [string] $NatIface,
        [int] $LeaseDays = 7300            # lease longo (20 anos) p/ as VMs nao renovarem
    )
    $display = "DHCP scope $ScopeId (NAT)"
    try {
        Start-FeatureTimer -Name $display
        # 1) Servico
        if ((Get-Service DHCPServer -ErrorAction Stop).Status -ne 'Running') { Start-Service DHCPServer }
        Set-Service DHCPServer -StartupType Automatic

        # 2) Scope (idempotente)
        if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
            Add-DhcpServerv4Scope -Name 'NAT-VMs' -StartRange $RangeFrom -EndRange $RangeTo -SubnetMask $Mask -State Active
            Write-Log "Scope $ScopeId criado ($RangeFrom - $RangeTo)." -Level OK
        } else {
            Write-Log "Scope $ScopeId ja existe - mantido." -Level OK
        }

        # 2b) Lease (opcao 051): lease longo deixa o IP "fixo na pratica" e evita
        # as VMs ficarem renovando. Em try proprio: um cap de lease nao deve
        # derrubar o resto da config. Ver runbook secao 7a.
        try {
            Set-DhcpServerv4Scope -ScopeId $ScopeId -LeaseDuration (New-TimeSpan -Days $LeaseDays)
            Write-Log "Lease do scope $ScopeId definido em $LeaseDays dias." -Level OK
        } catch {
            Write-Log "Nao foi possivel definir o lease em $LeaseDays dias: $($_.Exception.Message)" -Level WARN
        }

        # 3) Exclui o gateway da distribuicao (seguranca)
        Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange $Gateway -EndRange $Gateway -ErrorAction SilentlyContinue

        # 4) Opcoes 003 (gateway) e 006 (DNS)
        Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Gateway -DnsServer $Dns
        Write-Log "Gateway (003)=$Gateway e DNS (006)=$Dns aplicados ao scope $ScopeId." -Level OK

        # 5) Bind SOMENTE na interface do NAT (nunca na rede fisica)
        Get-DhcpServerv4Binding | ForEach-Object {
            if ($_.InterfaceAlias -eq $NatIface) {
                if (-not $_.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState $true }
            } else {
                if ($_.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState $false }
            }
        }
        Write-Log "DHCP vinculado somente a '$NatIface'." -Level OK

        Restart-Service DHCPServer
        Write-Log "DHCP configurado: as VMs no NAT $ScopeId agora pegam IP automatico." -Level OK
        Add-FeatureResult -Name $display -Status 'Instalado' -Detail "range $RangeFrom-$RangeTo / gw $Gateway / dns $Dns"
    }
    catch {
        Write-Log "Falha ao configurar o DHCP: $($_.Exception.Message)" -Level ERRO
        Add-FeatureResult -Name $display -Status 'Falha' -Detail $_.Exception.Message
    }
}

# Prompt interativo: instala a role (se preciso), DETECTA a rede NAT e o IP do
# host (gateway) e os mostra, e pergunta faixa e DNS (OVH como default). Aplica
# apos confirmacao.
function Invoke-NatDhcpPrompt {
    Write-Host ""
    Write-Host "  --- Configurar DHCP para o NAT Switch (Windows Server) ---" -ForegroundColor Cyan

    # 1) Garante a role DHCP. Se acabou de instalar / precisa reiniciar, para aqui.
    if (-not (Install-DhcpRoleForNat)) {
        Write-Host "  DHCP ainda nao esta pronto (ver mensagens acima)." -ForegroundColor Yellow
        Write-Host "  Se foi solicitado reinicio, reinicie o servidor e rode esta opcao de novo." -ForegroundColor Yellow
        return
    }

    # 2) Detecta as redes NAT e o IP do host (gateway) em cada uma.
    $nets = @(Get-NatNetworkInfo | Where-Object { $_.GatewayIP })
    if ($nets.Count -eq 0) {
        Write-Host "  Nenhuma rede NAT com IP de host detectada." -ForegroundColor Yellow
        Write-Host "  Crie antes um NAT Switch (opcao 3) ou verifique com 'Get-NetNat'." -ForegroundColor Yellow
        return
    }

    # Escolha da rede NAT quando houver mais de uma.
    $sel = $nets[0]
    if ($nets.Count -gt 1) {
        Write-Host "  Redes NAT detectadas:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $nets.Count; $i++) {
            Write-Host ("    {0}) {1}/{2}  gateway {3}  via '{4}'" -f ($i + 1), $nets[$i].ScopeId, $nets[$i].PrefixLength, $nets[$i].GatewayIP, $nets[$i].InterfaceAlias)
        }
        $pick = (Read-Host "Escolha a rede (1-$($nets.Count), ENTER = 1)").Trim()
        if ($pick) {
            $idx = 0
            if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $nets.Count) { $sel = $nets[$idx - 1] }
        }
    }

    Write-Host ""
    Write-Host "  Rede NAT detectada automaticamente:" -ForegroundColor Green
    Write-Host ("    Sub-rede : {0}/{1}  (mascara {2})" -f $sel.ScopeId, $sel.PrefixLength, $sel.Mask)
    Write-Host ("    Gateway  : {0}   (IP do host na interface '{1}')" -f $sel.GatewayIP, $sel.InterfaceAlias)
    Write-Host ""

    # 3) Faixa do DHCP - defaults derivados da sub-rede (.50 a .200 acima da rede).
    $netU    = ConvertTo-IPv4UInt32 -IP $sel.ScopeId
    $defFrom = ConvertFrom-IPv4UInt32 -Value ($netU + 50)
    $defTo   = ConvertFrom-IPv4UInt32 -Value ($netU + 200)

    $rFrom = (Read-Host "Faixa inicial (ENTER = $defFrom)").Trim(); if (-not $rFrom) { $rFrom = $defFrom }
    $rTo   = (Read-Host "Faixa final   (ENTER = $defTo)").Trim();   if (-not $rTo)   { $rTo   = $defTo }

    # 4) DNS - campo editavel, com a OVH pre-preenchida como default.
    $dns = (Read-Host "DNS para as VMs (ENTER = $Script:DefaultNatDns)").Trim()
    if (-not $dns) { $dns = $Script:DefaultNatDns }

    # 5) Lease (opcao 051) - default longo p/ as VMs nao ficarem renovando.
    $leaseDays = 7300
    $leaseIn = (Read-Host "Duracao do lease em dias (ENTER = 7300 = 20 anos; 8 = padrao Windows)").Trim()
    if ($leaseIn) { $tmp = 0; if ([int]::TryParse($leaseIn, [ref]$tmp) -and $tmp -gt 0) { $leaseDays = $tmp } }

    # 6) Confirma e aplica.
    Write-Host ""
    Write-Host "  Resumo:" -ForegroundColor Cyan
    Write-Host ("    Scope {0} / mascara {1} / range {2} - {3}" -f $sel.ScopeId, $sel.Mask, $rFrom, $rTo)
    Write-Host ("    Gateway {0} / DNS {1} / lease {2} dias / bind em '{3}'" -f $sel.GatewayIP, $dns, $leaseDays, $sel.InterfaceAlias)
    if (-not (Confirm-Action "Aplicar esta configuracao de DHCP?")) {
        Write-Host "  Cancelado." -ForegroundColor Yellow
        return
    }

    Set-NatDhcpScope -ScopeId $sel.ScopeId -Mask $sel.Mask -RangeFrom $rFrom -RangeTo $rTo `
        -Gateway $sel.GatewayIP -Dns $dns -NatIface $sel.InterfaceAlias -LeaseDays $leaseDays
}

# --- Submenu de Features ----------------------------------------------------
function Invoke-FeaturesMenu {
    Reset-FeatureSession

    if (Test-PendingReboot) {
        Write-Log "AVISO: ja existe um reinicio pendente neste servidor." -Level WARN
        Write-Log "Novas instalacoes serao DEFERIDAS ate o reinicio. Reinicie antes de continuar." -Level WARN
    }

    do {
        Write-Host ""
        Write-Host "  --- Funcoes / Recursos do Windows ---" -ForegroundColor Cyan
        Write-Host "    1) Instalar Hyper-V            [REQUER REINICIO]"
        Write-Host "    2) Habilitar Telnet Client"
        Write-Host "    3) Criar NAT Switch (Hyper-V)  [nome/sub-rede/gateway]"
        Write-Host "    4) Configurar DHCP p/ o NAT    [Windows Server - detecta IP/DNS/lease]"
        Write-Host "    9) Ver resumo da sessao"
        Write-Host "    0) Voltar (mostra resumo)"
        Write-Host ""
        $o = Read-Host "Escolha"

        switch ($o) {
            '1' { Install-HyperVRole }
            '2' { Enable-TelnetClientFeature }
            '3' { Invoke-NatSwitchPrompt }
            '4' { Invoke-NatDhcpPrompt }
            '9' { Show-FeaturesSummary }
            '0' { }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }
    } while ($o -ne '0')

    Show-FeaturesSummary
}
# ===== FIM modules\WindowsFeatures.ps1 =====

# ===== INICIO modules\BaseConfig.ps1 =====
# ============================================================================
#  BaseConfig.ps1  -  Hardening / Configuracao base do Windows Server
#  Funcoes chamadas pelo setup.ps1. Dependem do Common.ps1 (Write-Log etc).
# ============================================================================

# --- Desativar IE Enhanced Security Configuration (IE ESC) ------------------
function Disable-IEEsc {
    Write-Log "Desativando o IE Enhanced Security Configuration (IE ESC)..." -Level STEP

    # {..A7..} = Administradores  |  {..A8..} = Usuarios
    $admin = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
    $user  = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'

    $changed = $false
    if (Test-Path $admin) { if (Set-RegistryValue -Path $admin -Name 'IsInstalled' -Value 0 -Type DWord) { $changed = $true } }
    else { Write-Log "Componente IE ESC (Admin) nao encontrado - pode ja estar removido." -Level WARN }

    if (Test-Path $user)  { if (Set-RegistryValue -Path $user  -Name 'IsInstalled' -Value 0 -Type DWord) { $changed = $true } }
    else { Write-Log "Componente IE ESC (Usuario) nao encontrado - pode ja estar removido." -Level WARN }

    if ($changed) {
        # Reinicia o Explorer para aplicar a mudanca de imediato
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-Log "IE ESC desativado." -Level OK
    } else {
        Write-Log "IE ESC ja estava desativado." -Level OK
    }
}

# --- Time zone para Brasilia ------------------------------------------------
function Set-TimeZoneBrasilia {
    $tzId = 'E. South America Standard Time'   # = Brasilia (UTC-03:00)
    Write-Log "Ajustando time zone para '$tzId' (Brasilia)..." -Level STEP

    $current = (Get-TimeZone).Id
    if ($current -eq $tzId) {
        Write-Log "Time zone ja esta em Brasilia." -Level OK
        return
    }

    Set-TimeZone -Id $tzId
    Write-Log "Time zone alterado de '$current' para Brasilia." -Level OK
}

# --- Ajustar data/hora atual (sincronizacao NTP) ---------------------------
function Sync-DateTime {
    Write-Log "Configurando e sincronizando o relogio (NTP)..." -Level STEP

    # Servidores NTP do NTP.br + fallback Microsoft (0x8 = client mode)
    $peers = 'a.st1.ntp.br,0x8 b.st1.ntp.br,0x8 time.windows.com,0x8'

    try {
        Set-Service -Name w32time -StartupType Automatic
        Start-Service -Name w32time -ErrorAction SilentlyContinue

        # Em maquina fora de dominio, define a lista manual de servidores
        & w32tm.exe /config /manualpeerlist:"$peers" /syncfromflags:manual /update | Out-Null
        Restart-Service -Name w32time
        Start-Sleep -Seconds 2
        & w32tm.exe /resync /force | Out-Null

        Write-Log "Relogio sincronizado. Hora atual: $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))" -Level OK
    }
    catch {
        Write-Log "Falha ao sincronizar o relogio: $($_.Exception.Message)" -Level ERRO
    }
}

# --- Nao iniciar o Server Manager automaticamente no logon -----------------
function Disable-ServerManagerAutoStart {
    Write-Log "Desabilitando inicio automatico do Server Manager no logon..." -Level STEP

    # Registro: vale para a maquina (todos os admins)
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name 'DoNotOpenServerManagerAtLogon' -Value 1 -Type DWord | Out-Null

    # Desativa tambem a tarefa agendada que abre o Server Manager
    try {
        $task = Get-ScheduledTask -TaskName 'ServerManager' -TaskPath '\Microsoft\Windows\Server Manager\' -ErrorAction Stop
        if ($task.State -ne 'Disabled') {
            Disable-ScheduledTask -TaskName 'ServerManager' -TaskPath '\Microsoft\Windows\Server Manager\' | Out-Null
            Write-Log "Tarefa agendada do Server Manager desativada." -Level OK
        } else {
            Write-Log "Tarefa agendada do Server Manager ja estava desativada." -Level OK
        }
    }
    catch {
        Write-Log "Tarefa agendada do Server Manager nao encontrada (ok)." -Level WARN
    }
}

# --- Submenu da configuracao base ------------------------------------------
function Invoke-BaseConfigMenu {
    do {
        Write-Host ""
        Write-Host "  --- Hardening / Configuracao base ---" -ForegroundColor Cyan
        Write-Host "    1) Aplicar TODAS as opcoes abaixo"
        Write-Host "    2) Desativar IE Enhanced Security Configuration"
        Write-Host "    3) Time zone para Brasilia"
        Write-Host "    4) Ajustar/sincronizar data e hora (NTP)"
        Write-Host "    5) Nao iniciar Server Manager no logon"
        Write-Host "    0) Voltar"
        Write-Host ""
        $o = Read-Host "Escolha"

        switch ($o) {
            '1' {
                Disable-IEEsc
                Set-TimeZoneBrasilia
                Sync-DateTime
                Disable-ServerManagerAutoStart
            }
            '2' { Disable-IEEsc }
            '3' { Set-TimeZoneBrasilia }
            '4' { Sync-DateTime }
            '5' { Disable-ServerManagerAutoStart }
            '0' { }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }
    } while ($o -ne '0')
}
# ===== FIM modules\BaseConfig.ps1 =====

# ===== INICIO modules\IIS.ps1 =====
# ============================================================================
#  IIS.ps1  -  Instalacao do IIS + ASP.NET / WCF / WAS / MSMQ
#  Baseado na lista de features DISM fornecida. Depende do Common.ps1.
#
#  Usa Enable-OptionalFeatureSafe (Common.ps1): -NoRestart, guarda de reinicio
#  pendente (defere), deteccao de reinicio exigido e registro no resumo.
# ============================================================================

# Lista ordenada e SEM duplicatas das features. -All ($true) puxa dependencias.
# A ordem coloca .NET/WAS/core do IIS primeiro; o -All resolve o resto.
$Script:IISFeatures = @(
    # .NET Framework
    'NetFx3'                                          # ASP.NET 3.5 (.NET 3.5)

    # Nucleo do IIS
    'IIS-WebServerRole'
    'IIS-WebServer'

    # ASP.NET / extensibilidade
    'IIS-ASPNET45'                                    # ASP.NET 4.x
    'IIS-ASPNET'
    'IIS-NetFxExtensibility'

    # Ferramentas de gerenciamento
    'IIS-ManagementConsole'
    'IIS-ManagementScriptingTools'
    'IIS-ManagementService'

    # Common HTTP Features
    'IIS-HttpRedirect'
    'IIS-WebDAV'
    'IIS-ApplicationInit'

    # Health and Diagnostics
    'IIS-CustomLogging'
    'IIS-LoggingLibraries'
    'IIS-ODBCLogging'
    'IIS-RequestMonitor'
    'IIS-HttpTracing'

    # Performance
    'IIS-HttpCompressionDynamic'

    # Security
    'IIS-RequestFiltering'
    'IIS-BasicAuthentication'
    'IIS-CertProvider'
    'IIS-ClientCertificateMappingAuthentication'
    'IIS-DigestAuthentication'
    'IIS-IISCertificateMappingAuthentication'
    'IIS-IPSecurity'
    'IIS-URLAuthorization'
    'IIS-WindowsAuthentication'

    # Application Development
    'IIS-ServerSideIncludes'
    'IIS-WebSockets'

    # WAS - Windows Process Activation Service
    'WAS-WindowsActivationService'
    'WAS-ProcessModel'
    'WAS-NetFxEnvironment'
    'WAS-ConfigurationAPI'

    # MSMQ
    'MSMQ'
    'MSMQ-Services'
    'MSMQ-Server'

    # WCF Activation
    'WCF-HTTP-Activation'
    'WCF-NonHTTP-Activation'
    'WCF-HTTP-Activation45'
    'WCF-MSMQ-Activation45'
    'WCF-Pipe-Activation45'
    'WCF-TCP-Activation45'
)

# --- Servico aspnet_state em automatico ------------------------------------
function Set-AspNetStateAuto {
    Write-Log "Configurando o servico 'aspnet_state' para inicio automatico..." -Level STEP
    $svc = Get-Service -Name aspnet_state -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Servico 'aspnet_state' nao encontrado (instale o ASP.NET State Service antes)." -Level WARN
        return
    }
    Set-Service -Name aspnet_state -StartupType Automatic
    Write-Log "'aspnet_state' definido como Automatico." -Level OK
}

# --- iisreset (so quando seguro) -------------------------------------------
function Invoke-IISReset {
    if (Test-PendingReboot) {
        Write-Log "iisreset ADIADO: ha reinicio pendente. Execute apos reiniciar o servidor." -Level WARN
        return
    }
    if (-not (Get-Service -Name W3SVC -ErrorAction SilentlyContinue)) {
        Write-Log "Servico W3SVC (IIS) nao encontrado - iisreset ignorado." -Level WARN
        return
    }
    Write-Log "Executando iisreset..." -Level STEP
    & iisreset.exe | Out-Null
    Write-Log "iisreset concluido." -Level OK
}

# --- Instalacao completa do IIS --------------------------------------------
function Install-IISFull {
    Write-Log "Iniciando instalacao do conjunto IIS ($($Script:IISFeatures.Count) features)..." -Level STEP

    foreach ($feat in $Script:IISFeatures) {
        # Se um item gerar reinicio pendente, os proximos serao deferidos
        # automaticamente por Enable-OptionalFeatureSafe (e entram no resumo).
        Enable-OptionalFeatureSafe -FeatureName $feat -All
    }

    # Pos-configuracao
    Set-AspNetStateAuto
    Invoke-IISReset
}

# --- Submenu do IIS ---------------------------------------------------------
function Invoke-IISMenu {
    Reset-FeatureSession

    if (Test-PendingReboot) {
        Write-Log "AVISO: ja existe reinicio pendente. As features serao DEFERIDAS." -Level WARN
        Write-Log "Recomendado reiniciar o servidor antes de instalar o IIS." -Level WARN
    }

    do {
        Write-Host ""
        Write-Host "  --- IIS / Servidor Web ---" -ForegroundColor Cyan
        Write-Host "    1) Instalar IIS COMPLETO (lista padrao: IIS + ASP.NET + WCF + WAS + MSMQ)"
        Write-Host "    2) Configurar aspnet_state como Automatico"
        Write-Host "    3) Executar iisreset"
        Write-Host "    9) Ver resumo da sessao"
        Write-Host "    0) Voltar (mostra resumo)"
        Write-Host ""
        $o = Read-Host "Escolha"

        switch ($o) {
            '1' { Install-IISFull }
            '2' { Set-AspNetStateAuto }
            '3' { Invoke-IISReset }
            '9' { Show-FeaturesSummary }
            '0' { }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }
    } while ($o -ne '0')

    Show-FeaturesSummary
}
# ===== FIM modules\IIS.ps1 =====

# ===== INICIO modules\Software.ps1 =====
# ============================================================================
#  Software.ps1  -  Instalacao de softwares/runtimes via Chocolatey ou winget
#  Depende do Common.ps1 (Write-Log, Add-FeatureResult, Show-FeaturesSummary,
#  Test-PendingReboot, Reset-FeatureSession).
#
#  - Catalogo data-driven: cada app tem id do choco E/OU id do winget (IDs do
#    winget verificados na fonte 'winget' deste tipo de SO).
#  - O usuario escolhe o gerenciador: winget, choco ou auto (winget e fallback choco).
#  - Sempre roda nao-interativo (-y / --accept-*) e registra cada resultado.
# ============================================================================

# --- Bootstrap do Chocolatey (idempotente) ---------------------------------
function Install-Chocolatey {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Log "Chocolatey ja instalado." -Level OK
        return $true
    }
    Write-Log "Instalando o Chocolatey..." -Level STEP
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        # Atualiza PATH desta sessao para enxergar o choco recem-instalado
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Log "Chocolatey instalado." -Level OK
            return $true
        }
        Write-Log "Chocolatey instalado, mas 'choco' nao apareceu no PATH desta sessao." -Level WARN
        return $false
    }
    catch {
        Write-Log "Falha ao instalar o Chocolatey: $($_.Exception.Message)" -Level ERRO
        return $false
    }
}

function Test-WingetAvailable {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# --- Catalogo ---------------------------------------------------------------
function New-Pkg {
    param($Key, $Name, $Category, $Choco, $Winget, $ChocoArgs = @(), $WingetArgs = @(), $Reboot = 'no', $Notes = '')
    [PSCustomObject]@{
        Key = $Key; Name = $Name; Category = $Category
        Choco = $Choco; Winget = $Winget
        ChocoArgs = @($ChocoArgs); WingetArgs = @($WingetArgs)
        Reboot = $Reboot; Notes = $Notes
    }
}

# Choco='' ou Winget='' => nao disponivel naquele gerenciador.
$Script:SoftwareCatalog = @(
    # Web / IIS
    (New-Pkg 'urlrewrite'    'IIS URL Rewrite'         'Web/IIS'    'urlrewrite' 'Microsoft.IIS.URLRewrite')
    (New-Pkg 'iis-arr'       'IIS ARR (App Request Routing)' 'Web/IIS' 'iis-arr' 'Microsoft.IIS.ApplicationRequestRouting')

    # Banco de dados
    (New-Pkg 'sql2022'       'SQL Server 2022 (Developer)' 'Banco'  'sql-server-2022' '' @() @() 'maybe' 'Edicao Developer via choco; sem pacote winget oficial')
    (New-Pkg 'sql2025'       'SQL Server 2025 (Developer)' 'Banco'  'sql-server-2025' '' @() @() 'maybe' 'Edicao Developer via choco; sem pacote winget oficial')
    (New-Pkg 'ssms'          'SQL Server Mgmt Studio'  'Banco'      'sql-server-management-studio' 'Microsoft.SQLServerManagementStudio')
    (New-Pkg 'dbeaver'       'DBeaver (Community)'     'Banco'      'dbeaver' 'DBeaver.DBeaver.Community')

    # Navegadores
    (New-Pkg 'chrome'        'Google Chrome'           'Navegador'  'googlechrome' 'Google.Chrome' @('--ignore-checksums'))
    (New-Pkg 'firefox'       'Mozilla Firefox'         'Navegador'  'firefox' 'Mozilla.Firefox')
    (New-Pkg 'firefox-dev'   'Firefox Developer Ed.'   'Navegador'  'firefox-dev' 'Mozilla.Firefox.DeveloperEdition' @('--pre'))

    # APIs / testes
    (New-Pkg 'postman'       'Postman'                 'API'        'postman' 'Postman.Postman')
    (New-Pkg 'insomnia'      'Insomnia REST'           'API'        'insomnia-rest-api-client' 'Insomnia.Insomnia')
    (New-Pkg 'soapui'        'SoapUI'                  'API'        'soapui' 'SmartBear.SoapUI')

    # Utilitarios
    (New-Pkg 'notepadpp'     'Notepad++'               'Utilitario' 'notepadplusplus' 'Notepad++.Notepad++')
    (New-Pkg '7zip'          '7-Zip'                   'Utilitario' '7zip.install' '7zip.7zip')
    (New-Pkg 'greenshot'     'Greenshot'               'Utilitario' 'greenshot' 'Greenshot.Greenshot')
    (New-Pkg 'ditto'         'Ditto (clipboard)'       'Utilitario' 'ditto' 'Ditto.Ditto')
    (New-Pkg 'screentogif'   'ScreenToGif'             'Utilitario' 'screentogif' 'NickeManarin.ScreenToGif')
    (New-Pkg 'winscp'        'WinSCP'                  'Utilitario' 'winscp' 'WinSCP.WinSCP')
    (New-Pkg 's3browser'     'S3 Browser'              'Utilitario' 's3browser' 'Netsdk.S3Browser')

    # Acesso remoto / VPN
    (New-Pkg 'teamviewer'    'TeamViewer'              'Remoto/VPN' 'teamviewer' 'TeamViewer.TeamViewer')
    (New-Pkg 'forticlient'   'FortiClient VPN'         'Remoto/VPN' 'forticlientvpn' '' @() @() 'no' 'Sem pacote winget; usa choco')
    (New-Pkg 'openvpn'       'OpenVPN Connect'         'Remoto/VPN' 'openvpn-connect' 'OpenVPNTechnologies.OpenVPNConnect')
    (New-Pkg 'vncviewer'     'RealVNC Viewer'          'Remoto/VPN' 'vnc-viewer' 'RealVNC.VNCViewer')
    (New-Pkg 'netbird'       'NetBird'                 'Remoto/VPN' 'netbird' 'Netbird.Netbird')
    (New-Pkg 'cloudflared'   'Cloudflared'             'Remoto/VPN' 'cloudflared' 'Cloudflare.cloudflared')

    # Cloud
    (New-Pkg 'azstorage'     'Azure Storage Explorer'  'Cloud'      'microsoftazurestorageexplorer' 'Microsoft.Azure.StorageExplorer')
    (New-Pkg 'azcopy'        'AzCopy v10'              'Cloud'      'azcopy10' 'Microsoft.Azure.AZCopy.10')
    (New-Pkg 'azurecli'      'Azure CLI'               'Cloud'      'azure-cli' 'Microsoft.AzureCLI')

    # Runtimes / SDKs
    (New-Pkg 'dotnet8-sdk'   '.NET 8 SDK'              'Runtime'    'dotnet-8.0-sdk' 'Microsoft.DotNet.SDK.8')
    (New-Pkg 'dotnet10-sdk'  '.NET 10 SDK'             'Runtime'    'dotnet-10.0-sdk' 'Microsoft.DotNet.SDK.10')
    (New-Pkg 'dotnet8-host'  '.NET 8 Hosting Bundle'   'Runtime'    'dotnet-8.0-windowshosting' 'Microsoft.DotNet.HostingBundle.8')
    (New-Pkg 'dotnet10-host' '.NET 10 Hosting Bundle'  'Runtime'    'dotnet-10.0-windowshosting' 'Microsoft.DotNet.HostingBundle.10')
    (New-Pkg 'jdk21'         'Microsoft OpenJDK 21'    'Runtime'    'microsoft-openjdk-21' 'Microsoft.OpenJDK.21')
    (New-Pkg 'jdk17'         'OpenJDK 17 (17.0.2)'     'Runtime'    'openjdk' 'Microsoft.OpenJDK.17' @('--version=17.0.2'))
    (New-Pkg 'maven'         'Apache Maven'            'Runtime'    'maven' '' @() @() 'no' 'Sem pacote winget; usa choco')
    (New-Pkg 'nodejs'        'Node.js'                 'Runtime'    'nodejs' 'OpenJS.NodeJS')

    # IDEs
    (New-Pkg 'vs2022'        'Visual Studio 2022 Community' 'IDE'   'visualstudio2022community' 'Microsoft.VisualStudio.2022.Community' @() @() 'no' 'Download grande')
    (New-Pkg 'androidstudio' 'Android Studio'          'IDE'        'androidstudio' 'Google.AndroidStudio')

    # Containers
    (New-Pkg 'docker'        'Docker Desktop'          'Container'  'docker-desktop' 'Docker.DockerDesktop' @() @() 'maybe' 'Requer WSL2/Hyper-V; pode pedir reinicio')

    # Midia
    (New-Pkg 'obs'           'OBS Studio'              'Midia'      'obs-studio' 'OBSProject.OBSStudio')
    (New-Pkg 'bambustudio'   'Bambu Studio'            'Midia'      'bambustudio' 'Bambulab.Bambustudio')

    # Office
    (New-Pkg 'office'        'Microsoft 365 / Office'  'Office'     'office365business' 'Microsoft.Office' @() @() 'no' 'Instalacao demorada')

    # Outros
    (New-Pkg 'git'           'Git'                     'Outros'     'git' 'Git.Git')
    (New-Pkg 'choco-upg'     'Choco Upgrade-All p/ startup' 'Outros' 'choco-upgrade-all-at-startup' '' @() @() 'no' 'Especifico do Chocolatey')
)

# --- Catalogo de USUARIO (editavel, sem mexer no codigo) --------------------
# Arquivo JSON onde o usuario adiciona apps proprios (ex.: um lancamento novo).
# Formato: array de objetos { Key, Name, Category, Winget, Choco, Notes }.
# Minimo: Name + (Winget ou Choco). Key/Category sao opcionais.
$Script:UserSoftwareFile = Join-Path (Split-Path $Script:DefaultLogDir -Parent) 'software-extra.json'

# Le o catalogo de usuario e mescla no $Script:SoftwareCatalog (upsert por Key).
# Idempotente: pode ser chamada de novo que nao duplica. Retorna o nro lido.
function Import-UserSoftwareCatalog {
    if (-not (Test-Path $Script:UserSoftwareFile)) { return 0 }
    try {
        $raw = Get-Content -Path $Script:UserSoftwareFile -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw) { return 0 }
        $items = @($raw | ConvertFrom-Json)
    } catch {
        Write-Log "Catalogo de usuario invalido ($($Script:UserSoftwareFile)): $($_.Exception.Message)" -Level WARN
        return 0
    }
    $added = 0
    foreach ($it in $items) {
        if (-not $it.Name) { continue }
        $key = if ($it.Key) { [string]$it.Key } else { ($it.Name -replace '[^0-9A-Za-z]+', '-').Trim('-').ToLower() }
        if (-not $key) { continue }
        $cat   = if ($it.Category) { [string]$it.Category } else { 'Usuario' }
        $reb   = if ($it.Reboot)   { [string]$it.Reboot }   else { 'no' }
        $cargs = if ($it.ChocoArgs)  { @($it.ChocoArgs) }  else { @() }
        $wargs = if ($it.WingetArgs) { @($it.WingetArgs) } else { @() }
        $pkg = New-Pkg $key ([string]$it.Name) $cat ([string]$it.Choco) ([string]$it.Winget) $cargs $wargs $reb ([string]$it.Notes)
        $Script:SoftwareCatalog = @($Script:SoftwareCatalog | Where-Object { $_.Key -ne $key })
        $Script:SoftwareCatalog += $pkg
        $added++
    }
    if ($added) { Write-Log "Catalogo de usuario: $added item(ns) carregado(s)." -Level INFO }
    return $added
}

# Acrescenta (ou atualiza) um app no catalogo de usuario (grava no JSON).
function Add-UserSoftware {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Category = 'Usuario',
        [string] $Winget = '',
        [string] $Choco = '',
        [string] $Notes = ''
    )
    if (-not $Winget -and -not $Choco) {
        Write-Log "Informe ao menos um ID (winget ou choco) para '$Name'." -Level ERRO
        return $false
    }
    $key = ($Name -replace '[^0-9A-Za-z]+', '-').Trim('-').ToLower()
    if (-not $key) { $key = 'app-' + ([guid]::NewGuid().ToString('N').Substring(0, 6)) }

    $list = @()
    if (Test-Path $Script:UserSoftwareFile) {
        try { $raw = Get-Content $Script:UserSoftwareFile -Raw -Encoding UTF8; if ($raw) { $list = @($raw | ConvertFrom-Json) } } catch { }
    }
    $list = @($list | Where-Object { $_.Key -ne $key })
    $list += [PSCustomObject]@{ Key = $key; Name = $Name; Category = $Category; Winget = $Winget; Choco = $Choco; Notes = $Notes }
    try {
        $dir = Split-Path $Script:UserSoftwareFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($list | ConvertTo-Json -Depth 4) | Set-Content -Path $Script:UserSoftwareFile -Encoding UTF8
        Write-Log "Software '$Name' adicionado ao catalogo de usuario." -Level OK
        return $true
    } catch {
        Write-Log "Falha ao gravar o catalogo de usuario: $($_.Exception.Message)" -Level ERRO
        return $false
    }
}

# --- Resolve o gerenciador efetivo para um pacote ---------------------------
# Retorna 'winget', 'choco' ou $null (sem fonte).
function Resolve-Manager {
    param($Pkg, [string] $Preferred)
    switch ($Preferred) {
        'winget' { if ($Pkg.Winget) { return 'winget' } elseif ($Pkg.Choco) { Write-Log "'$($Pkg.Name)' sem pacote winget; usando choco." -Level WARN; return 'choco' } }
        'choco'  { if ($Pkg.Choco)  { return 'choco' }  elseif ($Pkg.Winget) { Write-Log "'$($Pkg.Name)' sem pacote choco; usando winget." -Level WARN; return 'winget' } }
        default  { if ($Pkg.Winget) { return 'winget' } elseif ($Pkg.Choco) { return 'choco' } }  # auto
    }
    return $null
}

# Extrai as ultimas linhas nao-vazias de uma saida (para detalhar erros).
function Get-OutputTail {
    param($Lines, [int] $Count = 15)
    $arr = @($Lines | ForEach-Object { "$_" } | Where-Object { $_ -match '\S' })
    if ($arr.Count -eq 0) { return '' }
    return (($arr | Select-Object -Last $Count) -join [Environment]::NewLine)
}

# Resumo de 1 linha (truncado) a partir da saida, para o campo Detail.
function Get-ErrorDetail {
    param($Lines, [int] $Code, [int] $Max = 160)
    $last = $Lines | ForEach-Object { "$_" } | Where-Object { $_ -match '\S' } | Select-Object -Last 1
    if (-not $last) { return "ExitCode $Code" }
    if ($last.Length -gt $Max) { $last = $last.Substring(0, $Max) + '...' }
    return "ExitCode $Code - $last"
}

# --- Instala um pacote ------------------------------------------------------
function Install-SoftwarePackage {
    param($Pkg, [string] $Preferred = 'auto')

    $mgr = Resolve-Manager -Pkg $Pkg -Preferred $Preferred
    if (-not $mgr) {
        Write-Log "Sem fonte (choco/winget) para '$($Pkg.Name)'." -Level ERRO
        Add-FeatureResult -Name $Pkg.Name -Status 'Falha' -Detail 'Sem pacote disponivel'
        return
    }

    if ($Pkg.Notes) { Write-Log "Nota ($($Pkg.Name)): $($Pkg.Notes)" -Level INFO }
    Start-FeatureTimer -Name $Pkg.Name

    if ($mgr -eq 'choco') {
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            if (-not (Install-Chocolatey)) {
                Add-FeatureResult -Name $Pkg.Name -Status 'Falha' -Detail 'Chocolatey indisponivel'
                return
            }
        }
        Write-Log "[choco] Instalando '$($Pkg.Name)' ($($Pkg.Choco))..." -Level STEP
        $argsList = @('install', $Pkg.Choco, '-y', '--no-progress') + $Pkg.ChocoArgs
        & choco @argsList | Tee-Object -Variable out   # mostra ao vivo E captura a saida
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Write-Log "'$($Pkg.Name)' instalado (choco)." -Level OK
            Add-FeatureResult -Name $Pkg.Name -Status 'Instalado'
        }
        elseif ($code -eq 3010 -or $code -eq 1641) {
            Write-Log "'$($Pkg.Name)' instalado (choco) - REINICIO necessario." -Level WARN
            Add-FeatureResult -Name $Pkg.Name -Status 'PrecisaReinicio'
        }
        else {
            Write-Log "Falha ao instalar '$($Pkg.Name)' (choco). ExitCode: $code" -Level ERRO
            $tail = Get-OutputTail $out
            if ($tail) { Write-Log "Detalhe (choco):`n$tail" -Level ERRO }
            Write-Log "Log completo: C:\ProgramData\chocolatey\logs\chocolatey.log" -Level INFO
            Add-FeatureResult -Name $Pkg.Name -Status 'Falha' -Detail (Get-ErrorDetail $out $code)
        }
    }
    else {
        Write-Log "[winget] Instalando '$($Pkg.Name)' ($($Pkg.Winget))..." -Level STEP
        $argsList = @('install', '--id', $Pkg.Winget, '-e', '--source', 'winget',
                      '--accept-package-agreements', '--accept-source-agreements',
                      '--disable-interactivity') + $Pkg.WingetArgs
        & winget @argsList | Tee-Object -Variable out   # mostra ao vivo E captura a saida
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Write-Log "'$($Pkg.Name)' instalado (winget)." -Level OK
            Add-FeatureResult -Name $Pkg.Name -Status 'Instalado'
        }
        else {
            Write-Log "Falha/aviso ao instalar '$($Pkg.Name)' (winget). ExitCode: $code" -Level ERRO
            $tail = Get-OutputTail $out
            if ($tail) { Write-Log "Detalhe (winget):`n$tail" -Level ERRO }
            Add-FeatureResult -Name $Pkg.Name -Status 'Falha' -Detail (Get-ErrorDetail $out $code)
        }
    }
}

# --- choco upgrade all ------------------------------------------------------
function Update-AllChoco {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        if (-not (Install-Chocolatey)) { return }
    }
    Write-Log "Executando 'choco upgrade all -y'..." -Level STEP
    & choco upgrade all -y --no-progress
    Write-Log "choco upgrade all concluido (ExitCode $LASTEXITCODE)." -Level OK
}

# --- Submenu de Softwares ---------------------------------------------------
function Invoke-SoftwareMenu {
    Reset-FeatureSession
    Import-UserSoftwareCatalog | Out-Null   # mescla apps adicionados pelo usuario

    # 1) Escolha do gerenciador
    Write-Host ""
    Write-Host "  --- Softwares / Runtimes ---" -ForegroundColor Cyan
    Write-Host "  Gerenciador de instalacao:"
    Write-Host "    1) winget   2) Chocolatey   3) auto (winget, fallback choco)"
    $mraw = Read-Host "Escolha [1/2/3]"
    $preferred = switch ($mraw) { '2' {'choco'} '3' {'auto'} default {'winget'} }
    Write-Log "Gerenciador selecionado: $preferred" -Level INFO

    if ($preferred -eq 'choco' -or $preferred -eq 'auto') {
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            if (Confirm-Action "Chocolatey nao esta instalado. Instalar agora?") { Install-Chocolatey | Out-Null }
        }
    }
    if (($preferred -eq 'winget') -and -not (Test-WingetAvailable)) {
        Write-Log "winget nao encontrado neste SO. Considere usar Chocolatey." -Level WARN
    }

    do {
        # Lista numerada do catalogo, por categoria
        Write-Host ""
        $i = 0
        $lastCat = ''
        foreach ($p in $Script:SoftwareCatalog) {
            if ($p.Category -ne $lastCat) { Write-Host ("  [{0}]" -f $p.Category) -ForegroundColor DarkCyan; $lastCat = $p.Category }
            $i++
            $src = @(); if ($p.Choco) { $src += 'choco' }; if ($p.Winget) { $src += 'winget' }
            Write-Host ("    {0,2}) {1,-30} ({2})" -f $i, $p.Name, ($src -join '/'))
        }
        Write-Host ""
        Write-Host "    A) Instalar TODOS      U) choco upgrade all      9) Resumo      0) Voltar"
        $sel = Read-Host "Numeros (ex: 1 4 7), A, U, 9 ou 0"

        if ($sel -match '^[0]$') { break }
        elseif ($sel -match '^[Uu]$') { Update-AllChoco }
        elseif ($sel -match '^[9]$') { Show-FeaturesSummary }
        elseif ($sel -match '^[Aa]$') {
            foreach ($p in $Script:SoftwareCatalog) { Install-SoftwarePackage -Pkg $p -Preferred $preferred }
        }
        else {
            $nums = $sel -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
            foreach ($n in $nums) {
                if ($n -ge 1 -and $n -le $Script:SoftwareCatalog.Count) {
                    Install-SoftwarePackage -Pkg $Script:SoftwareCatalog[$n - 1] -Preferred $preferred
                } else {
                    Write-Host "Numero fora da faixa: $n" -ForegroundColor Red
                }
            }
        }
    } while ($true)

    Show-FeaturesSummary
}
# ===== FIM modules\Software.ps1 =====

# ===== INICIO modules\Gui.ps1 =====
# ============================================================================
#  Gui.ps1  -  Tela clicavel (WinForms) com fallback de console
#  Depende de Common.ps1 e OSCommon.ps1 (Get-AvailableCapabilities,
#  Invoke-CapabilityInstall, Set-LogDirectory, $Script:FeatureResults).
#
#  Modelo: a tela e para SELECAO (o que instalar + pasta de log). A instalacao
#  roda depois que a tela fecha, com log ao vivo no console (Write-Log) e um
#  resumo final em MessageBox. Isso evita o congelamento da UI e a complexidade
#  de compartilhar funcoes entre runspaces sob 'irm | iex'.
# ============================================================================

# Le uma linha do console. Sob 'irm | iex' o pipeline carrega o corpo do script,
# entao Read-Host pode falhar; [Console]::ReadLine() e mais robusto.
function Read-Line {
    param([string] $Prompt)
    if ($Prompt) { Write-Host $Prompt -NoNewline }
    try { return [Console]::ReadLine() } catch { return (Read-Host) }
}

# Monta o texto do resumo (categorizado) a partir de $Script:FeatureResults.
function Get-SummaryText {
    if (-not $Script:FeatureResults -or $Script:FeatureResults.Count -eq 0) {
        return 'Nenhuma acao executada.'
    }
    $groups = @(
        @{ Label = 'Instalados / ja presentes';        Status = @('Instalado','JaPresente') }
        @{ Label = 'Precisam de REINICIO';             Status = @('PrecisaReinicio') }
        @{ Label = 'Deferidos (reinicio pendente)';    Status = @('Deferido') }
        @{ Label = 'Falhas';                           Status = @('Falha') }
    )
    $sb = New-Object System.Text.StringBuilder
    foreach ($g in $groups) {
        $items = $Script:FeatureResults | Where-Object { $g.Status -contains $_.Status }
        if ($items) {
            [void]$sb.AppendLine($g.Label + ':')
            foreach ($i in $items) {
                $d = if ($i.Detail) { "  ($($i.Detail))" } else { '' }
                [void]$sb.AppendLine('   - ' + $i.Name + $d)
            }
            [void]$sb.AppendLine('')
        }
    }
    return $sb.ToString()
}

# --- Tela WinForms ----------------------------------------------------------
# Retorna [PSCustomObject]@{ Ids=@(...); LogDir='...' } ou $null se cancelado.
function Show-InstallerGui {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $caps = @(Get-AvailableCapabilities)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Configurador Windows'
    $form.Size = New-Object System.Drawing.Size(540, 580)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Selecione o que instalar/configurar:'
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.AutoSize = $true
    $form.Controls.Add($lbl)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(12, 36)
    $clb.Size = New-Object System.Drawing.Size(500, 360)
    $clb.CheckOnClick = $true
    foreach ($c in $caps) {
        $txt = "{0}   [{1}]" -f $c.Display, $c.Category
        if ($c.Notes) { $txt += "  - $($c.Notes)" }
        [void]$clb.Items.Add($txt)
    }
    $form.Controls.Add($clb)

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = 'Selecionar tudo'
    $btnAll.Location = New-Object System.Drawing.Point(12, 404)
    $btnAll.Size = New-Object System.Drawing.Size(120, 28)
    $btnAll.Add_Click({
        $allChecked = $true
        for ($i = 0; $i -lt $clb.Items.Count; $i++) { if (-not $clb.GetItemChecked($i)) { $allChecked = $false; break } }
        for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, -not $allChecked) }
    })
    $form.Controls.Add($btnAll)

    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = 'Pasta de log:'
    $lblLog.Location = New-Object System.Drawing.Point(12, 446)
    $lblLog.AutoSize = $true
    $form.Controls.Add($lblLog)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(12, 468)
    $logBox.Size = New-Object System.Drawing.Size(500, 24)
    $logBox.Text = $Script:DefaultLogDir
    $form.Controls.Add($logBox)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = 'Instalar'
    $btnInstall.Location = New-Object System.Drawing.Point(316, 506)
    $btnInstall.Size = New-Object System.Drawing.Size(95, 32)
    $btnInstall.Add_Click({
        $ids = @()
        for ($i = 0; $i -lt $clb.Items.Count; $i++) {
            if ($clb.GetItemChecked($i)) { $ids += $caps[$i].Id }
        }
        if ($ids.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Selecione ao menos um item.', 'Atencao') | Out-Null
            return
        }
        $form.Tag = [PSCustomObject]@{ Ids = $ids; LogDir = $logBox.Text.Trim() }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnInstall)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancelar'
    $btnCancel.Location = New-Object System.Drawing.Point(417, 506)
    $btnCancel.Size = New-Object System.Drawing.Size(95, 32)
    $btnCancel.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.Controls.Add($btnCancel)

    $dr = $form.ShowDialog()
    if ($dr -eq [System.Windows.Forms.DialogResult]::OK) { return $form.Tag }
    return $null
}

# --- Fallback de console (Server Core / headless / sem STA) ------------------
# Retorna [PSCustomObject]@{ Ids=@(...); LogDir='...' } ou $null.
function Show-InstallerConsole {
    $caps = @(Get-AvailableCapabilities)

    Write-Host ""
    Write-Host "============ Configurador Windows (console) ============" -ForegroundColor Cyan
    Write-Host "Capacidades disponiveis neste SO:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $caps.Count; $i++) {
        $c = $caps[$i]
        $note = if ($c.Notes) { " - $($c.Notes)" } else { '' }
        Write-Host ("  {0,2}) {1,-32} [{2}]{3}" -f ($i + 1), $c.Display, $c.Category, $note)
    }
    Write-Host ""
    Write-Host "Digite os numeros separados por virgula (ex.: 1,3,5) ou 'tudo'." -ForegroundColor Yellow
    $resp = (Read-Line "Selecao: ").Trim()
    if (-not $resp) { return $null }

    $ids = @()
    if ($resp -match '^(tudo|all)$') {
        $ids = $caps | ForEach-Object { $_.Id }
    } else {
        foreach ($tok in ($resp -split '[,\s]+')) {
            if ($tok -match '^\d+$') {
                $idx = [int]$tok - 1
                if ($idx -ge 0 -and $idx -lt $caps.Count) { $ids += $caps[$idx].Id }
            }
        }
    }
    $ids = $ids | Select-Object -Unique
    if (-not $ids -or @($ids).Count -eq 0) { return $null }

    Write-Host ""
    $logDir = (Read-Line "Pasta de log (ENTER = $($Script:DefaultLogDir)): ").Trim()
    if (-not $logDir) { $logDir = $Script:DefaultLogDir }

    return [PSCustomObject]@{ Ids = @($ids); LogDir = $logDir }
}

# --- Orquestrador: escolhe GUI vs console e roda a instalacao ----------------
function Start-InstallerUi {
    $useGui = (Get-OSRole).CanUseGui

    $sel = $null
    if ($useGui) {
        try { $sel = Show-InstallerGui }
        catch {
            Write-Log "GUI indisponivel ($($_.Exception.Message)) - caindo para console." -Level WARN
            $useGui = $false
            $sel = Show-InstallerConsole
        }
    } else {
        $sel = Show-InstallerConsole
    }

    if (-not $sel -or -not $sel.Ids -or @($sel.Ids).Count -eq 0) {
        Write-Log "Nenhum item selecionado. Saindo." -Level INFO
        return
    }

    if ($sel.LogDir) { Set-LogDirectory -Path $sel.LogDir }

    Invoke-CapabilityInstall -Ids $sel.Ids

    $summary = Get-SummaryText
    if ($useGui) {
        try { [System.Windows.Forms.MessageBox]::Show($summary, 'Resumo da instalacao') | Out-Null } catch { }
    }
}

# --- Menu principal (compartilhado por setup.ps1 e pelo bundle irm) ----------
# Fica aqui (modulo empacotado) para o lancador 'irm | iex' poder abrir o MESMO
# menu completo do setup.ps1, e nao apenas a tela de capacidades. Depende das
# funcoes Invoke-*Menu dos modulos de area (ja carregados quando isto roda).
function Show-MainMenu {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   Configurador Windows Server  -  $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  CUSTOMIZACOES (Explorer / UI)"
    Write-Host "    1) Aplicar TODAS as customizacoes (dark mode + extensoes + ocultos)"
    Write-Host "    2) Ativar Dark Mode"
    Write-Host "    3) Mostrar extensoes de arquivos"
    Write-Host "    4) Mostrar arquivos ocultos"
    Write-Host ""
    Write-Host "  OUTRAS AREAS"
    Write-Host "    5) IIS / Servidor Web"
    Write-Host "    6) Funcoes/Recursos do Windows"
    Write-Host "    7) Softwares / Runtimes"
    Write-Host "    8) Config. base"
    Write-Host ""
    Write-Host "  INSTALACAO RAPIDA"
    Write-Host "    9) Tela de capacidades (GUI ou console)"
    Write-Host ""
    Write-Host "    0) Sair"
    Write-Host ""
}

function Start-MainMenu {
    do {
        Show-MainMenu
        $opt = Read-Host "Escolha uma opcao"

        switch ($opt) {
            '1' { Invoke-AllCustomizations }
            '2' { if (Enable-DarkMode)     { Restart-Explorer } }
            '3' { if (Show-FileExtensions) { Restart-Explorer } }
            '4' { if (Show-HiddenFiles)    { Restart-Explorer } }
            '5' { Invoke-IISMenu }
            '6' { Invoke-FeaturesMenu }
            '7' { Invoke-SoftwareMenu }
            '8' { Invoke-BaseConfigMenu }
            '9' { Start-InstallerUi }
            '0' { Write-Log "Saindo." -Level INFO }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }

        if ($opt -ne '0') {
            Write-Host ""
            Read-Host "Pressione ENTER para voltar ao menu"
        }
    } while ($opt -ne '0')
}
# ===== FIM modules\Gui.ps1 =====

# ===== INICIO modules\GuiWpf.ps1 =====
# ============================================================================
#  GuiWpf.ps1  -  Janela WPF (estilo app, abas) com fallback para console
#  Depende de Common.ps1, OSCommon.ps1, WindowsFeatures.ps1, IIS.ps1,
#  Software.ps1, Customizations.ps1, BaseConfig.ps1 e Gui.ps1.
#
#  Modelo: janela FICA ABERTA (sessao iterativa); cada aba tem seu "Aplicar".
#  Operacoes pesadas pedem CONFIRMACAO e desabilitam os botoes durante a execucao
#  (evita clique enfileirado disparar acao por engano enquanto a UI esta ocupada).
#  Operacoes longas rodam de forma sincrona - a janela pode ficar momentaneamente
#  irresponsiva; o log ao vivo sai no console.
#  Aba "Status" le o ledger persistente (installer-state.json) e mostra, ao abrir
#  (inclusive apos reinicio), o que ja foi feito / precisa de reinicio / deferido.
#  Sem WPF (Server Core / headless / nao-STA): cai para Start-MainMenu.
# ============================================================================

function Test-CanUseWpf {
    $role = Get-OSRole
    if ($role.IsServerCore) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return $false }
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        return $true
    } catch { return $false }
}

# Confirmacao Sim/Nao (rede contra cliques enfileirados em acoes pesadas).
function Confirm-Wpf {
    param([string] $Message)
    return ([System.Windows.MessageBox]::Show($Message, 'Confirmar',
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) `
        -eq [System.Windows.MessageBoxResult]::Yes)
}

# Formata uma lista de nomes para o texto da confirmacao (limita o tamanho).
function Format-ConfirmList {
    param([string[]] $Names, [int] $Max = 25)
    $n = @($Names | Where-Object { $_ })
    $txt = (($n | Select-Object -First $Max) | ForEach-Object { "  - $_" }) -join "`n"
    if ($n.Count -gt $Max) { $txt += "`n  ... +$($n.Count - $Max)" }
    return $txt
}

function New-WpfHeader {
    param([string] $Text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontWeight = 'Bold'
    $tb.Foreground = [System.Windows.Media.Brushes]::DeepSkyBlue
    $tb.Margin = [System.Windows.Thickness]::new(0, 10, 0, 4)
    return $tb
}

function Get-WpfCheckedTags {
    param($Panel)
    $out = @()
    foreach ($ch in $Panel.Children) {
        if ($ch -is [System.Windows.Controls.CheckBox] -and $ch.IsChecked) { $out += $ch.Tag }
    }
    return $out
}

function Set-WpfAllChecks {
    param($Panel, [bool] $Value)
    foreach ($ch in $Panel.Children) {
        if ($ch -is [System.Windows.Controls.CheckBox]) { $ch.IsChecked = $Value }
    }
}

# Mapa Name -> item do ledger, apenas dos que estao Instalado/JaPresente.
function Get-InstalledStateMap {
    $map = @{}
    foreach ($it in @(Get-FeatureStateLedger)) {
        if ($it.Name -and ($it.Status -eq 'Instalado' -or $it.Status -eq 'JaPresente')) { $map[[string]$it.Name] = $it }
    }
    return $map
}

# Marca um checkbox como "ja instalado" (texto ao lado + cor verde) pelo mapa.
function Set-WpfInstalledMark {
    param($CheckBox, $Map, [string] $Key)
    if ($Map.ContainsKey($Key)) {
        $ts  = $Map[$Key].Timestamp
        $tag = if ($ts) { "[instalado $($ts.Substring(0,10))]" } else { '[instalado]' }
        $CheckBox.Content = "$($CheckBox.Content)   $tag"
        $CheckBox.Foreground = [System.Windows.Media.Brushes]::LightGreen
    }
}

# Features: exclui Web/IIS e .NET (vao na aba IIS). Mantem Virtualizacao, Rede,
# Mensageria. Mantem a ordem do catalogo, agrupando por categoria.
function Add-WpfFeatureItems {
    param($Panel)
    $Panel.Children.Clear()
    $map = Get-InstalledStateMap
    $lastCat = ''
    foreach ($c in @(Get-AvailableCapabilities)) {
        if ($c.Category -in @('Web/IIS', '.NET')) { continue }
        if ($c.Category -ne $lastCat) { [void]$Panel.Children.Add((New-WpfHeader $c.Category)); $lastCat = $c.Category }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = if ($c.Notes) { "$($c.Display)   ($($c.Notes))" } else { $c.Display }
        $cb.Tag = $c.Id
        Set-WpfInstalledMark $cb $map $c.Display
        [void]$Panel.Children.Add($cb)
    }
}

# Softwares: catalogo embutido + de usuario. Filtro 'all' | 'winget' | 'choco'.
function Add-WpfSoftwareItems {
    param($Panel, [string] $Filter = 'all')
    $Panel.Children.Clear()
    Import-UserSoftwareCatalog | Out-Null
    $map = Get-InstalledStateMap
    $list = $Script:SoftwareCatalog
    if ($Filter -eq 'winget') { $list = @($list | Where-Object { $_.Winget }) }
    elseif ($Filter -eq 'choco') { $list = @($list | Where-Object { $_.Choco }) }
    $lastCat = ''
    foreach ($p in $list) {
        if ($p.Category -ne $lastCat) { [void]$Panel.Children.Add((New-WpfHeader $p.Category)); $lastCat = $p.Category }
        $src = @(); if ($p.Choco) { $src += 'choco' }; if ($p.Winget) { $src += 'winget' }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($p.Name)   ($($src -join '/'))"
        $cb.Tag = $p.Key
        Set-WpfInstalledMark $cb $map $p.Name
        [void]$Panel.Children.Add($cb)
    }
}

# IIS: lista COMPLETA na ordem de $Script:IISFeatures + itens de pos-instalacao
# (aspnet_state, iisreset) como marcadores especiais.
function Add-WpfIisItems {
    param($Panel)
    $Panel.Children.Clear()
    $map = Get-InstalledStateMap
    [void]$Panel.Children.Add((New-WpfHeader 'Features do IIS (ordem padrao)'))
    foreach ($f in $Script:IISFeatures) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $f
        $cb.Tag = $f
        Set-WpfInstalledMark $cb $map $f
        [void]$Panel.Children.Add($cb)
    }
    [void]$Panel.Children.Add((New-WpfHeader 'Pos-instalacao'))
    $a = New-Object System.Windows.Controls.CheckBox; $a.Content = 'aspnet_state = Automatico'; $a.Tag = '__aspnet_state__'; [void]$Panel.Children.Add($a)
    $i = New-Object System.Windows.Controls.CheckBox; $i.Content = 'iisreset'; $i.Tag = '__iisreset__'; [void]$Panel.Children.Add($i)
}

function Set-WpfStatusPanel {
    param($Panel, $RebootLabel)
    $Panel.Children.Clear()
    if (Test-PendingReboot) {
        $RebootLabel.Text = 'ATENCAO: ha um REINICIO pendente. Itens que dependem de reinicio foram adiados - reinicie o servidor e rode de novo.'
        $RebootLabel.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } else {
        $RebootLabel.Text = 'Sem reinicio pendente.'
        $RebootLabel.Foreground = [System.Windows.Media.Brushes]::LightGreen
    }
    # Cabecalho ao vivo: maquina / OS / IPs atuais.
    $mi = Get-MachineInfo
    $hMac = New-Object System.Windows.Controls.TextBlock
    $hMac.Text = "Maquina: $($mi.Machine)    IPs: $((@(Get-HostIPv4) -join ', '))"
    $hMac.Foreground = [System.Windows.Media.Brushes]::DeepSkyBlue
    $hMac.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$Panel.Children.Add($hMac)
    if ($mi.OS) {
        $hOs = New-Object System.Windows.Controls.TextBlock
        $hOs.Text = "SO: $($mi.OS)"
        $hOs.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        [void]$Panel.Children.Add($hOs)
    }

    $ledger = @(Get-FeatureStateLedger)
    if ($ledger.Count -eq 0) {
        [void]$Panel.Children.Add((New-WpfHeader 'Nenhuma execucao registrada ainda.'))
        return
    }
    $groups = @(
        @{ Label = 'Instalados / ja presentes';           St = @('Instalado', 'JaPresente') }
        @{ Label = 'Precisam de REINICIO';                St = @('PrecisaReinicio') }
        @{ Label = 'Deferidos (havia reinicio pendente)'; St = @('Deferido') }
        @{ Label = 'Falhas';                              St = @('Falha') }
    )
    foreach ($g in $groups) {
        $items = @($ledger | Where-Object { $g.St -contains $_.Status })
        if ($items.Count -gt 0) {
            [void]$Panel.Children.Add((New-WpfHeader $g.Label))
            foreach ($it in $items) {
                $tb = New-Object System.Windows.Controls.TextBlock
                $d   = if ($it.Detail) { "  ($($it.Detail))" } else { '' }
                $ts  = if ($it.Timestamp) { "   [$($it.Timestamp)]" } else { '' }
                $dur = if ($it.DurationSec) { "   $($it.DurationSec)s" } else { '' }
                $mq  = if ($it.Machine -and $it.Machine -ne $mi.Machine) { "   @$($it.Machine)" } else { '' }
                $tb.Text = "   - $($it.Name)$d$ts$dur$mq"
                $tb.Margin = [System.Windows.Thickness]::new(12, 1, 0, 1)
                [void]$Panel.Children.Add($tb)
            }
        }
    }
}

function Show-AddSoftwareDialog {
    param($Owner)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Adicionar software" Height="340" Width="470"
        WindowStartupLocation="CenterOwner" Background="#FF1E1E1E" ResizeMode="NoResize">
  <Grid Margin="14">
    <Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition Height="20"/><RowDefinition/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Grid.Column="0" Text="Nome:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aName" Grid.Row="0" Grid.Column="1" Margin="0,4" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="1" Grid.Column="0" Text="Categoria:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aCat" Grid.Row="1" Grid.Column="1" Margin="0,4" Text="Usuario" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="2" Grid.Column="0" Text="ID winget:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aWin" Grid.Row="2" Grid.Column="1" Margin="0,4" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="3" Grid.Column="0" Text="ID choco:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aCho" Grid.Row="3" Grid.Column="1" Margin="0,4" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="4" Grid.Column="0" Text="Notas:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aNotes" Grid.Row="4" Grid.Column="1" Margin="0,4" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="5" Grid.ColumnSpan="2" Text="Informe ao menos um ID (winget ou choco)." Foreground="#FF9CDCFE"/>
    <StackPanel Grid.Row="6" Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="aOk" Content="Salvar" Width="90" Height="30" Margin="0,0,8,0" Background="#FF0E639C" Foreground="White"/>
      <Button x:Name="aCancel" Content="Cancelar" Width="90" Height="30" Background="#FF3F3F46" Foreground="White"/>
    </StackPanel>
  </Grid>
</Window>
'@
    [xml]$xml = $x
    $rd = New-Object System.Xml.XmlNodeReader $xml
    $w = [Windows.Markup.XamlReader]::Load($rd)
    if ($Owner) { $w.Owner = $Owner }
    $aName = $w.FindName('aName'); $aCat = $w.FindName('aCat'); $aWin = $w.FindName('aWin')
    $aCho = $w.FindName('aCho'); $aNotes = $w.FindName('aNotes')
    $aOk = $w.FindName('aOk'); $aCancel = $w.FindName('aCancel')
    $aOk.Add_Click({
        if (-not $aName.Text.Trim()) { [System.Windows.MessageBox]::Show('Informe o nome.', 'Atencao') | Out-Null; return }
        if (-not $aWin.Text.Trim() -and -not $aCho.Text.Trim()) { [System.Windows.MessageBox]::Show('Informe ao menos um ID (winget ou choco).', 'Atencao') | Out-Null; return }
        $w.Tag = [PSCustomObject]@{
            Name = $aName.Text.Trim(); Category = $aCat.Text.Trim()
            Winget = $aWin.Text.Trim(); Choco = $aCho.Text.Trim(); Notes = $aNotes.Text.Trim()
        }
        $w.DialogResult = $true; $w.Close()
    })
    $aCancel.Add_Click({ $w.DialogResult = $false; $w.Close() })
    $null = $w.ShowDialog()
    if ($w.DialogResult -ne $true) { return $null }
    return $w.Tag
}

function Show-InstallerWpf {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop

    $xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configurador Windows Server" Height="720" Width="1080"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E1E" MinWidth="860" MinHeight="560">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFDDDDDD"/></Style>
    <Style TargetType="Label"><Setter Property="Foreground" Value="#FFDDDDDD"/></Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFDDDDDD"/>
      <Setter Property="Margin" Value="12,2,0,2"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="#FFDDDDDD"/>
      <Setter Property="Margin" Value="0,6,0,6"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF0E639C"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#FF0E639C"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#FF2D2D30"/>
      <Setter Property="Foreground" Value="#FFEEEEEE"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
      <Setter Property="Padding" Value="3,2"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF252526" Padding="8">
      <DockPanel LastChildFill="False">
        <Label Content="Pasta de log:" DockPanel.Dock="Left" VerticalAlignment="Center"/>
        <TextBox x:Name="txtLog" Width="360" DockPanel.Dock="Left" Margin="6,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="btnClose" Content="Fechar" DockPanel.Dock="Right" Width="90" Height="30"/>
      </DockPanel>
    </Border>
    <TabControl x:Name="tabs" Background="#FF1E1E1E" BorderBrush="#FF3F3F46" Margin="6">

      <TabItem Header="Status">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Margin="12,10">
            <TextBlock x:Name="lblReboot" TextWrapping="Wrap" FontWeight="Bold"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="btnRefresh" Content="Atualizar" Width="110" Height="28"/>
              <Button x:Name="btnClearState" Content="Limpar historico" Width="140" Height="28" Background="#FF6E1E1E" BorderBrush="#FF6E1E1E"/>
            </StackPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spStatus" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Features">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="12,8">
            <Button x:Name="btnFeatAll" Content="Selecionar tudo" Width="130" Height="28"/>
            <Button x:Name="btnFeatNone" Content="Limpar" Width="90" Height="28"/>
            <Button x:Name="btnFeatApply" Content="Aplicar selecionados" Width="180" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
            <TextBlock x:Name="lblFeat" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF9CDCFE"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spFeatures" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Softwares">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Margin="12,8">
            <StackPanel Orientation="Horizontal">
              <Label Content="Gerenciador:" VerticalAlignment="Center"/>
              <RadioButton x:Name="rbWinget" Content="winget" Foreground="#FFDDDDDD" IsChecked="True" Margin="8,0" VerticalAlignment="Center" GroupName="mgr"/>
              <RadioButton x:Name="rbChoco" Content="Chocolatey" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center" GroupName="mgr"/>
              <RadioButton x:Name="rbAuto" Content="auto" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center" GroupName="mgr"/>
              <Label Content="   Mostrar:" VerticalAlignment="Center"/>
              <RadioButton x:Name="rbFiltAll" Content="todos" Foreground="#FFDDDDDD" IsChecked="True" Margin="8,0" VerticalAlignment="Center" GroupName="filt"/>
              <RadioButton x:Name="rbFiltWinget" Content="so winget" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center" GroupName="filt"/>
              <RadioButton x:Name="rbFiltChoco" Content="so choco" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center" GroupName="filt"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="btnSoftAll" Content="Selecionar tudo" Width="130" Height="28"/>
              <Button x:Name="btnSoftNone" Content="Limpar" Width="90" Height="28"/>
              <Button x:Name="btnSoftApply" Content="Aplicar selecionados" Width="180" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
              <Button x:Name="btnAddSoft" Content="Adicionar software..." Width="160" Height="28"/>
              <Button x:Name="btnChocoUpg" Content="choco upgrade all" Width="150" Height="28"/>
            </StackPanel>
            <TextBlock x:Name="lblSoft" Margin="0,6,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spSoftware" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="IIS">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Margin="12,8">
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,6"
                       Text="Marque as features desejadas (ou use os botoes). 'IIS COMPLETO' instala a lista toda + aspnet_state + iisreset."/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnIisAll" Content="Selecionar tudo" Width="130" Height="28"/>
              <Button x:Name="btnIisNone" Content="Limpar" Width="90" Height="28"/>
              <Button x:Name="btnIisApply" Content="Aplicar selecionados" Width="170" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
              <Button x:Name="btnIisFull" Content="Instalar IIS COMPLETO" Width="180" Height="28"/>
              <Button x:Name="btnAspNet" Content="aspnet_state=Auto" Width="150" Height="28"/>
              <Button x:Name="btnIisReset" Content="iisreset" Width="90" Height="28"/>
            </StackPanel>
            <TextBlock x:Name="lblIis" Margin="0,6,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spIis" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Rede (NAT / DHCP)">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
          <StackPanel Margin="12">
            <GroupBox Header="NAT Switch (Hyper-V)">
              <Grid Margin="8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="380"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <Label Grid.Row="0" Grid.Column="0" Content="Nome do switch:"/>
                <TextBox x:Name="natName" Grid.Row="0" Grid.Column="1" Margin="0,3" Text="NATSwitch"/>
                <Label Grid.Row="1" Grid.Column="0" Content="Sub-rede (CIDR):"/>
                <TextBox x:Name="natSubnet" Grid.Row="1" Grid.Column="1" Margin="0,3" Text="172.16.3.0/24"/>
                <Label Grid.Row="2" Grid.Column="0" Content="Gateway:"/>
                <TextBox x:Name="natGw" Grid.Row="2" Grid.Column="1" Margin="0,3" Text="172.16.3.1"/>
                <Label Grid.Row="3" Grid.Column="0" Content="Nome rede NAT (opc.):"/>
                <TextBox x:Name="natNetName" Grid.Row="3" Grid.Column="1" Margin="0,3"/>
                <Button x:Name="btnNat" Grid.Row="4" Grid.Column="1" Content="Criar NAT Switch" Width="170" HorizontalAlignment="Left" Height="30" Margin="0,8"/>
              </Grid>
            </GroupBox>
            <GroupBox Header="DHCP para o NAT (Windows Server)">
              <Grid Margin="8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="380"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <Button x:Name="btnDetect" Grid.Row="0" Grid.Column="1" Content="Detectar rede NAT" Width="170" HorizontalAlignment="Left" Height="28" Margin="0,3"/>
                <Label Grid.Row="1" Grid.Column="0" Content="Rede NAT:"/>
                <ComboBox x:Name="cboNat" Grid.Row="1" Grid.Column="1" Margin="0,3" HorizontalAlignment="Left" Width="380"/>
                <Label Grid.Row="2" Grid.Column="0" Content="Sub-rede (scope):"/>
                <TextBox x:Name="dhScope" Grid.Row="2" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="3" Grid.Column="0" Content="Mascara:"/>
                <TextBox x:Name="dhMask" Grid.Row="3" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="4" Grid.Column="0" Content="Gateway:"/>
                <TextBox x:Name="dhGw" Grid.Row="4" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="5" Grid.Column="0" Content="Faixa inicio / fim:"/>
                <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal">
                  <TextBox x:Name="dhFrom" Width="180" Margin="0,3,6,3"/>
                  <TextBox x:Name="dhTo" Width="180" Margin="0,3"/>
                </StackPanel>
                <Label Grid.Row="6" Grid.Column="0" Content="DNS / Lease(dias):"/>
                <StackPanel Grid.Row="6" Grid.Column="1" Orientation="Horizontal">
                  <TextBox x:Name="dhDns" Width="210" Margin="0,3,6,3" Text="213.186.33.99"/>
                  <TextBox x:Name="dhLease" Width="100" Margin="0,3" Text="7300"/>
                </StackPanel>
                <Button x:Name="btnDhcp" Grid.Row="7" Grid.Column="1" Content="Aplicar DHCP" Width="170" HorizontalAlignment="Left" Height="30" Margin="0,8"/>
              </Grid>
            </GroupBox>
            <TextBlock x:Name="lblNet" TextWrapping="Wrap" Margin="2,8" Foreground="#FF9CDCFE"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Customizacoes">
        <StackPanel Margin="14">
          <CheckBox x:Name="chkDark" Content="Ativar Dark Mode (apps e sistema)"/>
          <CheckBox x:Name="chkExt" Content="Mostrar extensoes de arquivos"/>
          <CheckBox x:Name="chkHidden" Content="Mostrar arquivos ocultos"/>
          <CheckBox x:Name="chkSuperHidden" Content="Mostrar tambem arquivos protegidos do SO"/>
          <Button x:Name="btnCust" Content="Aplicar customizacoes" Width="200" Height="32" HorizontalAlignment="Left" Margin="12,12,0,0" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
          <TextBlock x:Name="lblCust" Margin="12,12,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
        </StackPanel>
      </TabItem>

      <TabItem Header="Config base">
        <StackPanel Margin="14">
          <CheckBox x:Name="chkIeEsc" Content="Desativar IE Enhanced Security Configuration (IE ESC)"/>
          <CheckBox x:Name="chkTz" Content="Time zone para Brasilia"/>
          <CheckBox x:Name="chkNtp" Content="Ajustar/sincronizar data e hora (NTP)"/>
          <CheckBox x:Name="chkSrvMgr" Content="Nao iniciar o Server Manager no logon"/>
          <Button x:Name="btnBase" Content="Aplicar config. base" Width="200" Height="32" HorizontalAlignment="Left" Margin="12,12,0,0" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
          <TextBlock x:Name="lblBase" Margin="12,12,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
        </StackPanel>
      </TabItem>

    </TabControl>
  </DockPanel>
</Window>
'@

    [xml]$xaml = $xamlText
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    # Icone proprio (em vez do icone do PowerShell): usa o do Server Manager
    # (Server) ou do mmc (fallback). Falha silenciosa mantem o padrao.
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $iconExe = "$env:WINDIR\System32\ServerManager.exe"
        if (-not (Test-Path $iconExe)) { $iconExe = "$env:WINDIR\System32\mmc.exe" }
        $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($iconExe)
        if ($ic) {
            $win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $ic.Handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        }
    } catch { }

    $txtLog = $win.FindName('txtLog'); $btnClose = $win.FindName('btnClose')
    $lblReboot = $win.FindName('lblReboot'); $spStatus = $win.FindName('spStatus')
    $btnRefresh = $win.FindName('btnRefresh'); $btnClearState = $win.FindName('btnClearState')
    $spFeatures = $win.FindName('spFeatures'); $btnFeatAll = $win.FindName('btnFeatAll'); $btnFeatNone = $win.FindName('btnFeatNone'); $btnFeatApply = $win.FindName('btnFeatApply'); $lblFeat = $win.FindName('lblFeat')
    $rbChoco = $win.FindName('rbChoco'); $rbAuto = $win.FindName('rbAuto')
    $rbFiltAll = $win.FindName('rbFiltAll'); $rbFiltWinget = $win.FindName('rbFiltWinget'); $rbFiltChoco = $win.FindName('rbFiltChoco')
    $spSoftware = $win.FindName('spSoftware'); $btnSoftAll = $win.FindName('btnSoftAll'); $btnSoftNone = $win.FindName('btnSoftNone')
    $btnSoftApply = $win.FindName('btnSoftApply'); $btnAddSoft = $win.FindName('btnAddSoft'); $btnChocoUpg = $win.FindName('btnChocoUpg'); $lblSoft = $win.FindName('lblSoft')
    $spIis = $win.FindName('spIis'); $btnIisAll = $win.FindName('btnIisAll'); $btnIisNone = $win.FindName('btnIisNone'); $btnIisApply = $win.FindName('btnIisApply')
    $btnIisFull = $win.FindName('btnIisFull'); $btnAspNet = $win.FindName('btnAspNet'); $btnIisReset = $win.FindName('btnIisReset'); $lblIis = $win.FindName('lblIis')
    $natName = $win.FindName('natName'); $natSubnet = $win.FindName('natSubnet'); $natGw = $win.FindName('natGw'); $natNetName = $win.FindName('natNetName'); $btnNat = $win.FindName('btnNat')
    $btnDetect = $win.FindName('btnDetect'); $cboNat = $win.FindName('cboNat')
    $dhScope = $win.FindName('dhScope'); $dhMask = $win.FindName('dhMask'); $dhGw = $win.FindName('dhGw')
    $dhFrom = $win.FindName('dhFrom'); $dhTo = $win.FindName('dhTo'); $dhDns = $win.FindName('dhDns'); $dhLease = $win.FindName('dhLease')
    $btnDhcp = $win.FindName('btnDhcp'); $lblNet = $win.FindName('lblNet')
    $chkDark = $win.FindName('chkDark'); $chkExt = $win.FindName('chkExt'); $chkHidden = $win.FindName('chkHidden'); $chkSuperHidden = $win.FindName('chkSuperHidden')
    $btnCust = $win.FindName('btnCust'); $lblCust = $win.FindName('lblCust')
    $chkIeEsc = $win.FindName('chkIeEsc'); $chkTz = $win.FindName('chkTz'); $chkNtp = $win.FindName('chkNtp'); $chkSrvMgr = $win.FindName('chkSrvMgr')
    $btnBase = $win.FindName('btnBase'); $lblBase = $win.FindName('lblBase')

    $txtLog.Text = $Script:DefaultLogDir
    $ui = @{ Nets = @(); Iface = '' }

    Add-WpfFeatureItems $spFeatures
    Add-WpfSoftwareItems $spSoftware 'all'
    Add-WpfIisItems $spIis
    Set-WpfStatusPanel $spStatus $lblReboot

    # Botoes que devem ser desabilitados durante uma operacao.
    $actionButtons = @($btnFeatApply, $btnFeatAll, $btnFeatNone, $btnSoftApply, $btnSoftAll, $btnSoftNone,
        $btnChocoUpg, $btnAddSoft, $btnIisApply, $btnIisAll, $btnIisNone, $btnIisFull, $btnAspNet, $btnIisReset,
        $btnNat, $btnDetect, $btnDhcp, $btnCust, $btnBase)
    $setBusy = { param([bool] $b) foreach ($x in $actionButtons) { if ($x) { $x.IsEnabled = -not $b } } }
    $applyLog = { if ($txtLog.Text.Trim()) { Set-LogDirectory -Path $txtLog.Text.Trim() } }
    $softFilter = { if ($rbFiltWinget.IsChecked) { 'winget' } elseif ($rbFiltChoco.IsChecked) { 'choco' } else { 'all' } }

    # --- Status ---
    $btnRefresh.Add_Click({ Set-WpfStatusPanel $spStatus $lblReboot })
    $btnClearState.Add_Click({ Clear-FeatureState; Set-WpfStatusPanel $spStatus $lblReboot })
    $btnClose.Add_Click({ $win.Close() })

    # --- Features ---
    $btnFeatAll.Add_Click({ Set-WpfAllChecks $spFeatures $true })
    $btnFeatNone.Add_Click({ Set-WpfAllChecks $spFeatures $false })
    $btnFeatApply.Add_Click({
        $ids = @(Get-WpfCheckedTags $spFeatures)
        if ($ids.Count -eq 0) { $lblFeat.Text = 'Nada selecionado.'; return }
        $names = @($ids | ForEach-Object { $id = $_; ($Script:CapabilityCatalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1).Display })
        if (-not (Confirm-Wpf "Aplicar estas $($ids.Count) feature(s)?`n$(Format-ConfirmList $names)")) { return }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            Invoke-CapabilityInstall -Ids $ids; $lblFeat.Text = Get-SummaryText
        } catch { $lblFeat.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfFeatureItems $spFeatures }
    })

    # --- Softwares ---
    $btnSoftAll.Add_Click({ Set-WpfAllChecks $spSoftware $true })
    $btnSoftNone.Add_Click({ Set-WpfAllChecks $spSoftware $false })
    $rbFiltAll.Add_Checked({ Add-WpfSoftwareItems $spSoftware 'all' })
    $rbFiltWinget.Add_Checked({ Add-WpfSoftwareItems $spSoftware 'winget' })
    $rbFiltChoco.Add_Checked({ Add-WpfSoftwareItems $spSoftware 'choco' })
    $btnAddSoft.Add_Click({
        $r = Show-AddSoftwareDialog -Owner $win
        if ($r) {
            if (Add-UserSoftware -Name $r.Name -Category $r.Category -Winget $r.Winget -Choco $r.Choco -Notes $r.Notes) {
                Add-WpfSoftwareItems $spSoftware (& $softFilter)
                $lblSoft.Text = "Adicionado: $($r.Name). Marque e clique 'Aplicar selecionados'."
            } else { $lblSoft.Text = 'Falha ao adicionar (ver log).' }
        }
    })
    $btnChocoUpg.Add_Click({
        if (-not (Confirm-Wpf 'Executar "choco upgrade all"? Pode demorar.')) { return }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog; Update-AllChoco; $lblSoft.Text = 'choco upgrade all executado (ver log/console).' }
        catch { $lblSoft.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false }
    })
    $btnSoftApply.Add_Click({
        $keys = @(Get-WpfCheckedTags $spSoftware)
        if ($keys.Count -eq 0) { $lblSoft.Text = 'Nada selecionado.'; return }
        $names = @($keys | ForEach-Object { $k = $_; ($Script:SoftwareCatalog | Where-Object { $_.Key -eq $k } | Select-Object -First 1).Name })
        if (-not (Confirm-Wpf "Instalar estes $($keys.Count) software(s)?`n$(Format-ConfirmList $names)")) { return }
        $pref = if ($rbChoco.IsChecked) { 'choco' } elseif ($rbAuto.IsChecked) { 'auto' } else { 'winget' }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            Reset-FeatureSession
            foreach ($k in $keys) {
                $pkg = $Script:SoftwareCatalog | Where-Object { $_.Key -eq $k }
                if ($pkg) { Install-SoftwarePackage -Pkg $pkg -Preferred $pref }
            }
            Show-FeaturesSummary; $lblSoft.Text = Get-SummaryText
        } catch { $lblSoft.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfSoftwareItems $spSoftware (& $softFilter) }
    })

    # --- IIS ---
    $btnIisAll.Add_Click({ Set-WpfAllChecks $spIis $true })
    $btnIisNone.Add_Click({ Set-WpfAllChecks $spIis $false })
    $btnIisApply.Add_Click({
        $tags = @(Get-WpfCheckedTags $spIis)
        $feats = @($tags | Where-Object { $_ -notlike '__*' })
        $doAspnet = $tags -contains '__aspnet_state__'
        $doReset  = $tags -contains '__iisreset__'
        if ($feats.Count -eq 0 -and -not $doAspnet -and -not $doReset) { $lblIis.Text = 'Nada selecionado.'; return }
        $lst = @($feats); if ($doAspnet) { $lst += 'aspnet_state = Automatico' }; if ($doReset) { $lst += 'iisreset' }
        if (-not (Confirm-Wpf "Aplicar no IIS ($($lst.Count) item(ns))?`n$(Format-ConfirmList $lst)")) { return }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            Reset-FeatureSession
            foreach ($f in $feats) { Enable-OptionalFeatureSafe -FeatureName $f -All }   # ordem = $IISFeatures
            if ($doAspnet) { Set-AspNetStateAuto }
            if ($doReset)  { Invoke-IISReset }
            Show-FeaturesSummary; $lblIis.Text = Get-SummaryText
        } catch { $lblIis.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfIisItems $spIis }
    })
    $btnIisFull.Add_Click({
        if (-not (Confirm-Wpf "Instalar IIS COMPLETO ($($Script:IISFeatures.Count) features) + aspnet_state + iisreset? Pode demorar.")) { return }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog; Reset-FeatureSession; Install-IISFull; Show-FeaturesSummary; $lblIis.Text = Get-SummaryText }
        catch { $lblIis.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfIisItems $spIis }
    })
    $btnAspNet.Add_Click({
        if (-not (Confirm-Wpf 'Definir o servico aspnet_state como Automatico?')) { return }
        try { & $setBusy $true; & $applyLog; Set-AspNetStateAuto; $lblIis.Text = 'aspnet_state configurado (ver log).' }
        catch { $lblIis.Text = "Erro: $($_.Exception.Message)" } finally { & $setBusy $false }
    })
    $btnIisReset.Add_Click({
        if (-not (Confirm-Wpf 'Executar iisreset agora?')) { return }
        try { & $setBusy $true; & $applyLog; Invoke-IISReset; $lblIis.Text = 'iisreset executado (ver log).' }
        catch { $lblIis.Text = "Erro: $($_.Exception.Message)" } finally { & $setBusy $false }
    })

    # --- Rede: NAT ---
    $btnNat.Add_Click({
        if (-not (Confirm-Wpf "Criar/atualizar o NAT Switch '$($natName.Text.Trim())' ($($natSubnet.Text.Trim()))?")) { return }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            Reset-FeatureSession
            if ($natNetName.Text.Trim()) {
                New-NatSwitch -SwitchName $natName.Text.Trim() -Subnet $natSubnet.Text.Trim() -GatewayIP $natGw.Text.Trim() -NatName $natNetName.Text.Trim()
            } else {
                New-NatSwitch -SwitchName $natName.Text.Trim() -Subnet $natSubnet.Text.Trim() -GatewayIP $natGw.Text.Trim()
            }
            $lblNet.Text = Get-SummaryText
        } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    # --- Rede: DHCP ---
    $fillFromNet = {
        param($n)
        $dhScope.Text = $n.ScopeId; $dhMask.Text = $n.Mask; $dhGw.Text = $n.GatewayIP
        $netU = ConvertTo-IPv4UInt32 -IP $n.ScopeId
        $dhFrom.Text = ConvertFrom-IPv4UInt32 -Value ($netU + 50)
        $dhTo.Text   = ConvertFrom-IPv4UInt32 -Value ($netU + 200)
        $ui.Iface = $n.InterfaceAlias
    }
    $cboNat.Add_SelectionChanged({
        $idx = $cboNat.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $ui.Nets.Count) { & $fillFromNet $ui.Nets[$idx] }
    })
    $btnDetect.Add_Click({
        try {
            $nets = @(Get-NatNetworkInfo | Where-Object { $_.GatewayIP })
            $ui.Nets = $nets; $cboNat.Items.Clear()
            if ($nets.Count -eq 0) { $lblNet.Text = 'Nenhuma rede NAT detectada. Crie o NAT Switch acima primeiro.'; return }
            foreach ($n in $nets) { [void]$cboNat.Items.Add("$($n.ScopeId)/$($n.PrefixLength)  (gw $($n.GatewayIP))") }
            $cboNat.SelectedIndex = 0
            $lblNet.Text = "$($nets.Count) rede(s) NAT detectada(s). Campos preenchidos pela selecionada."
        } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
    })
    $btnDhcp.Add_Click({
        if (-not (Confirm-Wpf "Instalar/configurar o DHCP para o NAT ($($dhScope.Text.Trim()))?")) { return }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            Reset-FeatureSession
            if (-not (Install-DhcpRoleForNat)) { $lblNet.Text = (Get-SummaryText) + "`nSe foi pedido reinicio: reinicie e rode de novo."; return }
            $iface = $ui.Iface
            if (-not $iface) {
                $m = Get-NatNetworkInfo | Where-Object { $_.ScopeId -eq $dhScope.Text.Trim() } | Select-Object -First 1
                if ($m) { $iface = $m.InterfaceAlias }
            }
            if (-not $iface) { $lblNet.Text = 'Clique "Detectar rede NAT" antes de aplicar o DHCP.'; return }
            $lease = 7300; $tmp = 0
            if ([int]::TryParse($dhLease.Text.Trim(), [ref]$tmp) -and $tmp -gt 0) { $lease = $tmp }
            Set-NatDhcpScope -ScopeId $dhScope.Text.Trim() -Mask $dhMask.Text.Trim() `
                -RangeFrom $dhFrom.Text.Trim() -RangeTo $dhTo.Text.Trim() `
                -Gateway $dhGw.Text.Trim() -Dns $dhDns.Text.Trim() -NatIface $iface -LeaseDays $lease
            $lblNet.Text = Get-SummaryText
        } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    # --- Customizacoes ---
    $btnCust.Add_Click({
        if (-not (Confirm-Wpf 'Aplicar as customizacoes marcadas?')) { return }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            Reset-FeatureSession
            $changed = $false
            if ($chkDark.IsChecked)   { $c = Enable-DarkMode;     Add-FeatureResult -Name 'Dark Mode' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $changed = $changed -or $c }
            if ($chkExt.IsChecked)    { $c = Show-FileExtensions; Add-FeatureResult -Name 'Mostrar extensoes' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $changed = $changed -or $c }
            if ($chkSuperHidden.IsChecked) { $c = Show-HiddenFiles -IncludeProtectedOsFiles; Add-FeatureResult -Name 'Mostrar ocultos (+protegidos)' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $changed = $changed -or $c }
            elseif ($chkHidden.IsChecked) { $c = Show-HiddenFiles; Add-FeatureResult -Name 'Mostrar ocultos' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $changed = $changed -or $c }
            if ($changed) { Restart-Explorer }
            $lblCust.Text = if ($Script:FeatureResults.Count) { Get-SummaryText } else { 'Nada selecionado.' }
        } catch { $lblCust.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    # --- Config base ---
    $btnBase.Add_Click({
        if (-not (Confirm-Wpf 'Aplicar a configuracao base marcada?')) { return }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            Reset-FeatureSession
            if ($chkIeEsc.IsChecked)  { try { Disable-IEEsc;                 Add-FeatureResult -Name 'IE ESC desativado' -Status 'Instalado' } catch { Add-FeatureResult -Name 'IE ESC' -Status 'Falha' -Detail $_.Exception.Message } }
            if ($chkTz.IsChecked)     { try { Set-TimeZoneBrasilia;          Add-FeatureResult -Name 'Time zone Brasilia' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Time zone' -Status 'Falha' -Detail $_.Exception.Message } }
            if ($chkNtp.IsChecked)    { try { Sync-DateTime;                 Add-FeatureResult -Name 'Sync NTP' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Sync NTP' -Status 'Falha' -Detail $_.Exception.Message } }
            if ($chkSrvMgr.IsChecked) { try { Disable-ServerManagerAutoStart; Add-FeatureResult -Name 'Server Manager no logon (off)' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Server Manager logon' -Status 'Falha' -Detail $_.Exception.Message } }
            $lblBase.Text = if ($Script:FeatureResults.Count) { Get-SummaryText } else { 'Nada selecionado.' }
        } catch { $lblBase.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    $null = $win.ShowDialog()
}

# Entry point da UI: tenta WPF; sem WPF, cai para o menu de console.
function Start-Gui {
    if (Test-CanUseWpf) {
        try { Show-InstallerWpf | Out-Null; return }
        catch { Write-Log "Falha na GUI WPF ($($_.Exception.Message)) - usando menu de console." -Level WARN }
    }
    Start-MainMenu
}
# ===== FIM modules\GuiWpf.ps1 =====

# ===== INICIO bootstrap-tail.ps1 =====
# ============================================================================
#  TAIL (payload)  -  ultima parte do bundle, apos os modulos carregarem.
#  Sob o launcher (irm | iex) ja estamos Admin + STA. Abre a janela WPF
#  (Start-Gui); sem WPF (Server Core/headless) cai para o menu de console.
# ============================================================================
Start-Gui
# ===== FIM bootstrap-tail.ps1 =====

