# backup-bundles.ps1 — copie n°2 du CODE (3-2-1, cf. SYSTEME-OMEN-35L.md §3.3) :
# un `git bundle --all` par dépôt -> OneDrive\Documents\08_Logiciels\CodeBundles (+ historique OneDrive 30 j).
#   - ne capture que le COMMITTÉ (le travail non committé n'est dans AUCUNE sauvegarde) ;
#   - incrémental : refs inchangées -> bundle gardé tel quel ;
#   - manifest.json = index (rel, remote, bundle) -> sert à migrate-projets.ps1 -Mode Clone pour les dépôts SANS remote ;
#   - alerte si un dépôt dépasse -WarnSizeMB (signe qu'on a committé de la data), saute au-delà de -MaxSizeMB.
# Tâche quotidienne 13h : ResetPack-CodeBundles (module 10-scheduled). Aucun secret ici : les .env ne sont pas committés.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Dest,
    [int]$WarnSizeMB = 2048,
    [int]$MaxSizeMB = 8192,
    [switch]$Force,     # refait tous les bundles, même inchangés / trop gros
    [switch]$Quiet      # mode tâche planifiée : résumé ajouté à %LOCALAPPDATA%\ResetPack\bundles.log
)
# 00-helpers pose $script:DryRun depuis l'env : on capture le switch avant, on le réapplique après.
$isDry = $DryRun.IsPresent -or ($env:RESETPACK_DRYRUN -eq '1')
. "$PSScriptRoot\modules\00-helpers.ps1"
$DryRun = $isDry; $script:DryRun = $isDry

function Get-RefsHash {
    param([Parameter(Mandatory)][string]$Repo)
    $refs = (git -C $Repo for-each-ref --format='%(objectname) %(refname)' 2>$null) -join "`n"
    if (-not $refs) { return $null }
    $sha = [Security.Cryptography.SHA1]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($refs))) -replace '-', '').ToLower()
}

function Get-PackSizeMB {
    param([Parameter(Mandatory)][string]$Repo)
    $kb = 0
    foreach ($l in @(git -C $Repo count-objects -v 2>$null)) {
        if ($l -match '^(size|size-pack): (\d+)') { $kb += [int64]$Matches[2] }
    }
    return [math]::Round($kb / 1024, 1)
}

