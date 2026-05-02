# Symlinks sauvegardes jeux : Saved Games + My Games + LoL/Overwatch/Dofus
. "$PSScriptRoot\00-helpers.ps1"

$gamingRoot = "$env:USERPROFILE\OneDrive\Documents\07_Gaming"
if (-not (Test-Path $gamingRoot)) {
    Write-Warn "$gamingRoot introuvable - skip games"
    return
}

# --- Génériques ---
$generic = @(
    @{ Link = "$env:USERPROFILE\Saved Games"
       Target = "$gamingRoot\Saved Games" }
    @{ Link = "$env:USERPROFILE\Documents\My Games"
       Target = "$gamingRoot\My Games" }
)

foreach ($g in $generic) {
    if (-not (Test-Path $g.Target)) {
        New-Item -ItemType Directory -Force -Path $g.Target | Out-Null
    }
    New-SymLinkSafe -Link $g.Link -Target $g.Target | Out-Null
}

# --- League of Legends configs ---
# LoL settings : Riot Games\League of Legends\Config (dans le dossier d'install)
# Plutôt qu'un symlink (dépend de l'install), on copie/restore les configs perso.
$lolBackup = "$gamingRoot\League of Legends"
if (Test-Path $lolBackup) {
    Write-Step "LoL: configs trouvées dans OneDrive"
    Write-Warn "Restore manuel : copie '$lolBackup\Config' vers <install LoL>\Config après install."
}

# --- Overwatch settings ---
# %DOCUMENTS%\Overwatch - déjà dans OneDrive\Documents\07_Gaming\Overwatch normalement
$owLink = "$env:USERPROFILE\Documents\Overwatch"
$owTarget = "$gamingRoot\Overwatch"
if (Test-Path $owTarget) {
    New-SymLinkSafe -Link $owLink -Target $owTarget | Out-Null
} else {
    Write-Warn "Overwatch backup absent dans OneDrive"
}

# --- Dofus configs ---
# %APPDATA%\Dofus ou %APPDATA%\Local\Ankama\Dofus
$dofusBackup = "$gamingRoot\Dofus"
$dofusLink = "$env:APPDATA\Dofus"
if (Test-Path $dofusBackup) {
    New-SymLinkSafe -Link $dofusLink -Target $dofusBackup | Out-Null
} else {
    Write-Warn "Dofus backup absent - sera créé au premier lancement"
}

Write-Ok "Games OK"
Write-Warn "Steam Cloud gère la majorité des autres jeux automatiquement."
