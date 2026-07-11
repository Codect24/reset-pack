# Finalize : pin taskbar, hosts file blocage pubs, ouvre Brave Sync
. "$PSScriptRoot\00-helpers.ps1"

# === BLOCAGE PUBS ===
# NOTE : on n'installe PLUS de hosts file anti-pub type StevenBlack.
# Un hosts de ~83k entrees (2.4 Mo) est memory-mappe par le service DNS Client
# (Dnscache, non-stoppable) au boot -> parsing O(n), NlaSvc reste bloque, et le
# reseau met 15-20 min a devenir dispo au demarrage. Le fichier reste aussi
# verrouille en ecriture tant que Dnscache le mappe. Bug vecu (incident 2026-07).
# A la place :
#   - Brave Shields bloque pubs + trackers nativement dans le navigateur (notre defaut)
#   - Blocage system-wide sans penalite : DNS filtrant au niveau adaptateur/routeur
#     (Cloudflare 1.1.1.2 malware / 1.1.1.3 familles, ou NextDNS)
# Si un hosts file custom est vraiment souhaite, le garder SOUS ~135 Ko
# (limite molle au-dela de laquelle Dnscache degrade fortement les perfs).
Write-Step "Blocage pubs : delegue a Brave Shields + DNS filtrant (pas de hosts file, cf. note)"

# === PIN TASKBAR ===
# Win11 a verrouillé la modif de la taskbar via API. Approche : Syspin (tiers) ou XML start layout.
# Solution pragmatique : guide manuel.
Write-Step "Pin taskbar : Brave / Explorer / Terminal / Claude"
Write-Warn "Win11 ne permet plus le pin programmatique fiable. Pin manuellement (clic droit sur l'icône > Pin to taskbar) :"
Write-Host "    - Brave"
Write-Host "    - File Explorer"
Write-Host "    - Windows Terminal"
Write-Host "    - Claude (Desktop)"

# === STORAGE SENSE ===
Write-Step "Activer Storage Sense (nettoyage auto)"
$ss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
Set-RegistryValue -Path $ss -Name '01' -Value 1            # Storage Sense ON
Set-RegistryValue -Path $ss -Name '04' -Value 1            # Vider corbeille
Set-RegistryValue -Path $ss -Name '256' -Value 30          # > 30 jours
Set-RegistryValue -Path $ss -Name '08' -Value 1            # Vider Downloads
Set-RegistryValue -Path $ss -Name '32' -Value 30
Set-RegistryValue -Path $ss -Name '2048' -Value 1          # Lance hebdo

# === OUVRIR BRAVE SYNC ===
Write-Step "Ouverture Brave Sync (colle ton code depuis ton autre device)"
if (Test-Path "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe") {
    Start-Process "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe" -ArgumentList 'brave://settings/braveSync'
} elseif (Test-Path "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe") {
    Start-Process "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe" -ArgumentList 'brave://settings/braveSync'
} else {
    Write-Warn "Brave introuvable. Ouvre brave://settings/braveSync manuellement."
}

Write-Ok "Finalize OK"
Write-Host ""
Write-Host "TODO MANUEL:" -ForegroundColor Yellow
Write-Host "  - Pin taskbar (voir au-dessus)"
Write-Host "  - Brave Sync : coller le code"
Write-Host "  - Discord/Steam/Signal : login"
Write-Host "  - Vérifier Gestionnaire de périphériques (drivers)"
