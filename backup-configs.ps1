# Backup configs locales -> OneDrive\Documents\08_Logiciels\Configs
# Idempotent : peut être relancé pour mettre à jour le backup.
# À utiliser AVANT le reset, ou périodiquement pour garder Configs à jour.

. "$PSScriptRoot\modules\00-helpers.ps1"

$DEST = $script:ConfigsRoot
Write-Banner "BACKUP CONFIGS -> $DEST"

# Crée la structure
$dirs = @('Git', 'Claude-Code\.claude', 'Claude-Desktop', 'VSCode', 'Windsurf', 'WindowsTerminal', 'PowerToys', 'Obsidian')
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
# gitignore global (core.excludesFile, sinon ~/.config/git/ignore) : restauré par le module 13-code
$xf = if (Test-CommandExists git) { "$(git config --global --get core.excludesFile 2>$null)".Trim() } else { '' }
$gi = if ($xf) { ($xf -replace '^~', $env:USERPROFILE) -replace '/', '\' } else { "$env:USERPROFILE\.config\git\ignore" }
if (Test-Path $gi) { Backup-File $gi "$DEST\Git\gitignore_global" }

function Backup-Canonical($src, $dst) {
    # Copie en réécrivant l'ancien chemin OneDrive des projets -> C:\Dev\03_Projets_Code (chemin canonique,
    # valable sur toutes les machines). UTF-8 sans BOM. Ne touche pas à la source.
    if (-not (Test-Path -LiteralPath $src)) { Write-Warn "Absent: $src"; return }
    $s = Get-Item -LiteralPath $src -Force
    $d = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    $sReal = if ($s.LinkType) { "$(@($s.Target)[0])" } else { $s.FullName }
    if ($d -and $sReal -ieq $d.FullName) { Write-Ok "Déjà lié (symlink) : $src"; return }
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    [IO.File]::WriteAllText($dst, (ConvertTo-CanonicalProjetsPath -Text ([IO.File]::ReadAllText($sReal))), (New-Object Text.UTF8Encoding $false))
    Write-Ok "Backup (chemins canoniques): $src"
}
function Backup-DirCanonical($src, $dst) {
    # Miroir d'un dossier de .md (skills, commands) avec réécriture des chemins.
    if (-not (Test-Path -LiteralPath $src)) { Write-Warn "Absent: $src"; return }
    $s = Get-Item -LiteralPath $src -Force
    if ($s.LinkType) { Write-Ok "Déjà lié (symlink) : $src"; return }
    Get-ChildItem -LiteralPath $src -Recurse -File -Force | ForEach-Object {
        $out = Join-Path $dst $_.FullName.Substring($s.FullName.Length).TrimStart('\')
        New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
        if ($_.Extension -in '.md', '.json', '.txt', '.ps1', '.sh', '.py') {
            [IO.File]::WriteAllText($out, (ConvertTo-CanonicalProjetsPath -Text ([IO.File]::ReadAllText($_.FullName))), (New-Object Text.UTF8Encoding $false))
        } else { Copy-Item -LiteralPath $_.FullName -Destination $out -Force }
    }
    Write-Ok "Backup dir (chemins canoniques): $src"
}

# === Claude Code (settings + plugins, skip projects/cache/etc.) ===
# settings.json : chemins canoniques (hooks Agent Monitor) -> la copie Configs marche telle quelle sur l'OMEN.
Backup-Canonical "$env:USERPROFILE\.claude\settings.json" "$DEST\Claude-Code\.claude\settings.json"
# Skills / commandes / CLAUDE.md perso : n'étaient sauvegardés NULLE PART (l'OMEN les reçoit via 04-symlinks).
Backup-DirCanonical "$env:USERPROFILE\.claude\skills"   "$DEST\Claude-Code\.claude\skills"
Backup-DirCanonical "$env:USERPROFILE\.claude\commands" "$DEST\Claude-Code\.claude\commands"
Backup-Canonical    "$env:USERPROFILE\.claude\CLAUDE.md" "$DEST\Claude-Code\.claude\CLAUDE.md"
# Mémoire par projet (~/.claude/projects/<clé>/memory) : migrate-projets.ps1 la rattache au nouveau chemin.
$projDir = "$env:USERPROFILE\.claude\projects"
if (Test-Path $projDir) {
    $n = 0
    Get-ChildItem $projDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'memory') } | ForEach-Object {
        $dst = "$DEST\Claude-Code\memory\$($_.Name)"
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item (Join-Path $_.FullName 'memory\*') $dst -Recurse -Force
        $n++
    }
    Write-Ok "Backup mémoire Claude Code : $n projet(s)"
}
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

