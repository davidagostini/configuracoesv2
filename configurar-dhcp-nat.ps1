# ============================================================
# Configura DHCP para as VMs no NAT switch (172.16.3.0/24)
# Rode este script APOS reiniciar o servidor.
# Requer PowerShell como Administrador.
# ============================================================

$ErrorActionPreference = 'Stop'

$ScopeId   = '172.16.3.0'
$Mask      = '255.255.255.0'
$RangeFrom = '172.16.3.50'
$RangeTo   = '172.16.3.200'
$Gateway   = '172.16.3.1'        # IP do host na vEthernet (NATSwitch)
$Dns       = '213.186.33.99'     # DNS do host -> para as VMs navegarem
$NatIface  = 'vEthernet (NATSwitch)'
$LeaseDays = 7300                # lease longo (20 anos) -> VMs nao ficam renovando

Write-Host '== 1) Verificando servico DHCP ==' -ForegroundColor Cyan
$svc = Get-Service DHCPServer
if ($svc.Status -ne 'Running') { Start-Service DHCPServer }
Set-Service DHCPServer -StartupType Automatic
Write-Host "DHCPServer: $((Get-Service DHCPServer).Status)"

Write-Host '== 2) Criando o scope ==' -ForegroundColor Cyan
if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name 'NAT-VMs' -StartRange $RangeFrom -EndRange $RangeTo `
        -SubnetMask $Mask -State Active
    Write-Host "Scope $ScopeId criado ($RangeFrom - $RangeTo)."
} else {
    Write-Host "Scope $ScopeId ja existe."
}

# Lease longo (opcao 051): deixa o IP "fixo na pratica" e evita renovacoes.
Set-DhcpServerv4Scope -ScopeId $ScopeId -LeaseDuration (New-TimeSpan -Days $LeaseDays)
Write-Host "Lease do scope definido em $LeaseDays dias."

# Excluir o gateway da distribuicao (seguranca)
Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange $Gateway -EndRange $Gateway -ErrorAction SilentlyContinue

Write-Host '== 3) Definindo gateway (003) e DNS (006) ==' -ForegroundColor Cyan
Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Gateway -DnsServer $Dns

Write-Host '== 4) Vinculando o DHCP SOMENTE a interface do NAT ==' -ForegroundColor Cyan
# Desativa o binding em TODAS as interfaces e ativa so na do NAT,
# para o DHCP nunca responder na rede fisica externa.
Get-DhcpServerv4Binding | ForEach-Object {
    if ($_.InterfaceAlias -eq $NatIface) {
        if (-not $_.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState $true }
    } else {
        if ($_.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState $false }
    }
}
Get-DhcpServerv4Binding | Format-Table InterfaceAlias, IPAddress, BindingState -AutoSize

Write-Host '== 5) Reiniciando servico e mostrando resumo ==' -ForegroundColor Cyan
Restart-Service DHCPServer
Get-DhcpServerv4Scope | Format-Table ScopeId, Name, StartRange, EndRange, State -AutoSize
Get-DhcpServerv4OptionValue -ScopeId $ScopeId | Format-Table OptionId, Name, Value -AutoSize

Write-Host ''
Write-Host 'PRONTO. As VMs no NATSwitch agora pegam IP automatico.' -ForegroundColor Green
Write-Host 'Obs: deixe as VMs em "Obter IP automaticamente" (DHCP).'
Write-Host 'Obs: VMs ja se comunicam entre si na mesma sub-rede; se o ping falhar,'
Write-Host '     libere "Compartilhamento de Arquivos/ICMP" no Firewall DENTRO de cada VM.'
