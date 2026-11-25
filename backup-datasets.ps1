# backup-datasets.ps1 — copie n°2 des données DL sur le SSD externe (X:), cf. SYSTEME-OMEN-35L.md §3.3.
#   - datasets + runs (checkpoints, logs) de C:\ML  -> X:\ResetPack-Backup\ML\...   (robocopy, sans purge par défaut)
#   - -WslExport : wsl --export de la distro -> X:\ResetPack-Backup\wsl\<distro>-<date>.tar  (arrête WSL !)
#   - -IncludeHfCache : ajoute le cache HuggingFace (souvent plus simple de re-télécharger : fibre 8 Gb/s)
#   - -Mirror : miroir exact (SUPPRIME côté X: ce qui a disparu de C:) — à éviter sauf ménage voulu.
# Jamais vers OneDrive. -DryRun = robocopy /L (liste sans copier).
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Dest,
    [switch]$WslExport,
    [switch]$IncludeHfCache,
    [switch]$Mirror
)
$isDry = $DryRun.IsPresent -or ($env:RESETPACK_DRYRUN -eq '1')
. "$PSScriptRoot\modules\00-helpers.ps1"
$DryRun = $isDry; $script:DryRun = $isDry

function Invoke-BackupDatasets {
    $layout = Get-StorageLayout
    $root = if ($Dest) { $Dest } else { Join-Path "$($layout.backupDrive)\" 'ResetPack-Backup' }
    Write-Banner "BACKUP DATASETS -> $root$(if ($DryRun) { ' (DRY-RUN)' })"
    if ($root -match '(?i)OneDrive') { throw "Destination dans OneDrive interdite (volume + données parfois sensibles)." }
    $q = Split-Path $root -Qualifier
    if (-not (Test-Path "$q\")) { throw "Lecteur $q absent : branche le SSD externe (lettre $($layout.backupDrive) réservée)." }

    $jobs = @()
    if ($layout.mlDatasets) { $jobs += @{ From = $layout.mlDatasets; To = Join-Path $root 'ML\datasets' } }
    if ($layout.mlRuns)     { $jobs += @{ From = $layout.mlRuns;     To = Join-Path $root 'ML\runs' } }
    if ($IncludeHfCache -and $layout.env.HF_HOME) { $jobs += @{ From = $layout.env.HF_HOME; To = Join-Path $root 'ML\hf' } }

    foreach ($j in $jobs) {
        if (-not (Test-Path $j.From)) { Write-Warn "Absent, sauté : $($j.From)"; continue }
        $flags = @('/E', '/R:1', '/W:2', '/NP', '/NDL', '/MT:8', '/XJ')
        if ($Mirror) { $flags += '/PURGE' }
        if ($DryRun) { $flags += '/L' }
        Write-Step "$($j.From) -> $($j.To)$(if ($Mirror) { '  [MIROIR]' })"
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $j.To | Out-Null }
        robocopy $j.From $j.To @flags /NJH | Select-Object -Last 12 | Out-Host
        if ($LASTEXITCODE -ge 8) { Write-Err "robocopy KO ($LASTEXITCODE) pour $($j.From)" } else { Write-Ok "OK : $($j.From)" }
    }

    if ($WslExport) {
        $distro = $layout.wsl.distro
        $tar = Join-Path $root ("wsl\{0}-{1:yyyyMMdd}.tar" -f $distro, (Get-Date))
        if ($DryRun) { Write-Dry "wsl --shutdown ; wsl --export $distro $tar" }
        else {
            New-Item -ItemType Directory -Force -Path (Split-Path $tar) | Out-Null
            Write-Warn "Arrêt de WSL (les sessions Linux en cours sont coupées)..."
            wsl --shutdown
            wsl --export $distro $tar
            if ($LASTEXITCODE -eq 0) { Write-Ok "WSL exportée : $tar ($([math]::Round((Get-Item $tar).Length / 1GB, 1)) Go)" }
            else { Write-Err "wsl --export KO ($LASTEXITCODE)" }
        }
    }
    Write-Warn "Les données WSL (~/ml dans ext4) ne sont couvertes QUE par -WslExport. Volumes Docker : voir TODO de backup-secrets.ps1."
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-BackupDatasets } catch { Write-Err $_.Exception.Message; exit 1 }
}
