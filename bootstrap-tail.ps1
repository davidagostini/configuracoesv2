# ============================================================================
#  TAIL (payload)  -  ultima parte do bundle, apos os modulos carregarem.
#  Sob o launcher (irm | iex) ja estamos Admin + STA. Abre a janela WPF
#  (Start-Gui); sem WPF (Server Core/headless) cai para o menu de console.
# ============================================================================
if (-not $env:WINCFG_NOUI) { Start-Gui }   # worker seta WINCFG_NOUI p/ carregar so as funcoes
