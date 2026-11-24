# bootstrap.ps1 — amorce le Reset Pack sur un Windows 11 fraîchement reseté.
# Usage (dans PowerShell, machine vierge) :
#   irm https://raw.githubusercontent.com/Codect24/reset-pack/main/bootstrap.ps1 | iex
#
# Résout le problème poule/œuf : OneDrive (donc le pack) n'existe pas encore -> on clone
# depuis GitHub dans un dossier LOCAL. `irm | iex` n'est pas bloqué par l'ExecutionPolicy.
# Prérequis : le dépôt doit être PUBLIC (sinon raw.githubusercontent = 404 / clone demande un login).
$ErrorActionPreference = 'Stop'

$Repo    = 'https://github.com/Codect24/reset-pack.git'
$Branch  = 'main'
$Dest    = 'C:\ResetPack'                                    # LOCAL, surtout pas OneDrive
$RawBase = 'https://raw.githubusercontent.com/Codect24/reset-pack/main'

function Write-BS($m, $c = 'Cyan') { Write-Host "[bootstrap] $m" -ForegroundColor $c }
function Test-Cmd($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Sync-Path {
    $env:Path = ([Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                 [Environment]::GetEnvironmentVariable('Path','User'))
}

# --- 0. Élévation admin (iex ne laisse pas de fichier -> on re-télécharge dans la session élevée) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-BS 'Relancement en admin...' 'Yellow'
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "irm $RawBase/bootstrap.ps1 | iex")
    return
}

# --- 1. winget (App Installer) ---
if (-not (Test-Cmd winget)) {
    Write-BS 'winget absent - re-enregistrement App Installer...' 'Yellow'
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe } catch {}
}
if (-not (Test-Cmd winget)) {
    Write-BS 'Download App Installer + dépendances...' 'Yellow'
    $tmp = Join-Path $env:TEMP 'wg-boot'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Invoke-WebRequest 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -OutFile "$tmp\vclibs.appx" -UseBasicParsing
    Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6' -OutFile "$tmp\xaml.zip" -UseBasicParsing
    Expand-Archive "$tmp\xaml.zip" -DestinationPath "$tmp\xaml" -Force
    Invoke-WebRequest 'https://aka.ms/getwinget' -OutFile "$tmp\winget.msixbundle" -UseBasicParsing
    Add-AppxPackage "$tmp\vclibs.appx"
    $xaml = Get-ChildItem "$tmp\xaml\tools\AppX\x64\Release" -Filter *.appx -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($xaml) { Add-AppxPackage $xaml.FullName }
    Add-AppxPackage "$tmp\winget.msixbundle"
}
if (-not (Test-Cmd winget)) { throw 'winget KO. Installe App Installer via le Microsoft Store puis relance.' }
Write-BS "winget OK : $(winget --version)"

# --- 2. git ---
if (-not (Test-Cmd git)) {
    Write-BS 'Install git via winget...'
    winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements
    Sync-Path
    if (-not (Test-Cmd git) -and (Test-Path 'C:\Program Files\Git\cmd')) { $env:Path += ';C:\Program Files\Git\cmd' }
}
if (-not (Test-Cmd git)) { throw 'git introuvable après install. Ouvre un nouveau terminal et relance.' }
Write-BS "git OK : $(git --version)"

# --- 3. Clone (dossier LOCAL) ---
if (Test-Path "$Dest\.git") {
    Write-BS "Dépôt déjà présent : $Dest -> git pull"; git -C $Dest pull --ff-only
} else {
    Write-BS "Clone -> $Dest"; git clone --branch $Branch --depth 1 $Repo $Dest
}

# --- 4. Lancement ---
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Write-BS 'Lancement de reset.ps1...' 'Green'
Write-BS "Astuce : teste d'abord sans rien casser avec  .\reset.ps1 -DryRun" 'DarkGray'
& "$Dest\reset.ps1"
