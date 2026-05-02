#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Auto,
    [string[]]$Only,
    [switch]$SkipReboot
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# Normalise -Only : si l'invocation est passee par "-File" (ex: powershell -File ... -Only a,b,c),
# PS 5.1 ne split pas les comma-separes vers [string[]] et $Only arrive en single-element.
# On force le split pour accepter les deux formes.
if ($Only) {
    $Only = $Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ }
}

# Admin check
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Relancement en admin..." -ForegroundColor Yellow
    # On utilise -Command (pas -File) car -File ne split pas les [string[]] comma-separes en PS 5.1
    $cmd = "& '$PSCommandPath'"
    if ($Auto)       { $cmd += " -Auto" }
    if ($Only)       { $cmd += " -Only " + (($Only | ForEach-Object { "'$_'" }) -join ',') }
    if ($SkipReboot) { $cmd += " -SkipReboot" }
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    exit
}

. "$Root\modules\00-helpers.ps1"

Write-Banner "RESET PACK"
Write-Host "Mode: $(if ($Auto) {'AUTO'} else {'INTERACTIF'})" -ForegroundColor Cyan
Write-Host "Configs source: $script:ConfigsRoot" -ForegroundColor DarkGray

if (-not (Test-Path $script:ConfigsRoot)) {
    Write-Warn "OneDrive\Configs introuvable. Tentative de force-download (Files On-Demand)..."
    Invoke-OneDrivePin -Path $script:ConfigsRoot | Out-Null
    if (Wait-OneDrivePath -Path $script:ConfigsRoot -TimeoutSec 180) {
        Write-Ok "OneDrive a sync les Configs."
    } else {
        Write-Warn "OneDrive n'a pas fini de sync apres 3 min. Verifie l'icone OneDrive (clic droit > Pause/Resume)."
        if (-not $Auto) { Read-Host "Appuie sur Entree pour continuer quand meme" }
    }
} else {
    # Pin quand meme pour s'assurer que TOUS les fichiers sont locaux (pas just placeholder)
    Invoke-OneDrivePin -Path $script:ConfigsRoot | Out-Null
}

$modules = @(
    @{ Key='apps';        File='01-apps.ps1';        Desc='Installer les apps (winget)' }
    @{ Key='drivers';     File='02-drivers.ps1';     Desc='Drivers (Nvidia + SDIO)' }
    @{ Key='dev-setup';   File='03-dev-setup.ps1';   Desc='WSL2, long paths, Git, gh auth' }
    @{ Key='symlinks';    File='04-symlinks.ps1';    Desc='Symlinks configs depuis OneDrive' }
    @{ Key='vscode';      File='05-vscode.ps1';      Desc='Extensions VSCode' }
    @{ Key='tweaks';      File='06-tweaks.ps1';      Desc='Tweaks Windows (Explorer, taskbar, privacy)' }
    @{ Key='defaults';    File='07-defaults.ps1';    Desc='Apps par défaut (Brave, VLC)' }
    @{ Key='debloat';     File='08-debloat.ps1';     Desc='Virer Cortana + apps préinstallées' }
    @{ Key='games';       File='09-games.ps1';       Desc='Symlinks sauvegardes jeux' }
    @{ Key='scheduled';   File='10-scheduled.ps1';   Desc='Tâches planifiées (upgrade hebdo, dark mode)' }
    @{ Key='finalize';    File='11-finalize.ps1';    Desc='Pin taskbar, hosts file, Brave sync' }
)

if ($Only) {
    $modules = $modules | Where-Object { $Only -contains $_.Key }
}

foreach ($mod in $modules) {
    Write-Banner $mod.Desc
    if (-not $Auto) {
        $r = Read-Host "Lancer ? [O/n/q]"
        if ($r -eq 'q') { Write-Host "Stop."; exit }
        if ($r -eq 'n') { Write-Host "Skip." -ForegroundColor DarkGray; continue }
    }
    try {
        & "$Root\modules\$($mod.File)"
        Write-Ok "$($mod.Desc) -OK"
    } catch {
        Write-Err "$($mod.Desc) -ÉCHEC: $_"
        if (-not $Auto) {
            $r = Read-Host "Continuer malgré tout ? [O/n]"
            if ($r -eq 'n') { exit 1 }
        }
    }
}

Write-Banner "FINI"
Write-Host "Reboot recommandé pour appliquer tous les tweaks." -ForegroundColor Yellow
if (-not $SkipReboot -and -not $Auto) {
    $r = Read-Host "Rebooter maintenant ? [o/N]"
    if ($r -eq 'o') { Restart-Computer -Force }
}
