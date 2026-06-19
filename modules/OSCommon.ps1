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
        $r = Install-WindowsFeature -Name $RoleName -IncludeManagementTools:$IncludeManagementTools -NoRestart -ErrorAction Stop
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
