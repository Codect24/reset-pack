#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Auto,          # non-interactif : enchaîne tout sans prompt
    [string[]]$Only,        # ne lancer que ces modules (ex: -Only apps,tweaks)
    [switch]$SkipReboot,
    [switch]$DryRun,        # simulation : aucune modification système (installs/reg/tâches mockés)
    [switch]$Fresh,         # ignore le fichier .state : rejoue tous les modules
    # Profil machine (config/profiles.json) : impose la liste ET l'ordre des modules.
    # Nom de variable != $PROFILE (variable automatique) ; on garde -Profile comme nom d'usage.
    [Alias('Profile')][ValidateSet('omen', 'exodius')][string]$MachineProfile
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# Normalise -Only (PS 5.1 ne split pas les comma-séparés passés via -File)
if ($Only) { $Only = $Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ } }

# --- Admin check + ré-élévation (en conservant tous les switches) ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Relancement en admin..." -ForegroundColor Yellow
    $cmd = "& '$PSCommandPath'"
    if ($Auto)       { $cmd += " -Auto" }
    if ($Only)       { $cmd += " -Only " + (($Only | ForEach-Object { "'$_'" }) -join ',') }
    if ($SkipReboot) { $cmd += " -SkipReboot" }
    if ($DryRun)     { $cmd += " -DryRun" }
    if ($Fresh)      { $cmd += " -Fresh" }
    if ($MachineProfile) { $cmd += " -Profile $MachineProfile" }
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    exit
}

# --- Flags visibles par les modules enfants (lus dans 00-helpers) ---
$env:RESETPACK_DRYRUN = if ($DryRun) { '1' } else { '' }
$env:RESETPACK_AUTO   = if ($Auto)   { '1' } else { '' }
if ($MachineProfile) { $env:RESETPACK_PROFILE = $MachineProfile }

. "$Root\modules\00-helpers.ps1"

# --- Profil : liste/ordre imposés + modules interdits + catégories d'apps ---
$ProfileDef = $null
if ($MachineProfile) {
    $ProfileDef = Get-ResetProfileDefinition -Name $MachineProfile
    $bad = @($Only | Where-Object { $ProfileDef.forbidden -contains $_ })
    if ($bad) { throw "Module(s) interdit(s) avec le profil ${MachineProfile} : $($bad -join ', ')" }
    if (-not $env:RESETPACK_APP_CATS) { $env:RESETPACK_APP_CATS = ($ProfileDef.appCats -join ',') }
}

