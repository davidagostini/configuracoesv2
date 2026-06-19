#Requires -Version 5.1
<#
============================================================================
  build.ps1  -  Gera os artefatos de distribuicao em dist/
============================================================================
  Produz DOIS arquivos (modelo launcher + payload, para a verificacao SHA256
  realmente proteger o que executa):

    dist/payload.ps1    <- modulos concatenados + bootstrap-tail.ps1 (chama a UI).
                           E o que roda de verdade. Tem seu SHA256 calculado.
    dist/bootstrap.ps1  <- launcher (bootstrap-head.ps1) com URLs pinadas e o
                           SHA256 do payload "baked". E o alvo do 'irm | iex'.

  Os modulos separados (modules\*.ps1) continuam sendo a FONTE de manutencao.

  Pinagem no commit SHA: o GitHub serve cada commit de forma imutavel, mas o
  SHA so existe DEPOIS de commitar os artefatos. Fluxo de publicacao:
    1. .\build.ps1                       (gera com -Ref main, para testar)
    2. commit + push                     (cria o commit SHA)
    3. .\build.ps1 -Ref <commitSHA>      (rebaka as URLs no SHA imutavel)
    4. commit + push                     (publica o launcher pinado)
  O one-liner final usa a URL do launcher no <commitSHA> do passo 4.

  Uso:  powershell -ExecutionPolicy Bypass -File .\build.ps1 [-Ref <sha|branch>]
============================================================================
#>
[CmdletBinding()]
param(
    [string] $Owner = 'davidagostini',
    [string] $Repo  = 'configuracoesv2',
    [string] $Ref   = 'main',
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

# Modulos que compoem o payload, na ordem de carga (Common e OSCommon primeiro).
$Body = @(
    'modules\Common.ps1'
    'modules\OSCommon.ps1'
    'modules\Customizations.ps1'
    'modules\WindowsFeatures.ps1'
    'modules\BaseConfig.ps1'
    'modules\IIS.ps1'
    'modules\Software.ps1'
    'modules\Gui.ps1'
)
$HeadFile = 'bootstrap-head.ps1'   # template do launcher
$TailFile = 'bootstrap-tail.ps1'   # ultima parte do payload (chama Start-InstallerUi)

# Remove linhas que so fazem sentido com modulos no disco.
function Strip-ModuleLines {
    param([string] $Text)
    $out = foreach ($ln in ($Text -split "`r?`n")) {
        if ($ln -match '^\s*#Requires')        { continue }  # consolidado uma vez
        if ($ln -match '^\s*\.\s*\(Join-Path') { continue }  # dot-source de modulo
        $ln
    }
    return ($out -join "`r`n")
}

function Read-Part {
    param([string] $RelPath)
    $full = Join-Path $root $RelPath
    if (-not (Test-Path $full)) { throw "Parte ausente: $RelPath" }
    return (Get-Content -LiteralPath $full -Raw)
}

function Write-Utf8NoBom {
    param([string] $Path, [string] $Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# --- 1) Monta o PAYLOAD (modulos + tail) -----------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("#Requires -Version 5.1")
[void]$sb.AppendLine("# === PAYLOAD GERADO POR build.ps1 - NAO EDITAR A MAO ===")
[void]$sb.AppendLine("# Fonte: modules\*.ps1 + $TailFile. Para alterar, edite as fontes e rode build.ps1.")
[void]$sb.AppendLine("")
foreach ($p in $Body) {
    $txt = Strip-ModuleLines (Read-Part $p)
    [void]$sb.AppendLine("# ===== INICIO $p =====")
    [void]$sb.AppendLine($txt.TrimEnd())
    [void]$sb.AppendLine("# ===== FIM $p =====")
    [void]$sb.AppendLine("")
}
$tail = Strip-ModuleLines (Read-Part $TailFile)
[void]$sb.AppendLine("# ===== INICIO $TailFile =====")
[void]$sb.AppendLine($tail.TrimEnd())
[void]$sb.AppendLine("# ===== FIM $TailFile =====")
[void]$sb.AppendLine("")

$payloadPath = Join-Path $OutDir 'payload.ps1'
Write-Utf8NoBom $payloadPath $sb.ToString()
$payloadSha = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash

# --- 2) Monta o LAUNCHER (head com URLs + SHA baked) -----------------------
$rawBase   = "https://raw.githubusercontent.com/$Owner/$Repo/$Ref"
$selfUrl   = "$rawBase/dist/bootstrap.ps1"
$payloadUrl = "$rawBase/dist/payload.ps1"

$head = Read-Part $HeadFile
$head = $head.Replace('__SELF_URL__',       $selfUrl)
$head = $head.Replace('__PAYLOAD_URL__',    $payloadUrl)
$head = $head.Replace('__PAYLOAD_SHA256__', $payloadSha)

$bootstrapPath = Join-Path $OutDir 'bootstrap.ps1'
Write-Utf8NoBom $bootstrapPath $head

# --- 3) Sidecar de hash + relatorio ----------------------------------------
$shaPath = Join-Path $OutDir 'payload.ps1.sha256'
Set-Content -LiteralPath $shaPath -Value $payloadSha -Encoding ascii -NoNewline

$oneLiner = "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm $selfUrl | iex"

Write-Host ""
Write-Host "Payload:   $payloadPath" -ForegroundColor Green
Write-Host "  SHA256:  $payloadSha" -ForegroundColor Green
Write-Host "Launcher:  $bootstrapPath" -ForegroundColor Green
Write-Host "  Ref:     $Ref  (URLs apontam para $rawBase)" -ForegroundColor Green
if ($Ref -eq 'main') {
    Write-Host ""
    Write-Host "[!] Ref=main e MUTAVEL. Para publicar, rode novamente com -Ref <commitSHA>" -ForegroundColor Yellow
    Write-Host "    apos commitar, para pinar as URLs no commit imutavel." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "One-liner:" -ForegroundColor Cyan
Write-Host "  $oneLiner"
Write-Host ""
