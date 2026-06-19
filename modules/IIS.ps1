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
