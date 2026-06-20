# ============================================================================
#  GuiWpf.ps1  -  Janela WPF (estilo app, abas) com fallback para console
#  Depende de Common.ps1, OSCommon.ps1, WindowsFeatures.ps1, IIS.ps1,
#  Software.ps1, Customizations.ps1, BaseConfig.ps1 e Gui.ps1.
#
#  Modelo: janela FICA ABERTA (sessao iterativa); cada aba tem seu "Aplicar".
#  Operacoes pesadas pedem CONFIRMACAO e sao ENFILEIRADAS num worker em runspace
#  separado (fila serial) -> a janela NAO congela; da pra navegar enquanto roda.
#  A aba "Log ao vivo" mostra o andamento (um DispatcherTimer drena o log do worker).
#  Se o worker nao iniciar, ha FALLBACK sincrono (igual ao comportamento antigo).
#  Cada item ja instalado mostra "[feito em <data>]" ao lado (verde); clicar nessa
#  marca abre um popup com o registro (JSON) daquele item do ledger.
#  Aba "Status" le o ledger persistente (installer-state.json) e mostra, ao abrir
#  (inclusive apos reinicio), o que ja foi feito / precisa de reinicio / deferido.
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

# Desenha o icone da janela (gordinho loiro de oculos Ray-Ban quadrados) em
# runtime com GDI+ e devolve um BitmapSource. Self-contained (funciona via irm).
function New-AppIconImage {
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bmp = New-Object System.Drawing.Bitmap(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $skin  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 245, 205, 160))
        $blond = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 242, 206, 82))
        $black = [System.Drawing.Color]::FromArgb(255, 25, 25, 25)

        $g.FillEllipse($blond, 28, 18, 200, 160)          # cabelo loiro
        $g.FillEllipse($skin, 18, 116, 34, 46)            # orelha esq
        $g.FillEllipse($skin, 204, 116, 34, 46)           # orelha dir
        $g.FillEllipse($skin, 34, 52, 188, 176)           # rosto gordinho
        $cheek = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(90, 240, 140, 140))
        $g.FillEllipse($cheek, 58, 160, 46, 34)           # bochechas
        $g.FillEllipse($cheek, 152, 160, 46, 34)
        $lens = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(80, 30, 45, 70))
        $g.FillRectangle($lens, 60, 104, 56, 52)          # lentes
        $g.FillRectangle($lens, 140, 104, 56, 52)
        $frame = New-Object System.Drawing.Pen ($black, 12)
        $g.DrawRectangle($frame, 60, 104, 56, 52)         # armacao quadrada
        $g.DrawRectangle($frame, 140, 104, 56, 52)
        $bar = New-Object System.Drawing.Pen ($black, 10)
        $g.DrawLine($bar, 116, 120, 140, 120)             # ponte
        $g.DrawLine($bar, 60, 116, 36, 124)               # hastes
        $g.DrawLine($bar, 196, 116, 220, 124)
        $eye = New-Object System.Drawing.SolidBrush ($black)
        $g.FillEllipse($eye, 82, 122, 15, 15)             # olhos
        $g.FillEllipse($eye, 162, 122, 15, 15)
        $mouth = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 120, 60, 50), 10)
        $g.DrawArc($mouth, 100, 166, 56, 40, 20, 140)     # sorriso
        $g.Dispose()

        $h = $bmp.GetHicon()
        $img = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $h, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $img.Freeze()
        return $img
    } catch { return $null }
}

# Confirmacao Sim/Nao (rede contra cliques enfileirados em acoes pesadas).
function Confirm-Wpf {
    param([string] $Message)
    return ([System.Windows.MessageBox]::Show($Message, 'Confirmar',
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) `
        -eq [System.Windows.MessageBoxResult]::Yes)
}

# Formata uma lista de nomes para o texto da confirmacao (limita o tamanho).
function Format-ConfirmList {
    param([string[]] $Names, [int] $Max = 25)
    $n = @($Names | Where-Object { $_ })
    $txt = (($n | Select-Object -First $Max) | ForEach-Object { "  - $_" }) -join "`n"
    if ($n.Count -gt $Max) { $txt += "`n  ... +$($n.Count - $Max)" }
    return $txt
}

function New-WpfHeader {
    param([string] $Text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontWeight = 'Bold'
    $tb.Foreground = [System.Windows.Media.Brushes]::DeepSkyBlue
    $tb.Margin = [System.Windows.Thickness]::new(0, 10, 0, 4)
    return $tb
}

# Popup generico com texto monoespacado (read-only). Usado p/ mostrar o JSON
# de um item do ledger e a saida das verificacoes de atualizacao.
function Show-TextPopup {
    param([string] $Title, [string] $Text, $Owner)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Detalhe" Height="440" Width="600" WindowStartupLocation="CenterOwner"
        Background="#FF1E1E1E">
  <DockPanel Margin="10">
    <Button x:Name="btnOk" Content="Fechar" DockPanel.Dock="Bottom" Width="100" Height="30"
            HorizontalAlignment="Right" Margin="0,8,0,0" Background="#FF0E639C" Foreground="White"/>
    <TextBox x:Name="txt" IsReadOnly="True" TextWrapping="NoWrap" FontFamily="Consolas"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             Background="#FF2D2D30" Foreground="#FFEEEEEE" BorderBrush="#FF3F3F46"/>
  </DockPanel>
</Window>
'@
    [xml]$xml = $x
    $rd = New-Object System.Xml.XmlNodeReader $xml
    $w = [Windows.Markup.XamlReader]::Load($rd)
    $w.Title = $Title
    if ($Owner) { $w.Owner = $Owner }
    $w.FindName('txt').Text = $Text
    $w.FindName('btnOk').Add_Click({ $w.Close() }.GetNewClosure())
    $null = $w.ShowDialog()
}

# Acha o item do ledger pelo Name e mostra o registro (JSON) num popup.
function Show-LedgerJsonPopup {
    param([string] $Name, $Owner)
    $item = @(Get-FeatureStateLedger | Where-Object { [string]$_.Name -eq $Name }) | Select-Object -First 1
    if (-not $item) {
        [System.Windows.MessageBox]::Show("Sem registro no historico para: $Name", 'Detalhe') | Out-Null
        return
    }
    Show-TextPopup -Title "Registro: $Name" -Text ($item | ConvertTo-Json -Depth 5) -Owner $Owner
}

# Coleta os CheckBox de um painel, sejam filhos diretos ou dentro das "linhas"
# (StackPanel [checkbox][marca clicavel]) criadas por New-WpfItemRow.
function Get-PanelCheckBoxes {
    param($Panel)
    $list = @()
    foreach ($ch in $Panel.Children) {
        if ($ch -is [System.Windows.Controls.CheckBox]) { $list += $ch }
        elseif ($ch -is [System.Windows.Controls.Panel]) {
            foreach ($g in $ch.Children) { if ($g -is [System.Windows.Controls.CheckBox]) { $list += $g } }
        }
    }
    return $list
}

function Get-WpfCheckedTags {
    param($Panel)
    $out = @()
    foreach ($cb in (Get-PanelCheckBoxes $Panel)) { if ($cb.IsChecked) { $out += $cb.Tag } }
    return $out
}

function Set-WpfAllChecks {
    param($Panel, [bool] $Value)
    foreach ($cb in (Get-PanelCheckBoxes $Panel)) { $cb.IsChecked = $Value }
}

# Mapa Name -> item do ledger, apenas dos que estao Instalado/JaPresente.
function Get-InstalledStateMap {
    $map = @{}
    foreach ($it in @(Get-FeatureStateLedger)) {
        if ($it.Name -and ($it.Status -eq 'Instalado' -or $it.Status -eq 'JaPresente')) { $map[[string]$it.Name] = $it }
    }
    return $map
}

# Cria uma "linha" de item: [CheckBox] + (se ja feito) [marca "[feito em <data>]"
# verde e clicavel -> popup com o JSON]. A marca fica FORA do checkbox para o
# clique nela nao marcar/desmarcar o item. $LedgerKey = Name no ledger.
function New-WpfItemRow {
    param([string] $Text, $Tag, $Map, [string] $LedgerKey, $Owner)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Text
    $cb.Tag = $Tag
    $cb.VerticalAlignment = 'Center'
    [void]$row.Children.Add($cb)

    if ($Map -and $LedgerKey -and $Map.ContainsKey($LedgerKey)) {
        $it = $Map[$LedgerKey]
        $ts = if ($it.Timestamp) { [string]$it.Timestamp } else { '' }
        $mk = New-Object System.Windows.Controls.TextBlock
        $mk.Text = if ($ts) { "   [feito em $ts]" } else { '   [feito]' }
        $mk.Foreground = [System.Windows.Media.Brushes]::LightGreen
        $mk.VerticalAlignment = 'Center'
        $mk.Cursor = [System.Windows.Input.Cursors]::Hand
        $mk.ToolTip = 'Clique para ver o registro (JSON) deste item'
        $mk.Add_MouseLeftButtonUp({ Show-LedgerJsonPopup -Name $LedgerKey -Owner $Owner }.GetNewClosure())
        [void]$row.Children.Add($mk)
    }
    return $row
}

# Features: exclui Web/IIS e .NET (vao na aba IIS). Mantem Virtualizacao, Rede,
# Mensageria. Mantem a ordem do catalogo, agrupando por categoria.
function Add-WpfFeatureItems {
    param($Panel, $Owner)
    $Panel.Children.Clear()
    $map = Get-InstalledStateMap
    $lastCat = ''
    foreach ($c in @(Get-AvailableCapabilities)) {
        if ($c.Category -in @('Web/IIS', '.NET')) { continue }
        if ($c.Category -ne $lastCat) { [void]$Panel.Children.Add((New-WpfHeader $c.Category)); $lastCat = $c.Category }
        $text = if ($c.Notes) { "$($c.Display)   ($($c.Notes))" } else { $c.Display }
        [void]$Panel.Children.Add((New-WpfItemRow -Text $text -Tag $c.Id -Map $map -LedgerKey $c.Display -Owner $Owner))
    }
}

# Softwares: catalogo embutido + de usuario. Filtro 'all' | 'winget' | 'choco'.
function Add-WpfSoftwareItems {
    param($Panel, [string] $Filter = 'all', $Owner)
    $Panel.Children.Clear()
    Import-UserSoftwareCatalog | Out-Null
    $map = Get-InstalledStateMap
    $list = $Script:SoftwareCatalog
    if ($Filter -eq 'winget') { $list = @($list | Where-Object { $_.Winget }) }
    elseif ($Filter -eq 'choco') { $list = @($list | Where-Object { $_.Choco }) }
    $lastCat = ''
    foreach ($p in $list) {
        if ($p.Category -ne $lastCat) { [void]$Panel.Children.Add((New-WpfHeader $p.Category)); $lastCat = $p.Category }
        $src = @(); if ($p.Choco) { $src += 'choco' }; if ($p.Winget) { $src += 'winget' }
        $text = "$($p.Name)   ($($src -join '/'))"
        [void]$Panel.Children.Add((New-WpfItemRow -Text $text -Tag $p.Key -Map $map -LedgerKey $p.Name -Owner $Owner))
    }
}

# IIS: lista COMPLETA na ordem de $Script:IISFeatures + itens de pos-instalacao
# (aspnet_state, iisreset) como marcadores especiais.
function Add-WpfIisItems {
    param($Panel, $Owner)
    $Panel.Children.Clear()
    $map = Get-InstalledStateMap
    [void]$Panel.Children.Add((New-WpfHeader 'Features do IIS (ordem padrao)'))
    foreach ($f in $Script:IISFeatures) {
        [void]$Panel.Children.Add((New-WpfItemRow -Text $f -Tag $f -Map $map -LedgerKey $f -Owner $Owner))
    }
    [void]$Panel.Children.Add((New-WpfHeader 'Pos-instalacao'))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'aspnet_state = Automatico' -Tag '__aspnet_state__' -Map $map -LedgerKey 'aspnet_state' -Owner $Owner))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'iisreset' -Tag '__iisreset__' -Map $map -LedgerKey 'iisreset' -Owner $Owner))
}