# --- Log horodaté ---
$LogDir  = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("reset-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $LogFile | Out-Null } catch {}

Write-Banner "RESET PACK"
Write-Host "Mode: $(if ($Auto) {'AUTO'} else {'INTERACTIF'})$(if ($DryRun) {' + DRY-RUN'} else {''})" -ForegroundColor Cyan
Write-Host "Profil     : $(if ($MachineProfile) { $MachineProfile } else { '(aucun : liste historique)' })" -ForegroundColor Cyan
Write-Host "OneDrive   : $script:OneDriveRoot" -ForegroundColor DarkGray
Write-Host "Configs    : $script:ConfigsRoot" -ForegroundColor DarkGray
Write-Host "Log        : $LogFile" -ForegroundColor DarkGray
if ($DryRun) { Write-Warn "DRY-RUN : rien ne sera installé ni modifié (simulation)." }

# --- OneDrive Configs dispo ? (sauté en dry-run) ---
if (-not $DryRun) {
    if (-not (Test-Path $script:ConfigsRoot)) {
        Write-Warn "Configs introuvable ($script:ConfigsRoot). Force-download OneDrive..."
        Invoke-OneDrivePin -Path $script:ConfigsRoot | Out-Null
        if (Wait-OneDrivePath -Path $script:ConfigsRoot -TimeoutSec 180) {
            Write-Ok "OneDrive a sync les Configs."
        } else {
            Write-Warn "OneDrive pas fini de sync après 3 min (clic droit icône OneDrive > Reprendre)."
            if (-not $Auto) { Read-Host "Entrée pour continuer quand même" }
        }
    } else {
        Invoke-OneDrivePin -Path $script:ConfigsRoot | Out-Null
    }
}

# Catalogue : TOUS les modules connus, dans l'ordre historique (utilisé sans -Profile).
$catalog = @(
    @{ Key='apps';        File='01-apps.ps1';        Desc='Installer les apps (winget)' }
    @{ Key='drivers';     File='02-drivers.ps1';     Desc='Drivers (Nvidia + SDIO)' }
    @{ Key='dev-setup';   File='03-dev-setup.ps1';   Desc='WSL2, long paths, Git, gh auth' }
    @{ Key='symlinks';    File='04-symlinks.ps1';    Desc='Symlinks configs depuis OneDrive' }
    @{ Key='vscode';      File='05-vscode.ps1';      Desc='Extensions VSCode' }
    @{ Key='tweaks';      File='06-tweaks.ps1';      Desc='Tweaks Windows (Explorer, taskbar, privacy)' }
    @{ Key='defaults';    File='07-defaults.ps1';    Desc='Apps par défaut (Brave, VLC)' }
    @{ Key='debloat';     File='08-debloat.ps1';     Desc='Virer Cortana + apps préinstallées' }
    @{ Key='games';       File='09-games.ps1';       Desc='Symlinks sauvegardes jeux' }
    @{ Key='scheduled';   File='10-scheduled.ps1';   Desc='Tâches planifiées (upgrade, bundles, dark mode)' }
    @{ Key='storage';     File='12-storage.ps1';     Desc='Stockage C:/D: selon le layout du profil' }
    @{ Key='code';        File='13-code.ps1';        Desc='Projets : PROJETS_CODE, gitignore global, garde-fous' }
    @{ Key='ml';          File='14-ml.ps1';          Desc='Deep learning : .wslconfig, WSL ML, smoke-test GPU' }
    @{ Key='hp-triage';   File='15-hp-triage.ps1';   Desc='Capture + tri du bloatware HP (liste blanche)' }
    @{ Key='gaming';      File='16-gaming.ps1';      Desc='Jeu : launchers sur D:, Game Mode, OMEN Hub muselé' }
    @{ Key='remote';      File='17-remote.ps1';      Desc='Accès distant : Tailscale, Sunshine, mono-écran' }
    @{ Key='finalize';    File='11-finalize.ps1';    Desc='Storage Sense, pin taskbar, Brave sync' }
)
# Sans profil : liste historique (les nouveaux modules ne tournent que via -Profile ou -Only).
$legacyKeys = @('apps','drivers','dev-setup','symlinks','vscode','tweaks','defaults','debloat','games','scheduled','storage','finalize')

if ($ProfileDef) {
    $modules = foreach ($k in $ProfileDef.modules) {
        $m = $catalog | Where-Object { $_.Key -eq $k }
        if (-not $m) { throw "Profil ${MachineProfile} : module inconnu '$k'" }
        $m
    }
} elseif ($Only) {
    $modules = $catalog
} else {
    $modules = $catalog | Where-Object { $legacyKeys -contains $_.Key }
}
if ($Only) {
    $unknown = @($Only | Where-Object { -not ($catalog.Key -contains $_) })
    if ($unknown) { throw "Module(s) inconnu(s) : $($unknown -join ', ')" }
    $modules = $modules | Where-Object { $Only -contains $_.Key }
}
$modules = @($modules)
foreach ($m in $modules) {
    if (-not (Test-Path "$Root\modules\$($m.File)")) { throw "Fichier module manquant : modules\$($m.File)" }
}
Write-Host "Modules    : $(($modules | ForEach-Object { $_.Key }) -join ' > ')" -ForegroundColor DarkGray

# --- Reprise (.state) : modules déjà faits lors d'un run précédent ---
$StateFile = Join-Path $Root '.state'
if ($Fresh -and (Test-Path $StateFile)) { Remove-Item $StateFile -Force }
$done = @(if ((Test-Path $StateFile) -and -not $DryRun) { Get-Content $StateFile })
function Add-Done($k) { if (-not $script:DryRun) { Add-Content -Path $StateFile -Value $k } }

$results = [ordered]@{}
$i = 0
try {
    foreach ($mod in $modules) {
        $i++
        $tag = "[$i/$($modules.Count)] $($mod.Desc)"

        if (($done -contains $mod.Key) -and -not ($Only -contains $mod.Key)) {
            Write-Ok "$tag -- déjà fait (reprise), skip"
            $results[$mod.Key] = 'REPRIS'
            continue
        }

        Write-Banner $tag
        if (-not $Auto) {
            $r = Read-Host "Lancer ? [O/n/q]"
            if ($r -eq 'q') { Write-Host "Stop."; break }
            if ($r -eq 'n') { Write-Host "Skip." -ForegroundColor DarkGray; $results[$mod.Key] = 'SKIP'; continue }
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            & "$Root\modules\$($mod.File)"
            $sw.Stop()
            Write-Ok "$($mod.Desc) -- OK en $([int]$sw.Elapsed.TotalSeconds)s"
            $results[$mod.Key] = 'OK'
            Add-Done $mod.Key
            # winget ne rafraîchit pas le PATH : après les apps, recharger pour que
            # git/gh/node/code soient dispo pour dev-setup / vscode dans CE run.
            if ($mod.Key -eq 'apps' -and -not $DryRun) { Update-SessionPath }
        } catch {
            $sw.Stop()
            Write-Err "$($mod.Desc) -- ÉCHEC: $_"
            $results[$mod.Key] = "ÉCHEC: $($_.Exception.Message)"
            if (-not $Auto) {
                $r = Read-Host "Continuer malgré tout ? [O/n]"
                if ($r -eq 'n') { break }
            }
        }
    }

    Write-Banner "RÉSUMÉ"
    foreach ($k in $results.Keys) {
        $v = $results[$k]
        $c = if ($v -eq 'OK') { 'Green' } elseif ($v -like 'ÉCHEC*') { 'Red' } else { 'DarkGray' }
        Write-Host ("  {0,-12} {1}" -f $k, $v) -ForegroundColor $c
    }
    $fail = @($results.Values | Where-Object { $_ -like 'ÉCHEC*' }).Count
    Write-Host ""
    if ($fail -eq 0) { Write-Ok "Tous les modules exécutés sans échec." }
    else { Write-Warn "$fail module(s) en échec -- voir le log : $LogFile" }

    Write-Banner "FINI"
    Write-Host "Reboot recommandé pour appliquer tous les tweaks." -ForegroundColor Yellow
    if (-not $SkipReboot -and -not $Auto -and -not $DryRun) {
        $r = Read-Host "Rebooter maintenant ? [o/N]"
        if ($r -eq 'o') { Restart-Computer -Force }
    }
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
