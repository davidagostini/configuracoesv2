#Requires -Version 5.1
# ============================================================================
#  LAUNCHER  -  ponto de entrada do 'irm | iex'
#  GERADO por build.ps1 a partir deste template. NAO editar o dist a mao.
#  Placeholders __SELF_URL__ / __PAYLOAD_URL__ / __PAYLOAD_SHA256__ sao
#  substituidos no build (URLs pinadas no commit SHA).
# ============================================================================
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SelfUrl    = '__SELF_URL__'        # este launcher (re-spawn elevado)
$PayloadUrl = '__PAYLOAD_URL__'     # payload (modulos + UI)
$PayloadSha = '__PAYLOAD_SHA256__'  # SHA256 esperado do payload

# --- PASSO 1: re-spawn unico = Admin + STA + Bypass -------------------------
# Sentinela $env:WINCFG_RELAUNCHED curto-circuita as checagens no filho (anti-loop UAC).
$needAdmin = -not (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needSta   = [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'

if (($needAdmin -or $needSta) -and -not $env:WINCFG_RELAUNCHED) {
    $cmd = "`$env:WINCFG_RELAUNCHED='1'; " +
           "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; " +
           "irm '$SelfUrl' | iex"
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-STA','-ExecutionPolicy','Bypass','-Command',$cmd)
    } catch {
        Write-Host "Elevacao cancelada (UAC). Abortando." -ForegroundColor Yellow
    }
    return
}
# Daqui em diante: ADMIN + STA + Bypass garantidos.

# --- PASSO 2: baixa o payload, confere o SHA256 e so entao executa ----------
Write-Host "Baixando componentes..." -ForegroundColor Cyan
try {
    $wc = New-Object System.Net.WebClient
    $bytes = $wc.DownloadData($PayloadUrl)   # bytes exatos => hash == Get-FileHash
} catch {
    Write-Host "ERRO ao baixar o payload: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$hash = ([BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        )).Replace('-', '')

# Pula a checagem se o hash nao foi baked (build local de teste deixa o placeholder).
# ==== TEMPORARIO (a pedido, p/ testes): validacao SHA256 apenas AVISA, nao aborta.
#      REATIVAR antes de publicar/pinar -> trocar o bloco abaixo de volta p/ 'return'.
if ($PayloadSha -notmatch '^_' -and $hash -ne $PayloadSha) {
    Write-Host "AVISO: SHA256 do payload nao confere (validacao DESATIVADA p/ teste)." -ForegroundColor Yellow
    Write-Host "  esperado: $PayloadSha" -ForegroundColor Yellow
    Write-Host "  obtido:   $hash" -ForegroundColor Yellow
}
# ==== FIM TEMPORARIO

$payload = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
Invoke-Expression $payload
