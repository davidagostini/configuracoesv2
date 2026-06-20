# ============================================================================
#  Customizations.ps1  -  Ajustes de interface / Explorer para o usuario atual
#  Funcoes chamadas pelo setup.ps1. Dependem do Common.ps1 (Write-Log etc).
# ============================================================================

$Script:ExplorerAdvanced = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$Script:Personalize      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'

# Reinicia o explorer.exe para aplicar mudancas de UI (so quando necessario).
function Restart-Explorer {
    Write-Log "Reiniciando o Explorer para aplicar as mudancas..." -Level STEP
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Write-Log "Explorer reiniciado." -Level OK
}

# --- Dark Mode (tema escuro para apps e sistema) ---------------------------
function Enable-DarkMode {
    Write-Log "Ativando Dark Mode (apps e sistema)..." -Level STEP
    $c1 = Set-RegistryValue -Path $Script:Personalize -Name 'AppsUseLightTheme'   -Value 0 -Type DWord
    $c2 = Set-RegistryValue -Path $Script:Personalize -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
    return ($c1 -or $c2)
}

# --- Mostrar extensoes de arquivos conhecidos ------------------------------
function Show-FileExtensions {
    Write-Log "Habilitando exibicao das extensoes de arquivo..." -Level STEP
    # HideFileExt = 0  => mostra as extensoes
    return (Set-RegistryValue -Path $Script:ExplorerAdvanced -Name 'HideFileExt' -Value 0 -Type DWord)
}

# --- Mostrar arquivos e pastas ocultos -------------------------------------
function Show-HiddenFiles {
    param([switch] $IncludeProtectedOsFiles)
    Write-Log "Habilitando exibicao de arquivos ocultos..." -Level STEP
    # Hidden = 1 => mostra ocultos ; 2 => nao mostra
    $changed = Set-RegistryValue -Path $Script:ExplorerAdvanced -Name 'Hidden' -Value 1 -Type DWord

    if ($IncludeProtectedOsFiles) {
        Write-Log "Habilitando arquivos protegidos do sistema (ShowSuperHidden)..." -Level STEP
        $c2 = Set-RegistryValue -Path $Script:ExplorerAdvanced -Name 'ShowSuperHidden' -Value 1 -Type DWord
        $changed = $changed -or $c2
    }
    return $changed
}

# --- Desativar Print Screen abrindo a Ferramenta de Captura ----------------
# Tira o atalho que faz a tecla PrintScreen abrir o Snipping Tool (HKCU).
function Disable-PrintScreenSnipping {
    Write-Log "Desvinculando a tecla Print Screen da Ferramenta de Captura..." -Level STEP
    return (Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Ease of Access\Keyboard' -Name 'PrintScreenKeyForSnippingEnabled' -Value 0 -Type DWord)
}

# --- Abrir as pastas de Inicializacao (Startup) ----------------------------
# shell:startup = do usuario atual ; shell:common startup = de todos os usuarios.
function Open-StartupFolders {
    param([switch] $AllUsers)
    if ($AllUsers) {
        Write-Log "Abrindo a pasta Startup de todos os usuarios (shell:common startup)..." -Level STEP
        Start-Process explorer.exe 'shell:common startup'
    } else {
        Write-Log "Abrindo a pasta Startup do usuario (shell:startup)..." -Level STEP
        Start-Process explorer.exe 'shell:startup'
    }
}

# --- Aplica todas as customizacoes de uma vez ------------------------------
function Invoke-AllCustomizations {
    $changed = $false
    if (Enable-DarkMode)        { $changed = $true }
    if (Show-FileExtensions)    { $changed = $true }
    if (Show-HiddenFiles)       { $changed = $true }
    Disable-PrintScreenSnipping | Out-Null   # nao depende do Explorer; aplica direto

    if ($changed) {
        Restart-Explorer
    } else {
        Write-Log "Nenhuma mudanca necessaria - tudo ja estava configurado." -Level OK
    }
}