# Sistema: aba unificada (Customizacoes + Configuracao base). Cada item vira uma
# linha com marca "[feito em ...]" clicavel, igual as demais abas. As Tags batem
# com o switch do botao "Aplicar selecionados".
function Add-WpfSystemItems {
    param($Panel, $Owner)
    $Panel.Children.Clear()
    $map = Get-InstalledStateMap

    [void]$Panel.Children.Add((New-WpfHeader 'Customizacoes (Explorer / UI)'))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Ativar Dark Mode (apps e sistema)'                  -Tag 'dark'        -Map $map -LedgerKey 'Dark Mode' -Owner $Owner))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Mostrar extensoes de arquivos'                       -Tag 'ext'         -Map $map -LedgerKey 'Mostrar extensoes' -Owner $Owner))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Mostrar arquivos ocultos'                            -Tag 'hidden'      -Map $map -LedgerKey 'Mostrar ocultos' -Owner $Owner))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Mostrar tambem arquivos protegidos do SO'            -Tag 'superhidden' -Map $map -LedgerKey 'Mostrar ocultos (+protegidos)' -Owner $Owner))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Desativar Print Screen abrindo a Ferramenta de Captura' -Tag 'printscr' -Map $map -LedgerKey 'Print Screen (Snipping off)' -Owner $Owner))

    [void]$Panel.Children.Add((New-WpfHeader 'Configuracao base'))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Desativar IE Enhanced Security Configuration (IE ESC)' -Tag 'ieesc'   -Map $map -LedgerKey 'IE ESC desativado' -Owner $Owner))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Time zone para Brasilia'                             -Tag 'tz'        -Map $map -LedgerKey 'Time zone Brasilia' -Owner $Owner))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Ajustar/sincronizar data e hora (via internet)'      -Tag 'datetime'  -Map $map -LedgerKey 'Data e hora' -Owner $Owner))
    [void]$Panel.Children.Add((New-WpfItemRow -Text 'Nao iniciar o Server Manager no logon'               -Tag 'srvmgr'    -Map $map -LedgerKey 'Server Manager no logon (off)' -Owner $Owner))
}

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
    # Cabecalho ao vivo: maquina / tipo (fisica/virtual) / OS / IPs atuais.
    $mi = Get-MachineInfo
    $hMac = New-Object System.Windows.Controls.TextBlock
    $hMac.Text = "Maquina: $($mi.Machine)   [$($mi.Kind)]    IPs: $((@(Get-HostIPv4) -join ', '))"
    $hMac.Foreground = [System.Windows.Media.Brushes]::DeepSkyBlue
    $hMac.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$Panel.Children.Add($hMac)
    if ($mi.OS) {
        $hOs = New-Object System.Windows.Controls.TextBlock
        $hOs.Text = "SO: $($mi.OS)"
        $hOs.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        [void]$Panel.Children.Add($hOs)
    }

    $ledger = @(Get-FeatureStateLedger)
    if ($ledger.Count -eq 0) {
        [void]$Panel.Children.Add((New-WpfHeader 'Nenhuma execucao registrada ainda.'))
        return
    }
    $groups = @(
        @{ Label = 'Instalados / ja presentes';           St = @('Instalado', 'JaPresente') }
        @{ Label = 'Precisam de REINICIO';                St = @('PrecisaReinicio') }
        @{ Label = 'Deferidos (havia reinicio pendente)'; St = @('Deferido') }
        @{ Label = 'Falhas';                              St = @('Falha') }
    )
    foreach ($g in $groups) {
        $items = @($ledger | Where-Object { $g.St -contains $_.Status })
        if ($items.Count -gt 0) {
            [void]$Panel.Children.Add((New-WpfHeader $g.Label))
            foreach ($it in $items) {
                $tb = New-Object System.Windows.Controls.TextBlock
                $d   = if ($it.Detail) { "  ($($it.Detail))" } else { '' }
                $ts  = if ($it.Timestamp) { "   [$($it.Timestamp)]" } else { '' }
                $dur = if ($it.DurationSec) { "   $($it.DurationSec)s" } else { '' }
                $mq  = if ($it.Machine -and $it.Machine -ne $mi.Machine) { "   @$($it.Machine)" } else { '' }
                $tb.Text = "   - $($it.Name)$d$ts$dur$mq"
                $tb.Margin = [System.Windows.Thickness]::new(12, 1, 0, 1)
                $tb.Cursor = [System.Windows.Input.Cursors]::Hand
                $tb.ToolTip = 'Clique para ver o registro (JSON) deste item'
                $nm = [string]$it.Name
                $own = [System.Windows.Window]::GetWindow($Panel)
                $tb.Add_MouseLeftButtonUp({ Show-LedgerJsonPopup -Name $nm -Owner $own }.GetNewClosure())
                [void]$Panel.Children.Add($tb)
            }
        }
    }
}

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

