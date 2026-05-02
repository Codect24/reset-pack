# Helpers communs à tous les modules

$script:Root = Split-Path $PSScriptRoot -Parent
$script:ConfigsRoot = "$env:USERPROFILE\OneDrive\Documents\08_Logiciels\Configs"
$script:DownloadDir = "$env:TEMP\ResetPack-Downloads"
New-Item -ItemType Directory -Force -Path $script:DownloadDir | Out-Null

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

function Test-CommandExists($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
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
    $parent = Split-Path $Link -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path $Link) {
        $item = Get-Item $Link -Force
        if ($item.LinkType -eq 'SymbolicLink') {
            Write-Ok "Symlink existe déjà: $Link"
            return $true
        }
        # Backup l'existant avant de le remplacer (avec retry si verrouille)
        $backup = "$Link.before-resetpack-$(Get-Date -f yyyyMMdd-HHmmss)"
        $moved = $false
        for ($i = 0; $i -lt 3 -and -not $moved; $i++) {
            try {
                Move-Item -Path $Link -Destination $backup -Force -ErrorAction Stop
                $moved = $true
            } catch {
                if ($i -lt 2) { Start-Sleep -Seconds 2 } else { throw }
            }
        }
        Write-Warn "Backup existant -> $backup"
    }
    # Creation du symlink avec retry (PowerToys/Claude peuvent relancer entre temps)
    $created = $false
    for ($i = 0; $i -lt 3 -and -not $created; $i++) {
        try {
            New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop | Out-Null
            $created = $true
        } catch {
            if ($i -lt 2) { Start-Sleep -Seconds 2 } else { throw }
        }
    }
    Write-Ok "Symlink créé: $Link -> $Target"
    return $true
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    if (Test-Path $OutFile) {
        Write-Step "Déjà téléchargé: $OutFile"
        return
    }
    Write-Step "Download: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Invoke-OneDrivePin {
    # Force le download d'un dossier OneDrive (Files On-Demand: "Always keep on this device")
    # via attrib +P recursif. Idempotent.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        # Le dossier peut etre marque "online-only" - on tente quand meme attrib sur le parent
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
    # Attend qu'un chemin OneDrive devienne disponible localement (fichiers telecharges).
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSec = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Path) {
            # Verifier qu'il y a au moins un fichier reellement local (pas juste placeholder)
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
    # Installe une Nerd Font depuis ryanoasis/nerd-fonts releases (user scope, pas besoin d'admin).
    # $FontName : nom du zip (ex: 'FiraCode', 'JetBrainsMono', 'CascadiaCode'...)
    param(
        [Parameter(Mandatory)][string]$FontName,
        [string]$DetectPattern  # Pattern pour detecter si deja installe (ex: '*FiraCode*')
    )
    if (-not $DetectPattern) { $DetectPattern = "*$FontName*" }

    $userFonts = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    if (Test-Path $userFonts) {
        $existing = Get-ChildItem $userFonts -Filter $DetectPattern -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Ok "$FontName Nerd Font deja installee ($($existing.Count) fichiers)"
            return $true
        }
    }

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
        Write-Ok "$FontName Nerd Font installee ($count fichiers, user scope)"
        return $true
    } catch {
        Write-Warn "Install $FontName Nerd Font echec : $($_.Exception.Message)"
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
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
