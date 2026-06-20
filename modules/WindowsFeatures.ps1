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
# OS-aware (definido pelo usuario):
#   - Windows 11 (client): Enable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All
#   - Windows Server:       Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
#                           (o servidor REINICIA automaticamente ao concluir).
function Install-HyperVRole {
    $name = 'Hyper-V'
    Write-Log "Verificando a role Hyper-V..." -Level STEP

    # Windows client (Win11): caminho DISM. Install-WindowsFeature nao existe aqui.
    if (-not (Get-OSRole).HasServerManager) {
        Write-Log "SO client detectado - Enable-WindowsOptionalFeature (Microsoft-Hyper-V-All)." -Level INFO
        Enable-OptionalFeatureSafe -FeatureName 'Microsoft-Hyper-V-All' -DisplayName 'Hyper-V' -All
        return
    }

    # Windows Server
    $state = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
    if ($state -and $state.Installed) {
        Write-Log "Hyper-V ja esta instalado." -Level OK
        Add-FeatureResult -Name $name -Status 'JaPresente'
        return
    }
    if (-not (Test-CanInstallOrDefer -Name $name)) { return }

    Write-Log "Instalando Hyper-V (Install-WindowsFeature -IncludeManagementTools -Restart)..." -Level STEP
    Write-Log "ATENCAO: o servidor sera REINICIADO automaticamente ao concluir a instalacao." -Level WARN
    Start-FeatureTimer -Name $name
    $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart

    # O codigo abaixo so roda se NAO reiniciar (ex.: ja-instalado / sem restart necessario).
    if ($result.Success) {
        if ($result.RestartNeeded -ne 'No') {
            Write-Log "Hyper-V instalado - REINICIO em andamento." -Level WARN
            Add-FeatureResult -Name $name -Status 'PrecisaReinicio' -Detail 'Reiniciando para concluir o Hyper-V'
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

# --- OpenSSH Server ---------------------------------------------------------
# Instala a capability OpenSSH.Server (FoD), poe o servico sshd em Automatico,
# sobe o servico e garante a regra de firewall na porta 22. Idempotente.
function Install-OpenSSHServer {
    $name = 'OpenSSH Server'
    Write-Log "Verificando/instalando o OpenSSH Server..." -Level STEP

    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cap) {
        Write-Log "Capability OpenSSH.Server nao encontrada neste SO." -Level ERRO
        Add-FeatureResult -Name $name -Status 'Falha' -Detail 'Capability ausente'
        return
    }

    if ($cap.State -eq 'Installed') {
        Write-Log "OpenSSH Server ja esta instalado." -Level OK
        Add-FeatureResult -Name $name -Status 'JaPresente'
    } else {
        if (-not (Test-CanInstallOrDefer -Name $name)) { return }
        Start-FeatureTimer -Name $name
        try {
            Write-Log "Instalando $($cap.Name)..." -Level STEP
            Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            Write-Log "OpenSSH Server instalado." -Level OK
            Add-FeatureResult -Name $name -Status 'Instalado'
        } catch {
            Write-Log "Falha ao instalar o OpenSSH Server: $($_.Exception.Message)" -Level ERRO
            Add-FeatureResult -Name $name -Status 'Falha' -Detail $_.Exception.Message
            return
        }
    }

    # Pos-config: servico em Automatico + iniciado + firewall na 22.
    try {
        Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
        if ((Get-Service sshd -ErrorAction Stop).Status -ne 'Running') { Start-Service sshd }
        Write-Log "Servico sshd em Automatico e em execucao." -Level OK
        if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
            Write-Log "Regra de firewall criada (TCP 22)." -Level OK
        } else {
            Write-Log "Regra de firewall para a porta 22 ja existe." -Level OK
        }
    } catch {
        Write-Log "OpenSSH instalado, mas houve problema ao configurar o servico/firewall: $($_.Exception.Message)" -Level WARN
    }
}

# --- WSL (atualizacao do kernel/componentes) -------------------------------
# Roda 'wsl --update'. Nao instala distro; so atualiza o WSL ja presente no SO.
function Update-Wsl {
    $name = 'WSL'
    Write-Log "Atualizando o WSL (wsl --update)..." -Level STEP
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Log "wsl.exe nao encontrado neste SO." -Level WARN
        Add-FeatureResult -Name $name -Status 'Falha' -Detail 'wsl.exe ausente'
        return
    }
    Start-FeatureTimer -Name $name
    & wsl.exe --update 2>&1 | Tee-Object -Variable out | Out-Null
    $code = $LASTEXITCODE
    if ($code -eq 0 -or $null -eq $code) {
        Write-Log "WSL atualizado (ou ja estava na ultima versao)." -Level OK
        Add-FeatureResult -Name $name -Status 'Instalado'
    } else {
        Write-Log "wsl --update retornou ExitCode $code." -Level WARN
        Add-FeatureResult -Name $name -Status 'Falha' -Detail "ExitCode $code"
    }
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
        Start-FeatureTimer -Name $display
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

# --- DHCP para o NAT Switch (somente Windows Server) ------------------------
# Um NAT switch NAO distribui IP. Para as VMs pegarem IP automatico, instala-se
# a role DHCP no proprio host e cria-se um scope na sub-rede do NAT, com bind
# SOMENTE na interface do NAT (nunca responde na rede fisica). Detalhes e
# diagnostico em docs/RUNBOOK-DHCP-NAT-HyperV.md.

# DNS sugerido como default (editavel no prompt). 213.186.33.99 = DNS da OVH.
$Script:DefaultNatDns = '213.186.33.99'

# --- Helpers de IPv4 (calculo de mascara e faixas) -------------------------
# Converte um IPv4 (string) para UInt32 (ordem logica big-endian).
function ConvertTo-IPv4UInt32 {
    param([Parameter(Mandatory)] [string] $IP)
    $b = ([System.Net.IPAddress]::Parse($IP)).GetAddressBytes()
    [array]::Reverse($b)
    return [System.BitConverter]::ToUInt32($b, 0)
}

# Converte um UInt32 de volta para IPv4 (string).
function ConvertFrom-IPv4UInt32 {
    param([Parameter(Mandatory)] [uint32] $Value)
    $b = [System.BitConverter]::GetBytes($Value)
    [array]::Reverse($b)
    return ([System.Net.IPAddress]::new($b)).ToString()
}

# Mascara pontilhada (ex.: 255.255.255.0) a partir do prefixo CIDR (ex.: 24).
function Get-IPv4MaskFromPrefix {
    param([Parameter(Mandatory)] [int] $PrefixLength)
    if ($PrefixLength -le 0)  { return '0.0.0.0' }
    if ($PrefixLength -ge 32) { return '255.255.255.255' }
    # 0xFFFFFFFFL com sufixo L = Int64 positivo (sem L, PS le 0xFFFFFFFF como Int32 = -1).
    $allOnes   = 0xFFFFFFFFL
    $hostCount = [int64][math]::Pow(2, (32 - $PrefixLength))    # 2^hostBits
    $mask = [uint32]($allOnes - ($hostCount - 1))
    return (ConvertFrom-IPv4UInt32 -Value $mask)
}

# Descobre as redes NAT do Hyper-V e o IP do host (gateway) em cada uma.
# Para cada Get-NetNat, parseia a sub-rede (InternalIPInterfaceAddressPrefix,
# ex.: 172.16.3.0/24) e procura a interface do host cujo IP cai nessa sub-rede:
# esse IP e o gateway que as VMs usam. Retorna candidatos com tudo pronto p/ o
# scope (ScopeId, Mask, GatewayIP, InterfaceAlias).
function Get-NatNetworkInfo {
    if (-not (Get-Command Get-NetNat -ErrorAction SilentlyContinue)) { return @() }

    $hostIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $result = @()
    foreach ($nat in (Get-NetNat -ErrorAction SilentlyContinue)) {
        $prefix = $nat.InternalIPInterfaceAddressPrefix     # ex.: 172.16.3.0/24
        if ($prefix -notmatch '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*/\s*(\d{1,2})\s*$') { continue }
        $scopeId   = $Matches[1]
        $prefixLen = [int]$Matches[2]
        $mask      = Get-IPv4MaskFromPrefix -PrefixLength $prefixLen

        $net = ConvertTo-IPv4UInt32 -IP $scopeId
        $msk = ConvertTo-IPv4UInt32 -IP $mask
        $gwIp = $null; $ifAlias = $null
        foreach ($a in $hostIps) {
            $ipU = ConvertTo-IPv4UInt32 -IP $a.IPAddress
            if (($ipU -band $msk) -eq ($net -band $msk)) {
                $gwIp = $a.IPAddress; $ifAlias = $a.InterfaceAlias; break
            }
        }

        $result += [PSCustomObject]@{
            NatName        = $nat.Name
            ScopeId        = $scopeId
            PrefixLength   = $prefixLen
            Mask           = $mask
            GatewayIP      = $gwIp
            InterfaceAlias = $ifAlias
        }
    }
    return $result
}

# Garante a role DHCP no host (somente Server). Retorna $true se ja esta pronta
# para configurar (cmdlets disponiveis); $false se exigiu instalacao/reinicio ou
# se o SO nao e Server. Segue as regras do projeto (-NoRestart, defere, registra).
function Install-DhcpRoleForNat {
    $name = 'DHCP Server'
    if (-not (Get-OSRole).HasServerManager) {
        Write-Log "DHCP para NAT so e suportado em Windows Server (role DHCP ausente neste SO)." -Level WARN
        Add-FeatureResult -Name $name -Status 'Falha' -Detail 'Recurso somente para Windows Server'
        return $false
    }

    $state = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    if (-not ($state -and $state.Installed)) {
        if (-not (Test-CanInstallOrDefer -Name $name)) { return $false }
        Write-Log "Instalando a role DHCP (com ferramentas de gerenciamento)..." -Level STEP
        Start-FeatureTimer -Name $name
        # Install-WindowsFeature NAO tem -NoRestart; por padrao ja nao reinicia (so com -Restart).
        $r = Install-WindowsFeature -Name DHCP -IncludeManagementTools
        if (-not $r.Success) {
            Write-Log "Falha ao instalar a role DHCP. ExitCode: $($r.ExitCode)" -Level ERRO
            Add-FeatureResult -Name $name -Status 'Falha' -Detail "ExitCode $($r.ExitCode)"
            return $false
        }
        # O proprio cmdlet sinaliza se exige reinicio (DHCP costuma retornar SuccessRestartRequired).
        if ($r.RestartNeeded -ne 'No') {
            Write-Log "Role DHCP instalada - REINICIO necessario para ativar cmdlets e servico." -Level WARN
            Add-FeatureResult -Name $name -Status 'PrecisaReinicio' -Detail 'Reinicie e rode de novo para configurar o scope'
            return $false
        }
        Write-Log "Role DHCP instalada." -Level OK
    }

    # Mesmo instalada, na 1a vez os cmdlets/servico podem so subir apos o reinicio.
    if (-not (Get-Command Add-DhcpServerv4Scope -ErrorAction SilentlyContinue) -or
        -not (Get-Service DHCPServer -ErrorAction SilentlyContinue)) {
        Write-Log "Role DHCP presente mas cmdlets/servico ainda nao disponiveis - reinicie e rode de novo." -Level WARN
        Add-FeatureResult -Name $name -Status 'PrecisaReinicio' -Detail 'Reinicie para ativar os cmdlets/servico do DHCP'
        return $false
    }

    Add-FeatureResult -Name $name -Status 'JaPresente'
    return $true
}

# Configura o DHCP para uma rede NAT: servico Automatic + scope + exclusao do
# gateway + opcoes 003 (gateway) e 006 (DNS) + bind SOMENTE na interface do NAT.
# Idempotente. Ver docs/RUNBOOK-DHCP-NAT-HyperV.md.
function Set-NatDhcpScope {
    param(
        [Parameter(Mandatory)] [string] $ScopeId,
        [Parameter(Mandatory)] [string] $Mask,
        [Parameter(Mandatory)] [string] $RangeFrom,
        [Parameter(Mandatory)] [string] $RangeTo,
        [Parameter(Mandatory)] [string] $Gateway,
        [Parameter(Mandatory)] [string] $Dns,
        [Parameter(Mandatory)] [string] $NatIface,
        [int] $LeaseDays = 7300            # lease longo (20 anos) p/ as VMs nao renovarem
    )
    $display = "DHCP scope $ScopeId (NAT)"
    try {
        Start-FeatureTimer -Name $display
        # 1) Servico
        if ((Get-Service DHCPServer -ErrorAction Stop).Status -ne 'Running') { Start-Service DHCPServer }
        Set-Service DHCPServer -StartupType Automatic

        # 2) Scope (idempotente)
        if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
            Add-DhcpServerv4Scope -Name 'NAT-VMs' -StartRange $RangeFrom -EndRange $RangeTo -SubnetMask $Mask -State Active
            Write-Log "Scope $ScopeId criado ($RangeFrom - $RangeTo)." -Level OK
        } else {
            Write-Log "Scope $ScopeId ja existe - mantido." -Level OK
        }

        # 2b) Lease (opcao 051): lease longo deixa o IP "fixo na pratica" e evita
        # as VMs ficarem renovando. Em try proprio: um cap de lease nao deve
        # derrubar o resto da config. Ver runbook secao 7a.
        try {
            Set-DhcpServerv4Scope -ScopeId $ScopeId -LeaseDuration (New-TimeSpan -Days $LeaseDays)
            Write-Log "Lease do scope $ScopeId definido em $LeaseDays dias." -Level OK
        } catch {
            Write-Log "Nao foi possivel definir o lease em $LeaseDays dias: $($_.Exception.Message)" -Level WARN
        }

        # 3) Exclui o gateway da distribuicao (seguranca). IDEMPOTENTE: o cmdlet lanca
        # erro TERMINANTE (que -ErrorAction SilentlyContinue NAO segura) se a exclusao
        # ja existe. O try/catch evita quebrar o resto ao reaplicar o DHCP (bug
        # relatado: "Failed to add exclusion range ... already ...").
        try {
            Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange $Gateway -EndRange $Gateway -ErrorAction Stop
            Write-Log "Gateway $Gateway excluido da distribuicao." -Level OK
        } catch {
            Write-Log "Exclusao do gateway $Gateway nao aplicada (provavelmente ja existe) - ignorando." -Level WARN
        }

        # 4) Opcoes 003 (gateway) e 006 (DNS)
        Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Gateway -DnsServer $Dns
        Write-Log "Gateway (003)=$Gateway e DNS (006)=$Dns aplicados ao scope $ScopeId." -Level OK

        # 5) Bind SOMENTE na interface do NAT (nunca na rede fisica)
        Get-DhcpServerv4Binding | ForEach-Object {
            if ($_.InterfaceAlias -eq $NatIface) {
                if (-not $_.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState $true }
            } else {
                if ($_.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState $false }
            }
        }
        Write-Log "DHCP vinculado somente a '$NatIface'." -Level OK

        Restart-Service DHCPServer
        Write-Log "DHCP configurado: as VMs no NAT $ScopeId agora pegam IP automatico." -Level OK
        Add-FeatureResult -Name $display -Status 'Instalado' -Detail "range $RangeFrom-$RangeTo / gw $Gateway / dns $Dns"
    }
    catch {
        Write-Log "Falha ao configurar o DHCP: $($_.Exception.Message)" -Level ERRO
        Add-FeatureResult -Name $display -Status 'Falha' -Detail $_.Exception.Message
    }
}

