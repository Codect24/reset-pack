# Drivers : NVCleanstall (Nvidia) + Snappy Driver Installer Origin (chipset/audio/etc.)
. "$PSScriptRoot\00-helpers.ps1"

if ($script:DryRun) { Write-Dry "drivers : NVCleanstall + SDIO (skip en dry-run)"; Write-Ok "Drivers OK (dry)"; return }

# --- NVCleanstall (Nvidia) ---
# Le lien "direct" TechPowerUp passe par un interstitiel : il renvoie du HTML en 200 OK
# (pas l'exe), et l'ID de build change souvent -> on NE tente PAS le download auto
# (ça produisait un faux .exe lancé ensuite). On ouvre la page pour un DL manuel.
Write-Step "NVCleanstall : téléchargement MANUEL"
Write-Warn "TechPowerUp n'a pas de lien direct fiable. Récupère NVCleanstall sur la page,"
Write-Warn "lance-le et fais un 'clean install' du driver Nvidia."
if (-not $script:Auto) {
    Start-Process 'https://www.techpowerup.com/download/techpowerup-nvcleanstall/'
    Read-Host "Entrée une fois NVCleanstall récupéré/installé (ou pour passer)"
} else {
    Write-Warn "Mode AUTO : à faire plus tard -> https://www.techpowerup.com/download/techpowerup-nvcleanstall/"
}

# --- Snappy Driver Installer Origin (chipset/audio/réseau...) ---
Write-Step "SDIO (Snappy Driver Installer Origin)"
$sdioZip = "$script:DownloadDir\SDIO.zip"
$sdioDir = "$script:DownloadDir\SDIO"
try {
    Invoke-Download -Url 'https://www.snappy-driver-installer.org/downloads/SDIO_Update.zip' -OutFile $sdioZip
    if (-not (Test-Path $sdioDir)) { Expand-Archive -Path $sdioZip -DestinationPath $sdioDir -Force }
    # Choisir explicitement le binaire 64-bit (le zip contient aussi un SDIO_R*.exe 32-bit)
    $sdioExe = Get-ChildItem -Path $sdioDir -Filter 'SDIO_x64_*.exe' -Recurse | Select-Object -First 1
    if (-not $sdioExe) { $sdioExe = Get-ChildItem -Path $sdioDir -Filter 'SDIO_*.exe' -Recurse | Select-Object -First 1 }
    if ($sdioExe) {
        # PAS de -autoinstall : sur un laptop, installer tous les drivers en aveugle peut
        # poser des drivers inadaptés et entrer en conflit avec NVCleanstall. Mode interactif.
        Write-Warn "SDIO s'ouvre en INTERACTIF : coche uniquement les drivers manquants pertinents, puis installe."
        Start-Process $sdioExe.FullName
        if (-not $script:Auto) { Read-Host "Entrée une fois SDIO terminé" }
    } else {
        Write-Warn "Exe SDIO introuvable dans le zip"
    }
} catch {
    Write-Warn "Échec SDIO : $_  (lien : https://www.snappy-driver-installer.org/)"
}

Write-Ok "Drivers OK (vérifier le Gestionnaire de périphériques : aucun point d'exclamation jaune)"
