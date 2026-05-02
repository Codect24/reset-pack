# Installer les apps via winget
. "$PSScriptRoot\00-helpers.ps1"

if (-not (Test-CommandExists winget)) {
    Write-Err "winget absent. Installe 'App Installer' depuis le Microsoft Store puis relance."
    Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1"
    throw "winget manquant"
}

$appsFile = Join-Path $script:Root 'config\apps.json'
$apps = (Get-Content $appsFile -Raw | ConvertFrom-Json).apps

foreach ($app in $apps) {
    Write-Step "Install $($app.name) ($($app.id))"
    $installed = winget list --id $app.id -e --accept-source-agreements 2>$null | Select-String $app.id
    if ($installed) {
        Write-Ok "Déjà installé"
        continue
    }
    $winArgs = @('install', '--id', $app.id, '-e', '--silent',
                 '--accept-package-agreements', '--accept-source-agreements',
                 '--disable-interactivity')
    if ($app.PSObject.Properties.Name -contains 'extraArgs' -and $app.extraArgs) {
        $winArgs += $app.extraArgs
    }
    & winget @winArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "winget exit $LASTEXITCODE pour $($app.id)"
    }
}

# Claude Code via npm (Node doit être installé juste avant)
Write-Step "Installer Claude Code via npm"
if (Test-CommandExists npm) {
    npm install -g @anthropic-ai/claude-code
    Write-Ok "Claude Code installé"
} else {
    Write-Warn "npm pas encore dispo (Node fraîchement installé). Relance ce module ou ouvre un nouveau terminal."
}

# --- Nerd Fonts (requises par la config Windows Terminal) ---
Install-NerdFont -FontName 'FiraCode' -DetectPattern '*FiraCode*Nerd*' | Out-Null

Write-Ok "Apps OK"