# Prompt interativo: instala a role (se preciso), DETECTA a rede NAT e o IP do
# host (gateway) e os mostra, e pergunta faixa e DNS (OVH como default). Aplica
# apos confirmacao.
function Invoke-NatDhcpPrompt {
    Write-Host ""
    Write-Host "  --- Configurar DHCP para o NAT Switch (Windows Server) ---" -ForegroundColor Cyan

    # 1) Garante a role DHCP. Se acabou de instalar / precisa reiniciar, para aqui.
    if (-not (Install-DhcpRoleForNat)) {
        Write-Host "  DHCP ainda nao esta pronto (ver mensagens acima)." -ForegroundColor Yellow
        Write-Host "  Se foi solicitado reinicio, reinicie o servidor e rode esta opcao de novo." -ForegroundColor Yellow
        return
    }

    # 2) Detecta as redes NAT e o IP do host (gateway) em cada uma.
    $nets = @(Get-NatNetworkInfo | Where-Object { $_.GatewayIP })
    if ($nets.Count -eq 0) {
        Write-Host "  Nenhuma rede NAT com IP de host detectada." -ForegroundColor Yellow
        Write-Host "  Crie antes um NAT Switch (opcao 3) ou verifique com 'Get-NetNat'." -ForegroundColor Yellow
        return
    }

    # Escolha da rede NAT quando houver mais de uma.
    $sel = $nets[0]
    if ($nets.Count -gt 1) {
        Write-Host "  Redes NAT detectadas:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $nets.Count; $i++) {
            Write-Host ("    {0}) {1}/{2}  gateway {3}  via '{4}'" -f ($i + 1), $nets[$i].ScopeId, $nets[$i].PrefixLength, $nets[$i].GatewayIP, $nets[$i].InterfaceAlias)
        }
        $pick = (Read-Host "Escolha a rede (1-$($nets.Count), ENTER = 1)").Trim()
        if ($pick) {
            $idx = 0
            if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $nets.Count) { $sel = $nets[$idx - 1] }
        }
    }

    Write-Host ""
    Write-Host "  Rede NAT detectada automaticamente:" -ForegroundColor Green
    Write-Host ("    Sub-rede : {0}/{1}  (mascara {2})" -f $sel.ScopeId, $sel.PrefixLength, $sel.Mask)
    Write-Host ("    Gateway  : {0}   (IP do host na interface '{1}')" -f $sel.GatewayIP, $sel.InterfaceAlias)
    Write-Host ""

    # 3) Faixa do DHCP - defaults derivados da sub-rede (.50 a .200 acima da rede).
    $netU    = ConvertTo-IPv4UInt32 -IP $sel.ScopeId
    $defFrom = ConvertFrom-IPv4UInt32 -Value ($netU + 50)
    $defTo   = ConvertFrom-IPv4UInt32 -Value ($netU + 200)

    $rFrom = (Read-Host "Faixa inicial (ENTER = $defFrom)").Trim(); if (-not $rFrom) { $rFrom = $defFrom }
    $rTo   = (Read-Host "Faixa final   (ENTER = $defTo)").Trim();   if (-not $rTo)   { $rTo   = $defTo }

    # 4) DNS - campo editavel, com a OVH pre-preenchida como default.
    $dns = (Read-Host "DNS para as VMs (ENTER = $Script:DefaultNatDns)").Trim()
    if (-not $dns) { $dns = $Script:DefaultNatDns }

    # 5) Lease (opcao 051) - default longo p/ as VMs nao ficarem renovando.
    $leaseDays = 7300
    $leaseIn = (Read-Host "Duracao do lease em dias (ENTER = 7300 = 20 anos; 8 = padrao Windows)").Trim()
    if ($leaseIn) { $tmp = 0; if ([int]::TryParse($leaseIn, [ref]$tmp) -and $tmp -gt 0) { $leaseDays = $tmp } }

    # 6) Confirma e aplica.
    Write-Host ""
    Write-Host "  Resumo:" -ForegroundColor Cyan
    Write-Host ("    Scope {0} / mascara {1} / range {2} - {3}" -f $sel.ScopeId, $sel.Mask, $rFrom, $rTo)
    Write-Host ("    Gateway {0} / DNS {1} / lease {2} dias / bind em '{3}'" -f $sel.GatewayIP, $dns, $leaseDays, $sel.InterfaceAlias)
    if (-not (Confirm-Action "Aplicar esta configuracao de DHCP?")) {
        Write-Host "  Cancelado." -ForegroundColor Yellow
        return
    }

    Set-NatDhcpScope -ScopeId $sel.ScopeId -Mask $sel.Mask -RangeFrom $rFrom -RangeTo $rTo `
        -Gateway $sel.GatewayIP -Dns $dns -NatIface $sel.InterfaceAlias -LeaseDays $leaseDays
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
        Write-Host "    4) Configurar DHCP p/ o NAT    [Windows Server - detecta IP/DNS/lease]"
        Write-Host "    5) Instalar OpenSSH Server     [servico sshd + firewall 22]"
        Write-Host "    6) Atualizar o WSL             [wsl --update]"
        Write-Host "    9) Ver resumo da sessao"
        Write-Host "    0) Voltar (mostra resumo)"
        Write-Host ""
        $o = Read-Host "Escolha"

        switch ($o) {
            '1' { Install-HyperVRole }
            '2' { Enable-TelnetClientFeature }
            '3' { Invoke-NatSwitchPrompt }
            '4' { Invoke-NatDhcpPrompt }
            '5' { Install-OpenSSHServer }
            '6' { Update-Wsl }
            '9' { Show-FeaturesSummary }
            '0' { }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }
    } while ($o -ne '0')

    Show-FeaturesSummary
}
