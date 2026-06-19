# ============================================================================
#  GuiWpf.ps1  -  Janela WPF (estilo "app", abas) com fallback para console
#  Depende de Common.ps1, OSCommon.ps1, WindowsFeatures.ps1, Software.ps1 e
#  Gui.ps1 (Get-SummaryText, Start-MainMenu, Show-InstallerConsole).
#
#  Modelo:
#   - Features e Softwares: SELECAO na janela; ao clicar "Aplicar", a janela
#     fecha e a instalacao roda no console (log ao vivo) + resumo.
#   - NAT e DHCP: sao interativos (detectam rede); rodam NA janela, com status
#     no painel. Use a aba "Rede" para criar o NAT e configurar o DHCP.
#   - Sem WPF (Server Core / headless / nao-STA): cai para Start-MainMenu.
# ============================================================================

# WPF disponivel? Precisa: nao ser Server Core, sessao interativa, thread STA e
# os assemblies de WPF carregaveis (so existem com a Experiencia de Desktop).
function Test-CanUseWpf {
    $role = Get-OSRole
    if ($role.IsServerCore) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return $false }
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        return $true
    } catch { return $false }
}

# Cabecalho de categoria (TextBlock em destaque) para as listas.
function New-WpfHeader {
    param([string] $Text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontWeight = 'Bold'
    $tb.Foreground = [System.Windows.Media.Brushes]::DeepSkyBlue
    $tb.Margin = [System.Windows.Thickness]::new(0, 10, 0, 4)
    return $tb
}

# Coleta as Tags dos CheckBox marcados dentro de um painel (ignora cabecalhos).
function Get-WpfCheckedTags {
    param($Panel)
    $out = @()
    foreach ($ch in $Panel.Children) {
        if ($ch -is [System.Windows.Controls.CheckBox] -and $ch.IsChecked) { $out += $ch.Tag }
    }
    return $out
}

# Monta e exibe a janela. Retorna selecao (Features/Softwares) ou $null.
# NAT/DHCP sao executados dentro da propria janela (nao entram no retorno).
function Show-InstallerWpf {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop

    $xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configurador Windows Server" Height="700" Width="1060"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E1E" MinWidth="820" MinHeight="520">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFDDDDDD"/></Style>
    <Style TargetType="Label"><Setter Property="Foreground" Value="#FFDDDDDD"/></Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFDDDDDD"/>
      <Setter Property="Margin" Value="12,2,0,2"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="#FFDDDDDD"/>
      <Setter Property="Margin" Value="0,6,0,6"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF0E639C"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#FF0E639C"/>
      <Setter Property="Padding" Value="10,4"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#FF2D2D30"/>
      <Setter Property="Foreground" Value="#FFEEEEEE"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
      <Setter Property="Padding" Value="3,2"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF252526" Padding="8">
      <DockPanel LastChildFill="False">
        <Label Content="Pasta de log:" DockPanel.Dock="Left" VerticalAlignment="Center"/>
        <TextBox x:Name="txtLog" Width="340" DockPanel.Dock="Left" Margin="6,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="btnClose" Content="Fechar" DockPanel.Dock="Right" Width="90" Height="30" Margin="6,0,0,0"/>
        <Button x:Name="btnApply" Content="Aplicar Features e Softwares" DockPanel.Dock="Right" Width="230" Height="30"/>
      </DockPanel>
    </Border>
    <TabControl x:Name="tabs" Background="#FF1E1E1E" BorderBrush="#FF3F3F46" Margin="6">
      <TabItem Header="Features">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
          <StackPanel x:Name="spFeatures" Margin="12"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="Softwares">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="12,8">
            <Label Content="Gerenciador:" VerticalAlignment="Center"/>
            <RadioButton x:Name="rbWinget" Content="winget" Foreground="#FFDDDDDD" IsChecked="True" Margin="8,0" VerticalAlignment="Center"/>
            <RadioButton x:Name="rbChoco" Content="Chocolatey" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center"/>
            <RadioButton x:Name="rbAuto" Content="auto (winget, fallback choco)" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spSoftware" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>
      <TabItem Header="Rede (NAT / DHCP)">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
          <StackPanel Margin="12">
            <GroupBox Header="NAT Switch (Hyper-V)">
              <Grid Margin="8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="360"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <Label Grid.Row="0" Grid.Column="0" Content="Nome do switch:"/>
                <TextBox x:Name="natName" Grid.Row="0" Grid.Column="1" Margin="0,3" Text="NATSwitch"/>
                <Label Grid.Row="1" Grid.Column="0" Content="Sub-rede (CIDR):"/>
                <TextBox x:Name="natSubnet" Grid.Row="1" Grid.Column="1" Margin="0,3" Text="172.16.3.0/24"/>
                <Label Grid.Row="2" Grid.Column="0" Content="Gateway:"/>
                <TextBox x:Name="natGw" Grid.Row="2" Grid.Column="1" Margin="0,3" Text="172.16.3.1"/>
                <Button x:Name="btnNat" Grid.Row="3" Grid.Column="1" Content="Criar NAT Switch" Width="170" HorizontalAlignment="Left" Height="30" Margin="0,8"/>
              </Grid>
            </GroupBox>
            <GroupBox Header="DHCP para o NAT (Windows Server)">
              <Grid Margin="8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="360"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <Button x:Name="btnDetect" Grid.Row="0" Grid.Column="1" Content="Detectar rede NAT" Width="170" HorizontalAlignment="Left" Height="28" Margin="0,3"/>
                <Label Grid.Row="1" Grid.Column="0" Content="Sub-rede (scope):"/>
                <TextBox x:Name="dhScope" Grid.Row="1" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="2" Grid.Column="0" Content="Mascara:"/>
                <TextBox x:Name="dhMask" Grid.Row="2" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="3" Grid.Column="0" Content="Gateway:"/>
                <TextBox x:Name="dhGw" Grid.Row="3" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="4" Grid.Column="0" Content="Faixa inicio / fim:"/>
                <StackPanel Grid.Row="4" Grid.Column="1" Orientation="Horizontal">
                  <TextBox x:Name="dhFrom" Width="170" Margin="0,3,6,3"/>
                  <TextBox x:Name="dhTo" Width="170" Margin="0,3"/>
                </StackPanel>
                <Label Grid.Row="5" Grid.Column="0" Content="DNS / Lease(dias):"/>
                <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal">
                  <TextBox x:Name="dhDns" Width="200" Margin="0,3,6,3" Text="213.186.33.99"/>
                  <TextBox x:Name="dhLease" Width="100" Margin="0,3" Text="7300"/>
                </StackPanel>
                <Button x:Name="btnDhcp" Grid.Row="6" Grid.Column="1" Content="Aplicar DHCP" Width="170" HorizontalAlignment="Left" Height="30" Margin="0,8"/>
              </Grid>
            </GroupBox>
            <TextBlock x:Name="lblNet" TextWrapping="Wrap" Margin="2,8" Foreground="#FF9CDCFE"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

    [xml]$xaml = $xamlText
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    # Referencias dos controles
    $spFeatures = $win.FindName('spFeatures')
    $spSoftware = $win.FindName('spSoftware')
    $txtLog     = $win.FindName('txtLog')
    $btnApply   = $win.FindName('btnApply')
    $btnClose   = $win.FindName('btnClose')
    $rbChoco    = $win.FindName('rbChoco')
    $rbAuto     = $win.FindName('rbAuto')
    $natName    = $win.FindName('natName')
    $natSubnet  = $win.FindName('natSubnet')
    $natGw      = $win.FindName('natGw')
    $btnNat     = $win.FindName('btnNat')
    $btnDetect  = $win.FindName('btnDetect')
    $dhScope    = $win.FindName('dhScope')
    $dhMask     = $win.FindName('dhMask')
    $dhGw       = $win.FindName('dhGw')
    $dhFrom     = $win.FindName('dhFrom')
    $dhTo       = $win.FindName('dhTo')
    $dhDns      = $win.FindName('dhDns')
    $dhLease    = $win.FindName('dhLease')
    $btnDhcp    = $win.FindName('btnDhcp')
    $lblNet     = $win.FindName('lblNet')

    $txtLog.Text = $Script:DefaultLogDir

    # Estado compartilhado pelos handlers (ex.: interface do NAT detectada).
    $ui = @{ Iface = '' }

    # --- Popula Features (capacidades validas no SO) ---
    $lastCat = ''
    foreach ($c in @(Get-AvailableCapabilities)) {
        if ($c.Category -ne $lastCat) { [void]$spFeatures.Children.Add((New-WpfHeader $c.Category)); $lastCat = $c.Category }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = if ($c.Notes) { "$($c.Display)   ($($c.Notes))" } else { $c.Display }
        $cb.Tag = $c.Id
        [void]$spFeatures.Children.Add($cb)
    }

    # --- Popula Softwares (catalogo) ---
    $lastCat = ''
    foreach ($p in $Script:SoftwareCatalog) {
        if ($p.Category -ne $lastCat) { [void]$spSoftware.Children.Add((New-WpfHeader $p.Category)); $lastCat = $p.Category }
        $src = @(); if ($p.Choco) { $src += 'choco' }; if ($p.Winget) { $src += 'winget' }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($p.Name)   ($($src -join '/'))"
        $cb.Tag = $p.Key
        [void]$spSoftware.Children.Add($cb)
    }

    # --- Handlers ---
    $btnClose.Add_Click({ $win.DialogResult = $false; $win.Close() })

    $btnApply.Add_Click({
        $ids  = @(Get-WpfCheckedTags $spFeatures)
        $keys = @(Get-WpfCheckedTags $spSoftware)
        if ($ids.Count -eq 0 -and $keys.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Selecione ao menos um Feature ou Software.', 'Atencao') | Out-Null
            return
        }
        $pref = if ($rbChoco.IsChecked) { 'choco' } elseif ($rbAuto.IsChecked) { 'auto' } else { 'winget' }
        $win.Tag = [PSCustomObject]@{
            FeatureIds   = @($ids)
            SoftwareKeys = @($keys)
            PkgMgr       = $pref
            LogDir       = $txtLog.Text.Trim()
        }
        $win.DialogResult = $true
        $win.Close()
    })

    $btnNat.Add_Click({
        try {
            if ($txtLog.Text.Trim()) { Set-LogDirectory -Path $txtLog.Text.Trim() }
            Reset-FeatureSession
            $win.Cursor = [System.Windows.Input.Cursors]::Wait
            New-NatSwitch -SwitchName $natName.Text.Trim() -Subnet $natSubnet.Text.Trim() -GatewayIP $natGw.Text.Trim()
            $lblNet.Text = Get-SummaryText
        } catch {
            $lblNet.Text = "Erro: $($_.Exception.Message)"
        } finally {
            $win.Cursor = [System.Windows.Input.Cursors]::Arrow
        }
    })

    $btnDetect.Add_Click({
        try {
            $nets = @(Get-NatNetworkInfo | Where-Object { $_.GatewayIP })
            if ($nets.Count -eq 0) { $lblNet.Text = 'Nenhuma rede NAT detectada. Crie o NAT Switch acima primeiro.'; return }
            $n = $nets[0]
            $dhScope.Text = $n.ScopeId
            $dhMask.Text  = $n.Mask
            $dhGw.Text    = $n.GatewayIP
            $netU = ConvertTo-IPv4UInt32 -IP $n.ScopeId
            $dhFrom.Text  = ConvertFrom-IPv4UInt32 -Value ($netU + 50)
            $dhTo.Text    = ConvertFrom-IPv4UInt32 -Value ($netU + 200)
            $ui.Iface = $n.InterfaceAlias
            $lblNet.Text = "Detectado: $($n.ScopeId)/$($n.PrefixLength)  gateway $($n.GatewayIP)  via '$($n.InterfaceAlias)'"
        } catch {
            $lblNet.Text = "Erro: $($_.Exception.Message)"
        }
    })

    $btnDhcp.Add_Click({
        try {
            if ($txtLog.Text.Trim()) { Set-LogDirectory -Path $txtLog.Text.Trim() }
            Reset-FeatureSession
            $win.Cursor = [System.Windows.Input.Cursors]::Wait

            if (-not (Install-DhcpRoleForNat)) {
                $lblNet.Text = (Get-SummaryText) + "`nSe foi pedido reinicio: reinicie o servidor e rode de novo."
                return
            }

            $iface = $ui.Iface
            if (-not $iface) {
                $m = Get-NatNetworkInfo | Where-Object { $_.ScopeId -eq $dhScope.Text.Trim() } | Select-Object -First 1
                if ($m) { $iface = $m.InterfaceAlias }
            }
            if (-not $iface) { $lblNet.Text = 'Clique "Detectar rede NAT" antes de aplicar o DHCP.'; return }

            $lease = 7300
            $tmp = 0
            if ([int]::TryParse($dhLease.Text.Trim(), [ref]$tmp) -and $tmp -gt 0) { $lease = $tmp }

            Set-NatDhcpScope -ScopeId $dhScope.Text.Trim() -Mask $dhMask.Text.Trim() `
                -RangeFrom $dhFrom.Text.Trim() -RangeTo $dhTo.Text.Trim() `
                -Gateway $dhGw.Text.Trim() -Dns $dhDns.Text.Trim() -NatIface $iface -LeaseDays $lease
            $lblNet.Text = Get-SummaryText
        } catch {
            $lblNet.Text = "Erro: $($_.Exception.Message)"
        } finally {
            $win.Cursor = [System.Windows.Input.Cursors]::Arrow
        }
    })

    $null = $win.ShowDialog()
    if ($win.DialogResult -ne $true) { return $null }
    return $win.Tag
}

# Roda as selecoes de Features e Softwares feitas na janela (apos ela fechar).
function Invoke-WpfSelections {
    param($Selection)
    if (-not $Selection) { return }
    if ($Selection.LogDir) { Set-LogDirectory -Path $Selection.LogDir }

    if (@($Selection.FeatureIds).Count -gt 0) {
        Invoke-CapabilityInstall -Ids $Selection.FeatureIds
    }

    if (@($Selection.SoftwareKeys).Count -gt 0) {
        Reset-FeatureSession
        foreach ($k in $Selection.SoftwareKeys) {
            $pkg = $Script:SoftwareCatalog | Where-Object { $_.Key -eq $k }
            if ($pkg) { Install-SoftwarePackage -Pkg $pkg -Preferred $Selection.PkgMgr }
        }
        Show-FeaturesSummary
    }
}

# Entry point da UI: tenta WPF; sem WPF, cai para o menu de console.
function Start-Gui {
    if (Test-CanUseWpf) {
        try {
            $sel = Show-InstallerWpf
            Invoke-WpfSelections -Selection $sel
            return
        } catch {
            Write-Log "Falha na GUI WPF ($($_.Exception.Message)) - usando menu de console." -Level WARN
        }
    }
    Start-MainMenu
}
