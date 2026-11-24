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
