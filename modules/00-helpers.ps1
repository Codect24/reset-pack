# Helpers communs à tous les modules

# --- Racine du repo ---
$script:Root = Split-Path $PSScriptRoot -Parent

# --- Racine OneDrive (DYNAMIQUE) ---
# NE PAS coder en dur "$env:USERPROFILE\OneDrive" : OneDrive expose %OneDrive%
# qui pointe sur la racine REELLE (peut être D:\OneDrive après déplacement du dossier).
# Fallback sur le chemin classique si la variable est absente.
function Get-OneDriveRoot {
    foreach ($c in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial, "$env:USERPROFILE\OneDrive")) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    if ($env:OneDrive) { return $env:OneDrive }   # dernier recours (les modules gèrent le Test-Path)
    return "$env:USERPROFILE\OneDrive"
}
$script:OneDriveRoot = Get-OneDriveRoot
$script:ConfigsRoot  = Join-Path $script:OneDriveRoot 'Documents\08_Logiciels\Configs'
$script:GamingRoot   = Join-Path $script:OneDriveRoot 'Documents\07_Gaming'

$script:DownloadDir = "$env:TEMP\ResetPack-Downloads"
New-Item -ItemType Directory -Force -Path $script:DownloadDir | Out-Null

# --- Modes posés par reset.ps1 via variables d'env (visibles dans les modules enfants) ---
$script:DryRun = ($env:RESETPACK_DRYRUN -eq '1')   # simulation : aucune mutation système
$script:Auto   = ($env:RESETPACK_AUTO   -eq '1')   # non-interactif : pas de Read-Host / prompts bloquants

function Write-Banner($msg) {
    $line = '=' * 70
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}
function Write-Step($msg) { Write-Host "  -> $msg" -ForegroundColor White }
function Write-Ok($msg)   { Write-Host "  ok  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  !!  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  XX  $msg" -ForegroundColor Red }
function Write-Dry($msg)  { Write-Host "  [dry] $msg" -ForegroundColor DarkYellow }

function Test-CommandExists($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Test-Admin {
    # $true si la session courante est élevée.
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-SessionPath {
    # winget / MSI ne rafraîchissent PAS le PATH du process courant.
    # À appeler après des installs pour que git/gh/node/code/... soient trouvés dans la même session.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function New-SymLinkSafe {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )
    if (-not (Test-Path $Target)) {
        Write-Warn "Cible introuvable, skip: $Target"
        return $false
    }
    if ($script:DryRun) { Write-Dry "symlink $Link -> $Target"; return $true }

    $parent = Split-Path $Link -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    # ATTENTION : un symlink CASSÉ (cible déplacée, ex. OneDrive migré sur D:) renvoie
    # Test-Path $false. On interroge donc l'item en -Force pour détecter le reparse point.
    $existing = Get-Item $Link -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.LinkType -eq 'SymbolicLink') {
            $curTgt = @($existing.Target)[0]
            if ($curTgt -and ($curTgt.TrimEnd('\') -ieq $Target.TrimEnd('\'))) {
                Write-Ok "Symlink déjà OK: $Link"
                return $true
            }
            # pointe vers une autre cible (ou cible morte) -> on retire et on recrée
            Write-Warn "Symlink existant vers une autre cible -> recréation ($Link)"
            Remove-Item $Link -Force -ErrorAction SilentlyContinue
        } else {
            # Backup l'existant (vrai fichier/dossier) avant de le remplacer (retry si verrouillé)
            $backup = "$Link.before-resetpack-$(Get-Date -f yyyyMMdd-HHmmss)"
            $moved = $false
            for ($i = 0; $i -lt 3 -and -not $moved; $i++) {
                try { Move-Item -Path $Link -Destination $backup -Force -ErrorAction Stop; $moved = $true }
                catch { if ($i -lt 2) { Start-Sleep -Seconds 2 } else { throw } }
            }
            Write-Warn "Backup existant -> $backup"
        }
    }

    # Création du symlink avec retry (PowerToys/Claude peuvent relancer entre temps)
    $created = $false
    for ($i = 0; $i -lt 3 -and -not $created; $i++) {
        try { New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop | Out-Null; $created = $true }
        catch { if ($i -lt 2) { Start-Sleep -Seconds 2 } else { throw } }
    }
    Write-Ok "Symlink créé: $Link -> $Target"
    return $true
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    if ($script:DryRun) { Write-Dry "download $Url -> $OutFile"; return }
    # Cache : on ne garde que si le fichier existant a une taille plausible (évite un cache HTML/corrompu).
    if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 1024)) {
        Write-Step "Déjà téléchargé: $OutFile"
        return
    }
    Write-Step "Download: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Invoke-Winget {
    # Wrapper winget : respecte le dry-run et centralise les messages. Retourne le code de sortie.
    param([Parameter(Mandatory)][string[]]$Arguments)
    if ($script:DryRun) { Write-Dry "winget $($Arguments -join ' ')"; return 0 }
    & winget @Arguments
    return $LASTEXITCODE
}