function Invoke-BackupBundles {
    if (-not (Test-CommandExists git)) { throw "git absent." }
    $target = $Dest
    if (-not $target) {
        try { $target = (Get-StorageLayout).bundlesDir } catch { $target = Join-Path $script:OneDriveRoot 'Documents\08_Logiciels\CodeBundles' }
    }
    if (-not $Quiet) { Write-Banner "BUNDLES GIT -> $target$(if ($DryRun) { ' (DRY-RUN)' })" }
    New-DirectorySafe -Path $target | Out-Null

    $manifestPath = Join-Path $target 'manifest.json'
    $old = @{}
    if (Test-Path $manifestPath) {
        try { foreach ($e in @((Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).entries)) { $old[$e.rel] = $e } }
        catch { Write-Warn "manifest.json illisible : il sera régénéré." }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $seenRel = @{}
    $stats = [ordered]@{ crees = 0; inchanges = 0; echecs = 0; sautes = 0 }
    $noRemote = @()
    $roots = @(Get-ProjetsRoots)
    # Sur l'OMEN, l'ancien dossier OneDrive est en « fichiers à la demande » : le bundler l'hydraterait. On s'en tient
    # au vrai dossier local (C:\Dev\...). Sur EXODIUS (jonction), la racine OneDrive EST le dossier de travail.
    if ((Get-ResetProfile) -eq 'omen') { $roots = @($roots | Where-Object { $_ -notmatch '(?i)\\OneDrive\\' }) }
    foreach ($root in $roots) {
        foreach ($repo in (Find-GitRepos -Root $root -MaxDepth 3)) {
            $rel = $repo.Substring($root.Length).TrimStart('\')
            if (-not $rel -or $seenRel.ContainsKey($rel.ToLower())) { continue }
            $seenRel[$rel.ToLower()] = $true

            $hash = Get-RefsHash -Repo $repo
            if (-not $hash) { if (-not $Quiet) { Write-Step "$rel : dépôt vide, ignoré" }; continue }
            $remote = "$(git -C $repo config --get remote.origin.url 2>$null)".Trim()
            if (-not $remote) { $noRemote += $rel }
            $name = ($rel -replace '[\\/:]', '__') + '.bundle'
            $file = Join-Path $target $name
            $entry = [ordered]@{ rel = $rel; remote = $remote; bundle = $name; refsHash = $hash
                                 sizeMB = 0; date = (Get-Date).ToString('s'); machine = $env:COMPUTERNAME }

            $prev = $old[$rel]
            if (-not $Force -and $prev -and $prev.refsHash -eq $hash -and (Test-Path $file)) {
                $entry.sizeMB = $prev.sizeMB; $entry.date = $prev.date; $entry.machine = $prev.machine
                $entries.Add($entry); $stats.inchanges++; continue
            }
            $pack = Get-PackSizeMB -Repo $repo
            if (-not $Force -and $pack -gt $MaxSizeMB) {
                Write-Warn "$rel : $pack Mo d'objets > $MaxSizeMB Mo -> SAUTÉ (data committée ? -Force pour forcer)"
                if ($prev) { $entries.Add($prev) }
                $stats.sautes++; continue
            }
            if ($DryRun) { Write-Dry "git bundle create $name --all  (~$pack Mo)"; $entries.Add($entry); $stats.crees++; continue }

            # Écriture dans %TEMP% puis déplacement : OneDrive ne synchronise jamais un bundle à moitié écrit.
            $tmp = Join-Path $env:TEMP "rp-$name"
            git -C $repo bundle create $tmp --all 2>&1 | Out-Null
            $okCreate = ($LASTEXITCODE -eq 0) -and (Test-Path $tmp)
            if ($okCreate) { git bundle verify $tmp 2>&1 | Out-Null; $okCreate = ($LASTEXITCODE -eq 0) }
            if (-not $okCreate) {
                Write-Err "$rel : bundle KO"
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                if ($prev) { $entries.Add($prev) }
                $stats.echecs++; continue
            }
            Move-Item $tmp $file -Force
            $entry.sizeMB = [math]::Round((Get-Item $file).Length / 1MB, 1)
            if ($entry.sizeMB -gt $WarnSizeMB) { Write-Warn "$rel : bundle de $($entry.sizeMB) Mo (> $WarnSizeMB) -> data committée ?" }
            elseif (-not $Quiet) { Write-Ok "$rel ($($entry.sizeMB) Mo)" }
            $entries.Add($entry); $stats.crees++
        }
    }

    if (-not $DryRun) {
        $manifest = [ordered]@{ generated = (Get-Date).ToString('s'); machine = $env:COMPUTERNAME; entries = $entries.ToArray() }
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    }

    $summary = "bundles : " + (($stats.GetEnumerator() | ForEach-Object { "$($_.Value) $($_.Key)" }) -join ', ') +
               " | $($noRemote.Count) dépôt(s) sans remote"
    if ($Quiet) {
        $logDir = Join-Path $env:LOCALAPPDATA 'ResetPack'
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        Add-Content -Path (Join-Path $logDir 'bundles.log') -Value ("{0:s} {1}" -f (Get-Date), $summary)
    } else {
        Write-Ok $summary
        if ($noRemote) {
            Write-Warn "Sans remote GitHub (ce bundle = leur SEULE copie hors poste) :"
            $noRemote | ForEach-Object { Write-Warn "  $_" }
        }
    }
    if ($stats.echecs -gt 0) { exit 1 }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-BackupBundles }
