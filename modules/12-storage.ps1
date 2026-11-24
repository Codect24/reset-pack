# 12-storage : prépare/oriente le stockage sur le disque D: (plan d'audit §6)
# Crée l'arborescence D:, pose HF_HOME, et guide les étapes non scriptables de façon fiable.
. "$PSScriptRoot\00-helpers.ps1"

if (-not (Test-Path 'D:\')) {
    Write-Warn "Disque D: absent -> module stockage ignoré."
    Write-Warn "Branche/initialise le SSD 1 To (Crucial P310), crée le volume D:, puis : .\reset.ps1 -Only storage"
    return
}

# 1. Arborescence cible sur D:
$dirs = @('D:\Docker', 'D:\WSL', 'D:\ml\huggingface', 'D:\Archives', 'D:\SteamLibrary', 'D:\Code')
foreach ($d in $dirs) {
    if ($script:DryRun) { Write-Dry "mkdir $d" }
    else { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
Write-Ok "Arborescence D: prête ($($dirs.Count) dossiers)"

# 2. Caches ML (HuggingFace) sur D: via variable d'env user -> évite de re-remplir C:
if ($script:DryRun) { Write-Dry "SetEnvironmentVariable HF_HOME=D:\ml\huggingface (User)" }
else {
    [Environment]::SetEnvironmentVariable('HF_HOME', 'D:\ml\huggingface', 'User')
    Write-Ok "HF_HOME = D:\ml\huggingface (effectif après réouverture du terminal)"
}

# 3. Étapes à finaliser à la main (fiabilité : non scriptées)
Write-Banner "STOCKAGE D: — étapes à finaliser"
Write-Host @"
  Docker Desktop : Settings > Resources > Advanced > 'Disk image location' = D:\Docker
                   (ou %ProgramData%\Docker\config\daemon.json : "data-root": "D:\\Docker") puis Apply & Restart.

  WSL (déplacer Ubuntu ~52 Go sur D:) :
     wsl --shutdown
     wsl --export Ubuntu D:\WSL\ubuntu-backup.tar
     wsl --unregister Ubuntu
     wsl --import Ubuntu D:\WSL\Ubuntu D:\WSL\ubuntu-backup.tar
     # remets ton user par défaut : ubuntu config --default-user <toi>

  Steam  : Paramètres > Stockage > '+' > D:\SteamLibrary (installe les jeux là).
  Riot / Blizzard / Epic / GOG : choisir un dossier d'install sur D:.

  OneDrive : pour tout mettre sur D:, délie le compte (Paramètres OneDrive) puis
             reconfigure en choisissant D:\OneDrive comme emplacement
             (ou garde C: avec la synchro sélective pour ne pas hydrater Mutinerie).

  Gros projets (Mutinerie ~97 Go) : déplacer vers D:\Archives ou D:\Code (hors OneDrive).
"@ -ForegroundColor Gray

Write-Ok "Storage OK (finalise les étapes ci-dessus)"
