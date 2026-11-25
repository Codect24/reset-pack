# scripts/ml-smoke-test.ps1 -- smoke-test GPU / deep learning (SYSTEME-OMEN-35L.md §5 et §8).
#   1. nvidia-smi côté Windows (le seul pilote : NVIDIA App)
#   2. torch + CUDA dans WSL : scripts/wsl-ml-setup.sh --smoke-only (venv ~/ml/.smoke existant, RIEN n'est installé)
#   3. Docker GPU : docker run --rm --gpus all <image CUDA> nvidia-smi, seulement si Docker répond
# Ne modifie rien. Effets de bord possibles : téléchargement de l'image Docker de test au 1er passage, et copie LF
# temporaire du .sh dans %TEMP% si git l'a extrait en CRLF.
# Renvoie un objet : Gpu, GpuName, DriverVersion, TorchCuda, TorchVersion, DockerGpu.
#   Gpu / TorchCuda / DockerGpu : $true = OK, $false = testé et KO, $null = non testé (prérequis absent).
#   DriverVersion : version du pilote (chaîne) ou $null.
# À relancer après chaque mise à jour du pilote proposée par NVIDIA App, avant de la valider.
#   .\scripts\ml-smoke-test.ps1 [-Distro Ubuntu] [-Quiet]
# Dot-sourcé (modules/14-ml.ps1, verify-omen.ps1) : ne fait que définir les fonctions.
param(
    [string]$Distro,   # distro WSL (défaut : storage-layout.json > wsl.distro, sinon Ubuntu)
    [switch]$Quiet     # aucun affichage : seulement l'objet résultat
)

. "$PSScriptRoot\..\modules\00-helpers.ps1"

$script:DockerGpuImage = 'nvidia/cuda:12.8.0-base-ubuntu24.04'

function Invoke-NativeCapture {
    # Exe natif -> stdout capturé + code de sortie ; stderr jeté.
    # EAP local à Continue : sous PS 5.1 avec EAP=Stop (reset.ps1), une ligne stderr redirigée lèverait une exception.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    $ErrorActionPreference = 'Continue'
    $out = & $FilePath @ArgumentList 2>$null
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
}

function Format-CommandLine {
    # Ligne de commande lisible et recopiable dans PowerShell ('$HOME' reste littéral entre apostrophes).
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    $parts = foreach ($a in $Arguments) {
        if ($a -match '[\s$''"]') { "'" + ($a -replace "'", "''") + "'" } else { $a }
    }
    return ((@($Exe) + @($parts)) -join ' ')
}

function ConvertTo-WslPath {
    # C:\Dev\x\y.sh -> /mnt/c/Dev/x/y.sh (montage automatique par défaut de WSL).
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath(($Path -replace '^\\\\\?\\', ''))
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "Chemin non convertible pour WSL (lecteur local attendu) : $Path" }
    return ('/mnt/{0}/{1}' -f $Matches[1].ToLower(), ($Matches[2] -replace '\\', '/'))
}

function Get-WslRunnableScript {
    # Chemin d'un .sh exécutable par bash : l'original s'il est en LF, sinon une copie LF temporaire
    # (git core.autocrlf=true l'extrait en CRLF et bash refuserait 'set -euo pipefail\r').
    param([Parameter(Mandatory)][string]$Path, [string]$TempDir = $script:DownloadDir)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Script introuvable : $Path" }
    $text = [IO.File]::ReadAllText($Path)
    if ($text.IndexOf("`r") -lt 0) { return $Path }
    $dest = Join-Path $TempDir (Split-Path $Path -Leaf)
    Write-Warn "$(Split-Path $Path -Leaf) extrait en CRLF -> copie LF $dest (ajoute '*.sh text eol=lf' à .gitattributes)"
    if ($script:DryRun) { return $dest }
    if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }
    $lf = ($text -replace "`r`n", "`n") -replace "`r", "`n"
    [IO.File]::WriteAllText($dest, $lf, (New-Object System.Text.UTF8Encoding $false))
    return $dest
}

