# Runbook — DHCP para VMs num NAT Switch do Hyper-V (Windows Server)

> Objetivo: fazer com que as VMs ligadas a um **NAT switch** do Hyper-V recebam **IP automático**,
> consigam **navegar na internet** e **conversem entre si**, sem que o DHCP atrapalhe a rede física do host.
>
> Este documento é **portátil**: serve para replicar a mesma solução em qualquer outro host
> Windows Server com Hyper-V. Basta ajustar os valores na seção "Parâmetros".

---

## 1. Conceito (por que isso é necessário)

Um **NAT switch** do Hyper-V faz **apenas tradução de endereço (NAT)** — ele **não distribui IP**.
Por isso, sem um DHCP, cada VM precisaria de **IP estático manual**.

A solução é instalar a role **DHCP Server no próprio host** e criar um *scope* (faixa de IPs)
na mesma sub-rede do NAT, **vinculado somente à interface interna do NAT**.

```
            +---------------------------- Host Windows Server ----------------------------+
            |                                                                             |
  Internet  |   NIC física  <--NAT-->  vEthernet (NATSwitch) = 172.16.3.1  (gateway)      |
  <-------->|                                |                                            |
            |                          [ DHCP Server ]  (bind SÓ nesta interface)         |
            |                                |                                            |
            |        +-----------------------+-----------------------+                    |
            |     VM1 (DHCP)             VM2 (DHCP)              VM3 (DHCP)                 |
            |   172.16.3.50            172.16.3.51             172.16.3.52  ...            |
            +-----------------------------------------------------------------------------+
```

- **Navegação:** o DHCP entrega o DNS do host (opção 006) → VMs resolvem nomes e navegam.
- **VMs entre si:** todas na mesma sub-rede e no mesmo switch interno → comunicação direta (camada 2).
  Se o ping falhar, o bloqueio é o **Firewall do Windows DENTRO da VM**, não o DHCP.
- **Segurança:** o DHCP é vinculado **só** à interface do NAT, então **nunca** responde na
  rede física/corporativa (evita virar "DHCP pirata" e causar conflito).

---

## 2. Parâmetros (ajuste para o seu ambiente)

| Variável        | Exemplo deste ambiente   | O que é                                            |
|-----------------|--------------------------|----------------------------------------------------|
| Switch NAT      | `NATSwitch`              | Nome do vSwitch interno do Hyper-V                 |
| NAT network     | `MyNATNetwork`           | Nome do objeto Get-NetNat                          |
| Sub-rede        | `172.16.3.0/24`          | Rede do NAT                                        |
| Interface NAT   | `vEthernet (NATSwitch)`  | Interface do host onde o DHCP fará bind            |
| Gateway         | `172.16.3.1`             | IP do host na interface do NAT (opção 003)         |
| Faixa DHCP      | `172.16.3.50` – `.200`   | IPs distribuídos automaticamente                   |
| DNS             | `213.186.33.99`          | DNS do host — obrigatório p/ navegação (opção 006) |
| Lease           | `7300 dias` (20 anos)    | Tempo do lease (opção 051) — longo p/ máquinas não renovarem/"chamarem" |

---

## 3. Pré-requisito: ter o NAT switch (pular se já existe)

```powershell
# Cria o switch interno e o NAT (exemplo p/ 172.16.3.0/24)
New-VMSwitch -Name 'NATSwitch' -SwitchType Internal
New-NetIPAddress -IPAddress 172.16.3.1 -PrefixLength 24 -InterfaceAlias 'vEthernet (NATSwitch)'
New-NetNat -Name 'MyNATNetwork' -InternalIPInterfaceAddressPrefix 172.16.3.0/24
```

Diagnóstico do que já existe:

```powershell
Get-VMSwitch | ft Name, SwitchType
Get-NetNat   | fl Name, InternalIPInterfaceAddressPrefix, Active
Get-NetIPAddress -AddressFamily IPv4 | ? InterfaceAlias -like '*vEthernet*' | ft InterfaceAlias, IPAddress, PrefixLength
Get-WindowsFeature DHCP | ft Name, InstallState
```

