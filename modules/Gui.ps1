# ============================================================================
#  Gui.ps1  -  Tela clicavel (WinForms) com fallback de console
#  Depende de Common.ps1 e OSCommon.ps1 (Get-AvailableCapabilities,
#  Invoke-CapabilityInstall, Set-LogDirectory, $Script:FeatureResults).
#
#  Modelo: a tela e para SELECAO (o que instalar + pasta de log). A instalacao
#  roda depois que a tela fecha, com log ao vivo no console (Write-Log) e um
#  resumo final em MessageBox. Isso evita o congelamento da UI e a complexidade
#  de compartilhar funcoes entre runspaces sob 'irm | iex'.
# ============================================================================

# Le uma linha do console. Sob 'irm | iex' o pipeline carrega o corpo do script,
# entao Read-Host pode falhar; [Console]::ReadLine() e mais robusto.
function Read-Line {
    param([string] $Prompt)
    if ($Prompt) { Write-Host $Prompt -NoNewline }
    try { return [Console]::ReadLine() } catch { return (Read-Host) }
}

# Monta o texto do resumo (categorizado) a partir de $Script:FeatureResults.
function Get-SummaryText {
    if (-not $Script:FeatureResults -or $Script:FeatureResults.Count -eq 0) {
        return 'Nenhuma acao executada.'
    }
    $groups = @(
        @{ Label = 'Instalados / ja presentes';        Status = @('Instalado','JaPresente') }
        @{ Label = 'Precisam de REINICIO';             Status = @('PrecisaReinicio') }
        @{ Label = 'Deferidos (reinicio pendente)';    Status = @('Deferido') }
        @{ Label = 'Falhas';                           Status = @('Falha') }
    )
    $sb = New-Object System.Text.StringBuilder
    foreach ($g in $groups) {
        $items = $Script:FeatureResults | Where-Object { $g.Status -contains $_.Status }
        if ($items) {
            [void]$sb.AppendLine($g.Label + ':')
            foreach ($i in $items) {
                $d = if ($i.Detail) { "  ($($i.Detail))" } else { '' }
                [void]$sb.AppendLine('   - ' + $i.Name + $d)
            }
            [void]$sb.AppendLine('')
        }
    }
    return $sb.ToString()
}

# --- Tela WinForms ----------------------------------------------------------
# Retorna [PSCustomObject]@{ Ids=@(...); LogDir='...' } ou $null se cancelado.
function Show-InstallerGui {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $caps = @(Get-AvailableCapabilities)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Configurador Windows'
    $form.Size = New-Object System.Drawing.Size(540, 580)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Selecione o que instalar/configurar:'
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.AutoSize = $true
    $form.Controls.Add($lbl)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(12, 36)
    $clb.Size = New-Object System.Drawing.Size(500, 360)
    $clb.CheckOnClick = $true
    foreach ($c in $caps) {
        $txt = "{0}   [{1}]" -f $c.Display, $c.Category
        if ($c.Notes) { $txt += "  - $($c.Notes)" }
        [void]$clb.Items.Add($txt)
    }
    $form.Controls.Add($clb)

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = 'Selecionar tudo'
    $btnAll.Location = New-Object System.Drawing.Point(12, 404)
    $btnAll.Size = New-Object System.Drawing.Size(120, 28)
    $btnAll.Add_Click({
        $allChecked = $true
        for ($i = 0; $i -lt $clb.Items.Count; $i++) { if (-not $clb.GetItemChecked($i)) { $allChecked = $false; break } }
        for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, -not $allChecked) }
    })
    $form.Controls.Add($btnAll)

    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = 'Pasta de log:'
    $lblLog.Location = New-Object System.Drawing.Point(12, 446)
    $lblLog.AutoSize = $true
    $form.Controls.Add($lblLog)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(12, 468)
    $logBox.Size = New-Object System.Drawing.Size(500, 24)
    $logBox.Text = $Script:DefaultLogDir
    $form.Controls.Add($logBox)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = 'Instalar'
    $btnInstall.Location = New-Object System.Drawing.Point(316, 506)
    $btnInstall.Size = New-Object System.Drawing.Size(95, 32)
    $btnInstall.Add_Click({
        $ids = @()
        for ($i = 0; $i -lt $clb.Items.Count; $i++) {
            if ($clb.GetItemChecked($i)) { $ids += $caps[$i].Id }
        }
        if ($ids.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Selecione ao menos um item.', 'Atencao') | Out-Null
            return
        }
        $form.Tag = [PSCustomObject]@{ Ids = $ids; LogDir = $logBox.Text.Trim() }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnInstall)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancelar'
    $btnCancel.Location = New-Object System.Drawing.Point(417, 506)
    $btnCancel.Size = New-Object System.Drawing.Size(95, 32)
    $btnCancel.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.Controls.Add($btnCancel)

    $dr = $form.ShowDialog()
    if ($dr -eq [System.Windows.Forms.DialogResult]::OK) { return $form.Tag }
    return $null
}