function Register-ScheduledTaskSafe {
    # Wrapper Register-ScheduledTask : respecte le dry-run.
    param([Parameter(Mandatory)][hashtable]$Params)
    if ($script:DryRun) { Write-Dry "Register-ScheduledTask $($Params.TaskName)"; return }
    Register-ScheduledTask @Params -Force | Out-Null
}

function Invoke-OneDrivePin {
    # Force le download d'un dossier OneDrive (Files On-Demand) via attrib +P récursif. Idempotent.
    param([Parameter(Mandatory)][string]$Path)
    if ($script:DryRun) { Write-Dry "pin OneDrive $Path"; return $true }
    if (-not (Test-Path $Path)) {
        $parent = Split-Path $Path -Parent
        if (Test-Path $parent) {
            Write-Step "Pin OneDrive parent: $parent"
            attrib +P /S /D "$parent\*" 2>$null | Out-Null
        }
        return $false
    }
    Write-Step "Pin OneDrive (force download): $Path"
    attrib +P /S /D "$Path\*" 2>$null | Out-Null
    return $true
}

function Wait-OneDrivePath {
    # Attend qu'un chemin OneDrive devienne disponible localement (fichiers téléchargés).
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSec = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Path) {
            $local = Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Offline) } |
                Select-Object -First 1
            if ($local) { return $true }
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Install-NerdFont {
    # Installe une Nerd Font depuis ryanoasis/nerd-fonts releases (user scope, pas d'admin).
    param(
        [Parameter(Mandatory)][string]$FontName,
        [string]$DetectPattern
    )
    if (-not $DetectPattern) { $DetectPattern = "*$FontName*" }

    $userFonts = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    if (Test-Path $userFonts) {
        # Where-Object (et non -Filter) : le filtre FileSystem multi-wildcard est peu fiable -> ratait la détection.
        $existing = Get-ChildItem $userFonts -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $DetectPattern }
        if ($existing) {
            Write-Ok "$FontName Nerd Font déjà installée ($($existing.Count) fichiers)"
            return $true
        }
    }
    if ($script:DryRun) { Write-Dry "install Nerd Font $FontName"; return $true }

    Write-Step "Install $FontName Nerd Font"
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest' -UseBasicParsing
        $asset = $rel.assets | Where-Object { $_.name -eq "$FontName.zip" } | Select-Object -First 1
        if (-not $asset) { Write-Err "$FontName.zip absent de la release"; return $false }

        $zip = "$script:DownloadDir\$FontName-NerdFont.zip"
        $extract = "$script:DownloadDir\$FontName-NerdFont"
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        Expand-Archive $zip -DestinationPath $extract -Force

        New-Item -ItemType Directory -Force -Path $userFonts | Out-Null
        $fontReg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (-not (Test-Path $fontReg)) { New-Item -Path $fontReg -Force | Out-Null }

        $count = 0
        Get-ChildItem $extract -Filter '*.ttf' -Recurse | ForEach-Object {
            $dest = Join-Path $userFonts $_.Name
            Copy-Item $_.FullName $dest -Force
            $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($_.Name)) (TrueType)"
            New-ItemProperty -Path $fontReg -Name $regName -Value $dest -PropertyType String -Force | Out-Null
            $count++
        }
        Write-Ok "$FontName Nerd Font installée ($count fichiers, user scope)"
        return $true
    } catch {
        Write-Warn "Install $FontName Nerd Font échec : $($_.Exception.Message)"
        return $false
    }
}

