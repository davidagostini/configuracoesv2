#Requires -Version 5.1
<#
============================================================================
  setup.ps1  -  Configurador interativo do Windows Server
============================================================================
  Como usar:
    1. Abra o PowerShell como Administrador (o script tenta auto-elevar).
    2. Execute:  .\setup.ps1
    3. Escolha no menu o que deseja instalar/configurar.

  Estrutura:
    setup.ps1            -> este menu (chama os modulos)
    modules\Common.ps1   -> funcoes compartilhadas (log, registro, etc)
    modules\*.ps1        -> um modulo por area (customizacoes, IIS, etc)
    logs\install.log     -> registro de tudo que foi executado
============================================================================
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# --- Auto-elevacao para Administrador --------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Resolve o proprio caminho sem depender so de $PSCommandPath (pode vir vazio).
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    if (-not $self) { $self = $MyInvocation.MyCommand.Definition }

    if (-not $self -or -not (Test-Path -LiteralPath $self -ErrorAction SilentlyContinue)) {
        Write-Host "Nao foi possivel localizar o proprio arquivo para auto-elevar." -ForegroundColor Red
        Write-Host "Abra o PowerShell como Administrador e rode:  .\setup.ps1" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Elevando privilegios (Administrador)..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$self) `
            -Verb RunAs
    } catch {
        Write-Host "Elevacao cancelada (UAC). Abortando." -ForegroundColor Yellow
    }
    exit
}

# --- Carrega os modulos (dot-source) ---------------------------------------
$ModulesDir = Join-Path $PSScriptRoot 'modules'
. (Join-Path $ModulesDir 'Common.ps1')
. (Join-Path $ModulesDir 'OSCommon.ps1')
. (Join-Path $ModulesDir 'Customizations.ps1')
. (Join-Path $ModulesDir 'WindowsFeatures.ps1')
. (Join-Path $ModulesDir 'BaseConfig.ps1')
. (Join-Path $ModulesDir 'IIS.ps1')
. (Join-Path $ModulesDir 'Software.ps1')
. (Join-Path $ModulesDir 'Gui.ps1')
. (Join-Path $ModulesDir 'GuiWpf.ps1')

# --- Entry point da UI ------------------------------------------------------
# Start-Gui (GuiWpf.ps1) abre a janela WPF; sem WPF (Server Core/headless) cai
# para Start-MainMenu (menu de console). Mesmo entry usado pelo bundle irm.
Start-Gui
