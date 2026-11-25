# 14-ml : deep learning sur WSL2 Ubuntu (SYSTEME-OMEN-35L.md §5 et §8). S'exécute après dev-setup (WSL) et storage (chemins).
#   1. %USERPROFILE%\.wslconfig depuis templates\wslconfig.ini : RAM ~56 %, cœurs logiques - 2 à 4 (backup si différent)
#   2. distro du layout : présente ? au bon endroit ? (jamais déplacée d'office : la commande est affichée)
#   3. provisioning : scripts\wsl-ml-setup.sh dans WSL (uv, ~/ml, bloc ~/.bashrc, torch cu128 + smoke-test CUDA)
#   4. pilote Windows (nvidia-smi) épinglé dans <racine ML>\driver-pin.txt + Docker --gpus all si Docker répond
# Le pilote NVIDIA vient de Windows (NVIDIA App), JAMAIS de WSL. Les variables d'env Windows : 12-storage.
# Idempotent. Dry-run : lectures et affichages seulement. Auto : aucun prompt (sudo non interactif dans WSL).
. "$PSScriptRoot\00-helpers.ps1"
. "$PSScriptRoot\..\scripts\ml-smoke-test.ps1"   # Get-NvidiaSmiInfo, Test-DockerGpu, ConvertTo-WslPath...

# ---------------------------------------------------------------- .wslconfig
function Get-PhysicalMemoryGB {
    # RAM installée (somme des barrettes), à défaut la RAM visible par Windows. 0 si illisible.
    $bytes = 0
    try { $bytes = (Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Measure-Object -Property Capacity -Sum).Sum }
    catch { Write-Verbose "Win32_PhysicalMemory : $($_.Exception.Message)" }
    if (-not $bytes) {
        try { $bytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory }
        catch { Write-Verbose "Win32_ComputerSystem : $($_.Exception.Message)" }
    }
    if (-not $bytes) { return 0 }
    return [int][Math]::Round($bytes / 1GB)
}

function Get-LogicalProcessorCount { return [Environment]::ProcessorCount }

function Get-WslMemoryGB {
    # ~56 % de la RAM, arrondi : 32 Go -> 18, 64 Go -> 36. Plancher 2 Go.
    param([Parameter(Mandatory)][double]$TotalGB, [double]$Ratio = 0.56)
    $gb = [int][Math]::Round($TotalGB * $Ratio, [MidpointRounding]::AwayFromZero)
    if ($gb -lt 2) { $gb = 2 }
    return $gb
}

function Get-WslProcessorCount {
    # Cœurs logiques moins une réserve Windows de 2 (<= 8), 3 (<= 16) ou 4 (au-delà). Plancher 1.
    param([Parameter(Mandatory)][int]$LogicalProcessors)
    $reserve = 2
    if ($LogicalProcessors -gt 16) { $reserve = 4 } elseif ($LogicalProcessors -gt 8) { $reserve = 3 }
    $n = $LogicalProcessors - $reserve
    if ($n -lt 1) { $n = 1 }
    return $n
}

function Get-WslConfigContent {
    # Modèle -> contenu final (CRLF, jetons {{MEMORY}} / {{PROCESSORS}} remplacés).
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][int]$MemoryGB, [Parameter(Mandatory)][int]$Processors)
    $c = $Template.Replace('{{MEMORY}}', "${MemoryGB}GB").Replace('{{PROCESSORS}}', "$Processors")
    if ($c -match '\{\{\w+\}\}') { throw "Jeton non remplacé dans le modèle .wslconfig : $($Matches[0])" }
    $lf = ($c -replace "`r`n", "`n").TrimEnd("`n")
    return (($lf -replace "`n", "`r`n") + "`r`n")
}

function Get-NormalizedText {
    param([AllowEmptyString()][string]$Text)
    return (($Text -replace "`r`n", "`n").TrimEnd())
}

function Write-WslConfigFile {
    # Écrit le .wslconfig si besoin. Renvoie 'unchanged' | 'created' | 'updated' | 'dry'.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $utf8 = New-Object System.Text.UTF8Encoding $false   # pas de BOM : WSL lit mal un [wsl2] précédé d'un BOM
    if (Test-Path -LiteralPath $Path) {
        $current = [IO.File]::ReadAllText($Path)
        if ((Get-NormalizedText $current) -ceq (Get-NormalizedText $Content)) {
            Write-Ok ".wslconfig déjà à jour ($Path)"
            return 'unchanged'
        }
        $backup = "$Path.before-resetpack-$(Get-Date -Format yyyyMMdd-HHmmss)"
        if ($script:DryRun) { Write-Dry "backup $Path -> $backup, puis réécriture"; return 'dry' }
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        Write-Warn "Ancien .wslconfig sauvegardé -> $backup"
        [IO.File]::WriteAllText($Path, $Content, $utf8)
        Write-Ok ".wslconfig mis à jour ($Path)"
        return 'updated'
    }
    if ($script:DryRun) { Write-Dry "créer $Path"; return 'dry' }
    [IO.File]::WriteAllText($Path, $Content, $utf8)
    Write-Ok ".wslconfig créé ($Path)"
    return 'created'
}