# ============================================================================
#  Infra de execucao assincrona: worker em runspace + fila serial + log vivo
#  A UI nunca executa trabalho pesado; ela ENFILEIRA. Um unico worker consome
#  a fila em serie (nunca dois choco/winget juntos). Toda atualizacao de UI
#  ocorre na thread do Dispatcher (DispatcherTimer / $win.Dispatcher).
# ============================================================================

# Fonte completa dos modulos para re-hidratar o worker. IRM: usa o payload ja
# capturado no bootstrap-head. DEV: concatena modules\*.ps1 na ordem do build.
# Retorna $null se nao houver fonte (=> fallback sincrono).
function Get-InstallerSource {
    if ($global:WINCFG_PAYLOAD_SRC) { return $global:WINCFG_PAYLOAD_SRC }
    if ($PSScriptRoot) {
        $order = 'Common','OSCommon','Customizations','WindowsFeatures','BaseConfig','IIS','Software','Gui','GuiWpf'
        $sb = New-Object System.Text.StringBuilder
        foreach ($n in $order) {
            $f = Join-Path $PSScriptRoot "$n.ps1"
            if (Test-Path $f) { [void]$sb.AppendLine((Get-Content -LiteralPath $f -Raw)) }
        }
        if ($sb.Length -gt 0) { return $sb.ToString() }
    }
    return $null
}

