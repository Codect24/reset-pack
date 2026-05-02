# Drivers : NVCleanstall (Nvidia) + Snappy Driver Installer Origin (chipset/audio/etc.)
. "$PSScriptRoot\00-helpers.ps1"

# --- NVCleanstall ---
Write-Step "NVCleanstall (Nvidia)"
$nvUrl = 'https://www.techpowerup.com/download/techpowerup-nvcleanstall/'
$nvExe = "$script:DownloadDir\NVCleanstall.exe"
Write-Warn "URL directe NVCleanstall change souvent - page de DL ouverte si besoin"
try {
    # Tentative direct (TechPowerUp peut nécessiter passer par leur page)
    Invoke-Download -Url 'https://www.techpowerup.com/download/techpowerup-nvcleanstall/?ID=4234' -OutFile $nvExe
} catch {
    Write-Warn "Échec DL auto. Ouvre la page :"
    Start-Process $nvUrl
    Read-Host "Télécharge manuellement -> $script:DownloadDir, renomme NVCleanstall.exe, puis Entrée"
}
if (Test-Path $nvExe) {
    Write-Step "Lancement NVCleanstall (mode interactif - pas de vrai silent)"
    Start-Process $nvExe -Wait
    Write-Ok "NVCleanstall fini"
}

# --- Snappy Driver Installer Origin ---
Write-Step "SDIO (Snappy Driver Installer Origin)"
$sdioZip = "$script:DownloadDir\SDIO.zip"
$sdioDir = "$script:DownloadDir\SDIO"
try {
    Invoke-Download -Url 'https://www.snappy-driver-installer.org/downloads/SDIO_Update.zip' -OutFile $sdioZip
    if (-not (Test-Path $sdioDir)) {
        Expand-Archive -Path $sdioZip -DestinationPath $sdioDir -Force
    }
    $sdioExe = Get-ChildItem -Path $sdioDir -Filter 'SDIO_*.exe' -Recurse | Select-Object -First 1
    if ($sdioExe) {
        Write-Step "Lancement SDIO en mode auto-install drivers manquants"
        # Flags : -autoinstall -autoclose -installoffline (silent best-effort)
        Start-Process $sdioExe.FullName -ArgumentList '-autoinstall', '-autoclose' -Wait
        Write-Ok "SDIO terminé"
    } else {
        Write-Warn "Exe SDIO introuvable dans le zip"
    }
} catch {
    Write-Warn "Échec DL SDIO : $_"
    Write-Warn "Lien : https://www.snappy-driver-installer.org/"
}

Write-Ok "Drivers OK (vérifier Gestionnaire de périphériques pour points d'exclamation jaunes)"