# === VSCode (settings + keybindings + snippets) ===
$codeUser = "$env:APPDATA\Code\User"
Backup-File "$codeUser\settings.json"    "$DEST\VSCode\settings.json"
Backup-File "$codeUser\keybindings.json" "$DEST\VSCode\keybindings.json"
if (Test-Path "$codeUser\snippets") {
    if (Test-Path "$DEST\VSCode\snippets") { Remove-Item "$DEST\VSCode\snippets" -Recurse -Force }
    Copy-Item "$codeUser\snippets" "$DEST\VSCode\snippets" -Recurse -Force
    Write-Ok "Backup dir: VSCode/snippets"
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

# === Deep learning : .wslconfig + journal des pilotes NVIDIA validés par le smoke-test (module 14-ml) ===
if (Test-Path "$env:USERPROFILE\.wslconfig") { New-Item -ItemType Directory -Force -Path "$DEST\ML" | Out-Null; Backup-File "$env:USERPROFILE\.wslconfig" "$DEST\ML\.wslconfig" }
if (Test-Path 'C:\ML\driver-pin.txt') { New-Item -ItemType Directory -Force -Path "$DEST\ML" | Out-Null; Backup-File 'C:\ML\driver-pin.txt' "$DEST\ML\driver-pin.txt" }

# === Remote (OMEN) : config Sunshine + mono-écran. JAMAIS sunshine_state.json (hash du mot de passe, clients
#     appairés) ni config\credentials\ (clé privée) : ceux-là vont dans backup-secrets (chiffré, hors OneDrive). ===
$sunCfg = Join-Path $env:ProgramFiles 'Sunshine\config'
$remoteFiles = @(
    @{ Src = "$sunCfg\sunshine.conf";                                   Dst = 'sunshine.conf' }
    @{ Src = "$sunCfg\apps.json";                                       Dst = 'sunshine-apps.json' }
    @{ Src = 'C:\Tools\remote\settings.json';                           Dst = 'remote-settings.json' }
    @{ Src = 'C:\Tools\MultiMonitorTool\MultiMonitorTool.cfg';          Dst = 'MultiMonitorTool.cfg' }
    @{ Src = "$env:LOCALAPPDATA\ResetPack\mono-ecran\agencement.cfg";   Dst = 'agencement-ecrans.cfg' }
)
foreach ($rf in $remoteFiles) {
    if (Test-Path $rf.Src) { New-Item -ItemType Directory -Force -Path "$DEST\Remote" | Out-Null; Backup-File $rf.Src "$DEST\Remote\$($rf.Dst)" }
}

# === OMEN : 1re capture HP (état usine AVANT tri, utile en cas de RMA / restauration ; logs\ est gitignoré) ===
$firstCap = Get-ChildItem (Join-Path $script:Root 'logs') -Directory -Filter 'hp-capture-*' -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object -First 1
if ($firstCap -and -not (Test-Path "$DEST\OMEN\$($firstCap.Name)")) {
    New-Item -ItemType Directory -Force -Path "$DEST\OMEN" | Out-Null
    Copy-Item $firstCap.FullName "$DEST\OMEN\$($firstCap.Name)" -Recurse -Force
    Write-Ok "Backup capture HP de référence : $($firstCap.Name)"
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
