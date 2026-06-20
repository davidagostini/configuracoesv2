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

# --- Ajustar data/hora atual (via internet / cabecalho HTTP "Date") --------
# O NTP (porta UDP 123) costuma vir BLOQUEADO em datacenter/firewall, entao em
# vez de w32tm pegamos a hora do cabecalho HTTP "Date" (HTTPS/443, quase sempre
# liberado), convertemos para a hora local da TZ atual e aplicamos com Set-Date.
# IMPORTANTE: Set-Date grava HORA LOCAL; configure a TZ para Brasilia
# (Set-TimeZoneBrasilia) ANTES para o relogio ficar exatamente em UTC-3.
# Retorna $true se ajustou, $false em falha (nao lanca excecao).
function Sync-DateTime {
    param(
        [string[]] $Urls = @('https://www.google.com', 'https://www.cloudflare.com', 'https://www.microsoft.com')
    )
    Write-Log "Ajustando o relogio pela hora da internet (cabecalho HTTP Date)..." -Level STEP

    $utc = $null
    foreach ($u in $Urls) {
        try {
            $resp = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $httpDate = $resp.Headers['Date']
            if (-not $httpDate) { $httpDate = $resp.Headers.Date }
            if ($httpDate) {
                # DateTimeOffset entende o "GMT" do cabecalho; .UtcDateTime = hora UTC exata.
                $utc = [System.DateTimeOffset]::Parse([string]$httpDate, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                Write-Log "Hora obtida de $u  (UTC $($utc.ToString('yyyy-MM-dd HH:mm:ss')))." -Level INFO
                break
            }
        }
        catch {
            Write-Log "Nao deu para obter a hora de ${u}: $($_.Exception.Message)" -Level WARN
        }
    }

    if (-not $utc) {
        Write-Log "Falha: nenhuma URL retornou o cabecalho Date. Relogio NAO ajustado." -Level ERRO
        return $false
    }

    try {
        # Converte o UTC para a hora local da TZ atual do Windows. Com a TZ em
        # Brasilia isso da exatamente UTC-3 (equivalente a subtrair 3h na mao,
        # porem sem fixar o fuso: fica certo mesmo se a TZ for outra).
        $local = $utc.ToLocalTime()
        Set-Date -Date $local -ErrorAction Stop | Out-Null
        Write-Log "Relogio ajustado: $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))  (TZ: $((Get-TimeZone).Id))." -Level OK
        return $true
    }
    catch {
        Write-Log "Falha ao aplicar a data/hora: $($_.Exception.Message)" -Level ERRO
        return $false
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
                Sync-DateTime | Out-Null
                Disable-ServerManagerAutoStart
            }
            '2' { Disable-IEEsc }
            '3' { Set-TimeZoneBrasilia }
            '4' { Sync-DateTime | Out-Null }
            '5' { Disable-ServerManagerAutoStart }
            '0' { }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }
    } while ($o -ne '0')
}
