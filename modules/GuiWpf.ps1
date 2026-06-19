# ============================================================================
#  GuiWpf.ps1  -  Janela WPF (estilo app, abas) com fallback para console
#  Depende de Common.ps1, OSCommon.ps1, WindowsFeatures.ps1, IIS.ps1,
#  Software.ps1, Customizations.ps1, BaseConfig.ps1 e Gui.ps1 (Get-SummaryText,
#  Start-MainMenu).
#
#  Modelo: janela FICA ABERTA; cada aba tem seu proprio "Aplicar" (sessao
#  iterativa). Operacoes longas (IIS/softwares) rodam de forma sincrona - a
#  janela pode ficar momentaneamente irresponsiva; o log ao vivo sai no console.
#  A aba "Status" le o ledger persistente (installer-state.json) e mostra, ao
#  abrir (inclusive apos reinicio), o que ja foi feito / precisa de reinicio /
#  ficou deferido, com aviso de reinicio pendente.
#  Sem WPF (Server Core / headless / nao-STA): cai para Start-MainMenu.
# ============================================================================

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

# Cabecalho de categoria (TextBlock em destaque).
function New-WpfHeader {
    param([string] $Text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontWeight = 'Bold'
    $tb.Foreground = [System.Windows.Media.Brushes]::DeepSkyBlue
    $tb.Margin = [System.Windows.Thickness]::new(0, 10, 0, 4)
    return $tb
}

# Tags dos CheckBox marcados num painel (ignora cabecalhos).
function Get-WpfCheckedTags {
    param($Panel)
    $out = @()
    foreach ($ch in $Panel.Children) {
        if ($ch -is [System.Windows.Controls.CheckBox] -and $ch.IsChecked) { $out += $ch.Tag }
    }
    return $out
}

# Marca/desmarca todos os CheckBox de um painel.
function Set-WpfAllChecks {
    param($Panel, [bool] $Value)
    foreach ($ch in $Panel.Children) {
        if ($ch -is [System.Windows.Controls.CheckBox]) { $ch.IsChecked = $Value }
    }
}

# Popula a lista de Features (capacidades validas no SO).
function Add-WpfFeatureItems {
    param($Panel)
    $Panel.Children.Clear()
    $lastCat = ''
    foreach ($c in @(Get-AvailableCapabilities)) {
        if ($c.Category -ne $lastCat) { [void]$Panel.Children.Add((New-WpfHeader $c.Category)); $lastCat = $c.Category }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = if ($c.Notes) { "$($c.Display)   ($($c.Notes))" } else { $c.Display }
        $cb.Tag = $c.Id
        [void]$Panel.Children.Add($cb)
    }
}

# Popula a lista de Softwares (catalogo embutido + catalogo de usuario).
function Add-WpfSoftwareItems {
    param($Panel)
    $Panel.Children.Clear()
    Import-UserSoftwareCatalog | Out-Null
    $lastCat = ''
    foreach ($p in $Script:SoftwareCatalog) {
        if ($p.Category -ne $lastCat) { [void]$Panel.Children.Add((New-WpfHeader $p.Category)); $lastCat = $p.Category }
        $src = @(); if ($p.Choco) { $src += 'choco' }; if ($p.Winget) { $src += 'winget' }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($p.Name)   ($($src -join '/'))"
        $cb.Tag = $p.Key
        [void]$Panel.Children.Add($cb)
    }
}

# Preenche a aba Status a partir do ledger + aviso de reinicio pendente.
function Set-WpfStatusPanel {
    param($Panel, $RebootLabel)
    $Panel.Children.Clear()

    if (Test-PendingReboot) {
        $RebootLabel.Text = 'ATENCAO: ha um REINICIO pendente. Itens que dependem de reinicio foram adiados - reinicie o servidor e rode de novo.'
        $RebootLabel.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } else {
        $RebootLabel.Text = 'Sem reinicio pendente.'
        $RebootLabel.Foreground = [System.Windows.Media.Brushes]::LightGreen
    }

    $ledger = @(Get-FeatureStateLedger)
    if ($ledger.Count -eq 0) {
        [void]$Panel.Children.Add((New-WpfHeader 'Nenhuma execucao registrada ainda.'))
        return
    }
    $groups = @(
        @{ Label = 'Instalados / ja presentes';          St = @('Instalado', 'JaPresente') }
        @{ Label = 'Precisam de REINICIO';               St = @('PrecisaReinicio') }
        @{ Label = 'Deferidos (havia reinicio pendente)'; St = @('Deferido') }
        @{ Label = 'Falhas';                             St = @('Falha') }
    )
    foreach ($g in $groups) {
        $items = @($ledger | Where-Object { $g.St -contains $_.Status })
        if ($items.Count -gt 0) {
            [void]$Panel.Children.Add((New-WpfHeader $g.Label))
            foreach ($it in $items) {
                $tb = New-Object System.Windows.Controls.TextBlock
                $d  = if ($it.Detail) { "  ($($it.Detail))" } else { '' }
                $ts = if ($it.Timestamp) { "   [$($it.Timestamp)]" } else { '' }
                $tb.Text = "   - $($it.Name)$d$ts"
                $tb.Margin = [System.Windows.Thickness]::new(12, 1, 0, 1)
                [void]$Panel.Children.Add($tb)
            }
        }
    }
}

# Dialogo "Adicionar software" (catalogo de usuario). Retorna objeto ou $null.
function Show-AddSoftwareDialog {
    param($Owner)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Adicionar software" Height="340" Width="470"
        WindowStartupLocation="CenterOwner" Background="#FF1E1E1E" ResizeMode="NoResize">
  <Grid Margin="14">
    <Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition Height="20"/><RowDefinition/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Grid.Column="0" Text="Nome:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aName" Grid.Row="0" Grid.Column="1" Margin="0,4" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="1" Grid.Column="0" Text="Categoria:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aCat" Grid.Row="1" Grid.Column="1" Margin="0,4" Text="Usuario" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="2" Grid.Column="0" Text="ID winget:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aWin" Grid.Row="2" Grid.Column="1" Margin="0,4" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="3" Grid.Column="0" Text="ID choco:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aCho" Grid.Row="3" Grid.Column="1" Margin="0,4" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="4" Grid.Column="0" Text="Notas:" Foreground="#FFDDDDDD" VerticalAlignment="Center"/>
    <TextBox  x:Name="aNotes" Grid.Row="4" Grid.Column="1" Margin="0,4" Background="#FF2D2D30" Foreground="#FFEEEEEE"/>
    <TextBlock Grid.Row="5" Grid.ColumnSpan="2" Text="Informe ao menos um ID (winget ou choco)." Foreground="#FF9CDCFE"/>
    <StackPanel Grid.Row="6" Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="aOk" Content="Salvar" Width="90" Height="30" Margin="0,0,8,0" Background="#FF0E639C" Foreground="White"/>
      <Button x:Name="aCancel" Content="Cancelar" Width="90" Height="30" Background="#FF3F3F46" Foreground="White"/>
    </StackPanel>
  </Grid>
</Window>
'@
    [xml]$xml = $x
    $rd = New-Object System.Xml.XmlNodeReader $xml
    $w = [Windows.Markup.XamlReader]::Load($rd)
    if ($Owner) { $w.Owner = $Owner }
    $aName = $w.FindName('aName'); $aCat = $w.FindName('aCat'); $aWin = $w.FindName('aWin')
    $aCho = $w.FindName('aCho'); $aNotes = $w.FindName('aNotes')
    $aOk = $w.FindName('aOk'); $aCancel = $w.FindName('aCancel')

    $aOk.Add_Click({
        if (-not $aName.Text.Trim()) { [System.Windows.MessageBox]::Show('Informe o nome.', 'Atencao') | Out-Null; return }
        if (-not $aWin.Text.Trim() -and -not $aCho.Text.Trim()) { [System.Windows.MessageBox]::Show('Informe ao menos um ID (winget ou choco).', 'Atencao') | Out-Null; return }
        $w.Tag = [PSCustomObject]@{
            Name = $aName.Text.Trim(); Category = $aCat.Text.Trim()
            Winget = $aWin.Text.Trim(); Choco = $aCho.Text.Trim(); Notes = $aNotes.Text.Trim()
        }
        $w.DialogResult = $true; $w.Close()
    })
    $aCancel.Add_Click({ $w.DialogResult = $false; $w.Close() })

    $null = $w.ShowDialog()
    if ($w.DialogResult -ne $true) { return $null }
    return $w.Tag
}

# Monta e exibe a janela principal. Tudo roda na propria janela.
function Show-InstallerWpf {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop

    $xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configurador Windows Server" Height="720" Width="1080"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E1E" MinWidth="860" MinHeight="560">
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
      <Setter Property="Margin" Value="0,0,8,0"/>
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
        <TextBox x:Name="txtLog" Width="360" DockPanel.Dock="Left" Margin="6,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="btnClose" Content="Fechar" DockPanel.Dock="Right" Width="90" Height="30"/>
      </DockPanel>
    </Border>
    <TabControl x:Name="tabs" Background="#FF1E1E1E" BorderBrush="#FF3F3F46" Margin="6">

      <TabItem Header="Status">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Margin="12,10">
            <TextBlock x:Name="lblReboot" TextWrapping="Wrap" FontWeight="Bold"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="btnRefresh" Content="Atualizar" Width="110" Height="28"/>
              <Button x:Name="btnClearState" Content="Limpar historico" Width="140" Height="28" Background="#FF6E1E1E" BorderBrush="#FF6E1E1E"/>
            </StackPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spStatus" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Features">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="12,8">
            <Button x:Name="btnFeatAll" Content="Selecionar tudo" Width="130" Height="28"/>
            <Button x:Name="btnFeatNone" Content="Limpar" Width="90" Height="28"/>
            <Button x:Name="btnFeatApply" Content="Aplicar selecionados" Width="180" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
            <TextBlock x:Name="lblFeat" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF9CDCFE"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spFeatures" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Softwares">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Margin="12,8">
            <StackPanel Orientation="Horizontal">
              <Label Content="Gerenciador:" VerticalAlignment="Center"/>
              <RadioButton x:Name="rbWinget" Content="winget" Foreground="#FFDDDDDD" IsChecked="True" Margin="8,0" VerticalAlignment="Center"/>
              <RadioButton x:Name="rbChoco" Content="Chocolatey" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center"/>
              <RadioButton x:Name="rbAuto" Content="auto" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="btnSoftAll" Content="Selecionar tudo" Width="130" Height="28"/>
              <Button x:Name="btnSoftNone" Content="Limpar" Width="90" Height="28"/>
              <Button x:Name="btnSoftApply" Content="Aplicar selecionados" Width="180" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
              <Button x:Name="btnAddSoft" Content="Adicionar software..." Width="160" Height="28"/>
              <Button x:Name="btnChocoUpg" Content="choco upgrade all" Width="150" Height="28"/>
            </StackPanel>
            <TextBlock x:Name="lblSoft" Margin="0,6,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spSoftware" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="IIS">
        <StackPanel Margin="14">
          <TextBlock TextWrapping="Wrap" Margin="0,0,0,8"
                     Text="Instalacao completa do IIS (IIS + ASP.NET + WCF + WAS + MSMQ e sub-features). Pode demorar; o log sai no console."/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="btnIisFull" Content="Instalar IIS COMPLETO" Width="200" Height="32" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
            <Button x:Name="btnAspNet" Content="aspnet_state = Automatico" Width="200" Height="32"/>
            <Button x:Name="btnIisReset" Content="iisreset" Width="110" Height="32"/>
          </StackPanel>
          <TextBlock x:Name="lblIis" Margin="0,12,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
        </StackPanel>
      </TabItem>

      <TabItem Header="Rede (NAT / DHCP)">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
          <StackPanel Margin="12">
            <GroupBox Header="NAT Switch (Hyper-V)">
              <Grid Margin="8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="380"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <Label Grid.Row="0" Grid.Column="0" Content="Nome do switch:"/>
                <TextBox x:Name="natName" Grid.Row="0" Grid.Column="1" Margin="0,3" Text="NATSwitch"/>
                <Label Grid.Row="1" Grid.Column="0" Content="Sub-rede (CIDR):"/>
                <TextBox x:Name="natSubnet" Grid.Row="1" Grid.Column="1" Margin="0,3" Text="172.16.3.0/24"/>
                <Label Grid.Row="2" Grid.Column="0" Content="Gateway:"/>
                <TextBox x:Name="natGw" Grid.Row="2" Grid.Column="1" Margin="0,3" Text="172.16.3.1"/>
                <Label Grid.Row="3" Grid.Column="0" Content="Nome rede NAT (opc.):"/>
                <TextBox x:Name="natNetName" Grid.Row="3" Grid.Column="1" Margin="0,3"/>
                <Button x:Name="btnNat" Grid.Row="4" Grid.Column="1" Content="Criar NAT Switch" Width="170" HorizontalAlignment="Left" Height="30" Margin="0,8"/>
              </Grid>
            </GroupBox>
            <GroupBox Header="DHCP para o NAT (Windows Server)">
              <Grid Margin="8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="380"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <Button x:Name="btnDetect" Grid.Row="0" Grid.Column="1" Content="Detectar rede NAT" Width="170" HorizontalAlignment="Left" Height="28" Margin="0,3"/>
                <Label Grid.Row="1" Grid.Column="0" Content="Rede NAT:"/>
                <ComboBox x:Name="cboNat" Grid.Row="1" Grid.Column="1" Margin="0,3" HorizontalAlignment="Left" Width="380"/>
                <Label Grid.Row="2" Grid.Column="0" Content="Sub-rede (scope):"/>
                <TextBox x:Name="dhScope" Grid.Row="2" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="3" Grid.Column="0" Content="Mascara:"/>
                <TextBox x:Name="dhMask" Grid.Row="3" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="4" Grid.Column="0" Content="Gateway:"/>
                <TextBox x:Name="dhGw" Grid.Row="4" Grid.Column="1" Margin="0,3"/>
                <Label Grid.Row="5" Grid.Column="0" Content="Faixa inicio / fim:"/>
                <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal">
                  <TextBox x:Name="dhFrom" Width="180" Margin="0,3,6,3"/>
                  <TextBox x:Name="dhTo" Width="180" Margin="0,3"/>
                </StackPanel>
                <Label Grid.Row="6" Grid.Column="0" Content="DNS / Lease(dias):"/>
                <StackPanel Grid.Row="6" Grid.Column="1" Orientation="Horizontal">
                  <TextBox x:Name="dhDns" Width="210" Margin="0,3,6,3" Text="213.186.33.99"/>
                  <TextBox x:Name="dhLease" Width="100" Margin="0,3" Text="7300"/>
                </StackPanel>
                <Button x:Name="btnDhcp" Grid.Row="7" Grid.Column="1" Content="Aplicar DHCP" Width="170" HorizontalAlignment="Left" Height="30" Margin="0,8"/>
              </Grid>
            </GroupBox>
            <TextBlock x:Name="lblNet" TextWrapping="Wrap" Margin="2,8" Foreground="#FF9CDCFE"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Customizacoes">
        <StackPanel Margin="14">
          <CheckBox x:Name="chkDark" Content="Ativar Dark Mode (apps e sistema)"/>
          <CheckBox x:Name="chkExt" Content="Mostrar extensoes de arquivos"/>
          <CheckBox x:Name="chkHidden" Content="Mostrar arquivos ocultos"/>
          <CheckBox x:Name="chkSuperHidden" Content="Mostrar tambem arquivos protegidos do SO"/>
          <Button x:Name="btnCust" Content="Aplicar customizacoes" Width="200" Height="32" HorizontalAlignment="Left" Margin="12,12,0,0" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
          <TextBlock x:Name="lblCust" Margin="12,12,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
        </StackPanel>
      </TabItem>

      <TabItem Header="Config base">
        <StackPanel Margin="14">
          <CheckBox x:Name="chkIeEsc" Content="Desativar IE Enhanced Security Configuration (IE ESC)"/>
          <CheckBox x:Name="chkTz" Content="Time zone para Brasilia"/>
          <CheckBox x:Name="chkNtp" Content="Ajustar/sincronizar data e hora (NTP)"/>
          <CheckBox x:Name="chkSrvMgr" Content="Nao iniciar o Server Manager no logon"/>
          <Button x:Name="btnBase" Content="Aplicar config. base" Width="200" Height="32" HorizontalAlignment="Left" Margin="12,12,0,0" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
          <TextBlock x:Name="lblBase" Margin="12,12,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
        </StackPanel>
      </TabItem>

    </TabControl>
  </DockPanel>
</Window>
'@

    [xml]$xaml = $xamlText
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    # Referencias
    $txtLog   = $win.FindName('txtLog');   $btnClose = $win.FindName('btnClose')
    $lblReboot = $win.FindName('lblReboot'); $spStatus = $win.FindName('spStatus')
    $btnRefresh = $win.FindName('btnRefresh'); $btnClearState = $win.FindName('btnClearState')
    $spFeatures = $win.FindName('spFeatures'); $btnFeatAll = $win.FindName('btnFeatAll')
    $btnFeatNone = $win.FindName('btnFeatNone'); $btnFeatApply = $win.FindName('btnFeatApply'); $lblFeat = $win.FindName('lblFeat')
    $rbChoco = $win.FindName('rbChoco'); $rbAuto = $win.FindName('rbAuto')
    $spSoftware = $win.FindName('spSoftware'); $btnSoftAll = $win.FindName('btnSoftAll'); $btnSoftNone = $win.FindName('btnSoftNone')
    $btnSoftApply = $win.FindName('btnSoftApply'); $btnAddSoft = $win.FindName('btnAddSoft'); $btnChocoUpg = $win.FindName('btnChocoUpg'); $lblSoft = $win.FindName('lblSoft')
    $btnIisFull = $win.FindName('btnIisFull'); $btnAspNet = $win.FindName('btnAspNet'); $btnIisReset = $win.FindName('btnIisReset'); $lblIis = $win.FindName('lblIis')
    $natName = $win.FindName('natName'); $natSubnet = $win.FindName('natSubnet'); $natGw = $win.FindName('natGw'); $natNetName = $win.FindName('natNetName'); $btnNat = $win.FindName('btnNat')
    $btnDetect = $win.FindName('btnDetect'); $cboNat = $win.FindName('cboNat')
    $dhScope = $win.FindName('dhScope'); $dhMask = $win.FindName('dhMask'); $dhGw = $win.FindName('dhGw')
    $dhFrom = $win.FindName('dhFrom'); $dhTo = $win.FindName('dhTo'); $dhDns = $win.FindName('dhDns'); $dhLease = $win.FindName('dhLease')
    $btnDhcp = $win.FindName('btnDhcp'); $lblNet = $win.FindName('lblNet')
    $chkDark = $win.FindName('chkDark'); $chkExt = $win.FindName('chkExt'); $chkHidden = $win.FindName('chkHidden'); $chkSuperHidden = $win.FindName('chkSuperHidden')
    $btnCust = $win.FindName('btnCust'); $lblCust = $win.FindName('lblCust')
    $chkIeEsc = $win.FindName('chkIeEsc'); $chkTz = $win.FindName('chkTz'); $chkNtp = $win.FindName('chkNtp'); $chkSrvMgr = $win.FindName('chkSrvMgr')
    $btnBase = $win.FindName('btnBase'); $lblBase = $win.FindName('lblBase')

    $txtLog.Text = $Script:DefaultLogDir
    $ui = @{ Nets = @(); Iface = '' }

    # Popula listas + status inicial
    Add-WpfFeatureItems $spFeatures
    Add-WpfSoftwareItems $spSoftware
    Set-WpfStatusPanel $spStatus $lblReboot

    $applyLog = { if ($txtLog.Text.Trim()) { Set-LogDirectory -Path $txtLog.Text.Trim() } }

    # --- Status ---
    $btnRefresh.Add_Click({ Set-WpfStatusPanel $spStatus $lblReboot })
    $btnClearState.Add_Click({ Clear-FeatureState; Set-WpfStatusPanel $spStatus $lblReboot })

    # --- Bottom ---
    $btnClose.Add_Click({ $win.Close() })

    # --- Features ---
    $btnFeatAll.Add_Click({ Set-WpfAllChecks $spFeatures $true })
    $btnFeatNone.Add_Click({ Set-WpfAllChecks $spFeatures $false })
    $btnFeatApply.Add_Click({
        $ids = @(Get-WpfCheckedTags $spFeatures)
        if ($ids.Count -eq 0) { $lblFeat.Text = 'Nada selecionado.'; return }
        try {
            $win.Cursor = [System.Windows.Input.Cursors]::Wait
            & $applyLog
            Invoke-CapabilityInstall -Ids $ids
            $lblFeat.Text = Get-SummaryText
        } catch { $lblFeat.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    # --- Softwares ---
    $btnSoftAll.Add_Click({ Set-WpfAllChecks $spSoftware $true })
    $btnSoftNone.Add_Click({ Set-WpfAllChecks $spSoftware $false })
    $btnAddSoft.Add_Click({
        $r = Show-AddSoftwareDialog -Owner $win
        if ($r) {
            if (Add-UserSoftware -Name $r.Name -Category $r.Category -Winget $r.Winget -Choco $r.Choco -Notes $r.Notes) {
                Add-WpfSoftwareItems $spSoftware
                $lblSoft.Text = "Adicionado: $($r.Name). Marque e clique 'Aplicar selecionados'."
            } else { $lblSoft.Text = 'Falha ao adicionar (ver log).' }
        }
    })
    $btnChocoUpg.Add_Click({
        try { $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog; Update-AllChoco; $lblSoft.Text = 'choco upgrade all executado (ver log/console).' }
        catch { $lblSoft.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow }
    })
    $btnSoftApply.Add_Click({
        $keys = @(Get-WpfCheckedTags $spSoftware)
        if ($keys.Count -eq 0) { $lblSoft.Text = 'Nada selecionado.'; return }
        $pref = if ($rbChoco.IsChecked) { 'choco' } elseif ($rbAuto.IsChecked) { 'auto' } else { 'winget' }
        try {
            $win.Cursor = [System.Windows.Input.Cursors]::Wait
            & $applyLog
            Reset-FeatureSession
            foreach ($k in $keys) {
                $pkg = $Script:SoftwareCatalog | Where-Object { $_.Key -eq $k }
                if ($pkg) { Install-SoftwarePackage -Pkg $pkg -Preferred $pref }
            }
            Show-FeaturesSummary
            $lblSoft.Text = Get-SummaryText
        } catch { $lblSoft.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    # --- IIS ---
    $btnIisFull.Add_Click({
        try { $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog; Reset-FeatureSession; Install-IISFull; Show-FeaturesSummary; $lblIis.Text = Get-SummaryText }
        catch { $lblIis.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; Set-WpfStatusPanel $spStatus $lblReboot }
    })
    $btnAspNet.Add_Click({
        try { & $applyLog; Set-AspNetStateAuto; $lblIis.Text = 'aspnet_state configurado (ver log).' } catch { $lblIis.Text = "Erro: $($_.Exception.Message)" }
    })
    $btnIisReset.Add_Click({
        try { & $applyLog; Invoke-IISReset; $lblIis.Text = 'iisreset executado (ver log).' } catch { $lblIis.Text = "Erro: $($_.Exception.Message)" }
    })

    # --- Rede: NAT ---
    $btnNat.Add_Click({
        try {
            $win.Cursor = [System.Windows.Input.Cursors]::Wait
            & $applyLog
            Reset-FeatureSession
            if ($natNetName.Text.Trim()) {
                New-NatSwitch -SwitchName $natName.Text.Trim() -Subnet $natSubnet.Text.Trim() -GatewayIP $natGw.Text.Trim() -NatName $natNetName.Text.Trim()
            } else {
                New-NatSwitch -SwitchName $natName.Text.Trim() -Subnet $natSubnet.Text.Trim() -GatewayIP $natGw.Text.Trim()
            }
            $lblNet.Text = Get-SummaryText
        } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    # --- Rede: DHCP ---
    $fillFromNet = {
        param($n)
        $dhScope.Text = $n.ScopeId; $dhMask.Text = $n.Mask; $dhGw.Text = $n.GatewayIP
        $netU = ConvertTo-IPv4UInt32 -IP $n.ScopeId
        $dhFrom.Text = ConvertFrom-IPv4UInt32 -Value ($netU + 50)
        $dhTo.Text   = ConvertFrom-IPv4UInt32 -Value ($netU + 200)
        $ui.Iface = $n.InterfaceAlias
    }
    $cboNat.Add_SelectionChanged({
        $idx = $cboNat.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $ui.Nets.Count) { & $fillFromNet $ui.Nets[$idx] }
    })
    $btnDetect.Add_Click({
        try {
            $nets = @(Get-NatNetworkInfo | Where-Object { $_.GatewayIP })
            $ui.Nets = $nets
            $cboNat.Items.Clear()
            if ($nets.Count -eq 0) { $lblNet.Text = 'Nenhuma rede NAT detectada. Crie o NAT Switch acima primeiro.'; return }
            foreach ($n in $nets) { [void]$cboNat.Items.Add("$($n.ScopeId)/$($n.PrefixLength)  (gw $($n.GatewayIP))") }
            $cboNat.SelectedIndex = 0
            $lblNet.Text = "$($nets.Count) rede(s) NAT detectada(s). Campos preenchidos pela selecionada."
        } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
    })
    $btnDhcp.Add_Click({
        try {
            $win.Cursor = [System.Windows.Input.Cursors]::Wait
            & $applyLog
            Reset-FeatureSession
            if (-not (Install-DhcpRoleForNat)) {
                $lblNet.Text = (Get-SummaryText) + "`nSe foi pedido reinicio: reinicie e rode de novo."
                return
            }
            $iface = $ui.Iface
            if (-not $iface) {
                $m = Get-NatNetworkInfo | Where-Object { $_.ScopeId -eq $dhScope.Text.Trim() } | Select-Object -First 1
                if ($m) { $iface = $m.InterfaceAlias }
            }
            if (-not $iface) { $lblNet.Text = 'Clique "Detectar rede NAT" antes de aplicar o DHCP.'; return }
            $lease = 7300; $tmp = 0
            if ([int]::TryParse($dhLease.Text.Trim(), [ref]$tmp) -and $tmp -gt 0) { $lease = $tmp }
            Set-NatDhcpScope -ScopeId $dhScope.Text.Trim() -Mask $dhMask.Text.Trim() `
                -RangeFrom $dhFrom.Text.Trim() -RangeTo $dhTo.Text.Trim() `
                -Gateway $dhGw.Text.Trim() -Dns $dhDns.Text.Trim() -NatIface $iface -LeaseDays $lease
            $lblNet.Text = Get-SummaryText
        } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    # --- Customizacoes ---
    $btnCust.Add_Click({
        try {
            $win.Cursor = [System.Windows.Input.Cursors]::Wait
            & $applyLog
            Reset-FeatureSession
            $changed = $false
            if ($chkDark.IsChecked)   { $c = Enable-DarkMode;     Add-FeatureResult -Name 'Dark Mode' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $changed = $changed -or $c }
            if ($chkExt.IsChecked)    { $c = Show-FileExtensions; Add-FeatureResult -Name 'Mostrar extensoes' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $changed = $changed -or $c }
            if ($chkSuperHidden.IsChecked) { $c = Show-HiddenFiles -IncludeProtectedOsFiles; Add-FeatureResult -Name 'Mostrar ocultos (+protegidos)' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $changed = $changed -or $c }
            elseif ($chkHidden.IsChecked) { $c = Show-HiddenFiles; Add-FeatureResult -Name 'Mostrar ocultos' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $changed = $changed -or $c }
            if ($changed) { Restart-Explorer }
            $lblCust.Text = if ($Script:FeatureResults.Count) { Get-SummaryText } else { 'Nada selecionado.' }
        } catch { $lblCust.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    # --- Config base ---
    $btnBase.Add_Click({
        try {
            $win.Cursor = [System.Windows.Input.Cursors]::Wait
            & $applyLog
            Reset-FeatureSession
            if ($chkIeEsc.IsChecked)  { try { Disable-IEEsc;                 Add-FeatureResult -Name 'IE ESC desativado' -Status 'Instalado' } catch { Add-FeatureResult -Name 'IE ESC' -Status 'Falha' -Detail $_.Exception.Message } }
            if ($chkTz.IsChecked)     { try { Set-TimeZoneBrasilia;          Add-FeatureResult -Name 'Time zone Brasilia' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Time zone' -Status 'Falha' -Detail $_.Exception.Message } }
            if ($chkNtp.IsChecked)    { try { Sync-DateTime;                 Add-FeatureResult -Name 'Sync NTP' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Sync NTP' -Status 'Falha' -Detail $_.Exception.Message } }
            if ($chkSrvMgr.IsChecked) { try { Disable-ServerManagerAutoStart; Add-FeatureResult -Name 'Server Manager no logon (off)' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Server Manager logon' -Status 'Falha' -Detail $_.Exception.Message } }
            $lblBase.Text = if ($Script:FeatureResults.Count) { Get-SummaryText } else { 'Nada selecionado.' }
        } catch { $lblBase.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; Set-WpfStatusPanel $spStatus $lblReboot }
    })

    $null = $win.ShowDialog()
}

# Entry point da UI: tenta WPF; sem WPF, cai para o menu de console.
function Start-Gui {
    if (Test-CanUseWpf) {
        try { Show-InstallerWpf | Out-Null; return }
        catch { Write-Log "Falha na GUI WPF ($($_.Exception.Message)) - usando menu de console." -Level WARN }
    }
    Start-MainMenu
}