# ---------------------------------------------------------------- distro WSL
function Test-NvidiaAdapter {
    try { return [bool](Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -match 'NVIDIA' }) }
    catch { Write-Verbose "Win32_VideoController : $($_.Exception.Message)"; return $false }
}

function Get-WslDistroRegistration {
    # Enregistrement de la distro dans le registre (BasePath = dossier du ext4.vhdx, DefaultUid). $null si absente.
    param([Parameter(Mandatory)][string]$Name, [string]$LxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss')
    if (-not (Test-Path $LxssKey)) { return $null }
    foreach ($k in @(Get-ChildItem $LxssKey -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DistributionName -eq $Name) {
            return [pscustomobject]@{
                Name       = [string]$p.DistributionName
                BasePath   = ([string]$p.BasePath) -replace '^\\\\\?\\', ''
                DefaultUid = $p.DefaultUid
            }
        }
    }
    return $null
}

function Test-SamePath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $na = ($A -replace '^\\\\\?\\', '').Replace('/', '\').TrimEnd('\')
    $nb = ($B -replace '^\\\\\?\\', '').Replace('/', '\').TrimEnd('\')
    return ($na -ieq $nb)
}

function Show-WslMoveAdvice {
    # Déplacement JAMAIS automatique (risque de perte de la distro) : on affiche la marche à suivre.
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$Current, [Parameter(Mandatory)][string]$Target)
    $tar = Join-Path (Split-Path $Target -Parent) "$Distro-export.tar"
    Write-Warn "'$Distro' est dans $Current, pas dans $Target (SYSTEME §2.5) : pas de déplacement automatique."
    Write-Host @"
  À faire à la main (Docker Desktop quitté, aucune session ouverte dans la distro) :
     wsl --shutdown
     wsl --manage $Distro --move $Target
  Repli si --move est inconnu (WSL trop ancien, sinon : wsl --update) :
     wsl --export $Distro $tar
     wsl --unregister $Distro        # SUPPRIME l'original : vérifie d'abord le .tar
     wsl --import $Distro $Target $tar
     # utilisateur par défaut : /etc/wsl.conf -> [user] default=<toi>, puis wsl --shutdown
"@ -ForegroundColor Gray
}

function Test-WslDefaultUserIsRoot {
    # $true si la distro n'a pas encore de compte (OOBE jamais faite) ; $false sinon ; $null si indéterminé.
    param([Parameter(Mandatory)][string]$Distro, $Registration)
    if ($Registration -and $null -ne $Registration.DefaultUid -and [int]$Registration.DefaultUid -ne 0) { return $false }
    # DefaultUid 0 dans le registre : le compte peut venir de /etc/wsl.conf -> on demande à la distro.
    $r = Invoke-NativeCapture -FilePath 'wsl' -ArgumentList @('-d', $Distro, '--exec', 'id', '-u')
    if ($r.ExitCode -ne 0) { return $null }
    return ((("$($r.Output)") -replace "`0", '').Trim() -eq '0')
}

function Get-WslSetupArgumentList {
    # Arguments de wsl.exe pour lancer wsl-ml-setup.sh ; --exec : pas de shell, '$HOME' arrive littéral au script.
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$ScriptWslPath,
        $EnvMap,
        [switch]$SmokeTest,
        [switch]$NonInteractive
    )
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($a in @('-d', $Distro, '--cd', '~', '--exec', 'bash', $ScriptWslPath)) { $list.Add($a) }
    if ($SmokeTest) { $list.Add('--smoke-test') }
    if ($NonInteractive) { $list.Add('--non-interactive') }
    $isDict = $EnvMap -is [System.Collections.IDictionary]
    $names = @()
    if ($isDict) { $names = @($EnvMap.Keys) }
    elseif ($EnvMap) { $names = @($EnvMap.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($n in $names) {
        if ($n -like '_*') { continue }
        if ($isDict) { $v = $EnvMap[$n] } else { $v = $EnvMap.$n }
        $list.Add('--env')
        $list.Add(('{0}={1}' -f $n, $v))
    }
    return , $list.ToArray()
}

# ---------------------------------------------------------------- pilote épinglé
function Get-MlRoot {
    # Racine ML du layout : 'mlRoot' s'il existe, sinon le parent de HF_HOME (C:\ML\hf -> C:\ML).
    param($Layout)
    if (-not $Layout) { return $null }
    if ($Layout.mlRoot) { return [string]$Layout.mlRoot }
    if ($Layout.env -and $Layout.env.HF_HOME) { return (Split-Path ([string]$Layout.env.HF_HOME) -Parent) }
    return $null
}

function Add-DriverPinLine {
    # Journal des pilotes testés (une ligne horodatée par passage). Le dossier appartient à 12-storage.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Line)
    if ($script:DryRun) { Write-Dry "append $Path : $Line"; return $true }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Warn "$dir absent (module storage pas encore passé ?) -> pilote non épinglé : $Line"
        return $false
    }
    [IO.File]::AppendAllText($Path, $Line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    Write-Ok "Pilote épinglé -> $Path"
    return $true
}

# ---------------------------------------------------------------- module
function Invoke-MlModule {
    # N'écrit rien sur le pipeline : la sortie de wsl (prompt sudo, progression apt) doit aller droit à la console.
    # Résultat consultable dans $script:MlLastResult (tests, verify-omen).
    param(
        [string]$WslConfigPath = (Join-Path $env:USERPROFILE '.wslconfig'),
        [string]$DriverPinPath
    )
    $templatePath = Join-Path $script:Root 'templates\wslconfig.ini'
    $setupScript  = Join-Path $script:Root 'scripts\wsl-ml-setup.sh'
    $result = [pscustomobject]@{ WslConfig = $null; Provisioned = $null; TorchCuda = $null; DockerGpu = $null; DriverVersion = $null }
    $script:MlLastResult = $result

    # --- 0. Garde : profil + GPU ---
    $profileName = Get-ResetProfile
    $smi = Get-NvidiaSmiInfo
    if ($profileName -ne 'omen' -and -not $smi.Gpu -and -not (Test-NvidiaAdapter)) {
        Write-Warn "Pas de GPU NVIDIA sur cette machine (profil '$profileName') -> module ml ignoré."
        return
    }
    try { $layout = Get-StorageLayout -Name $profileName }
    catch { Write-Warn "Layout indisponible ($($_.Exception.Message)) -> module ml ignoré."; return }
    $distro = [string]$layout.wsl.distro
    if (-not $distro) { $distro = 'Ubuntu' }

    # --- 1. .wslconfig ---
    Write-Step ".wslconfig (ressources de la VM WSL2)"
    $totalGB = Get-PhysicalMemoryGB
    if ($totalGB -le 0) {
        Write-Warn "RAM physique illisible -> .wslconfig non écrit."
    } else {
        $logical = Get-LogicalProcessorCount
        $mem = Get-WslMemoryGB -TotalGB $totalGB
        $cpu = Get-WslProcessorCount -LogicalProcessors $logical
        Write-Step "RAM $totalGB Go, $logical cœurs logiques -> memory=${mem}GB processors=$cpu swap=16GB"
        $content = Get-WslConfigContent -Template ([IO.File]::ReadAllText($templatePath)) -MemoryGB $mem -Processors $cpu
        $result.WslConfig = Write-WslConfigFile -Path $WslConfigPath -Content $content
        if ($result.WslConfig -ne 'unchanged') {
            Write-Warn "À appliquer : wsl --shutdown (arrête toutes les distros ET Docker Desktop), puis relance WSL."
            Write-Step "sparseVhd ne vaut que pour les nouveaux disques ; distro existante : wsl --manage $distro --set-sparse true (après wsl --shutdown)"
        }
    }

    # --- 2. Distro WSL ---
    Write-Step "Distro WSL '$distro'"
    $canProvision = $false
    if (-not (Test-CommandExists 'wsl')) {
        Write-Warn "wsl absent -> lance d'abord dev-setup (.\reset.ps1 -Only dev-setup), puis .\reset.ps1 -Only ml"
    } elseif (@(Get-WslDistroList) -notcontains $distro) {
        Write-Warn "Distro '$distro' absente de 'wsl --list' : lance 'wsl -d $distro' une fois (ou wsl --install -d $distro) pour créer ton compte, puis .\reset.ps1 -Only ml"
    } else {
        $reg = Get-WslDistroRegistration -Name $distro
        $target = [string]$layout.wsl.location
        if ($target -and $reg -and $reg.BasePath) {
            if (Test-SamePath $reg.BasePath $target) { Write-Ok "'$distro' est bien dans $target" }
            else { Show-WslMoveAdvice -Distro $distro -Current $reg.BasePath -Target $target }
        } elseif ($target) {
            Write-Warn "Emplacement de '$distro' illisible (registre Lxss) : vérifie qu'il est dans $target"
        }
        if (Test-WslDefaultUserIsRoot -Distro $distro -Registration $reg) {
            Write-Warn "'$distro' n'a pas encore de compte (utilisateur par défaut = root) : lance 'wsl -d $distro' une fois pour le créer, puis .\reset.ps1 -Only ml"
        } else {
            $canProvision = $true
        }
    }

    # --- 3. Provisioning + smoke-test torch (dans WSL) ---
    $wslScript = ConvertTo-WslPath $setupScript
    if ($canProvision) {
        Write-Step "Provisioning WSL : uv, ~/ml, bloc ~/.bashrc, torch cu128 + smoke-test CUDA"
        $wslScript = ConvertTo-WslPath (Get-WslRunnableScript -Path $setupScript)
        $wslArgs = Get-WslSetupArgumentList -Distro $distro -ScriptWslPath $wslScript -EnvMap $layout.wsl.env -SmokeTest -NonInteractive:$script:Auto
        if ($script:DryRun) {
            Write-Dry (Format-CommandLine -Exe 'wsl' -Arguments $wslArgs)
        } else {
            if (-not $script:Auto) { Write-Step "sudo peut demander ton mot de passe Linux (paquets apt manquants)." }
            & wsl @wslArgs
            $code = $LASTEXITCODE
            switch ($code) {
                0 { $result.Provisioned = $true; $result.TorchCuda = $true; Write-Ok "WSL provisionné ; torch voit le GPU" }
                2 { $result.Provisioned = $true; $result.TorchCuda = $false; Write-Err "torch dans WSL : CUDA indisponible (pilote Windows à jour ? aucun pilote Linux dans WSL ?)" }
                default { $result.Provisioned = $false; Write-Err "wsl-ml-setup.sh a échoué (code $code) : relis la sortie ci-dessus." }
            }
        }
    }

    # --- 4. Pilote Windows + Docker GPU ---
    Write-Step "Smoke-test GPU côté Windows"
    if ($smi.Gpu) {
        $result.DriverVersion = $smi.DriverVersion
        Write-Ok "nvidia-smi : $($smi.Name) - pilote $($smi.DriverVersion)"
    } else {
        Write-Err "nvidia-smi : aucun GPU NVIDIA -> installe le pilote via NVIDIA App (jamais dans WSL)."
    }
    $result.DockerGpu = Test-DockerGpu
    if ($smi.Gpu) {
        if (-not $DriverPinPath) {
            $mlRoot = Get-MlRoot -Layout $layout
            if ($mlRoot) { $DriverPinPath = Join-Path $mlRoot 'driver-pin.txt' }
        }
        if ($DriverPinPath) {
            $line = '{0:yyyy-MM-dd HH:mm:ss} | pilote {1} | {2} | torch-wsl={3} | docker-gpu={4}' -f (Get-Date), $smi.DriverVersion, $smi.Name, (Format-SmokeFlag $result.TorchCuda), (Format-SmokeFlag $result.DockerGpu)
            $null = Add-DriverPinLine -Path $DriverPinPath -Line $line
        } else {
            Write-Warn "Racine ML absente du layout -> pilote non épinglé."
        }
    }

    # --- 5. Rappels ---
    Write-Step "Après chaque mise à jour du pilote (NVIDIA App) : .\scripts\ml-smoke-test.ps1 avant de la valider."
    Write-Step "Toolkit CUDA (compiler des kernels seulement) : wsl -d $distro --cd ~ --exec bash $wslScript --with-cuda-toolkit"
    if ($result.Provisioned -eq $false) { throw "provisioning WSL en échec (wsl-ml-setup.sh)" }
    if ($result.TorchCuda -eq $false) { throw "torch ne voit pas le GPU dans WSL" }
    Write-Ok "Deep learning OK$(if ($script:DryRun) { ' (dry)' })"
}

# Dot-sourcé (tests) : fonctions seulement. Lancé par reset.ps1 (&) : exécution.
if ($MyInvocation.InvocationName -ne '.') { Invoke-MlModule }