function Get-WslDistroList {
    # Distros WSL enregistrées. Code de sortie plutôt que texte (localisé) ; WSL_UTF8 évite la sortie UTF-16.
    if (-not (Test-CommandExists 'wsl')) { return @() }
    $env:WSL_UTF8 = '1'
    $r = Invoke-NativeCapture -FilePath 'wsl' -ArgumentList @('--list', '--quiet')
    if ($r.ExitCode -ne 0) { return @() }
    return @($r.Output | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
}

function Get-MlDistroName {
    try {
        $l = Get-StorageLayout
        if ($l.wsl -and $l.wsl.distro) { return [string]$l.wsl.distro }
    } catch { Write-Verbose "layout indisponible : $($_.Exception.Message)" }
    return 'Ubuntu'
}

function Get-NvidiaSmiInfo {
    # GPU vu par le pilote Windows : { Gpu, Name, DriverVersion }. Lecture seule.
    $info = [pscustomobject]@{ Gpu = $false; Name = $null; DriverVersion = $null }
    if (-not (Test-CommandExists 'nvidia-smi')) { return $info }
    $r = Invoke-NativeCapture -FilePath 'nvidia-smi' -ArgumentList @('--query-gpu=name,driver_version', '--format=csv,noheader')
    if ($r.ExitCode -ne 0) { return $info }
    $line = @($r.Output | Where-Object { "$_".Trim() }) | Select-Object -First 1
    if (-not $line) { return $info }
    $parts = @("$line" -split ',\s*')
    $info.Name = $parts[0].Trim()
    if ($parts.Count -gt 1) { $info.DriverVersion = $parts[-1].Trim() }
    $info.Gpu = $true
    return $info
}

function ConvertFrom-SmokeOutput {
    # Lignes 'RESETPACK_SMOKE cle=valeur' émises par wsl-ml-setup.sh -> hashtable.
    param([object[]]$Lines)
    $h = @{}
    foreach ($l in @($Lines)) {
        if ("$l" -match '^RESETPACK_SMOKE\s+([A-Za-z_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() }
    }
    return $h
}

function Test-WslTorchCuda {
    # torch + CUDA dans la distro, avec le venv ~/ml/.smoke existant (--smoke-only : rien n'est installé).
    param([Parameter(Mandatory)][string]$Distro, [string]$ScriptPath)
    if (-not $ScriptPath) { $ScriptPath = Join-Path $script:Root 'scripts\wsl-ml-setup.sh' }
    $res = [pscustomobject]@{ TorchCuda = $null; TorchVersion = $null; GpuName = $null; Capability = $null; Reason = $null }
    if (-not (Test-CommandExists 'wsl')) {
        $res.Reason = 'wsl absent'; Write-Warn "torch WSL non testé : wsl absent"; return $res
    }
    if (@(Get-WslDistroList) -notcontains $Distro) {
        $res.Reason = "distro $Distro absente"; Write-Warn "torch WSL non testé : distro '$Distro' absente"; return $res
    }
    $wslArgs = @('-d', $Distro, '--cd', '~', '--exec', 'bash', (ConvertTo-WslPath (Get-WslRunnableScript -Path $ScriptPath)), '--smoke-only')
    if ($script:DryRun) {
        Write-Dry (Format-CommandLine -Exe 'wsl' -Arguments $wslArgs)
        $res.Reason = 'simulation'; return $res
    }
    $r = Invoke-NativeCapture -FilePath 'wsl' -ArgumentList $wslArgs
    $kv = ConvertFrom-SmokeOutput -Lines $r.Output
    $res.TorchVersion = $kv['torch']
    $res.GpuName = $kv['gpu']
    $res.Capability = $kv['capability']
    switch ($r.ExitCode) {
        0 {
            $res.TorchCuda = $true
            Write-Ok "torch $($res.TorchVersion) dans WSL voit $($res.GpuName) (capability $($res.Capability))"
        }
        2 {
            $res.TorchCuda = $false
            $res.Reason = $kv['error']
            Write-Err "torch $($res.TorchVersion) dans WSL : CUDA indisponible ou matmul KO $(if ($res.Reason) { "($($res.Reason))" })"
        }
        3 {
            $res.Reason = 'venv ~/ml/.smoke ou torch absent'
            Write-Warn "torch WSL non testé : venv ~/ml/.smoke absent -> .\reset.ps1 -Only ml"
        }
        default {
            $res.Reason = "wsl-ml-setup.sh code $($r.ExitCode)"
            Write-Warn "torch WSL non testé : wsl-ml-setup.sh --smoke-only a renvoyé $($r.ExitCode)"
        }
    }
    return $res
}

function Test-DockerGpu {
    # $true / $false si Docker répond ; $null (non testé, jamais un échec) sinon. Respecte le dry-run (pas de pull).
    param([string]$Image = $script:DockerGpuImage)
    if (-not (Test-CommandExists 'docker')) { Write-Warn "Docker GPU non testé : docker absent"; return $null }
    $info = Invoke-NativeCapture -FilePath 'docker' -ArgumentList @('info', '--format', '{{.ServerVersion}}')
    if ($info.ExitCode -ne 0) { Write-Warn "Docker GPU non testé : Docker ne répond pas (Docker Desktop lancé ?)"; return $null }
    $runArgs = @('run', '--rm', '--gpus', 'all', $Image, 'nvidia-smi')
    if ($script:DryRun) { Write-Dry (Format-CommandLine -Exe 'docker' -Arguments $runArgs); return $null }
    Write-Step "$(Format-CommandLine -Exe 'docker' -Arguments $runArgs)  (télécharge l'image au 1er passage)"
    $r = Invoke-NativeCapture -FilePath 'docker' -ArgumentList $runArgs
    if ($r.ExitCode -eq 0) { Write-Ok "Docker voit le GPU (--gpus all)"; return $true }
    Write-Warn "docker run --gpus all a échoué (code $($r.ExitCode)) : backend WSL2 de Docker Desktop actif ?"
    return $false
}

function Format-SmokeFlag {
    param($Value)
    if ($Value -eq $true) { return 'ok' }
    if ($Value -eq $false) { return 'KO' }
    return 'n/a'
}

function Invoke-MlSmokeTest {
    param([string]$Distro)
    if (-not $Distro) { $Distro = Get-MlDistroName }
    Write-Step "Smoke-test GPU : pilote Windows, torch dans WSL '$Distro', Docker"
    $smi = Get-NvidiaSmiInfo
    if ($smi.Gpu) { Write-Ok "nvidia-smi : $($smi.Name) - pilote $($smi.DriverVersion)" }
    else { Write-Err "nvidia-smi : aucun GPU NVIDIA (pilote absent ? -> NVIDIA App, jamais dans WSL)" }
    $torch = Test-WslTorchCuda -Distro $Distro
    $docker = Test-DockerGpu
    $res = [pscustomobject]@{
        Gpu           = $smi.Gpu
        GpuName       = $smi.Name
        DriverVersion = $smi.DriverVersion
        TorchCuda     = $torch.TorchCuda
        TorchVersion  = $torch.TorchVersion
        DockerGpu     = $docker
    }
    Write-Step ("Résultat : GPU={0} pilote={1} torch-wsl={2} docker-gpu={3}" -f (Format-SmokeFlag $res.Gpu), $res.DriverVersion, (Format-SmokeFlag $res.TorchCuda), (Format-SmokeFlag $res.DockerGpu))
    return $res
}

if ($MyInvocation.InvocationName -ne '.') {
    # Write-Host passe par le flux Information (6) : -Quiet le coupe, l'objet résultat reste sur la sortie.
    if ($Quiet) { Invoke-MlSmokeTest -Distro $Distro 6>$null }
    else { Invoke-MlSmokeTest -Distro $Distro }
}
