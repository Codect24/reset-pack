# Installer extensions VSCode
. "$PSScriptRoot\00-helpers.ps1"

if (-not (Test-CommandExists code)) {
    Write-Warn "code CLI absent. VSCode pas encore installé ou pas dans PATH (relancer un terminal)."
    return
}

$listFile = Join-Path $script:Root 'config\vscode-extensions.txt'
$exts = Get-Content $listFile | Where-Object { $_ -and ($_ -notmatch '^#') }

# Le CLI `code` (node) écrit des warnings sur stderr (ex. DEP0169). Sous Windows PowerShell 5.1 avec
# ErrorActionPreference=Stop (hérité de reset.ps1), un stderr redirigé devient une erreur TERMINANTE :
# le module plantait dès la 1re extension. Portée locale à ce module uniquement.
$ErrorActionPreference = 'Continue'

$installed = @(code --list-extensions 2>$null) -join "`n"
$failed = @()
foreach ($ext in $exts) {
    if ($installed -match [regex]::Escape($ext)) {
        Write-Ok "Déjà installé: $ext"
        continue
    }
    # DRY-RUN : on n'installe RIEN (bug historique : ce module ignorait le dry-run)
    if ($script:DryRun) { Write-Dry "code --install-extension $ext"; continue }
    Write-Step "Install: $ext"
    $null = code --install-extension $ext --force 2>&1
    if ($LASTEXITCODE -ne 0) { $failed += $ext }
}
if ($failed) { Write-Warn "Extensions en échec : $($failed -join ', ')" }

# Symlink VSCode user settings vers Windsurf settings (à adapter si tu veux migrer)
$vscodeUserDir = "$env:APPDATA\Code\User"
$windsurfBackup = "$script:ConfigsRoot\Windsurf\settings.json"
if ((Test-Path $vscodeUserDir) -and (Test-Path $windsurfBackup)) {
    $dst = "$vscodeUserDir\settings.json"
    if (-not (Test-Path $dst)) {
        Write-Step "Copier les settings Windsurf -> VSCode"
        if ($script:DryRun) { Write-Dry "copie $windsurfBackup -> $dst" } else { Copy-Item $windsurfBackup $dst }
    }
}

Write-Ok "VSCode OK"
