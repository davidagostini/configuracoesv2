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