# ============================================================================
# Profil machine + disposition du stockage (config/storage-layout.json)
# ============================================================================
# Profil : 'omen' | 'exodius'. Posé par reset.ps1 -Profile (RESETPACK_PROFILE), sinon détecté.
function Get-ResetProfile {
    if ($env:RESETPACK_PROFILE) { return $env:RESETPACK_PROFILE.ToLower() }
    $model = ''
    try { $model = "$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Model)" } catch { Write-Verbose "Win32_ComputerSystem indisponible" }
    if ($model -match 'OMEN') { return 'omen' }
    if ($model -match 'AORUS' -or $env:COMPUTERNAME -eq 'EXODIUS') { return 'exodius' }
    return $null
}

function Get-ResetProfileDefinition {
    # Définition d'un profil de reset.ps1 (liste/ordre des modules, interdits, catégories d'apps).
    param([Parameter(Mandatory)][string]$Name)
    $all = Get-Content (Join-Path $script:Root 'config\profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $p = $all.profiles.$Name
    if (-not $p) { throw "Profil '$Name' absent de config\profiles.json" }
    return $p
}

function Get-StorageLayout {
    # Chemins du profil, jetons {OneDrive}/{UserProfile} résolus. SEULE source des chemins C:/D:/X:.
    param([string]$Name)
    if (-not $Name) { $Name = Get-ResetProfile }
    if (-not $Name) { throw "Profil machine inconnu : lance reset.ps1 -Profile omen|exodius (ou pose RESETPACK_PROFILE)." }
    $raw = Get-Content (Join-Path $script:Root 'config\storage-layout.json') -Raw -Encoding UTF8
    # Injection échappée JSON (les chemins contiennent des '\')
    $od = (ConvertTo-Json ([string]$script:OneDriveRoot)).Trim('"')
    $up = (ConvertTo-Json ([string]$env:USERPROFILE)).Trim('"')
    $layout = ($raw.Replace('{OneDrive}', $od).Replace('{UserProfile}', $up) | ConvertFrom-Json).profiles.$Name
    if (-not $layout) { throw "Profil '$Name' absent de config\storage-layout.json" }
    $layout | Add-Member -NotePropertyName Name -NotePropertyValue $Name -Force
    return $layout
}

function Get-ProjetsRoots {
    # Toutes les racines de projets connues (PROJETS_CODE + layout + historiques), existantes, sans doublon.
    # Utilisé par backup-secrets / pre-reset-check / backup-bundles : un projet déplacé reste couvert.
    $cands = @($env:PROJETS_CODE, [Environment]::GetEnvironmentVariable('PROJETS_CODE', 'User'))
    try {
        $l = Get-StorageLayout
        $cands += $l.projetsCode
        $cands += @($l.legacyProjetsRoots)
    } catch { Write-Verbose "layout indisponible : $($_.Exception.Message)" }
    $cands += (Join-Path $script:OneDriveRoot 'Documents\03_Projets_Code')
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in $cands) {
        if (-not $r -or -not (Test-Path $r)) { continue }
        # Une jonction (EXODIUS : C:\Dev\03_Projets_Code -> OneDrive) = le même dossier : dédoublonner sur la cible.
        $real = $r.TrimEnd('\')
        $item = Get-Item -LiteralPath $real -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType -in @('Junction', 'SymbolicLink')) { $real = "$(@($item.Target)[0])".TrimEnd('\') }
        $k = $real.ToLower()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out.Add($r.TrimEnd('\'))
    }
    # Émission normale (pas `return , $tableau`) : @(Get-ProjetsRoots) et foreach donnent bien N éléments.
    $out.ToArray()
}

function Find-GitRepos {
    # Dépôts git sous $Root (profondeur max), sans descendre DANS un dépôt ni dans les dossiers lourds.
    # NB : les dossiers OneDrive sont des ReparsePoint (placeholders) -> on n'exclut que les vrais liens.
    param([Parameter(Mandatory)][string]$Root, [int]$MaxDepth = 3)
    $skip = @('node_modules', '.venv', 'venv', '__pycache__', '.git', 'dist', 'build', '.next', 'target', '.cache')
    $out = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root.TrimEnd('\'), 0))
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        $dir = $cur[0]; $depth = $cur[1]
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $out.Add($dir); continue }
        if ($depth -ge $MaxDepth) { continue }
        Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $skip -notcontains $_.Name -and -not $_.LinkType } |
            ForEach-Object { $queue.Enqueue(@($_.FullName, ($depth + 1))) }
    }
    $out.ToArray()
}

# Chemin CANONIQUE des projets, identique sur toutes les machines (dossier réel sur l'OMEN,
# jonction vers OneDrive sur EXODIUS). Cf. storage-layout.json et migrate-projets.ps1.
$script:CanonicalProjets = 'C:\Dev\03_Projets_Code'

function ConvertTo-CanonicalProjetsPath {
    # Réécrit tout ancien chemin <X>:\Users\<qui>\OneDrive\Documents\03_Projets_Code vers C:\Dev\03_Projets_Code,
    # en CONSERVANT le style de séparateur (\ , \\ échappé JSON, /). Texte inchangé si rien ne matche.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $rx = '(?i)[A-Z]:(\\\\|\\|/)Users\1[^\\/"\r\n]+?\1OneDrive\1Documents\1(?=03_Projets_Code)'
    return [regex]::Replace($Text, $rx, { param($m) 'C:' + $m.Groups[1].Value + 'Dev' + $m.Groups[1].Value })
}

function ConvertTo-ClaudeProjectKey {
    # Nom du dossier ~/.claude/projects/<clé> d'un chemin de projet (tout non-alphanumérique -> '-').
    param([Parameter(Mandatory)][string]$Path)
    return ($Path.TrimEnd('\') -replace '[^A-Za-z0-9]', '-')
}

function Set-UserEnvVar {
    # Variable d'environnement User (persistante) + process courant. Idempotent, respecte le dry-run.
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value)
    $cur = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($cur -eq $Value) { Write-Ok "$Name déjà = $Value"; return }
    if ($script:DryRun) { Write-Dry "env User $Name = '$Value' (actuel : '$cur')"; return }
    [Environment]::SetEnvironmentVariable($Name, $(if ($Value) { $Value } else { $null }), 'User')
    if ($Value) { Set-Item -Path "Env:$Name" -Value $Value } else { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
    Write-Ok "$Name = $Value"
}

function New-DirectorySafe {
    # mkdir idempotent, respecte le dry-run. Renvoie $true si le dossier a été (ou serait) créé.
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { return $false }
    if ($script:DryRun) { Write-Dry "mkdir $Path"; return $true }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    return $true
}

function Test-DriveReady {
    # $true si la lettre (ex. 'D' ou 'D:') existe et est montée.
    param([Parameter(Mandatory)][string]$Letter)
    return (Test-Path ("{0}:\" -f $Letter.TrimEnd(':', '\')))
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Type = 'DWord'
    )
    if ($script:DryRun) { Write-Dry "reg $Path\$Name = $Value ($Type)"; return }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
