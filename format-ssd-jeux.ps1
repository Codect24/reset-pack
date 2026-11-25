#Requires -Version 5.1
# format-ssd-jeux.ps1 — EFFACE puis reformate le SSD jeux (Crucial P310) en  D:  "Jeux"  (GPT + NTFS).
#
#  !! DESTRUCTIF : TOUTES les données du disque ciblé sont perdues (c'est voulu : il revient d'EXODIUS). !!
#
# Garde-fous (aucun n'est contournable par un paramètre) :
#   - cible = UN SEUL disque dont le modèle contient 'P310' (config/storage-layout.json, profil omen) ;
#   - refuse le disque boot/système, celui qui porte C:, celui qui porte un pagefile,
#     un bus autre que NVMe, une taille hors 900-1100 Go ;
#   - montre le contenu actuel du disque, puis exige de taper  EFFACER <n° du disque>.
#
# Usage (PowerShell ADMIN, sur l'OMEN, P310 installé dans le 2e slot M.2) :
#   .\format-ssd-jeux.ps1 -DryRun      # montre le disque choisi, ce qui sera effacé, ne touche à rien
#   .\format-ssd-jeux.ps1              # en réel (confirmation tapée)
#   puis : .\reset.ps1 -Profile omen -Only storage   (crée D:\Games\... — aucun dossier à la main)
[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$DiskNumber = -1,      # forcer un n° de disque (tous les garde-fous restent actifs)
    [string]$ModelMatch,        # défaut : layout omen  gamesDisk.modelMatch  ('P310')
    [string]$DriveLetter,       # défaut : layout omen  gamesDisk.letter      ('D')
    [string]$Label              # défaut : layout omen  gamesDisk.label       ('Jeux')
)

# ATTENTION : 00-helpers pose $script:DryRun depuis l'env -> il ÉCRASERAIT le switch -DryRun de ce script
# (même variable de portée script). On capture donc le switch AVANT et on le réapplique APRÈS.
$isDry = $DryRun.IsPresent -or ($env:RESETPACK_DRYRUN -eq '1')
. "$PSScriptRoot\modules\00-helpers.ps1"
$DryRun = $isDry
$script:DryRun = $isDry

function Get-DiskInventory {
    # Vue à plat de tous les disques + lettres + pagefile. Lecture seule.
    $pagefileLetters = @()
    try {
        $pagefileLetters = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop |
            ForEach-Object { ($_.Name -split ':')[0].ToUpper() })
    } catch { Write-Verbose "Win32_PageFileUsage indisponible" }
    $sysLetter = $env:SystemDrive.TrimEnd(':').ToUpper()

    foreach ($d in @(Get-Disk)) {
        $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)
        $letters = @($parts | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
            ForEach-Object { "$($_.DriveLetter)".ToUpper() })
        [pscustomobject]@{
            Number         = [int]$d.Number
            FriendlyName   = "$($d.FriendlyName)"
            Model          = "$($d.Model)"
            Serial         = "$($d.SerialNumber)".Trim()
            BusType        = "$($d.BusType)"
            SizeGB         = [math]::Round($d.Size / 1GB, 0)
            PartitionStyle = "$($d.PartitionStyle)"
            IsBoot         = [bool]$d.IsBoot
            IsSystem       = [bool]$d.IsSystem
            IsOffline      = [bool]$d.IsOffline
            IsReadOnly     = [bool]$d.IsReadOnly
            Letters        = $letters
            HasSystemDrive = ($letters -contains $sysLetter)
            HasPagefile    = [bool](@($letters | Where-Object { $pagefileLetters -contains $_ }).Count)
            Partitions     = $parts
        }
    }
}

function Get-GamesDiskRefusal {
    # Raisons de REFUSER un disque comme cible (vide = acceptable). Pure : testable sans matériel.
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)][string]$Match,
        [int]$MinGB = 900,
        [int]$MaxGB = 1100
    )
    $r = @()
    if ($Disk.IsBoot)          { $r += 'disque de démarrage' }
    if ($Disk.IsSystem)        { $r += 'disque système' }
    if ($Disk.HasSystemDrive)  { $r += "porte $env:SystemDrive" }
    if ($Disk.HasPagefile)     { $r += 'porte un fichier d''échange' }
    if ("$($Disk.FriendlyName) $($Disk.Model)" -notmatch [regex]::Escape($Match)) { $r += "modèle ≠ '$Match'" }
    if ($Disk.BusType -ne 'NVMe') { $r += "bus $($Disk.BusType) (NVMe attendu)" }
    if ($Disk.SizeGB -lt $MinGB -or $Disk.SizeGB -gt $MaxGB) { $r += "taille $($Disk.SizeGB) Go hors $MinGB-$MaxGB" }
    return , $r
}

