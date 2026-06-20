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

# Sink opcional de log ao vivo: quando a GUI (ou o worker) cria esta colecao
# sincronizada, Write-Log empurra cada linha aqui alem do arquivo/console. Um
# DispatcherTimer na UI drena para o painel. Mesma referencia nos dois runspaces.
$Script:LiveLog = $null

# No worker (runspace sem console util) o Write-Host pode TRAVAR ou lancar e
# segurar a thread inteira. Quando $Script:NoConsole = $true (o worker liga isso),
# Write-Log pula o console e escreve so no arquivo + sink LiveLog (painel "Log ao vivo").
$Script:NoConsole = $false

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
    if (-not $Script:NoConsole) {
        try { Write-Host "$prefix$Message" -ForegroundColor $color } catch { }
    }

    if ($null -ne $Script:LiveLog) { try { [void]$Script:LiveLog.Add($line) } catch { } }
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

# Detecta se a maquina e FISICA ou VIRTUAL (cacheado). Olha fabricante/modelo do
# Win32_ComputerSystem + BIOS; cobre VMware, Hyper-V, KVM/QEMU (ex.: VPS OVH),
# VirtualBox, Xen, Parallels, GCP/OpenStack, etc. Um HOST fisico com a role Hyper-V
# continua 'Fisica' (o ComputerSystem reflete o hardware real, nao o hypervisor).
$Script:MachineKind = $null
function Get-MachineKind {
    if ($Script:MachineKind) { return $Script:MachineKind }
    $kind = 'Desconhecido'
    try {
        $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $hay  = "$($cs.Manufacturer) $($cs.Model) $($bios.Manufacturer) $($bios.Version) $($bios.SerialNumber)"
        if ($hay -match 'VMware|VirtualBox|Virtual Machine|Hyper-V|KVM|QEMU|Bochs|Xen|HVM domU|Parallels|Google Compute|OpenStack|oVirt|RHEV|innotek') {
            $kind = 'Virtual'
        } else {
            $kind = 'Fisica'
        }
    } catch { $kind = 'Desconhecido' }
    $Script:MachineKind = $kind
    return $kind
}

# Nome/OS/tipo da maquina (cacheados) para o cabecalho do ledger.
$Script:MachineInfo = $null
function Get-MachineInfo {
    if (-not $Script:MachineInfo) {
        $os = ''
        try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
        $Script:MachineInfo = [PSCustomObject]@{ Machine = $env:COMPUTERNAME; OS = $os; Kind = (Get-MachineKind) }
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
        # PS 5.1: capturar em variavel antes evita o aninhamento que @(... | ConvertFrom-Json)
        # causa com 2+ itens. O loop achata 1 nivel e CURA arquivos ja aninhados por bug antigo
        # (o proximo Save regrava achatado).
        $parsed = $raw | ConvertFrom-Json
        $flat = @()
        foreach ($p in @($parsed)) { $flat += $p }
        return $flat
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
            MachineKind   = $mi.Kind
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