# --- Fallback de console (Server Core / headless / sem STA) ------------------
# Retorna [PSCustomObject]@{ Ids=@(...); LogDir='...' } ou $null.
function Show-InstallerConsole {
    $caps = @(Get-AvailableCapabilities)

    Write-Host ""
    Write-Host "============ Configurador Windows (console) ============" -ForegroundColor Cyan
    Write-Host "Capacidades disponiveis neste SO:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $caps.Count; $i++) {
        $c = $caps[$i]
        $note = if ($c.Notes) { " - $($c.Notes)" } else { '' }
        Write-Host ("  {0,2}) {1,-32} [{2}]{3}" -f ($i + 1), $c.Display, $c.Category, $note)
    }
    Write-Host ""
    Write-Host "Digite os numeros separados por virgula (ex.: 1,3,5) ou 'tudo'." -ForegroundColor Yellow
    $resp = (Read-Line "Selecao: ").Trim()
    if (-not $resp) { return $null }

    $ids = @()
    if ($resp -match '^(tudo|all)$') {
        $ids = $caps | ForEach-Object { $_.Id }
    } else {
        foreach ($tok in ($resp -split '[,\s]+')) {
            if ($tok -match '^\d+$') {
                $idx = [int]$tok - 1
                if ($idx -ge 0 -and $idx -lt $caps.Count) { $ids += $caps[$idx].Id }
            }
        }
    }
    $ids = $ids | Select-Object -Unique
    if (-not $ids -or @($ids).Count -eq 0) { return $null }

    Write-Host ""
    $logDir = (Read-Line "Pasta de log (ENTER = $($Script:DefaultLogDir)): ").Trim()
    if (-not $logDir) { $logDir = $Script:DefaultLogDir }

    return [PSCustomObject]@{ Ids = @($ids); LogDir = $logDir }
}

# --- Orquestrador: escolhe GUI vs console e roda a instalacao ----------------
function Start-InstallerUi {
    $useGui = (Get-OSRole).CanUseGui

    $sel = $null
    if ($useGui) {
        try { $sel = Show-InstallerGui }
        catch {
            Write-Log "GUI indisponivel ($($_.Exception.Message)) - caindo para console." -Level WARN
            $useGui = $false
            $sel = Show-InstallerConsole
        }
    } else {
        $sel = Show-InstallerConsole
    }

    if (-not $sel -or -not $sel.Ids -or @($sel.Ids).Count -eq 0) {
        Write-Log "Nenhum item selecionado. Saindo." -Level INFO
        return
    }

    if ($sel.LogDir) { Set-LogDirectory -Path $sel.LogDir }

    Invoke-CapabilityInstall -Ids $sel.Ids

    $summary = Get-SummaryText
    if ($useGui) {
        try { [System.Windows.Forms.MessageBox]::Show($summary, 'Resumo da instalacao') | Out-Null } catch { }
    }
}

# --- Menu principal (compartilhado por setup.ps1 e pelo bundle irm) ----------
# Fica aqui (modulo empacotado) para o lancador 'irm | iex' poder abrir o MESMO
# menu completo do setup.ps1, e nao apenas a tela de capacidades. Depende das
# funcoes Invoke-*Menu dos modulos de area (ja carregados quando isto roda).
function Show-MainMenu {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   Configurador Windows Server  -  $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  CUSTOMIZACOES (Explorer / UI)"
    Write-Host "    1) Aplicar TODAS as customizacoes (dark mode + extensoes + ocultos)"
    Write-Host "    2) Ativar Dark Mode"
    Write-Host "    3) Mostrar extensoes de arquivos"
    Write-Host "    4) Mostrar arquivos ocultos"
    Write-Host ""
    Write-Host "  OUTRAS AREAS"
    Write-Host "    5) IIS / Servidor Web"
    Write-Host "    6) Funcoes/Recursos do Windows"
    Write-Host "    7) Softwares / Runtimes"
    Write-Host "    8) Config. base"
    Write-Host ""
    Write-Host "  INSTALACAO RAPIDA"
    Write-Host "    9) Tela de capacidades (GUI ou console)"
    Write-Host ""
    Write-Host "    0) Sair"
    Write-Host ""
}

function Start-MainMenu {
    do {
        Show-MainMenu
        $opt = Read-Host "Escolha uma opcao"

        switch ($opt) {
            '1' { Invoke-AllCustomizations }
            '2' { if (Enable-DarkMode)     { Restart-Explorer } }
            '3' { if (Show-FileExtensions) { Restart-Explorer } }
            '4' { if (Show-HiddenFiles)    { Restart-Explorer } }
            '5' { Invoke-IISMenu }
            '6' { Invoke-FeaturesMenu }
            '7' { Invoke-SoftwareMenu }
            '8' { Invoke-BaseConfigMenu }
            '9' { Start-InstallerUi }
            '0' { Write-Log "Saindo." -Level INFO }
            default { Write-Host "Opcao invalida." -ForegroundColor Red }
        }

        if ($opt -ne '0') {
            Write-Host ""
            Read-Host "Pressione ENTER para voltar ao menu"
        }
    } while ($opt -ne '0')
}
