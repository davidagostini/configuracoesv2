#Requires -Version 5.1
<#
============================================================================
  build.ps1  -  Gera o bundle unico dist/bootstrap.ps1 + SHA256
============================================================================
  Os modulos separados (modules\*.ps1) sao a FONTE de manutencao. Sob
  'irm | iex' nao ha disco para dot-source, entao publicamos um unico
  arquivo concatenado. Este script faz essa concatenacao de forma
  deterministica e emite o hash SHA256 que o bootstrap confere antes de rodar.

  Estrutura do bundle (nesta ordem):
    [head]  bootstrap-head.ps1  (re-spawn Admin+STA+Bypass, verificacao SHA256)
    [body]  modules\Common.ps1, OSCommon.ps1, ... , Gui.ps1   (dot-sources removidos)
    [tail]  bootstrap-tail.ps1  (chama Start-InstallerUi)

  Head e tail sao opcionais: enquanto nao existirem (fases iniciais), o build
  gera so o corpo concatenado, util para testar o bundle localmente.

  Uso:  powershell -ExecutionPolicy Bypass -File .\build.ps1
============================================================================
#>
[CmdletBinding()]
param(
    [string] $OutDir,
    [string] $OutFile = 'bootstrap.ps1'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

# Ordem de inclusao. Common e OSCommon primeiro (fundacao); area depois; Gui por ultimo.
$Body = @(
    'modules\Common.ps1'
    'modules\OSCommon.ps1'
    'modules\Customizations.ps1'
    'modules\WindowsFeatures.ps1'
    'modules\BaseConfig.ps1'
    'modules\IIS.ps1'
    'modules\Software.ps1'
    'modules\Gui.ps1'          # fase C - pode ainda nao existir
)
$HeadFile = 'bootstrap-head.ps1'   # fase D - pode ainda nao existir
$TailFile = 'bootstrap-tail.ps1'   # fase D - pode ainda nao existir

# Remove linhas que so fazem sentido com modulos no disco.
function Strip-ModuleLines {
    param([string] $Text)
    $out = foreach ($ln in ($Text -split "`r?`n")) {
        if ($ln -match '^\s*#Requires')            { continue }  # consolidado no head
        if ($ln -match '^\s*\.\s*\(Join-Path')     { continue }  # dot-source de modulo
        $ln
    }
    return ($out -join "`r`n")
}

$sb = New-Object System.Text.StringBuilder
$missing = @()

function Add-Section {
    param([string] $RelPath, [switch] $Strip)
    $full = Join-Path $root $RelPath
    if (-not (Test-Path $full)) { $script:missing += $RelPath; return $false }
    $txt = Get-Content -LiteralPath $full -Raw
    if ($Strip) { $txt = Strip-ModuleLines $txt }
    [void]$sb.AppendLine("# ===== INICIO $RelPath =====")
    [void]$sb.AppendLine($txt.TrimEnd())
    [void]$sb.AppendLine("# ===== FIM $RelPath =====")
    [void]$sb.AppendLine("")
    return $true
}

[void]$sb.AppendLine("#Requires -Version 5.1")
[void]$sb.AppendLine("# === BUNDLE GERADO POR build.ps1 - NAO EDITAR A MAO ===")
[void]$sb.AppendLine("# Fonte: modules\*.ps1. Para alterar, edite os modulos e rode build.ps1.")
[void]$sb.AppendLine("")

# Head (opcional)
if (Test-Path (Join-Path $root $HeadFile)) { Add-Section $HeadFile | Out-Null }
else { Write-Host "[i] $HeadFile ausente - bundle sem re-spawn/SHA (fase D pendente)." -ForegroundColor DarkYellow }

# Body
foreach ($p in $Body) {
    if (-not (Add-Section $p -Strip)) {
        Write-Host "[i] $p ausente - pulado (fase pendente)." -ForegroundColor DarkYellow
    }
}

# Tail (opcional)
if (Test-Path (Join-Path $root $TailFile)) { Add-Section $TailFile | Out-Null }
else { Write-Host "[i] $TailFile ausente - bundle sem chamada de UI (fase D pendente)." -ForegroundColor DarkYellow }

# Grava o bundle
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$outPath = Join-Path $OutDir $OutFile
# UTF-8 SEM BOM (BOM atrapalha 'irm | iex')
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outPath, $sb.ToString(), $enc)

# SHA256
$hash = (Get-FileHash -LiteralPath $outPath -Algorithm SHA256).Hash
$shaPath = Join-Path $OutDir ($OutFile + '.sha256')
Set-Content -LiteralPath $shaPath -Value $hash -Encoding ascii -NoNewline

Write-Host ""
Write-Host "Bundle gerado:  $outPath" -ForegroundColor Green
Write-Host "SHA256:         $hash" -ForegroundColor Green
Write-Host "Hash salvo em:  $shaPath" -ForegroundColor Green
if ($missing.Count) {
    Write-Host ""
    Write-Host "Partes ainda nao incluidas (fases pendentes):" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
Write-Host ""
