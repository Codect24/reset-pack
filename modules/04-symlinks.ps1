# Restore configs depuis OneDrive\Configs via symlinks
. "$PSScriptRoot\00-helpers.ps1"

if (-not (Test-Path $script:ConfigsRoot)) {
    if ($script:DryRun) { Write-Dry "Configs absent ($script:ConfigsRoot) - en réel on attendrait la sync OneDrive" }
    else { throw "Configs introuvables : $script:ConfigsRoot - attends que OneDrive sync." }
}

# Tuer les apps qui verrouillent leurs fichiers de config avant de creer les symlinks
# PowerToys 0.99+ lance CmdPal (Command Palette) qui tient ses logs ouverts.
# CmdPal a un nom different (Microsoft.CmdPal.UI / Microsoft.CmdPal.Ext.PowerToys)
# donc on chasse aussi par chemin d'install.
# (sauté en dry-run : on ne tue aucune app ni ne désactive de tâche en simulation)
if (-not $script:DryRun) {
$procPatterns = @('PowerToys*', 'obsidian*', 'Claude*', 'Microsoft.CmdPal*')
foreach ($pat in $procPatterns) {
    $procs = Get-Process -Name $pat -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Step "Stop process: $pat ($($procs.Count) instance(s))"
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}
# Bonus : tuer tout ce qui tourne depuis les dossiers PowerToys
$pathProcs = Get-Process | Where-Object {
    $_.Path -and (
        $_.Path -like "*\PowerToys\*" -or
        $_.Path -like "*\Microsoft\PowerToys\*" -or
        $_.Path -like "*Microsoft.CommandPalette*"
    )
}
if ($pathProcs) {
    Write-Step "Stop processes by path: $($pathProcs.Count) instance(s)"
    $pathProcs | Stop-Process -Force -ErrorAction SilentlyContinue
}
# Desactiver l'autorun PowerToys temporairement pour eviter les relaunches pendant qu'on symlink
$ptTasks = Get-ScheduledTask -TaskName "PowerToys*" -ErrorAction SilentlyContinue
if ($ptTasks) { $ptTasks | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
Start-Sleep -Seconds 3
}  # fin if (-not DryRun) : kill process + désactivation autorun

# Map : ConfigsRoot subfolder -> destination réelle
$wtPkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory | Where-Object { $_.Name -like 'Microsoft.WindowsTerminal_*' } | Select-Object -First 1

$links = @(
    # Git
    @{ Link = "$env:USERPROFILE\.gitconfig"
       Target = "$script:ConfigsRoot\Git\.gitconfig" }

    # Claude Code
    @{ Link = "$env:USERPROFILE\.claude\settings.json"
       Target = "$script:ConfigsRoot\Claude-Code\.claude\settings.json" }
    @{ Link = "$env:USERPROFILE\.claude\plugins"
       Target = "$script:ConfigsRoot\Claude-Code\.claude\plugins" }
    @{ Link = "$env:USERPROFILE\.claude.json"
       Target = "$script:ConfigsRoot\Claude-Code\.claude.json" }

    # Claude Desktop (config MCP)
    @{ Link = "$env:APPDATA\Claude\claude_desktop_config.json"
       Target = "$script:ConfigsRoot\Claude-Desktop\claude_desktop_config.json" }

    # PowerToys (full folder)
    @{ Link = "$env:LOCALAPPDATA\Microsoft\PowerToys"
       Target = "$script:ConfigsRoot\PowerToys" }

    # Obsidian
    @{ Link = "$env:APPDATA\obsidian\obsidian.json"
       Target = "$script:ConfigsRoot\Obsidian\obsidian.json" }

    # PowerShell profile (depuis le repo, pas Configs)
    @{ Link = "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
       Target = "$script:Root\config\powershell\profile.ps1" }
)

# Windows Terminal - utilise la nouvelle config du repo (pas l'ancienne backup)
if ($wtPkg) {
    $links += @{
        Link   = "$($wtPkg.FullName)\LocalState\settings.json"
        Target = "$script:Root\config\windows-terminal\settings.json"
    }
}

foreach ($l in $links) {
    Write-Step "Link $($l.Link)"
    try {
        New-SymLinkSafe -Link $l.Link -Target $l.Target | Out-Null
    } catch {
        Write-Warn "Skip ($($l.Link)) : $($_.Exception.Message)"
    }
}

# Re-enable PowerToys autorun (desactive plus haut)
if ($ptTasks) {
    $ptTasks | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    Write-Ok "PowerToys autorun re-active"
}

Write-Ok "Symlinks OK"
Write-Warn "Note: Windsurf settings backupés dans Configs\Windsurf - ignorés (on migre vers VSCode)."
