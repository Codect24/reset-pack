# Backup configs locales -> OneDrive\Documents\08_Logiciels\Configs
# Idempotent : peut être relancé pour mettre à jour le backup.
# À utiliser AVANT le reset, ou périodiquement pour garder Configs à jour.

. "$PSScriptRoot\modules\00-helpers.ps1"

$DEST = $script:ConfigsRoot
Write-Banner "BACKUP CONFIGS -> $DEST"

# Crée la structure
$dirs = @('Git', 'Claude-Code\.claude', 'Claude-Desktop', 'Windsurf', 'WindowsTerminal', 'PowerToys', 'Obsidian')
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Force -Path "$DEST\$d" | Out-Null
}

function Backup-File($src, $dst) {
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Ok "Backup: $src"
    } else {
        Write-Warn "Absent: $src"
    }
}
function Backup-Dir($src, $dst) {
    if (Test-Path $src) {
        Copy-Item $src $dst -Recurse -Force
        Write-Ok "Backup dir: $src"
    } else {
        Write-Warn "Absent: $src"
    }
}

# === Git ===
Backup-File "$env:USERPROFILE\.gitconfig" "$DEST\Git\.gitconfig"

# === Claude Code (settings + plugins, skip projects/cache/etc.) ===
Backup-File "$env:USERPROFILE\.claude\settings.json" "$DEST\Claude-Code\.claude\settings.json"
if (Test-Path "$env:USERPROFILE\.claude\plugins") {
    if (Test-Path "$DEST\Claude-Code\.claude\plugins") {
        Remove-Item "$DEST\Claude-Code\.claude\plugins" -Recurse -Force
    }
    Copy-Item "$env:USERPROFILE\.claude\plugins" "$DEST\Claude-Code\.claude\plugins" -Recurse -Force
    Write-Ok "Backup dir: ~/.claude/plugins"
}
Backup-File "$env:USERPROFILE\.claude.json" "$DEST\Claude-Code\.claude.json"

# === Claude Desktop ===
Backup-File "$env:APPDATA\Claude\claude_desktop_config.json" "$DEST\Claude-Desktop\claude_desktop_config.json"
Backup-File "$env:APPDATA\Claude\config.json" "$DEST\Claude-Desktop\config.json"

# === Windsurf ===
Backup-File "$env:APPDATA\Windsurf\User\settings.json" "$DEST\Windsurf\settings.json"
if (Test-Path "$env:APPDATA\Windsurf\User\snippets") {
    if (Test-Path "$DEST\Windsurf\snippets") {
        Remove-Item "$DEST\Windsurf\snippets" -Recurse -Force
    }
    Copy-Item "$env:APPDATA\Windsurf\User\snippets" "$DEST\Windsurf\snippets" -Recurse -Force
    Write-Ok "Backup dir: Windsurf/snippets"
}

# === Windows Terminal ===
$wtPkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory | Where-Object Name -like 'Microsoft.WindowsTerminal_*' | Select-Object -First 1
if ($wtPkg) {
    Backup-File "$($wtPkg.FullName)\LocalState\settings.json" "$DEST\WindowsTerminal\current-settings.json"
}

# === PowerToys (skip Updates + RunnerLogs) ===
$ptSrc = "$env:LOCALAPPDATA\Microsoft\PowerToys"
if (Test-Path $ptSrc) {
    Get-ChildItem $ptSrc -Directory | Where-Object { $_.Name -notin @('Updates', 'RunnerLogs') } | ForEach-Object {
        $dst = "$DEST\PowerToys\$($_.Name)"
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        Copy-Item $_.FullName $dst -Recurse -Force
    }
    Write-Ok "Backup dir: PowerToys (sans Updates/RunnerLogs)"
}

# === Obsidian global ===
Backup-File "$env:APPDATA\obsidian\obsidian.json" "$DEST\Obsidian\obsidian.json"

# === Régénère vscode-extensions.txt si Windsurf ou code dispo ===
$extFile = Join-Path $script:Root 'config\vscode-extensions.txt'
if (Test-CommandExists code) {
    code --list-extensions | Set-Content $extFile -Encoding UTF8
    Write-Ok "Refresh vscode-extensions.txt depuis 'code'"
}

Write-Banner "BACKUP TERMINÉ"
Write-Host "Total: " -NoNewline
"{0:N1} MB" -f ((Get-ChildItem $DEST -Recurse | Measure-Object Length -Sum).Sum / 1MB) | Write-Host -ForegroundColor Green