function Select-GamesDisk {
    # Renvoie LE disque cible, ou lève une erreur explicite (0 ou plusieurs candidats).
    param(
        [Parameter(Mandatory)][object[]]$Inventory,
        [Parameter(Mandatory)][string]$Match,
        [int]$Number = -1,
        [int]$MinGB = 900,
        [int]$MaxGB = 1100
    )
    $pool = $Inventory
    if ($Number -ge 0) {
        $pool = @($Inventory | Where-Object { $_.Number -eq $Number })
        if (-not $pool) { throw "Disque n°$Number introuvable." }
    }
    $ok = @(); $ko = @()
    foreach ($d in $pool) {
        $why = Get-GamesDiskRefusal -Disk $d -Match $Match -MinGB $MinGB -MaxGB $MaxGB
        if ($why.Count -eq 0) { $ok += $d } else { $ko += "  disque $($d.Number) '$($d.FriendlyName)' : $($why -join ', ')" }
    }
    if ($ok.Count -eq 1) { return $ok[0] }
    if ($ok.Count -eq 0) { throw "Aucun disque acceptable.`n$($ko -join "`n")" }
    throw "Plusieurs disques '$Match' acceptables ($(($ok | ForEach-Object { $_.Number }) -join ', ')) : précise -DiskNumber."
}

function Show-DiskContent {
    # Ce qui va être effacé : partitions, volumes, 1er niveau de chaque volume monté.
    param([Parameter(Mandatory)]$Disk)
    Write-Host ("  Disque {0} : {1}  |  série {2}  |  {3} Go  |  {4}  |  {5}" -f $Disk.Number, $Disk.FriendlyName,
        $Disk.Serial, $Disk.SizeGB, $Disk.BusType, $Disk.PartitionStyle) -ForegroundColor White
    if (-not $Disk.Partitions -or $Disk.Partitions.Count -eq 0) { Write-Host "    (aucune partition)" -ForegroundColor DarkGray; return }
    foreach ($p in $Disk.Partitions) {
        $letter = if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) { "$($p.DriveLetter):" } else { '--' }
        Write-Host ("    partition {0}  {1,-4} {2,8:N1} Go  {3}" -f $p.PartitionNumber, $letter, ($p.Size / 1GB), $p.Type) -ForegroundColor Gray
        if ($letter -ne '--') {
            try {
                $v = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction Stop
                Write-Host ("      volume '{0}' {1} : {2:N1} Go utilisés" -f $v.FileSystemLabel, $v.FileSystem, (($v.Size - $v.SizeRemaining) / 1GB)) -ForegroundColor Gray
                Get-ChildItem "$letter\" -Force -ErrorAction SilentlyContinue | Select-Object -First 20 |
                    ForEach-Object { Write-Host "        $($_.Name)" -ForegroundColor DarkGray }
            } catch { Write-Host "      (volume illisible : chiffré/verrouillé ?)" -ForegroundColor DarkYellow }
        }
    }
}

function Resolve-DriveLetterConflict {
    # La lettre voulue est-elle prise par AUTRE CHOSE que le disque cible ?
    # Lecteur optique / carte -> déplacé sur la 1re lettre libre. Autre disque -> arrêt.
    param([Parameter(Mandatory)][string]$Letter, [Parameter(Mandatory)][int]$TargetNumber)
    $Letter = $Letter.TrimEnd(':').ToUpper()
    $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='${Letter}:'" -ErrorAction SilentlyContinue
    if (-not $vol) { return }
    $part = Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue
    if ($part -and $part.DiskNumber -eq $TargetNumber) { return }   # c'est déjà le P310 : il sera effacé
    if ($vol.DriveType -in 2, 5) {                                     # 2 = amovible, 5 = optique
        $used = @(Get-CimInstance Win32_Volume | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter.TrimEnd(':') })
        $free = [char[]](69..90) | ForEach-Object { "$_" } | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if ($DryRun) { Write-Dry "lecteur amovible/optique ${Letter}: -> ${free}:"; return }
        Set-CimInstance -InputObject $vol -Property @{ DriveLetter = "${free}:" }
        Write-Ok "Lecteur amovible/optique déplacé de ${Letter}: vers ${free}:"
        return
    }
    throw "${Letter}: est déjà utilisé par un autre disque (disque $($part.DiskNumber)). Libère-le ou passe -DriveLetter."
}

function Invoke-FormatGamesDisk {
    param([Parameter(Mandatory)]$Disk, [Parameter(Mandatory)][string]$Letter, [Parameter(Mandatory)][string]$VolumeLabel)
    $n = $Disk.Number
    if ($DryRun) {
        Write-Dry "Set-Disk $n online/RW ; Clear-Disk $n -RemoveData -RemoveOEM ; Initialize-Disk $n GPT"
        Write-Dry "New-Partition $n -UseMaximumSize -DriveLetter $Letter ; Format-Volume NTFS '$VolumeLabel' (4 Ko) ; Optimize-Volume -ReTrim"
        return
    }
    if ($Disk.IsOffline)  { Set-Disk -Number $n -IsOffline $false }
    if ($Disk.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false }
    Write-Step "Effacement de la table de partitions du disque $n"
    Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false
    Write-Step "Initialisation GPT"
    Initialize-Disk -Number $n -PartitionStyle GPT
    Write-Step "Partition unique -> ${Letter}:"
    New-Partition -DiskNumber $n -UseMaximumSize -DriveLetter $Letter | Out-Null
    Write-Step "Formatage NTFS '$VolumeLabel'"
    Format-Volume -DriveLetter $Letter -FileSystem NTFS -NewFileSystemLabel $VolumeLabel -AllocationUnitSize 4096 -Confirm:$false | Out-Null
    # TRIM de tout le volume : le contrôleur (QLC, sans DRAM) sait que tout est libre -> perfs d'écriture nominales.
    Write-Step "TRIM complet du volume"
    Optimize-Volume -DriveLetter $Letter -ReTrim
    Write-Ok "Disque $n prêt : ${Letter}: '$VolumeLabel'"
}

function Invoke-Main {
    Write-Banner "FORMATAGE SSD JEUX$(if ($DryRun) { ' (DRY-RUN)' })"
    if (-not (Test-Admin)) { throw "Lance ce script dans un PowerShell ADMIN." }

    $gd = (Get-StorageLayout -Name 'omen').gamesDisk
    $match  = if ($ModelMatch)  { $ModelMatch }  else { $gd.modelMatch }
    $letter = if ($DriveLetter) { $DriveLetter.TrimEnd(':').ToUpper() } else { $gd.letter }
    $lbl    = if ($Label)       { $Label }       else { $gd.label }

    $inv = @(Get-DiskInventory)
    Write-Step "Disques détectés :"
    foreach ($d in $inv) {
        Write-Host ("    {0}  {1,-34} {2,6} Go  {3,-5} boot={4} lettres={5}" -f $d.Number, $d.FriendlyName, $d.SizeGB,
            $d.BusType, $d.IsBoot, ($d.Letters -join ',')) -ForegroundColor DarkGray
    }

    $target = Select-GamesDisk -Inventory $inv -Match $match -Number $DiskNumber -MinGB $gd.minSizeGB -MaxGB $gd.maxSizeGB
    Write-Banner "CIBLE : TOUT CE QUI SUIT SERA EFFACÉ"
    Show-DiskContent -Disk $target

    Resolve-DriveLetterConflict -Letter $letter -TargetNumber $target.Number

    if ($DryRun) {
        Invoke-FormatGamesDisk -Disk $target -Letter $letter -VolumeLabel $lbl
        Write-Ok "Dry-run terminé : rien n'a été modifié. Relance sans -DryRun pour effacer."
        return
    }
    $expected = "EFFACER $($target.Number)"
    $answer = Read-Host "Tape exactement  $expected  pour effacer le disque $($target.Number) ($($target.FriendlyName))"
    if ($answer -cne $expected) { Write-Warn "Confirmation différente de '$expected' : abandon, rien n'a été touché."; return }

    Invoke-FormatGamesDisk -Disk $target -Letter $letter -VolumeLabel $lbl
    Write-Host ""
    Write-Ok "Étape suivante : .\reset.ps1 -Profile omen -Only storage   (crée $($letter):\Games\..., \ISO, \Captures, \ML-cold)"
    Write-Warn "Si le chiffrement de l'appareil s'active aussi sur ${letter}: (déverrouillage auto), sa clé suit ton compte Microsoft."
}

if ($MyInvocation.InvocationName -ne '.') {
    $logDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    try { Start-Transcript -Path (Join-Path $logDir ("format-ssd-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null } catch { Write-Verbose 'transcript KO' }
    try { Invoke-Main } catch { Write-Err $_.Exception.Message; exit 1 } finally { try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript KO' } }
}
