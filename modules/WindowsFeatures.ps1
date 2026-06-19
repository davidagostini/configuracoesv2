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
        Write-Host "    9) Ver resumo da sessao"
        Write-Host "    0) Voltar (mostra resumo)"
        Write-Host ""
        $o = Read-Host "Escolha"

        switch ($o) {
            '1' { Install-HyperVRole }
            '2' { Enable-TelnetClientFeature }
            '3' { Invoke-NatSwitchPrompt }
            '9' { Show-FeaturesSummary }
            '0' { }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }
    } while ($o -ne '0')

    Show-FeaturesSummary
}
