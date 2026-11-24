# Installer les apps via winget
. "$PSScriptRoot\00-helpers.ps1"

if (-not (Test-CommandExists winget)) {
    Write-Err "winget absent. Installe 'App Installer' (Microsoft Store) puis relance (ou utilise bootstrap.ps1)."
    Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1"
    throw "winget manquant"
}

$appsFile = Join-Path $script:Root 'config\apps.json'
$apps = (Get-Content $appsFile -Raw | ConvertFrom-Json).apps

# Filtre optionnel par catégorie (ex: RESETPACK_APP_CATS="core,dev" pour un test rapide / VM)
if ($env:RESETPACK_APP_CATS) {
    $cats = $env:RESETPACK_APP_CATS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $apps = $apps | Where-Object { $_.category -in $cats }
    Write-Warn "Filtre catégories: $($cats -join ', ') -> $($apps.Count) apps"
}

$failed = @()
foreach ($app in $apps) {
    Write-Step "Install $($app.name) ($($app.id))"
    $installed = winget list --id $app.id -e --accept-source-agreements 2>$null | Select-String ([regex]::Escape($app.id))
    if ($installed) { Write-Ok "Déjà installé"; continue }

    $winArgs = @('install', '--id', $app.id, '-e', '--silent',
                 '--accept-package-agreements', '--accept-source-agreements',
                 '--disable-interactivity')
    if ($app.PSObject.Properties.Name -contains 'extraArgs' -and $app.extraArgs) { $winArgs += $app.extraArgs }

    $code = Invoke-Winget -Arguments $winArgs
    if ($code -ne 0) { Write-Warn "winget exit $code pour $($app.id)"; $failed += $app.id }
}
if ($failed) { Write-Warn "Apps en échec winget : $($failed -join ', ')" }

# winget vient de poser Node dans le PATH machine -> recharger pour trouver npm dans CE process.
Update-SessionPath

# --- Outils npm globaux ---
Write-Step "Outils npm globaux (Claude Code, wavespeed)"
if (Test-CommandExists npm) {
    if ($script:DryRun) {
        Write-Dry "npm install -g @anthropic-ai/claude-code @wavespeed/cli"
    } else {
        npm install -g @anthropic-ai/claude-code
        npm install -g @wavespeed/cli
        Write-Ok "Claude Code + wavespeed installés (pense à reconfigurer la clé API wavespeed)"
    }
} else {
    Write-Warn "npm pas dispo (Node fraîchement installé). Rouvre un terminal et relance : -Only apps"
}

# --- Nerd Fonts (requises par la config Windows Terminal) ---
Install-NerdFont -FontName 'FiraCode' -DetectPattern '*FiraCode*Nerd*' | Out-Null

Write-Ok "Apps OK"
