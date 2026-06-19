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
