# Dev setup : WSL2 Ubuntu, long paths, Git config, gh auth
. "$PSScriptRoot\00-helpers.ps1"

# wsl/dism/git/gh/msiexec sont des mutations brutes (hors wrappers) -> rien en dry-run.
if ($script:DryRun) { Write-Dry "dev-setup : long paths + WSL2 Ubuntu + git config + gh auth (simulation)"; Write-Ok "Dev setup OK (dry)"; return }

# --- Long paths ---
Write-Step "Activer long paths Windows (>260 char)"
Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1
Write-Ok "Long paths ON"

# --- WSL2 + Ubuntu ---
Write-Step "WSL2 + Ubuntu"

function Try-WslInstallUbuntu {
    # Retourne $true si install OK, $false sinon. Capture stderr pour detecter REGDB_E.
    $output = & wsl --install -d Ubuntu --no-launch 2>&1
    $exit = $LASTEXITCODE
    if ($exit -eq 0 -and "$output" -notmatch 'REGDB_E_CLASSNOTREG|endommag') {
        return $true
    }
    Write-Warn "wsl --install : exit=$exit"
    if ("$output") { Write-Warn ("  output: " + ("$output" -replace "`r`n", " | ")) }
    return $false
}

function Repair-WslViaUpdate {
    # wsl --update telecharge la version MSI moderne et fixe REGDB_E_CLASSNOTREG
    Write-Step "Tentative repair via 'wsl --update'"
    & wsl --update 2>&1 | Out-Host
    return ($LASTEXITCODE -eq 0)
}

function Repair-WslViaMsi {
    # Fallback : telecharger le MSI WSL officiel depuis GitHub releases (microsoft/WSL)
    Write-Step "Tentative repair via MSI GitHub (microsoft/WSL releases)"
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/microsoft/WSL/releases/latest' -UseBasicParsing
        $msiUrl = ($rel.assets | Where-Object { $_.name -like '*x64.msi' } | Select-Object -First 1).browser_download_url
        if (-not $msiUrl) { Write-Err "Pas de MSI x64 trouve dans la release"; return $false }
        $msi = "$script:DownloadDir\wsl.msi"
        Invoke-WebRequest $msiUrl -OutFile $msi -UseBasicParsing
        Write-Step "Install MSI: $msi"
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Ok "MSI WSL installe (exit $($p.ExitCode))"
            return $true
        }
        Write-Err "msiexec exit $($p.ExitCode)"; return $false
    } catch {
        Write-Err "MSI install echec: $_"; return $false
    }
}

# Etape 1 : WSL deja actif ? On se base sur le CODE DE SORTIE (pas une chaine localisee FR).
$env:WSL_UTF8 = '1'   # force la sortie wsl en UTF-8 (sinon UTF-16 + 'par defaut' en FR -> match rate)
$wslReady = $false
try {
    wsl --status *> $null
    if ($LASTEXITCODE -eq 0) { $wslReady = $true }
} catch { Write-Warn "wsl --status indisponible : $($_.Exception.Message)" }

if ($wslReady) {
    Write-Ok "WSL deja actif"
    $distros = wsl --list --quiet 2>$null
    if ($distros -notmatch 'Ubuntu') {
        Write-Step "Install Ubuntu"
        if (-not (Try-WslInstallUbuntu)) {
            Write-Warn "Install Ubuntu echec - relance manuellement plus tard : wsl --install -d Ubuntu"
        }
    }
} else {
    # Etape 2 : tentative directe
    Write-Step "Tentative wsl --install -d Ubuntu"
    $ok = Try-WslInstallUbuntu

    # Etape 3 : si REGDB_E ou autre, repair via wsl --update
    if (-not $ok) {
        if (Repair-WslViaUpdate) {
            Write-Ok "wsl --update OK - retry install"
            $ok = Try-WslInstallUbuntu
        }
    }

    # Etape 4 : si toujours KO, install MSI GitHub
    if (-not $ok) {
        if (Repair-WslViaMsi) {
            Write-Ok "MSI WSL OK - retry install"
            $ok = Try-WslInstallUbuntu
        }
    }

    # Etape 5 : derniere chance, dism (necessite reboot)
    if (-not $ok) {
        Write-Warn "Toutes les tentatives wsl ont echoue. Fallback dism (active les features Windows)..."
        try {
            dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
            dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
            Write-Ok "Features WSL + VirtualMachinePlatform activees via dism"
            Write-Warn "REBOOT REQUIS, puis relance ce module pour installer Ubuntu"
        } catch {
            Write-Err "dism echec : $_"
            Write-Warn "Manuel : Settings > Apps > Optional features > More Windows features > active 'Windows Subsystem for Linux' et 'Virtual Machine Platform'"
        }
    } elseif ($ok) {
        Write-Ok "WSL + Ubuntu installes"
    }
}

# --- Git config ---
Write-Step "Git config"
if (Test-CommandExists git) {
    git config --global user.name 'Codect'
    git config --global user.email 'contact@tom-lefrere.fr'
    git config --global init.defaultBranch main
    git config --global core.autocrlf input
    git config --global pull.rebase false
    Write-Ok "Git configure (Codect / contact@tom-lefrere.fr)"
} else {
    Write-Warn "git absent - relance apres module 01"
}

# --- gh CLI auth (genere SSH key + l'ajoute a GitHub) ---
Write-Step "gh auth (GitHub + SSH key)"
if (Test-CommandExists gh) {
    try {
        $authStatus = gh auth status 2>&1
        # gh auth status retourne exit 1 quand pas logge - on regarde juste le texte
        if ("$authStatus" -match 'Logged in to github.com') {
            Write-Ok "Deja logge sur GitHub"
        } elseif ($script:Auto) {
            Write-Warn "Mode AUTO : 'gh auth login' interactif saute (il bloquerait le run)."
            Write-Warn "A faire a la main : gh auth login --git-protocol ssh --web --hostname github.com"
        } else {
            Write-Warn "Le navigateur va s'ouvrir pour login GitHub. Choisis 'SSH' comme protocole, et 'Login with a web browser'."
            gh auth login --git-protocol ssh --web --hostname github.com
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "gh auth login non complete. Tu pourras relancer plus tard : gh auth login"
            }
        }
    } catch {
        Write-Warn "gh auth skip : $($_.Exception.Message)"
    }
} else {
    Write-Warn "gh absent - relance apres module 01"
}

Write-Ok "Dev setup OK"