---

## 4. Passo 1 — Instalar a role DHCP (exige REBOOT)

```powershell
Install-WindowsFeature -Name DHCP -IncludeManagementTools
```

> Retorna `SuccessRestartRequired`. **Reinicie o servidor** — os cmdlets e o serviço
> `DHCPServer` só ficam ativos após o reboot. (O reboot desliga as VMs em execução.)

---

## 5. Passo 2 — Configurar o DHCP (rodar APÓS o reboot, como Administrador)

Edite as variáveis do topo conforme a tabela de Parâmetros e execute:

```powershell
$ErrorActionPreference = 'Stop'

$ScopeId   = '172.16.3.0'
$Mask      = '255.255.255.0'
$RangeFrom = '172.16.3.50'
$RangeTo   = '172.16.3.200'
$Gateway   = '172.16.3.1'
$Dns       = '213.186.33.99'
$NatIface  = 'vEthernet (NATSwitch)'

# 1) Servico
if ((Get-Service DHCPServer).Status -ne 'Running') { Start-Service DHCPServer }
Set-Service DHCPServer -StartupType Automatic

# 2) Scope
if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name 'NAT-VMs' -StartRange $RangeFrom -EndRange $RangeTo -SubnetMask $Mask -State Active
}
Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange $Gateway -EndRange $Gateway -ErrorAction SilentlyContinue

# 3) Gateway (003) + DNS (006)
Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Gateway -DnsServer $Dns

# 4) Bind SOMENTE na interface do NAT (essencial p/ seguranca)
Get-DhcpServerv4Binding | ForEach-Object {
    if ($_.InterfaceAlias -eq $NatIface) {
        if (-not $_.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState $true }
    } else {
        if ($_.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState $false }
    }
}

# 5) Aplicar
Restart-Service DHCPServer
```

> Em **servidor de domínio (AD)**, o DHCP precisa ser *autorizado*:
> `Add-DhcpServerInDC -DnsName $env:COMPUTERNAME`. Em servidor **standalone/workgroup**
> (caso deste ambiente) **não é necessário**.

---

## 6. Passo 3 — Validar

```powershell
Get-DhcpServerv4Scope | ft ScopeId, Name, StartRange, EndRange, State
Get-DhcpServerv4OptionValue -ScopeId '172.16.3.0' | ft OptionId, Name, Value
Get-DhcpServerv4Binding | ft InterfaceAlias, IPAddress, BindingState   # so o NAT = True
Get-DhcpServerv4Lease -ScopeId '172.16.3.0'                            # leases entregues
```

Dentro de uma VM (com adaptador em "Obter IP automaticamente"):

```powershell
ipconfig /release; ipconfig /renew
ipconfig /all          # deve mostrar IP 172.16.3.x, gateway .1, DNS configurado
ping 172.16.3.1        # gateway
nslookup google.com    # resolucao DNS
```

---

## 7. VMs conversarem entre si

Já funciona por padrão (mesma sub-rede / mesmo switch interno). Se o ping entre VMs falhar,
libere o ICMP **dentro de cada VM** (não é config de DHCP):

```powershell
# Rodar DENTRO da VM
Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing'
# ou, especificamente o ping:
Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In'
```

---

## 7a. Lease longo (máquinas não renovam / não "chamam")

Para as VMs segurarem o IP por muito tempo sem ficar renovando, aumente a **duração do lease**
(opção 051) no scope. Vale para todas as VMs de uma vez, sem config por máquina:

```powershell
# 20 anos (7300 dias). Para ilimitado use a opção "Unlimited" no console dhcpmgmt.msc.
Set-DhcpServerv4Scope -ScopeId '172.16.3.0' -LeaseDuration (New-TimeSpan -Days 7300)
Get-DhcpServerv4Scope -ScopeId '172.16.3.0' | ft ScopeId,Name,State,LeaseDuration
```

> Máquinas **já ligadas** só adotam o novo lease após `ipconfig /release; ipconfig /renew` (ou reboot).
> Lease longo deixa o IP "fixo na prática"; para garantia **absoluta** de imutabilidade use **reserva** (7b).

