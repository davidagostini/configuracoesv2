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
    $Script:LogFile = Join-Path $Path $FileName
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

function Reset-FeatureSession {
    $Script:FeatureResults = @()
}

function Add-FeatureResult {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Instalado','PrecisaReinicio','Deferido','JaPresente','Falha')] [string] $Status,
        [string] $Detail = ''
    )
    $Script:FeatureResults += [PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail }
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