# Despacho declarativo de um job no WORKER (usa as funcoes ja re-hidratadas).
# Jobs sao hashtables de dados (nunca scriptblocks) -> seguro cruzar runspace.
function Invoke-WorkerJob {
    param($Job)
    switch ($Job.Kind) {
        'setlog'    { if ($Job.Data.Path) { Set-LogDirectory -Path $Job.Data.Path } }
        'features'  { Invoke-CapabilityInstall -Ids $Job.Data.Ids }
        'software'  {
            Reset-FeatureSession
            foreach ($k in $Job.Data.Keys) {
                $pkg = $Script:SoftwareCatalog | Where-Object { $_.Key -eq $k } | Select-Object -First 1
                if ($pkg) { Install-SoftwarePackage -Pkg $pkg -Preferred $Job.Data.Pref }
            }
            Show-FeaturesSummary
        }
        'iis'       {
            Reset-FeatureSession
            foreach ($f in $Job.Data.Feats) { Enable-OptionalFeatureSafe -FeatureName $f -All }
            if ($Job.Data.Aspnet) { Set-AspNetStateAuto }
            if ($Job.Data.Reset)  { Invoke-IISReset }
            Show-FeaturesSummary
        }
        'iisfull'   { Reset-FeatureSession; Install-IISFull; Show-FeaturesSummary }
        'aspnet'    { Reset-FeatureSession; Set-AspNetStateAuto; Show-FeaturesSummary }
        'iisreset'  { Reset-FeatureSession; Invoke-IISReset; Show-FeaturesSummary }
        'nat'       {
            Reset-FeatureSession
            if ($Job.Data.NatName) {
                New-NatSwitch -SwitchName $Job.Data.SwitchName -Subnet $Job.Data.Subnet -GatewayIP $Job.Data.GatewayIP -NatName $Job.Data.NatName
            } else {
                New-NatSwitch -SwitchName $Job.Data.SwitchName -Subnet $Job.Data.Subnet -GatewayIP $Job.Data.GatewayIP
            }
        }
        'dhcp'      {
            Reset-FeatureSession
            if (-not (Install-DhcpRoleForNat)) { Show-FeaturesSummary; return }
            Set-NatDhcpScope -ScopeId $Job.Data.ScopeId -Mask $Job.Data.Mask `
                -RangeFrom $Job.Data.RangeFrom -RangeTo $Job.Data.RangeTo `
                -Gateway $Job.Data.Gateway -Dns $Job.Data.Dns -NatIface $Job.Data.Iface -LeaseDays $Job.Data.LeaseDays
        }
        'system'    {
            Reset-FeatureSession
            $restartExplorer = $false
            foreach ($t in $Job.Data.Tags) {
                switch ($t) {
                    'dark'        { $c = Enable-DarkMode;        Add-FeatureResult -Name 'Dark Mode' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $restartExplorer = $restartExplorer -or $c }
                    'ext'         { $c = Show-FileExtensions;    Add-FeatureResult -Name 'Mostrar extensoes' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $restartExplorer = $restartExplorer -or $c }
                    'hidden'      { $c = Show-HiddenFiles;       Add-FeatureResult -Name 'Mostrar ocultos' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $restartExplorer = $restartExplorer -or $c }
                    'superhidden' { $c = Show-HiddenFiles -IncludeProtectedOsFiles; Add-FeatureResult -Name 'Mostrar ocultos (+protegidos)' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $restartExplorer = $restartExplorer -or $c }
                    'printscr'    { $c = Disable-PrintScreenSnipping; Add-FeatureResult -Name 'Print Screen (Snipping off)' -Status $(if ($c) {'Instalado'} else {'JaPresente'}) }
                    'ieesc'       { try { Disable-IEEsc;                 Add-FeatureResult -Name 'IE ESC desativado' -Status 'Instalado' } catch { Add-FeatureResult -Name 'IE ESC desativado' -Status 'Falha' -Detail $_.Exception.Message } }
                    'tz'          { try { Set-TimeZoneBrasilia;          Add-FeatureResult -Name 'Time zone Brasilia' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Time zone Brasilia' -Status 'Falha' -Detail $_.Exception.Message } }
                    'datetime'    { try { if (Sync-DateTime) { Add-FeatureResult -Name 'Data e hora' -Status 'Instalado' } else { Add-FeatureResult -Name 'Data e hora' -Status 'Falha' -Detail 'Nao obteve a hora via HTTP' } } catch { Add-FeatureResult -Name 'Data e hora' -Status 'Falha' -Detail $_.Exception.Message } }
                    'srvmgr'      { try { Disable-ServerManagerAutoStart; Add-FeatureResult -Name 'Server Manager no logon (off)' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Server Manager no logon (off)' -Status 'Falha' -Detail $_.Exception.Message } }
                }
            }
            if ($restartExplorer) { Restart-Explorer }
        }
        'updchoco'  { Update-AllChoco }
        'updwinget' { Update-AllWinget }
    }
}

# Sobe o worker: runspace STA que re-hidrata a fonte e roda o laco serial.
# Retorna o handle (ou $null -> fallback sincrono). Estruturas compartilhadas
# por referencia: $LiveLog, $JobQueue, $UiSignals, $Ctrl (flag de stop).
function Start-InstallWorker {
    param($LiveLog, $JobQueue, $UiSignals, $Ctrl, [string] $LogDir)
    $src = Get-InstallerSource
    if (-not $src) { return $null }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $p = $rs.SessionStateProxy
        $p.SetVariable('WINCFG_SRC',    $src)
        $p.SetVariable('WINCFG_LIVE',   $LiveLog)
        $p.SetVariable('WINCFG_QUEUE',  $JobQueue)
        $p.SetVariable('WINCFG_SIGNAL', $UiSignals)
        $p.SetVariable('WINCFG_CTRL',   $Ctrl)
        $p.SetVariable('WINCFG_LOGDIR', $LogDir)
        $env:WINCFG_NOUI = '1'   # impede o tail (na fonte) de abrir 2a janela
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            $env:WINCFG_NOUI = '1'
            # Runspace sem host de UI: silenciar progresso evita que Install-WindowsFeature
            # (Server Manager) e DISM travem esperando um host de Write-Progress inexistente.
            $ProgressPreference = 'SilentlyContinue'
            $WarningPreference  = 'SilentlyContinue'
            # (1) re-hidrata TODAS as funcoes/estado: mesmo texto-fonte da UI.
            try {
                Invoke-Expression $WINCFG_SRC
            } catch {
                try { [void]$WINCFG_LIVE.Add("!! Falha ao re-hidratar o worker: $($_.Exception.Message)") } catch { }
                try { $WINCFG_SIGNAL.Enqueue(@{ Type = 'WorkerDead'; Detail = $_.Exception.Message }) } catch { }
                return
            }
            # (2) religa as estruturas compartilhadas ao $Script: do worker.
            $Script:LiveLog = $WINCFG_LIVE
            $Script:NoConsole = $true   # worker NAO escreve no console (evita travar/lancar)
            if ($WINCFG_LOGDIR) { try { Set-LogDirectory -Path $WINCFG_LOGDIR } catch { } }
            try { Import-UserSoftwareCatalog | Out-Null } catch { }
            # Sinaliza que a re-hidratacao concluiu (a UI so confia no worker apos isso).
            try { [void]$WINCFG_LIVE.Add('==> Worker pronto.') } catch { }
            try { $WINCFG_SIGNAL.Enqueue(@{ Type = 'WorkerReady' }) } catch { }
            # (3) laco serial: 1 job por vez. try/catch externo: nunca morrer calado.
            while (-not $WINCFG_CTRL['Stop']) {
              try {
                $job = $null
                [System.Threading.Monitor]::Enter($WINCFG_QUEUE.SyncRoot)
                try { if ($WINCFG_QUEUE.Count -gt 0) { $job = $WINCFG_QUEUE.Dequeue() } }
                finally { [System.Threading.Monitor]::Exit($WINCFG_QUEUE.SyncRoot) }
                if ($job) {
                    try {
                        $WINCFG_SIGNAL.Enqueue(@{ Type = 'JobStart'; Label = $job.Label; Tab = $job.Tab })
                        try { [void]$WINCFG_LIVE.Add("==> Iniciando: $($job.Label)") } catch { }
                        if ($job.Data -and $job.Data.LogDir) { try { Set-LogDirectory -Path $job.Data.LogDir } catch { } }
                        Invoke-WorkerJob -Job $job
                    } catch {
                        Write-Log "Falha no job '$($job.Label)': $($_.Exception.Message)" -Level ERRO
                    } finally {
                        try { [void]$WINCFG_LIVE.Add("<== Concluido: $($job.Label)") } catch { }
                        # Oferece reinicio se a maquina ficou com reinicio pendente (cobre
                        # tanto features DISM 'PrecisaReinicio' quanto WSL/outros que setam
                        # a flag sem registrar PrecisaReinicio) - so quando a fila esvaziar.
                        $rb = $false
                        try { $rb = [bool](Test-PendingReboot) } catch { }
                        try {
                            if (@($Script:FeatureResults | Where-Object { $_.Status -eq 'PrecisaReinicio' }).Count -gt 0) { $rb = $true }
                        } catch { }
                        $WINCFG_SIGNAL.Enqueue(@{ Type = 'JobDone'; Label = $job.Label; Tab = $job.Tab; Reboot = $rb })
                    }
                } else {
                    Start-Sleep -Milliseconds 150
                }
              } catch {
                try { [void]$WINCFG_LIVE.Add("!! Erro no laco do worker: $($_.Exception.Message)") } catch { }
                Start-Sleep -Milliseconds 200
              }
            }
        })
        $async = $ps.BeginInvoke()
        return [pscustomobject]@{ Rs = $rs; Ps = $ps; Async = $async }
    } catch {
        Write-Log "Worker indisponivel ($($_.Exception.Message)); modo sincrono." -Level WARN
        try { Remove-Item Env:\WINCFG_NOUI -ErrorAction SilentlyContinue } catch { }
        return $null
    }
}

# Avisa que um item precisa reiniciar e REINICIA automaticamente apos uma
# contagem (cancelavel). Chamada SO na thread da UI, quando a fila esvazia e
# algum job registrou 'PrecisaReinicio'. Fechar a janela (X) ou "Adiar" cancela.
function Invoke-RebootOffer {
    param($Owner, [int] $Seconds = 60)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Reinicio necessario" Height="210" Width="470"
        WindowStartupLocation="CenterOwner" Background="#FF1E1E1E" ResizeMode="NoResize">
  <StackPanel Margin="16">
    <TextBlock TextWrapping="Wrap" Foreground="#FFEEEEEE"
               Text="Uma instalacao precisa REINICIAR o servidor para concluir (ex.: Hyper-V)."/>
    <TextBlock x:Name="lblCount" Margin="0,14,0,0" FontWeight="Bold" FontSize="14" Foreground="#FFFFC83D"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
      <Button x:Name="btnNow" Content="Reiniciar agora" Width="140" Height="32" Margin="0,0,8,0" Background="#FF6E1E1E" Foreground="White"/>
      <Button x:Name="btnDefer" Content="Adiar (nao reiniciar)" Width="170" Height="32" Background="#FF3F3F46" Foreground="White"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    try {
        [xml]$xml = $x
        $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
        if ($Owner) { $w.Owner = $Owner }
        $lbl = $w.FindName('lblCount'); $btnNow = $w.FindName('btnNow'); $btnDefer = $w.FindName('btnDefer')
        $st = @{ Remaining = [int]$Seconds; Do = $false }
        $lbl.Text = "Reinicio automatico em $($st.Remaining)s..."
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(1)
        $timer.Add_Tick({
            $st.Remaining = $st.Remaining - 1
            if ($st.Remaining -le 0) { $timer.Stop(); $st.Do = $true; $w.Close() }
            else { $lbl.Text = "Reinicio automatico em $($st.Remaining)s..." }
        }.GetNewClosure())
        $btnNow.Add_Click({ $timer.Stop(); $st.Do = $true; $w.Close() }.GetNewClosure())
        $btnDefer.Add_Click({ $timer.Stop(); $st.Do = $false; $w.Close() }.GetNewClosure())
        $w.Add_Closing({ $timer.Stop() }.GetNewClosure())
        $timer.Start()
        $null = $w.ShowDialog()
        if ($st.Do) {
            Write-Log "Reiniciando o servidor para concluir a instalacao..." -Level WARN
            try { Restart-Computer -Force } catch { Write-Log "Falha ao reiniciar: $($_.Exception.Message)" -Level ERRO }
        } else {
            Write-Log "Reinicio adiado. Reinicie manualmente para concluir a instalacao." -Level INFO
        }
    } catch {
        Write-Log "Nao foi possivel mostrar o aviso de reinicio: $($_.Exception.Message)" -Level WARN
    }
}

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
        <TextBlock x:Name="lblQueueFoot" DockPanel.Dock="Right" VerticalAlignment="Center"
                   Margin="0,0,16,0" Foreground="#FF9CDCFE" Text="Ocioso."/>
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
              <RadioButton x:Name="rbWinget" Content="winget" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center" GroupName="mgr"/>
              <RadioButton x:Name="rbChoco" Content="Chocolatey" Foreground="#FFDDDDDD" IsChecked="True" Margin="8,0" VerticalAlignment="Center" GroupName="mgr"/>
              <RadioButton x:Name="rbAuto" Content="auto" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center" GroupName="mgr"/>
              <Label Content="   Mostrar:" VerticalAlignment="Center"/>
              <RadioButton x:Name="rbFiltAll" Content="todos" Foreground="#FFDDDDDD" IsChecked="True" Margin="8,0" VerticalAlignment="Center" GroupName="filt"/>
              <RadioButton x:Name="rbFiltWinget" Content="so winget" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center" GroupName="filt"/>
              <RadioButton x:Name="rbFiltChoco" Content="so choco" Foreground="#FFDDDDDD" Margin="8,0" VerticalAlignment="Center" GroupName="filt"/>
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
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Margin="12,8">
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,6"
                       Text="Marque as features desejadas (ou use os botoes). 'IIS COMPLETO' instala a lista toda + aspnet_state + iisreset."/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnIisAll" Content="Selecionar tudo" Width="130" Height="28"/>
              <Button x:Name="btnIisNone" Content="Limpar" Width="90" Height="28"/>
              <Button x:Name="btnIisApply" Content="Aplicar selecionados" Width="170" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
              <Button x:Name="btnIisFull" Content="Instalar IIS COMPLETO" Width="180" Height="28"/>
              <Button x:Name="btnAspNet" Content="aspnet_state=Auto" Width="150" Height="28"/>
              <Button x:Name="btnIisReset" Content="iisreset" Width="90" Height="28"/>
            </StackPanel>
            <TextBlock x:Name="lblIis" Margin="0,6,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spIis" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
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

      <TabItem Header="Sistema">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Margin="12,8">
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnSysAll" Content="Selecionar tudo" Width="130" Height="28"/>
              <Button x:Name="btnSysNone" Content="Limpar" Width="90" Height="28"/>
              <Button x:Name="btnSysApply" Content="Aplicar selecionados" Width="180" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
              <Button x:Name="btnStartupUser" Content="Abrir Startup (usuario)" Width="170" Height="28"/>
              <Button x:Name="btnStartupAll" Content="Abrir Startup (todos)" Width="160" Height="28"/>
            </StackPanel>
            <TextBlock x:Name="lblSys" Margin="0,6,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#FF1E1E1E">
            <StackPanel x:Name="spSystem" Margin="12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Atualizacoes">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Margin="12,8">
            <TextBlock TextWrapping="Wrap" Margin="0,0,0,6"
                       Text="Mostra e aplica atualizacoes pendentes do winget e do Chocolatey - inclusive de apps que NAO foram instalados por esta ferramenta. Tudo fica registrado no log."/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnUpdCheck" Content="Ver pendentes" Width="140" Height="28"/>
              <Button x:Name="btnUpdWinget" Content="Atualizar tudo (winget)" Width="180" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
              <Button x:Name="btnUpdChoco" Content="Atualizar tudo (choco)" Width="180" Height="28" Background="#FF1E7D34" BorderBrush="#FF1E7D34"/>
            </StackPanel>
            <TextBlock x:Name="lblUpd" Margin="0,6,0,0" TextWrapping="Wrap" Foreground="#FF9CDCFE"/>
          </StackPanel>
          <TextBox x:Name="txtUpd" Margin="12" IsReadOnly="True" TextWrapping="NoWrap" FontFamily="Consolas"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   Background="#FF252526" Foreground="#FFEEEEEE" BorderBrush="#FF3F3F46"/>
        </DockPanel>
      </TabItem>

      <TabItem Header="Log ao vivo">
        <DockPanel Background="#FF1E1E1E">
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="12,8">
            <TextBlock x:Name="lblQueue" VerticalAlignment="Center" Foreground="#FF9CDCFE" Text="Ocioso."/>
            <Button x:Name="btnLogClear" Content="Limpar painel" Width="120" Height="26" Margin="16,0,0,0"/>
            <Button x:Name="btnCancelQueue" Content="Cancelar fila" Width="120" Height="26"
                    Background="#FF6E1E1E" BorderBrush="#FF6E1E1E"/>
          </StackPanel>
          <TextBox x:Name="txtLive" Margin="12" IsReadOnly="True" TextWrapping="NoWrap" FontFamily="Consolas"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   Background="#FF101010" Foreground="#FFCFCFCF" BorderBrush="#FF3F3F46"/>
        </DockPanel>
      </TabItem>

    </TabControl>
  </DockPanel>
</Window>
'@

    [xml]$xaml = $xamlText
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    # Icone proprio (gordinho desenhado em runtime). Fallback: Server Manager / mmc.
    try {
        $appIcon = New-AppIconImage
        if ($appIcon) {
            $win.Icon = $appIcon
        } else {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $iconExe = "$env:WINDIR\System32\ServerManager.exe"
            if (-not (Test-Path $iconExe)) { $iconExe = "$env:WINDIR\System32\mmc.exe" }
            $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($iconExe)
            if ($ic) {
                $win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                    $ic.Handle, [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            }
        }
    } catch { }

    $txtLog = $win.FindName('txtLog'); $btnClose = $win.FindName('btnClose')
    $lblReboot = $win.FindName('lblReboot'); $spStatus = $win.FindName('spStatus')
    $btnRefresh = $win.FindName('btnRefresh'); $btnClearState = $win.FindName('btnClearState')
    $spFeatures = $win.FindName('spFeatures'); $btnFeatAll = $win.FindName('btnFeatAll'); $btnFeatNone = $win.FindName('btnFeatNone'); $btnFeatApply = $win.FindName('btnFeatApply'); $lblFeat = $win.FindName('lblFeat')
    $rbChoco = $win.FindName('rbChoco'); $rbAuto = $win.FindName('rbAuto')
    $rbFiltAll = $win.FindName('rbFiltAll'); $rbFiltWinget = $win.FindName('rbFiltWinget'); $rbFiltChoco = $win.FindName('rbFiltChoco')
    $spSoftware = $win.FindName('spSoftware'); $btnSoftAll = $win.FindName('btnSoftAll'); $btnSoftNone = $win.FindName('btnSoftNone')
    $btnSoftApply = $win.FindName('btnSoftApply'); $btnAddSoft = $win.FindName('btnAddSoft'); $btnChocoUpg = $win.FindName('btnChocoUpg'); $lblSoft = $win.FindName('lblSoft')
    $spIis = $win.FindName('spIis'); $btnIisAll = $win.FindName('btnIisAll'); $btnIisNone = $win.FindName('btnIisNone'); $btnIisApply = $win.FindName('btnIisApply')
    $btnIisFull = $win.FindName('btnIisFull'); $btnAspNet = $win.FindName('btnAspNet'); $btnIisReset = $win.FindName('btnIisReset'); $lblIis = $win.FindName('lblIis')
    $natName = $win.FindName('natName'); $natSubnet = $win.FindName('natSubnet'); $natGw = $win.FindName('natGw'); $natNetName = $win.FindName('natNetName'); $btnNat = $win.FindName('btnNat')
    $btnDetect = $win.FindName('btnDetect'); $cboNat = $win.FindName('cboNat')
    $dhScope = $win.FindName('dhScope'); $dhMask = $win.FindName('dhMask'); $dhGw = $win.FindName('dhGw')
    $dhFrom = $win.FindName('dhFrom'); $dhTo = $win.FindName('dhTo'); $dhDns = $win.FindName('dhDns'); $dhLease = $win.FindName('dhLease')
    $btnDhcp = $win.FindName('btnDhcp'); $lblNet = $win.FindName('lblNet')
    $spSystem = $win.FindName('spSystem'); $btnSysAll = $win.FindName('btnSysAll'); $btnSysNone = $win.FindName('btnSysNone'); $btnSysApply = $win.FindName('btnSysApply')
    $btnStartupUser = $win.FindName('btnStartupUser'); $btnStartupAll = $win.FindName('btnStartupAll'); $lblSys = $win.FindName('lblSys')
    $btnUpdCheck = $win.FindName('btnUpdCheck'); $btnUpdWinget = $win.FindName('btnUpdWinget'); $btnUpdChoco = $win.FindName('btnUpdChoco')
    $txtUpd = $win.FindName('txtUpd'); $lblUpd = $win.FindName('lblUpd')
    $txtLive = $win.FindName('txtLive'); $lblQueue = $win.FindName('lblQueue')
    $lblQueueFoot = $win.FindName('lblQueueFoot')
    $btnLogClear = $win.FindName('btnLogClear'); $btnCancelQueue = $win.FindName('btnCancelQueue')

    $txtLog.Text = $Script:DefaultLogDir
    $ui = @{ Nets = @(); Iface = '' }

    # Sincroniza o ledger ($Script:StateFile/$Script:LogFile) da thread da UI com a
    # pasta de log efetiva ANTES do primeiro repaint. Sem isso, no caminho async a UI
    # leria de uma pasta (derivada de $PSScriptRoot no init de Common.ps1) diferente da
    # que o worker grava ($job.Data.LogDir = DefaultLogDir), e a aba Status / marcas
    # '[feito em ...]' nunca refletiriam o que o worker acabou de fazer.
    if ($txtLog.Text.Trim()) { try { Set-LogDirectory -Path $txtLog.Text.Trim() } catch { } }

    Add-WpfFeatureItems $spFeatures $win
    Add-WpfSoftwareItems $spSoftware 'all' $win
    Add-WpfIisItems $spIis $win
    Add-WpfSystemItems $spSystem $win
    Set-WpfStatusPanel $spStatus $lblReboot

    # Botoes que devem ser desabilitados durante uma operacao.
    $actionButtons = @($btnFeatApply, $btnFeatAll, $btnFeatNone, $btnSoftApply, $btnSoftAll, $btnSoftNone,
        $btnChocoUpg, $btnAddSoft, $btnIisApply, $btnIisAll, $btnIisNone, $btnIisFull, $btnAspNet, $btnIisReset,
        $btnNat, $btnDetect, $btnDhcp, $btnSysApply, $btnSysAll, $btnSysNone, $btnStartupUser, $btnStartupAll,
        $btnUpdCheck, $btnUpdWinget, $btnUpdChoco)
    $setBusy = { param([bool] $b) foreach ($x in $actionButtons) { if ($x) { $x.IsEnabled = -not $b } } }
    $applyLog = { if ($txtLog.Text.Trim()) { Set-LogDirectory -Path $txtLog.Text.Trim() } }
    $softFilter = { if ($rbFiltWinget.IsChecked) { 'winget' } elseif ($rbFiltChoco.IsChecked) { 'choco' } else { 'all' } }

    # ---- Async: fila serial + worker em runspace + log ao vivo ----
    $Script:LiveLog = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    # IMPORTANTE: o DispatcherTimer e criado com .GetNewClosure(), e um $Script:
    # setado DENTRO desta funcao NAO e visivel la dentro (vira uma var vazia). Por
    # isso o timer le este ALIAS LOCAL (mesmo objeto), igual ao $uiSignals/$jobQueue.
    $liveSink  = $Script:LiveLog
    $jobQueue  = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    $uiSignals = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    $ctrl      = [hashtable]::Synchronized(@{ Stop = $false })
    # Estado compartilhado entre TODOS os closures (.GetNewClosure() nao compartilha
    # $Script:; hashtable LOCAL e compartilhada por referencia - igual a $jobQueue).
    $uiState = [hashtable]::Synchronized(@{ CurrentJobLabel = $null; RebootRequested = $false; DrainBusy = $false; WorkerReady = $false; ModalOpen = $false; Pending = 0; UseWorker = $false })
    $defaultLogDir = $Script:DefaultLogDir

    $logDir0 = if ($txtLog.Text.Trim()) { $txtLog.Text.Trim() } else { $defaultLogDir }
    $worker  = Start-InstallWorker -LiveLog $Script:LiveLog -JobQueue $jobQueue -UiSignals $uiSignals -Ctrl $ctrl -LogDir $logDir0
    $uiState.UseWorker = [bool]$worker

    # Enfileira um job declarativo (chamado pelos handlers apos Confirm-Wpf).
    # Injeta a pasta de log atual no job -> o worker aplica antes de executar.
    $enqueue = {
        param([string] $Kind, $Data, [string] $Tab, [string] $Label)
        if (-not $Data) { $Data = @{} }
        $Data.LogDir = if ($txtLog.Text.Trim()) { $txtLog.Text.Trim() } else { $defaultLogDir }
        # Mantem o ledger da UI apontando para o MESMO installer-state.json que o worker
        # vai gravar (Data.LogDir). Assim o repaint pos-job (Set-WpfStatusPanel /
        # Get-InstalledStateMap) le o arquivo correto, inclusive se o usuario mudou a pasta.
        try { Set-LogDirectory -Path $Data.LogDir } catch { }
        $jobQueue.Enqueue(@{ Kind = $Kind; Data = $Data; Tab = $Tab; Label = $Label })
        # Desabilita os botoes enquanto houver job(s) enfileirado(s) -> evita duplo-enqueue.
        $uiState.Pending = [int]$uiState.Pending + 1
        & $setBusy $true
        $n = $jobQueue.Count
        $lblQueueFoot.Text = "Na fila: $n"
    }.GetNewClosure()

    # Repinta a aba afetada por um job (roda SEMPRE na thread da UI).
    $repaintTab = {
        param([string] $Tab)
        Set-WpfStatusPanel $spStatus $lblReboot
        switch ($Tab) {
            'Features'  { Add-WpfFeatureItems $spFeatures $win }
            'Softwares' { Add-WpfSoftwareItems $spSoftware (& $softFilter) $win }
            'IIS'       { Add-WpfIisItems $spIis $win }
            'Sistema'   { Add-WpfSystemItems $spSystem $win }
        }
    }.GetNewClosure()

    # DispatcherTimer: drena LiveLog -> painel e UiSignals -> repintura. Roda na
    # thread do Dispatcher (UI), entao mexer em controles WPF aqui e seguro.
    $logTimer = New-Object System.Windows.Threading.DispatcherTimer
    $logTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $logTimer.Add_Tick({
        if ($uiState.DrainBusy -or $uiState.ModalOpen) { return }
        $uiState.DrainBusy = $true
        try {
            # (a) log ao vivo: snapshot + clear sob lock (nao perde linhas)
            if ($liveSink.Count -gt 0) {
                $chunk = $null
                [System.Threading.Monitor]::Enter($liveSink.SyncRoot)
                try { $chunk = @($liveSink.ToArray()); $liveSink.Clear() }
                finally { [System.Threading.Monitor]::Exit($liveSink.SyncRoot) }
                if ($chunk -and $chunk.Count) {
                    $txtLive.AppendText(($chunk -join "`r`n") + "`r`n")
                    if ($txtLive.Text.Length -gt 200000) { $txtLive.Text = $txtLive.Text.Substring($txtLive.Text.Length - 120000) }
                    $txtLive.ScrollToEnd()
                }
            }
            # (b) sinais do worker
            while ($uiSignals.Count -gt 0) {
                $s = $null
                [System.Threading.Monitor]::Enter($uiSignals.SyncRoot)
                try { if ($uiSignals.Count -gt 0) { $s = $uiSignals.Dequeue() } }
                finally { [System.Threading.Monitor]::Exit($uiSignals.SyncRoot) }
                if (-not $s) { break }
                if ($s.Type -eq 'WorkerReady') { $uiState.WorkerReady = $true; continue }
                if ($s.Type -eq 'WorkerDead') {
                    $uiState.UseWorker = $false
                    $uiState.WorkerReady = $false
                    # O worker morreu sem reprocessar o que ja foi aceito: descarta os
                    # jobs orfaos da fila, zera o contador de pendentes e reabilita os
                    # botoes (senao a UI trava IsEnabled=$false para sempre).
                    [System.Threading.Monitor]::Enter($jobQueue.SyncRoot)
                    try { $jobQueue.Clear() } finally { [System.Threading.Monitor]::Exit($jobQueue.SyncRoot) }
                    $uiState.CurrentJobLabel = $null
                    $uiState.Pending = 0
                    & $setBusy $false
                    $lblQueue.Text = 'Ocioso.'
                    $lblQueueFoot.Text = 'Ocioso.'
                    $txtLive.AppendText("[modo sincrono] worker falhou: $($s.Detail) - fila descartada, use novamente (modo sincrono).`r`n")
                    continue
                }
                if ($s.Type -eq 'JobStart') { $uiState.CurrentJobLabel = $s.Label }
                elseif ($s.Type -eq 'JobDone') {
                    $uiState.CurrentJobLabel = $null
                    $uiState.Pending = [Math]::Max(0, [int]$uiState.Pending - 1)
                    if ($uiState.Pending -le 0) { & $setBusy $false }
                    if ($s.Reboot) { $uiState.RebootRequested = $true }
                    & $repaintTab $s.Tab
                    # Confirma na propria aba que o job terminou (sem isso o rotulo
                    # ficava parado em "Enfileirado..." e parecia que nada acontecia).
                    $doneMsg = "Concluido: $($s.Label). Veja 'Log ao vivo' / aba Status."
                    switch ($s.Tab) {
                        'Features'     { $lblFeat.Text = $doneMsg }
                        'Softwares'    { $lblSoft.Text = $doneMsg }
                        'IIS'          { $lblIis.Text  = $doneMsg }
                        'Sistema'      { $lblSys.Text  = $doneMsg }
                        'Rede'         { $lblNet.Text  = $doneMsg }
                        'Atualizacoes' { $lblUpd.Text  = $doneMsg }
                    }
                }
            }
            # (c) indicador de fila
            $n = $jobQueue.Count
            $cur = $uiState.CurrentJobLabel
            $txt = if ($cur) { "Executando: $cur   |   Na fila: $n" }
                   elseif ($n -gt 0) { "Na fila: $n" } else { 'Ocioso.' }
            $lblQueue.Text = $txt
            $lblQueueFoot.Text = $txt
            # (d) reinicio: oferece SO quando a fila esvazia e um job pediu reinicio
            if ($uiState.RebootRequested -and $jobQueue.Count -eq 0 -and -not $uiState.CurrentJobLabel) {
                $uiState.RebootRequested = $false
                # Enfileira o modal para DEPOIS deste Tick terminar (nao bloqueia o drain).
                $null = $win.Dispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::Background,
                    [action]{ Invoke-RebootOffer $win })
            }
        } finally { $uiState.DrainBusy = $false }
    }.GetNewClosure())
    $logTimer.Start()
    if (-not $uiState.UseWorker) {
        $txtLive.AppendText("[modo sincrono] worker indisponivel - a janela pode congelar durante operacoes longas.`r`n")
    }

    $btnLogClear.Add_Click({ $txtLive.Clear() })
    $btnCancelQueue.Add_Click({
        [System.Threading.Monitor]::Enter($jobQueue.SyncRoot)
        try { $jobQueue.Clear() } finally { [System.Threading.Monitor]::Exit($jobQueue.SyncRoot) }
        $txtLive.AppendText("[fila] pendentes descartados (o job atual continua ate terminar).`r`n")
    }.GetNewClosure())

    # --- Status ---
    $btnRefresh.Add_Click({ Set-WpfStatusPanel $spStatus $lblReboot })
    $btnClearState.Add_Click({ Clear-FeatureState; Set-WpfStatusPanel $spStatus $lblReboot })
    $btnClose.Add_Click({ $win.Close() })

    # --- Features ---
    $btnFeatAll.Add_Click({ Set-WpfAllChecks $spFeatures $true })
    $btnFeatNone.Add_Click({ Set-WpfAllChecks $spFeatures $false })
    $btnFeatApply.Add_Click({
        $ids = @(Get-WpfCheckedTags $spFeatures)
        if ($ids.Count -eq 0) { $lblFeat.Text = 'Nada selecionado.'; return }
        $names = @($ids | ForEach-Object { $id = $_; ($Script:CapabilityCatalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1).Display })
        if (-not (Confirm-Wpf "Aplicar estas $($ids.Count) feature(s)?`n$(Format-ConfirmList $names)")) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'features' @{ Ids = $ids } 'Features' "Features ($($ids.Count))"
            $lblFeat.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
                Invoke-CapabilityInstall -Ids $ids; $lblFeat.Text = Get-SummaryText
            } catch { $lblFeat.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfFeatureItems $spFeatures $win; if (Test-PendingReboot) { Invoke-RebootOffer $win } }
        }
    })

    # --- Softwares ---
    $btnSoftAll.Add_Click({ Set-WpfAllChecks $spSoftware $true })
    $btnSoftNone.Add_Click({ Set-WpfAllChecks $spSoftware $false })
    $rbFiltAll.Add_Checked({ Add-WpfSoftwareItems $spSoftware 'all' $win })
    $rbFiltWinget.Add_Checked({ Add-WpfSoftwareItems $spSoftware 'winget' $win })
    $rbFiltChoco.Add_Checked({ Add-WpfSoftwareItems $spSoftware 'choco' $win })
    $btnAddSoft.Add_Click({
        $r = Show-AddSoftwareDialog -Owner $win
        if ($r) {
            if (Add-UserSoftware -Name $r.Name -Category $r.Category -Winget $r.Winget -Choco $r.Choco -Notes $r.Notes) {
                Add-WpfSoftwareItems $spSoftware (& $softFilter) $win
                $lblSoft.Text = "Adicionado: $($r.Name). Marque e clique 'Aplicar selecionados'."
            } else { $lblSoft.Text = 'Falha ao adicionar (ver log).' }
        }
    })
    $btnChocoUpg.Add_Click({
        if (-not (Confirm-Wpf 'Executar "choco upgrade all"? Pode demorar.')) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'updchoco' @{} 'Softwares' 'choco upgrade all'
            $lblSoft.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog; Update-AllChoco; $lblSoft.Text = 'choco upgrade all executado (ver log/console).' }
            catch { $lblSoft.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false }
        }
    })
    $btnSoftApply.Add_Click({
        $keys = @(Get-WpfCheckedTags $spSoftware)
        if ($keys.Count -eq 0) { $lblSoft.Text = 'Nada selecionado.'; return }
        $names = @($keys | ForEach-Object { $k = $_; ($Script:SoftwareCatalog | Where-Object { $_.Key -eq $k } | Select-Object -First 1).Name })
        if (-not (Confirm-Wpf "Instalar estes $($keys.Count) software(s)?`n$(Format-ConfirmList $names)")) { return }
        $pref = if ($rbChoco.IsChecked) { 'choco' } elseif ($rbAuto.IsChecked) { 'auto' } else { 'winget' }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'software' @{ Keys = $keys; Pref = $pref } 'Softwares' "Softwares ($($keys.Count))"
            $lblSoft.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
                Reset-FeatureSession
                foreach ($k in $keys) {
                    $pkg = $Script:SoftwareCatalog | Where-Object { $_.Key -eq $k }
                    if ($pkg) { Install-SoftwarePackage -Pkg $pkg -Preferred $pref }
                }
                Show-FeaturesSummary; $lblSoft.Text = Get-SummaryText
            } catch { $lblSoft.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfSoftwareItems $spSoftware (& $softFilter) $win }
        }
    })

    # --- IIS ---
    $btnIisAll.Add_Click({ Set-WpfAllChecks $spIis $true })
    $btnIisNone.Add_Click({ Set-WpfAllChecks $spIis $false })
    $btnIisApply.Add_Click({
        $tags = @(Get-WpfCheckedTags $spIis)
        $feats = @($tags | Where-Object { $_ -notlike '__*' })
        $doAspnet = $tags -contains '__aspnet_state__'
        $doReset  = $tags -contains '__iisreset__'
        if ($feats.Count -eq 0 -and -not $doAspnet -and -not $doReset) { $lblIis.Text = 'Nada selecionado.'; return }
        $lst = @($feats); if ($doAspnet) { $lst += 'aspnet_state = Automatico' }; if ($doReset) { $lst += 'iisreset' }
        if (-not (Confirm-Wpf "Aplicar no IIS ($($lst.Count) item(ns))?`n$(Format-ConfirmList $lst)")) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'iis' @{ Feats = $feats; Aspnet = $doAspnet; Reset = $doReset } 'IIS' "IIS ($($lst.Count))"
            $lblIis.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
                Reset-FeatureSession
                foreach ($f in $feats) { Enable-OptionalFeatureSafe -FeatureName $f -All }   # ordem = $IISFeatures
                if ($doAspnet) { Set-AspNetStateAuto }
                if ($doReset)  { Invoke-IISReset }
                Show-FeaturesSummary; $lblIis.Text = Get-SummaryText
            } catch { $lblIis.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfIisItems $spIis $win; if (Test-PendingReboot) { Invoke-RebootOffer $win } }
        }
    })
    $btnIisFull.Add_Click({
        if (-not (Confirm-Wpf "Instalar IIS COMPLETO ($($Script:IISFeatures.Count) features) + aspnet_state + iisreset? Pode demorar.")) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'iisfull' @{} 'IIS' 'IIS COMPLETO'
            $lblIis.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog; Reset-FeatureSession; Install-IISFull; Show-FeaturesSummary; $lblIis.Text = Get-SummaryText }
            catch { $lblIis.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfIisItems $spIis $win; if (Test-PendingReboot) { Invoke-RebootOffer $win } }
        }
    })
    $btnAspNet.Add_Click({
        if (-not (Confirm-Wpf 'Definir o servico aspnet_state como Automatico?')) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'aspnet' @{} 'IIS' 'aspnet_state=Auto'
            $lblIis.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; & $applyLog; Set-AspNetStateAuto; $lblIis.Text = 'aspnet_state configurado (ver log).' }
            catch { $lblIis.Text = "Erro: $($_.Exception.Message)" } finally { & $setBusy $false }
        }
    })
    $btnIisReset.Add_Click({
        if (-not (Confirm-Wpf 'Executar iisreset agora?')) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'iisreset' @{} 'IIS' 'iisreset'
            $lblIis.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; & $applyLog; Invoke-IISReset; $lblIis.Text = 'iisreset executado (ver log).' }
            catch { $lblIis.Text = "Erro: $($_.Exception.Message)" } finally { & $setBusy $false }
        }
    })

    # --- Rede: NAT ---
    $btnNat.Add_Click({
        if (-not (Confirm-Wpf "Criar/atualizar o NAT Switch '$($natName.Text.Trim())' ($($natSubnet.Text.Trim()))?")) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'nat' @{ SwitchName = $natName.Text.Trim(); Subnet = $natSubnet.Text.Trim(); GatewayIP = $natGw.Text.Trim(); NatName = $natNetName.Text.Trim() } 'Rede' "NAT Switch '$($natName.Text.Trim())'"
            $lblNet.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
                Reset-FeatureSession
                if ($natNetName.Text.Trim()) {
                    New-NatSwitch -SwitchName $natName.Text.Trim() -Subnet $natSubnet.Text.Trim() -GatewayIP $natGw.Text.Trim() -NatName $natNetName.Text.Trim()
                } else {
                    New-NatSwitch -SwitchName $natName.Text.Trim() -Subnet $natSubnet.Text.Trim() -GatewayIP $natGw.Text.Trim()
                }
                $lblNet.Text = Get-SummaryText
            } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot }
        }
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
            $ui.Nets = $nets; $cboNat.Items.Clear()
            if ($nets.Count -eq 0) { $lblNet.Text = 'Nenhuma rede NAT detectada. Crie o NAT Switch acima primeiro.'; return }
            foreach ($n in $nets) { [void]$cboNat.Items.Add("$($n.ScopeId)/$($n.PrefixLength)  (gw $($n.GatewayIP))") }
            $cboNat.SelectedIndex = 0
            $lblNet.Text = "$($nets.Count) rede(s) NAT detectada(s). Campos preenchidos pela selecionada."
        } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
    })
    $btnDhcp.Add_Click({
        if (-not (Confirm-Wpf "Instalar/configurar o DHCP para o NAT ($($dhScope.Text.Trim()))?")) { return }
        # Descoberta da interface fica na UI (precisa do estado de $ui / catalogo de rede).
        $iface = $ui.Iface
        if (-not $iface) {
            try {
                $m = Get-NatNetworkInfo | Where-Object { $_.ScopeId -eq $dhScope.Text.Trim() } | Select-Object -First 1
                if ($m) { $iface = $m.InterfaceAlias }
            } catch { }
        }
        if (-not $iface) { $lblNet.Text = 'Clique "Detectar rede NAT" antes de aplicar o DHCP.'; return }
        $lease = 7300; $tmp = 0
        if ([int]::TryParse($dhLease.Text.Trim(), [ref]$tmp) -and $tmp -gt 0) { $lease = $tmp }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'dhcp' @{ ScopeId = $dhScope.Text.Trim(); Mask = $dhMask.Text.Trim(); RangeFrom = $dhFrom.Text.Trim(); RangeTo = $dhTo.Text.Trim(); Gateway = $dhGw.Text.Trim(); Dns = $dhDns.Text.Trim(); Iface = $iface; LeaseDays = $lease } 'Rede' "DHCP NAT ($($dhScope.Text.Trim()))"
            $lblNet.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
                Reset-FeatureSession
                if (-not (Install-DhcpRoleForNat)) { $lblNet.Text = (Get-SummaryText) + "`nSe foi pedido reinicio: reinicie e rode de novo."; return }
                Set-NatDhcpScope -ScopeId $dhScope.Text.Trim() -Mask $dhMask.Text.Trim() `
                    -RangeFrom $dhFrom.Text.Trim() -RangeTo $dhTo.Text.Trim() `
                    -Gateway $dhGw.Text.Trim() -Dns $dhDns.Text.Trim() -NatIface $iface -LeaseDays $lease
                $lblNet.Text = Get-SummaryText
            } catch { $lblNet.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot }
        }
    })

    # --- Sistema (Customizacoes + Config base unificadas) ---
    $btnSysAll.Add_Click({ Set-WpfAllChecks $spSystem $true })
    $btnSysNone.Add_Click({ Set-WpfAllChecks $spSystem $false })
    $btnStartupUser.Add_Click({ Open-StartupFolders })
    $btnStartupAll.Add_Click({ Open-StartupFolders -AllUsers })
    $btnSysApply.Add_Click({
        $tags = @(Get-WpfCheckedTags $spSystem)
        if ($tags.Count -eq 0) { $lblSys.Text = 'Nada selecionado.'; return }
        if (-not (Confirm-Wpf "Aplicar os $($tags.Count) item(ns) marcado(s)?")) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'system' @{ Tags = $tags } 'Sistema' "Sistema ($($tags.Count))"
            $lblSys.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
            return
        }
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            Reset-FeatureSession
            $restartExplorer = $false
            foreach ($t in $tags) {
                switch ($t) {
                    'dark'        { $c = Enable-DarkMode;        Add-FeatureResult -Name 'Dark Mode' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $restartExplorer = $restartExplorer -or $c }
                    'ext'         { $c = Show-FileExtensions;    Add-FeatureResult -Name 'Mostrar extensoes' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $restartExplorer = $restartExplorer -or $c }
                    'hidden'      { $c = Show-HiddenFiles;       Add-FeatureResult -Name 'Mostrar ocultos' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $restartExplorer = $restartExplorer -or $c }
                    'superhidden' { $c = Show-HiddenFiles -IncludeProtectedOsFiles; Add-FeatureResult -Name 'Mostrar ocultos (+protegidos)' -Status $(if ($c) {'Instalado'} else {'JaPresente'}); $restartExplorer = $restartExplorer -or $c }
                    'printscr'    { $c = Disable-PrintScreenSnipping; Add-FeatureResult -Name 'Print Screen (Snipping off)' -Status $(if ($c) {'Instalado'} else {'JaPresente'}) }
                    'ieesc'       { try { Disable-IEEsc;                 Add-FeatureResult -Name 'IE ESC desativado' -Status 'Instalado' } catch { Add-FeatureResult -Name 'IE ESC desativado' -Status 'Falha' -Detail $_.Exception.Message } }
                    'tz'          { try { Set-TimeZoneBrasilia;          Add-FeatureResult -Name 'Time zone Brasilia' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Time zone Brasilia' -Status 'Falha' -Detail $_.Exception.Message } }
                    'datetime'    { try { if (Sync-DateTime) { Add-FeatureResult -Name 'Data e hora' -Status 'Instalado' } else { Add-FeatureResult -Name 'Data e hora' -Status 'Falha' -Detail 'Nao obteve a hora via HTTP' } } catch { Add-FeatureResult -Name 'Data e hora' -Status 'Falha' -Detail $_.Exception.Message } }
                    'srvmgr'      { try { Disable-ServerManagerAutoStart; Add-FeatureResult -Name 'Server Manager no logon (off)' -Status 'Instalado' } catch { Add-FeatureResult -Name 'Server Manager no logon (off)' -Status 'Falha' -Detail $_.Exception.Message } }
                }
            }
            if ($restartExplorer) { Restart-Explorer }
            $lblSys.Text = if ($Script:FeatureResults.Count) { Get-SummaryText } else { 'Nada aplicado.' }
        } catch { $lblSys.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false; Set-WpfStatusPanel $spStatus $lblReboot; Add-WpfSystemItems $spSystem $win }
    })

    # --- Atualizacoes (winget + choco) ---
    $btnUpdCheck.Add_Click({
        try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog
            $w1 = Get-WingetUpgrades; $c1 = Get-ChocoOutdated
            $txtUpd.Text = "===== WINGET (winget upgrade) =====`r`n$w1`r`n`r`n===== CHOCOLATEY (choco outdated) =====`r`n$c1"
            $lblUpd.Text = 'Lista de pendentes atualizada (ver tambem o log).'
        } catch { $lblUpd.Text = "Erro: $($_.Exception.Message)" }
        finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false }
    })
    $btnUpdWinget.Add_Click({
        if (-not (Confirm-Wpf 'Atualizar TUDO que o winget tem pendente? Pode demorar.')) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'updwinget' @{} 'Atualizacoes' 'winget upgrade --all'
            $lblUpd.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog; Update-AllWinget; $lblUpd.Text = 'winget upgrade --all executado (ver log/console).' }
            catch { $lblUpd.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false }
        }
    })
    $btnUpdChoco.Add_Click({
        if (-not (Confirm-Wpf 'Atualizar TUDO que o choco tem pendente? Pode demorar.')) { return }
        if ($uiState.UseWorker -and $uiState.WorkerReady) {
            & $enqueue 'updchoco' @{} 'Atualizacoes' 'choco upgrade all'
            $lblUpd.Text = "Enfileirado (fila: $($jobQueue.Count)). Veja 'Log ao vivo'."
        } else {
            try { & $setBusy $true; $win.Cursor = [System.Windows.Input.Cursors]::Wait; & $applyLog; Update-AllChoco; $lblUpd.Text = 'choco upgrade all executado (ver log/console).' }
            catch { $lblUpd.Text = "Erro: $($_.Exception.Message)" }
            finally { $win.Cursor = [System.Windows.Input.Cursors]::Arrow; & $setBusy $false }
        }
    })

    $win.Add_Closing({
        if (($jobQueue.Count -gt 0 -or $uiState.CurrentJobLabel) -and
            -not (Confirm-Wpf 'Ha instalacao em andamento ou na fila. Fechar pode interromper. Sair?')) {
            $_.Cancel = $true; return
        }
        try { $logTimer.Stop() } catch { }
        $ctrl['Stop'] = $true
        try { if ($worker) { $worker.Ps.Stop(); $worker.Rs.Close(); $worker.Rs.Dispose() } } catch { }
        try { Remove-Item Env:\WINCFG_NOUI -ErrorAction SilentlyContinue } catch { }
    }.GetNewClosure())

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