---

## 7b. IP fixo e imutável por VM (reserva de DHCP)

Para uma VM **sempre** receber o mesmo IP — trancado pro MAC dela, sem nenhuma outra máquina
poder pegar — use **reserva de DHCP** (melhor que IP fixo manual: a VM continua em "obter IP
automaticamente" e gateway/DNS continuam vindo do scope).

> A reserva precisa cair **dentro da faixa do scope** (`.50`–`.200`). A faixa `.2`–`.49` só serve
> para IP fixo manual digitado dentro da VM, não para reserva.

```powershell
# 1) Descobrir o MAC da VM (no host)
Get-VM | Get-VMNetworkAdapter | ? SwitchName -eq 'NATSwitch' |
  Select VMName, MacAddress, @{N='IP';E={$_.IPAddresses -join ', '}}
# MAC vem sem separador (00155D73A202); use com hifens na reserva: 00-15-5d-73-a2-02

# 2) Criar a reserva
Add-DhcpServerv4Reservation -ScopeId '172.16.3.0' `
  -IPAddress '172.16.3.51' `        # IP livre da faixa .50-.200
  -ClientId  '00-15-5d-XX-XX-XX' `  # MAC da VM
  -Name      'NomeDaVM' `
  -Description 'IP fixo via reserva DHCP'

# 3) Na VM: ipconfig /release; ipconfig /renew  (ou reiniciar a VM)

# Conferir reservas/leases
Get-DhcpServerv4Reservation -ScopeId '172.16.3.0' | ft IPAddress,ClientId,Name
Get-DhcpServerv4Lease       -ScopeId '172.16.3.0' | ft IPAddress,ClientId,HostName,AddressState
```

Convenção sugerida: reservar no bloco `.50`–`.99` (servidores/apps com IP estável) e deixar
`.100`–`.200` para VMs descartáveis pegarem dinâmico. É só organização; o DHCP aceita reserva
em qualquer IP da faixa.

| VM     | MAC               | IP reservado |
|--------|-------------------|--------------|
| W2025  | 00-15-5d-73-a2-02 | 172.16.3.50  |

---

## 8. Problemas comuns

| Sintoma                                  | Causa provável                         | Correção                                              |
|------------------------------------------|----------------------------------------|-------------------------------------------------------|
| VM não pega IP                           | Scope inativo / bind errado            | `State Active`; bind só no NAT; `Restart-Service DHCPServer` |
| Pega IP mas não navega                   | DNS faltando (opção 006)               | `Set-DhcpServerv4OptionValue -DnsServer <dns>`        |
| Pega IP mas não sai do host              | Gateway errado (opção 003) ou NAT off  | Router = IP do host; `Get-NetNat` ativo               |
| DHCP responde na rede física            | Bind em interface errada               | Bind **somente** em `vEthernet (NATSwitch)`           |
| Cmdlets DHCP não existem                | Faltou reboot após instalar a role     | Reiniciar o host                                      |
| VMs não se pingam                        | Firewall dentro da VM                  | Liberar ICMP/File-and-Printer-Sharing no convidado    |
| Após reboot a VM não pega IP             | Scope não existe (nunca persistido / 1ª config não rodou) | Rodar `configurar-dhcp-nat.ps1` (recria o scope; é idempotente). Depois `ipconfig /release; ipconfig /renew` na VM |
| Scope some a CADA reboot (recorrente)    | Banco do DHCP corrompido (`C:\Windows\System32\dhcp\dhcp.mdb`) | Restaurar backup em `...\dhcp\backup\` ou recriar o banco; aí sim vale agendar o script no boot via Task Scheduler |

> **Observação importante:** o scope é **persistente** — uma vez criado, fica gravado no banco do DHCP
> e volta sozinho a cada reboot (serviço em `Automatic`). Não precisa rodar o script toda vez.
> Só rode de novo se o scope tiver sumido. Se sumir de forma recorrente, é banco corrompido (ver tabela acima).
