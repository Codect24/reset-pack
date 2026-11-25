# 12-storage : arborescence C:/D: + variables d'environnement selon config/storage-layout.json.
# SEUL propriétaire de l'arborescence : aucun autre module ne crée ces dossiers (cf. SYSTEME-OMEN-35L.md §2).
#   omen    : C: = OS + dev + Docker/WSL + DL (écritures) ; D: (P310 QLC) = jeux + froid en lecture.
#   exodius : disposition historique (data lourde sur D:).
. "$PSScriptRoot\00-helpers.ps1"

$layout = Get-StorageLayout
Write-Step "Profil stockage : $($layout.Name)"

# --- 1. Dossiers (un lecteur absent est signalé, jamais bloquant) ---
$missingDrives = @{}
$created = 0
foreach ($d in @($layout.dirs)) {
    $q = Split-Path $d -Qualifier
    if (-not (Test-Path "$q\")) { $missingDrives[$q] = $true; continue }
    if (New-DirectorySafe -Path $d) { $created++ }
}
Write-Ok "Arborescence : $created dossier(s) créé(s), $(@($layout.dirs).Count) attendus"
foreach ($q in $missingDrives.Keys) {
    Write-Warn "Lecteur $q absent : ses dossiers sont sautés."
    if ($layout.gamesDisk -and $q -eq "$($layout.gamesDisk.letter):") {
        Write-Warn "  -> SSD jeux pas encore prêt : .\format-ssd-jeux.ps1 -DryRun, puis en réel, puis : .\reset.ps1 -Profile $($layout.Name) -Only storage"
    }
}

# --- 2. Variables d'environnement (User) : chaînes EXACTES du layout ---
foreach ($p in $layout.env.PSObject.Properties) { Set-UserEnvVar -Name $p.Name -Value $p.Value }
foreach ($n in @($layout.removeEnv)) { if ($n) { Set-UserEnvVar -Name $n -Value '' } }

# --- 3. Le disque D: est-il bien le SSD jeux attendu ? (lecture seule) ---
if ($layout.gamesDisk) {
    $gl = $layout.gamesDisk.letter
    try {
        $disk = Get-Partition -DriveLetter $gl -ErrorAction Stop | Get-Disk
        if ("$($disk.FriendlyName) $($disk.Model)" -match [regex]::Escape($layout.gamesDisk.modelMatch)) {
            Write-Ok "${gl}: = $($disk.FriendlyName) (disque $($disk.Number))"
        } else {
            Write-Warn "${gl}: est '$($disk.FriendlyName)' et non le SSD jeux ($($layout.gamesDisk.modelMatch)) -> vérifie avant d'y installer des jeux."
        }
    } catch { Write-Verbose "${gl}: non monté : $($_.Exception.Message)" }
}

# --- 4. Hibernation off sur une tour (omen) : +13-26 Go sur C: ---
if ($layout.Name -eq 'omen') {
    if (Test-Path "$env:SystemDrive\hiberfil.sys") {
        if ($script:DryRun) { Write-Dry "powercfg /h off (libère hiberfil.sys)" }
        else { powercfg /h off; Write-Ok "Hibernation désactivée (hiberfil.sys libéré)" }
    } else { Write-Ok "Hibernation déjà désactivée" }
}

# --- 5. Santé de C: (garder >= 15 % libres) ---
try {
    $c = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
    $pct = [math]::Round(100 * $c.SizeRemaining / $c.Size, 1)
    $msg = "C: : {0:N0} Go libres sur {1:N0} ({2} %)" -f ($c.SizeRemaining / 1GB), ($c.Size / 1GB), $pct
    if ($pct -lt 15) { Write-Warn "$msg -> sous 15 % : purge (docker system prune, caches) ou D:\ML-cold / X:" } else { Write-Ok $msg }
} catch { Write-Verbose "Get-Volume C: indisponible" }

# --- 6. Étapes non scriptées (fiabilité) ---
Write-Banner "STOCKAGE ($($layout.Name)) : étapes à finaliser"
if ($layout.Name -eq 'omen') {
    Write-Host @"
  Steam     : Paramètres > Stockage > '+' > $($layout.launchers.Steam) > définir par défaut.
  Epic      : géré par le module gaming ($($layout.launchers.Epic)).
  Battle.net: client sur C:, dossier des jeux = $($layout.launchers.BattleNet) (dans l'app).
  Riot      : installer via le client dans $($layout.launchers.Riot) ; Vanguard reste sur C: (imposé).
  Docker    : on LAISSE le défaut (C:). Jamais sur D: (QLC = mauvais en écriture soutenue).
  WSL       : distro attendue dans $($layout.wsl.location) (module ml : commande --move si besoin).
  OneDrive  : Fichiers à la demande ON, OneDrive reste sur C:, et DÉCOCHE l'ancien 03_Projets_Code
              (synchro sélective) une fois migrate-projets.ps1 passé.
  Captures  : NVIDIA App > Paramètres > Capture > dossier = $($layout.captures).
  Soupapes  : C: > 80 % -> purge, puis $($layout.mlCold) (poids statiques), puis SSD externe $($layout.backupDrive).
"@ -ForegroundColor Gray
} else {
    Write-Host @"
  Docker Desktop : Settings > Resources > Advanced > 'Disk image location' = D:\Docker.
  WSL (déplacer Ubuntu sur D:) : wsl --shutdown ; wsl --manage Ubuntu --move $($layout.wsl.location)
                                 (sinon --export / --unregister / --import).
  Steam  : Paramètres > Stockage > '+' > $($layout.launchers.Steam).
  Gros projets (Mutinerie ~97 Go) : D:\Archives ou D:\Code (hors OneDrive).
"@ -ForegroundColor Gray
}

Write-Ok "Storage OK (profil $($layout.Name))"
