# Installer extensions VSCode
. "$PSScriptRoot\00-helpers.ps1"

if (-not (Test-CommandExists code)) {
    Write-Warn "code CLI absent. VSCode pas encore installé ou pas dans PATH (relancer un terminal)."
    return
}

$listFile = Join-Path $script:Root 'config\vscode-extensions.txt'
$exts = Get-Content $listFile | Where-Object { $_ -and ($_ -notmatch '^#') }

$installed = @(code --list-extensions 2>$null) -join "`n"
foreach ($ext in $exts) {
    if ($installed -match [regex]::Escape($ext)) {
        Write-Ok "Déjà installé: $ext"
        continue
    }
    Write-Step "Install: $ext"
    code --install-extension $ext --force 2>&1 | Out-Null
}

# Symlink VSCode user settings vers Windsurf settings (à adapter si tu veux migrer)
$vscodeUserDir = "$env:APPDATA\Code\User"
$windsurfBackup = "$script:ConfigsRoot\Windsurf\settings.json"
if ((Test-Path $vscodeUserDir) -and (Test-Path $windsurfBackup)) {
    $dst = "$vscodeUserDir\settings.json"
    if (-not (Test-Path $dst)) {
        Write-Step "Copier les settings Windsurf -> VSCode"
        Copy-Item $windsurfBackup $dst
    }
}

Write-Ok "VSCode OK"
