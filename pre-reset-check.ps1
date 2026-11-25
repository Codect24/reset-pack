# pre-reset-check.ps1 — AVANT un reset : repère ce qui n'est NI poussé NI sauvegardé.
# Lecture seule (ne modifie rien). À lancer, relire les  !!  puis agir.
. "$PSScriptRoot\modules\00-helpers.ps1"
Write-Banner "PRE-RESET CHECK (lecture seule)"

# Toutes les racines connues (PROJETS_CODE + ancienne OneDrive) : un projet déplacé reste couvert.
$roots = Get-ProjetsRoots
if (-not $roots) { Write-Warn "03_Projets_Code introuvable (ni PROJETS_CODE ni OneDrive\Documents\03_Projets_Code)" }

foreach ($codeRoot in $roots) {
# 1. Dépôts git : working tree sale / commits non poussés / pas de remote
Write-Banner "1. Dépôts git à risque ($codeRoot)"
if (Test-Path $codeRoot) {
    Get-ChildItem $codeRoot -Directory -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName '.git') } | ForEach-Object {
            $r = $_.FullName
            $dirty = git -C $r status --porcelain 2>$null
            $ahead = (git -C $r rev-list --count '@{u}..HEAD' 2>$null)
            $hasRemote = [bool](git -C $r remote 2>$null)
            $flags = @()
            if ($dirty) { $flags += "sale($(@($dirty).Count))" }
            if ($ahead -and $ahead -ne '0') { $flags += "non-poussé($ahead)" }
            if (-not $hasRemote) { $flags += "pas-de-remote" }
            if ($flags) { Write-Warn ("{0}  [{1}]" -f $r.Replace($codeRoot, '...'), ($flags -join ', ')) }
        }
    Write-Ok "Scan dépôts terminé"
}

# 2. Fichiers sensibles / non versionnés (.env, clés)
Write-Banner "2. .env / clés (à sauver HORS git via backup-secrets.ps1)"
if (Test-Path $codeRoot) {
    Get-ChildItem $codeRoot -Recurse -Force -Include '.env', '*.env', '*.pem', '*.key' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
        Select-Object -First 60 | ForEach-Object { Write-Warn $_.FullName.Replace($codeRoot, '...') }
}
}  # fin foreach racine

# 3. Clés SSH
Write-Banner "3. Clés SSH (~/.ssh)"
if (Test-Path "$env:USERPROFILE\.ssh") {
    Get-ChildItem "$env:USERPROFILE\.ssh" -File | ForEach-Object { Write-Step $_.Name }
    Write-Warn "-> sauvegarde ~/.ssh HORS OneDrive avec : .\backup-secrets.ps1 -Dest <USB>"
} else { Write-Ok "Pas de ~/.ssh" }

# 4. WSL + Docker à exporter
Write-Banner "4. WSL / Docker"
$env:WSL_UTF8 = '1'; wsl -l -v 2>$null
Write-Warn "WSL : wsl --export <distro> D:\WSL\<distro>.tar  (avant reset !)"
if (Test-CommandExists docker) {
    $vols = docker volume ls -q 2>$null
    if ($vols) { Write-Warn "Volumes Docker (à exporter si données uniques) :"; $vols | ForEach-Object { Write-Step $_ } }
    else { Write-Step "Docker : démon arrêté ou aucun volume (démarre Docker Desktop pour lister)" }
}

# 5. OneDrive
Write-Banner "5. OneDrive"
Write-Warn "Vérifie que l'icône OneDrive est 'À jour' (aucune flèche de synchro) AVANT de resetter."

Write-Banner "FIN — agis sur les  !!  ci-dessus"
