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
    $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -NoRestart

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
        Write-Host "    9) Ver resumo da sessao"
        Write-Host "    0) Voltar (mostra resumo)"
        Write-Host ""
        $o = Read-Host "Escolha"

        switch ($o) {
            '1' { Install-HyperVRole }
            '2' { Enable-TelnetClientFeature }
            '9' { Show-FeaturesSummary }
            '0' { }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }
    } while ($o -ne '0')

    Show-FeaturesSummary
}
