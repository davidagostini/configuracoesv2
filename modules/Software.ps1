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
    (New-Pkg 'sql2022'       'SQL Server 2022'         'Banco'      'sql-server-2022' '' @() @() 'maybe' 'Edicao Developer/Express via choco; sem pacote winget oficial')
    (New-Pkg 'sql2025'       'SQL Server 2025'         'Banco'      'sql-server-2025' '' @() @() 'maybe' 'Verificar disponibilidade no choco; sem pacote winget oficial')
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

    if ($mgr -eq 'choco') {
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            if (-not (Install-Chocolatey)) {
                Add-FeatureResult -Name $Pkg.Name -Status 'Falha' -Detail 'Chocolatey indisponivel'
                return
            }
        }
        Write-Log "[choco] Instalando '$($Pkg.Name)' ($($Pkg.Choco))..." -Level STEP
        $argsList = @('install', $Pkg.Choco, '-y', '--no-progress') + $Pkg.ChocoArgs
        & choco @argsList
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
            Add-FeatureResult -Name $Pkg.Name -Status 'Falha' -Detail "choco ExitCode $code"
        }
    }
    else {
        Write-Log "[winget] Instalando '$($Pkg.Name)' ($($Pkg.Winget))..." -Level STEP
        $argsList = @('install', '--id', $Pkg.Winget, '-e', '--source', 'winget',
                      '--accept-package-agreements', '--accept-source-agreements',
                      '--disable-interactivity') + $Pkg.WingetArgs
        & winget @argsList
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Write-Log "'$($Pkg.Name)' instalado (winget)." -Level OK
            Add-FeatureResult -Name $Pkg.Name -Status 'Instalado'
        }
        else {
            Write-Log "Falha/aviso ao instalar '$($Pkg.Name)' (winget). ExitCode: $code" -Level ERRO
            Add-FeatureResult -Name $Pkg.Name -Status 'Falha' -Detail "winget ExitCode $code"
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
