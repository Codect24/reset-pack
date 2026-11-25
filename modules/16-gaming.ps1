# 16-gaming : launchers sur D:, tweaks jeu sûrs, OMEN Gaming Hub muselé (pas tué), contrôles sécurité
# Réf. : SYSTEME-OMEN-35L.md §2.5 et §6. Passe APRÈS 06-tweaks : celui-ci coupe le Game Mode, on le rallume
# (lui seul : le Game DVR reste off, la capture passe par NVIDIA App).
#  1. Launchers (si le disque des jeux est là) : Epic scripté (GameUserSettings.ini), les autres en instructions.
#  2. Game Mode ON, HAGS ON (reboot), priorités multimédia « Games ».
#  3. Plan d'alimentation : on VÉRIFIE « Utilisation normale » (Balanced), on n'en crée aucun (voir plus bas).
#  4. OMEN Gaming Hub : GUI au démarrage + notifications coupés. AUCUN service n'est touché.
#  5. Sécurité, en lecture seule : Defender temps réel, VBS / Memory Integrity, aucune exclusion sous les jeux.
# Testable : dot-sourcé (. .\16-gaming.ps1), le fichier ne fait que définir ses fonctions.
. "$PSScriptRoot\00-helpers.ps1"

# --- Plan d'alimentation : correction VOLONTAIRE de SYSTEME §6 (qui proposait « Performances optimales ») ---
# Intel recommande le plan Windows « Utilisation normale » (Balanced) pour les Core Ultra 200S (Arrow Lake) :
# l'ordonnancement P-cores / E-cores (Thread Director) et le parking de cœurs sont calibrés pour lui ; les plans
# « Performances élevées » / « optimales » empêchent les cœurs de se garer, n'apportent rien en jeu et peuvent
# même dégrader l'affectation des threads. Et l'OMEN reste allumé 24/7 pour l'accès distant : un plan qui bloque
# les états basse consommation coûte en watts et en chaleur pour rien.
# => ce module ne crée AUCUN plan ; il vérifie que Balanced est actif et propose de le rétablir sinon.
$script:BalancedPlanGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'

# --- OMEN Gaming Hub (Appx HP) ---
$script:OmenHubAppxPattern = 'AD2F1837.OMENCommandCenter*'
$script:OmenPattern = 'OMEN|Omen'   # -cmatch : évite les faux positifs en minuscules
$script:SystemAppDataRoot = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
$script:NotificationRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
# StartupApproved : 1er octet impair = désactivé (même valeur que le Gestionnaire des tâches).
$script:StartupDisabledValue = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
$script:StartupLocations = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Machine = $false }
    @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Machine = $true }
    @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Machine = $true }
    @{ Run = $null
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Machine = $false }
    @{ Run = $null
       Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Machine = $true }
)
$script:PsMetaProps = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')

# ============================================================================
# Registre (lecture + écriture idempotente)
# ============================================================================
function Get-RegistryValueSafe {
    # Valeur d'un registre, $null si la clé ou la valeur est absente.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        if ($p) { return $p.$Name }
    } catch { Write-Verbose "Absent : $Path\$Name" }
    return $null
}

function Get-RegistryValueMap {
    # Valeurs d'une clé (Nom -> Donnée, sans les propriétés PS*). Table vide si la clé est absente.
    param([Parameter(Mandatory)][string]$Path)
    $map = @{}
    $props = $null
    try { $props = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop } catch { return $map }
    if (-not $props) { return $map }
    foreach ($pr in $props.PSObject.Properties) {
        if ($script:PsMetaProps -contains $pr.Name) { continue }
        $map[$pr.Name] = $pr.Value
    }
    return $map
}

function Sync-RegistryValue {
    # Écrit la valeur seulement si elle diffère (idempotent, dry-run respecté). $true si écrite (ou à écrire).
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Type = 'DWord',
        [string]$Label,
        [bool]$DryRun = $script:DryRun
    )
    if (-not $Label) { $Label = "$Name = $Value" }
    $cur = Get-RegistryValueSafe -Path $Path -Name $Name
    if (($null -ne $cur) -and ("$cur" -eq "$Value")) { Write-Ok "$Label (déjà OK)"; return $false }
    if ($DryRun) { Write-Dry "$Label : reg $Path\$Name = $Value ($Type)"; return $true }
    Set-RegistryValue -Path $Path -Name $Name -Value $Value -Type $Type
    Write-Ok $Label
    return $true
}

# ============================================================================
# 1. Launchers
# ============================================================================
function Get-GamesDriveLetter {
    # Lettre du disque des jeux : layout.gamesDisk.letter, sinon celle du 1er launcher.
    param($Layout)
    if (-not $Layout) { return $null }
    if ($Layout.gamesDisk -and $Layout.gamesDisk.letter) { return ([string]$Layout.gamesDisk.letter).TrimEnd(':', '\') }
    if ($Layout.launchers) {
        foreach ($p in $Layout.launchers.PSObject.Properties) {
            if ("$($p.Value)" -match '^([A-Za-z]):') { return $Matches[1] }
        }
    }
    return $null
}

function Get-GamesRoot {
    # Dossiers racine des jeux (parent commun des launchers, ex. D:\Games ; le launcher lui-même s'il est à la racine).
    param($Layout)
    $roots = New-Object System.Collections.Generic.List[string]
    if ($Layout -and $Layout.launchers) {
        foreach ($p in $Layout.launchers.PSObject.Properties) {
            $v = "$($p.Value)".TrimEnd('\')
            if (-not $v) { continue }
            $parent = (Split-Path $v -Parent).TrimEnd('\')
            $r = $parent
            if (-not $parent -or $parent -match '^[A-Za-z]:$') { $r = $v }
            if (-not $roots.Contains($r)) { $roots.Add($r) }
        }
    }
    return $roots.ToArray()
}

function Get-EpicIniCandidate {
    # Emplacements connus de GameUserSettings.ini (Windows ; WindowsEditor sur certaines versions).
    $base = Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved\Config'
    return @((Join-Path $base 'Windows\GameUserSettings.ini'), (Join-Path $base 'WindowsEditor\GameUserSettings.ini'))
}

function Get-TextFileEncoding {
    # Encodage à conserver à la réécriture : BOM UTF-16 / UTF-8 détecté, sinon UTF-8 sans BOM.
    param([Parameter(Mandatory)][string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return (New-Object Text.UTF8Encoding $true) }
    return (New-Object Text.UTF8Encoding $false)
}

function Test-SameIniValue {
    # Compare deux valeurs de chemin (guillemets, / ou \, séparateur final et casse ignorés).
    param([string]$A, [string]$B)
    $na = "$A".Trim().Trim('"').Replace('/', '\').TrimEnd('\')
    $nb = "$B".Trim().Trim('"').Replace('/', '\').TrimEnd('\')
    return ($na -ieq $nb)
}

function Merge-IniSetting {
    # Pose Key=Value dans [Section] (crée la clé, voire la section). Fonction pure : renvoie { Lines ; Changed }.
    param(
        [string[]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false; $sectionFound = $false; $done = $false; $changed = $false; $insertAt = -1
    $keyRx = '^\s*' + [regex]::Escape($Key) + '\s*=(.*)$'
    foreach ($line in @($Lines)) {
        $t = "$line".Trim()
        if ($t -match '^\[(.+)\]$') {
            $inSection = ($Matches[1].Trim() -ieq $Section)
            $out.Add($line)
            if ($inSection) { $sectionFound = $true; $insertAt = $out.Count }
            continue
        }
        if ($inSection -and ("$line" -match $keyRx)) {
            if ($done) { $changed = $true; continue }   # clé en double : on ne garde que la première
            $done = $true
            if (Test-SameIniValue $Matches[1] $Value) { $out.Add($line) }
            else { $out.Add("$Key=$Value"); $changed = $true }
            $insertAt = $out.Count
            continue
        }
        $out.Add($line)
        if ($inSection -and $t -ne '') { $insertAt = $out.Count }
    }
    if (-not $done) {
        $changed = $true
        if ($sectionFound) {
            $out.Insert($insertAt, "$Key=$Value")
        } else {
            if ($out.Count -gt 0 -and "$($out[$out.Count - 1])".Trim() -ne '') { $out.Add('') }
            $out.Add("[$Section]")
            $out.Add("$Key=$Value")
        }
    }
    return [pscustomobject]@{ Lines = $out.ToArray(); Changed = $changed }
}

function Invoke-EpicDefaultLocation {
    # Epic : [Launcher] DefaultAppInstallLocation=<Target> dans GameUserSettings.ini. Idempotent, backup avant écriture.
    # Renvoie 'absent' | 'ouvert' | 'ok' | 'dry' | 'ecrit'.
    param(
        [Parameter(Mandatory)][string]$Target,
        [string[]]$IniPath = (Get-EpicIniCandidate),
        [bool]$DryRun = $script:DryRun
    )
    $files = @($IniPath | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($files.Count -eq 0) {
        Write-Warn "Epic : GameUserSettings.ini introuvable (launcher jamais lancé ?)"
        Write-Step "Epic : lance-le une fois, quitte-le (icône près de l'horloge > Quitter), puis : .\reset.ps1 -Profile omen -Only gaming"
        Write-Step "Epic : d'ici là, choisis $Target à chaque installation de jeu"
        return 'absent'
    }
    if (Get-Process -Name 'EpicGamesLauncher' -ErrorAction SilentlyContinue) {
        Write-Warn "Epic est ouvert : il réécrit GameUserSettings.ini en quittant -> quitte-le, puis relance -Only gaming"
        return 'ouvert'
    }
    $state = 'ok'
    foreach ($f in $files) {
        $full = (Resolve-Path -LiteralPath $f).ProviderPath
        $enc = Get-TextFileEncoding -Path $full
        $text = [IO.File]::ReadAllText($full, $enc)
        $nl = "`n"
        if ($text -match "`r`n") { $nl = "`r`n" }
        $lines = @()
        if ($text.Length -gt 0) {
            $lines = @($text -split "`r?`n")
            if ($text.EndsWith("`n")) {
                if ($lines.Count -gt 1) { $lines = $lines[0..($lines.Count - 2)] } else { $lines = @() }
            }
        }
        $m = Merge-IniSetting -Lines $lines -Section 'Launcher' -Key 'DefaultAppInstallLocation' -Value $Target
        if (-not $m.Changed) { Write-Ok "Epic : DefaultAppInstallLocation déjà = $Target"; continue }
        if ($DryRun) {
            Write-Dry "Epic : [Launcher] DefaultAppInstallLocation=$Target dans $full (backup avant écriture)"
            $state = 'dry'
            continue
        }
        $backup = "$full.before-resetpack-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item -LiteralPath $full -Destination $backup -Force
        [IO.File]::WriteAllText($full, (($m.Lines -join $nl) + $nl), $enc)
        Write-Ok "Epic : DefaultAppInstallLocation = $Target (backup : $backup)"
        $state = 'ecrit'
    }
    return $state
}

function Show-LauncherInstruction {
    # Ce qui ne se scripte pas proprement (Steam : on n'édite pas libraryfolders.vdf). Chemins tirés du layout.
    param([Parameter(Mandatory)]$Layout)
    $l = $Layout.launchers
    Write-Step "À régler une fois dans chaque launcher :"
    if ($l.Steam)     { Write-Step "  Steam      : Paramètres > Stockage > (+) Ajouter un disque > $($l.Steam), puis (...) > Définir par défaut" }
    if ($l.BattleNet) { Write-Step "  Battle.net : le client reste sur C: ; Paramètres > Téléchargements > Emplacement d'installation = $($l.BattleNet)" }
    if ($l.Riot)      { Write-Step "  Riot       : installe LoL / Valorant depuis le Riot Client dans $($l.Riot) (winget ignore le chemin)" }
    if ($l.Riot)      { Write-Step "               Riot Vanguard RESTE sur C: (imposé par Riot) : ne le déplace pas" }
    if ($l.GOG)       { Write-Step "  GOG Galaxy : Paramètres > Installation et mises à jour > Emplacement d'installation = $($l.GOG)" }
    if ($l.EA)        { Write-Step "  EA app     : Paramètres > Téléchargement > Emplacement d'installation = $($l.EA)" }
    if ($l.Ubisoft)   { Write-Step "  Ubisoft    : Paramètres > Téléchargements > Emplacement d'installation par défaut = $($l.Ubisoft)" }
    if ($Layout.captures) {
        Write-Step "  NVIDIA App : Alt+Z > Paramètres > Captures et enregistrements > Emplacement = $($Layout.captures) (le Game DVR Windows reste off)"
    }
}

function Invoke-LauncherSetup {
    # Partie « launchers » : dossiers cibles, Epic scripté, instructions pour le reste.
    param([Parameter(Mandatory)]$Layout, [string[]]$EpicIniPath = (Get-EpicIniCandidate), [bool]$DryRun = $script:DryRun)
    foreach ($d in @($Layout.launchers.Epic, $Layout.captures)) {
        if (-not $d -or (Test-Path -LiteralPath $d)) { continue }
        Write-Warn "Dossier absent : $d (normalement créé par le module storage)"
        if ($DryRun) { Write-Dry "mkdir $d" } else { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    if ($Layout.launchers.Epic) {
        $null = Invoke-EpicDefaultLocation -Target $Layout.launchers.Epic -IniPath $EpicIniPath -DryRun $DryRun
    }
    Show-LauncherInstruction -Layout $Layout
}

# ============================================================================
# 2. Tweaks jeu
# ============================================================================
function Enable-GamingTweak {
    # Game Mode ON (et lui seul : le Game DVR de 06-tweaks reste off), HAGS ON, priorités multimédia « Games ».
    param([bool]$DryRun = $script:DryRun, [bool]$IsAdmin = (Test-Admin))
    $gb = 'HKCU:\Software\Microsoft\GameBar'
    $null = Sync-RegistryValue -Path $gb -Name 'AutoGameModeEnabled' -Value 1 -Label 'Game Mode ON (AutoGameModeEnabled=1)' -DryRun $DryRun
    $null = Sync-RegistryValue -Path $gb -Name 'AllowAutoGameMode' -Value 1 -Label 'Game Mode autorisé (AllowAutoGameMode=1)' -DryRun $DryRun

    if (-not $IsAdmin -and -not $DryRun) {
        Write-Warn "Pas admin : HAGS et priorités multimédia (HKLM) sautés -> relance en admin."
        return
    }
    $hags = Sync-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 `
        -Label 'HAGS ON (HwSchMode=2)' -DryRun $DryRun
    if ($hags) { Write-Warn "HAGS : redémarrage requis pour l'appliquer." }

    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    $null = Sync-RegistryValue -Path $mm -Name 'GPU Priority' -Value 8 -Label 'Jeux : GPU Priority = 8' -DryRun $DryRun
    $null = Sync-RegistryValue -Path $mm -Name 'Priority' -Value 6 -Label 'Jeux : Priority = 6' -DryRun $DryRun
    $null = Sync-RegistryValue -Path $mm -Name 'Scheduling Category' -Value 'High' -Type 'String' -Label 'Jeux : Scheduling Category = High' -DryRun $DryRun
    $null = Sync-RegistryValue -Path $mm -Name 'SFIO Priority' -Value 'High' -Type 'String' -Label 'Jeux : SFIO Priority = High' -DryRun $DryRun
}

# ============================================================================
# 3. Plan d'alimentation (vérification seulement, cf. l'en-tête)
# ============================================================================
function Invoke-PowerCfg {
    # Unique point d'appel de powercfg.exe (mocké par les tests).
    param([Parameter(Mandatory)][string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    return (& powercfg.exe @Arguments 2>&1 | Out-String)
}

function ConvertFrom-PowerCfgScheme {
    # GUID du plan dans la sortie de 'powercfg /getactivescheme' (langue indifférente). $null si absent.
    param([string]$Text)
    $m = [regex]::Match("$Text", '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value.ToLower() }
    return $null
}

function Confirm-BalancedPowerPlan {
    # Vérifie que « Utilisation normale » (Balanced) est actif ; sinon propose de le rétablir (jamais en Auto / dry-run).
    param([bool]$DryRun = $script:DryRun, [bool]$Auto = $script:Auto)
    $active = ConvertFrom-PowerCfgScheme (Invoke-PowerCfg -Arguments '/getactivescheme')
    if (-not $active) { Write-Warn "Plan d'alimentation actif illisible (powercfg /getactivescheme)"; return $false }
    if ($active -eq $script:BalancedPlanGuid) { Write-Ok "Plan d'alimentation : Utilisation normale (Balanced) actif"; return $true }

    Write-Warn "Plan d'alimentation actif = $active : pas « Utilisation normale » (Balanced), le plan recommandé par Intel pour Arrow Lake."
    $fix = "powercfg /setactive $script:BalancedPlanGuid"
    if ($DryRun) { Write-Dry $fix; return $false }
    if ($Auto) { Write-Warn "Mode Auto : plan inchangé. Pour le rétablir : $fix"; return $false }
    $ans = Read-Host "Rétablir « Utilisation normale » (Balanced) ? [O/n]"
    if ($ans -match '^\s*(n|non|no)\s*$') { Write-Step "Plan d'alimentation laissé tel quel"; return $false }
    $null = Invoke-PowerCfg -Arguments @('/setactive', $script:BalancedPlanGuid)
    if ((ConvertFrom-PowerCfgScheme (Invoke-PowerCfg -Arguments '/getactivescheme')) -eq $script:BalancedPlanGuid) {
        Write-Ok "Plan Utilisation normale (Balanced) rétabli"
        return $true
    }
    Write-Warn "Échec : Balanced est peut-être absent de l'image HP -> vérifie 'powercfg /list'"
    return $false
}

# ============================================================================
# 4. OMEN Gaming Hub : muselé, pas tué
# ============================================================================
function Get-AppxManifestInfo {
    # TaskId des StartupTask et Id des applications d'un paquet Appx, lus dans son manifest.
    param([Parameter(Mandatory)]$Package)
    $xml = $null
    try { $xml = Get-AppxPackageManifest -Package $Package.PackageFullName -ErrorAction Stop }
    catch { Write-Verbose "Get-AppxPackageManifest : $($_.Exception.Message)" }
    if (-not $xml -and $Package.InstallLocation) {
        $mf = Join-Path $Package.InstallLocation 'AppxManifest.xml'
        if (Test-Path -LiteralPath $mf) {
            try { $xml = [xml](Get-Content -LiteralPath $mf -Raw -Encoding UTF8) }
            catch { Write-Verbose "Manifest illisible : $mf" }
        }
    }
    if (-not $xml) { return $null }
    $tasks = @($xml.SelectNodes("//*[local-name()='StartupTask']") | ForEach-Object { $_.GetAttribute('TaskId') } | Where-Object { $_ })
    $apps = @($xml.SelectNodes("//*[local-name()='Applications']/*[local-name()='Application']") |
        ForEach-Object { $_.GetAttribute('Id') } | Where-Object { $_ })
    return [pscustomobject]@{ TaskIds = $tasks; AppIds = $apps }
}

function Get-OmenHubTarget {
    # Par paquet OMEN Gaming Hub : tâches de démarrage et AUMID (manifest + clés déjà présentes au registre).
    param([object[]]$Packages)
    foreach ($pkg in @($Packages)) {
        if (-not $pkg) { continue }
        $pfn = $pkg.PackageFamilyName
        $tasks = New-Object System.Collections.Generic.List[string]
        $aumids = New-Object System.Collections.Generic.List[string]
        $info = Get-AppxManifestInfo -Package $pkg
        if ($info) {
            foreach ($t in @($info.TaskIds)) { if ($t -and -not $tasks.Contains($t)) { $tasks.Add($t) } }
            foreach ($a in @($info.AppIds)) {
                $id = "$pfn!$a"
                if ($a -and -not $aumids.Contains($id)) { $aumids.Add($id) }
            }
        }
        $base = Join-Path $script:SystemAppDataRoot $pfn
        if (Test-Path -LiteralPath $base) {
            foreach ($sub in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
                if ($sub -and ($null -ne $sub.GetValue('State')) -and -not $tasks.Contains($sub.PSChildName)) { $tasks.Add($sub.PSChildName) }
            }
        }
        if (Test-Path -LiteralPath $script:NotificationRoot) {
            foreach ($k in @(Get-ChildItem -LiteralPath $script:NotificationRoot -ErrorAction SilentlyContinue)) {
                if ($k -and ($k.PSChildName -like "$pfn!*") -and -not $aumids.Contains($k.PSChildName)) { $aumids.Add($k.PSChildName) }
            }
        }
        [pscustomobject]@{
            Name = $pkg.Name; PackageFamilyName = $pfn; StartupKey = $base
            TaskIds = $tasks.ToArray(); Aumids = $aumids.ToArray()
        }
    }
}

function Get-OmenStartupEntry {
    # Entrées de démarrage classiques (Run / StartupApproved) dont le nom ou la commande matche OMEN.
    foreach ($loc in $script:StartupLocations) {
        $approved = Get-RegistryValueMap -Path $loc.Approved
        $names = New-Object System.Collections.Generic.List[string]
        if ($loc.Run) {
            $run = Get-RegistryValueMap -Path $loc.Run
            foreach ($n in @($run.Keys)) {
                if (($n -cmatch $script:OmenPattern) -or ("$($run[$n])" -cmatch $script:OmenPattern)) { $names.Add($n) }
            }
        }
        foreach ($n in @($approved.Keys)) {
            if (($n -cmatch $script:OmenPattern) -and -not $names.Contains($n)) { $names.Add($n) }
        }
        foreach ($n in $names) {
            [pscustomobject]@{ Name = $n; ApprovedPath = $loc.Approved; Machine = $loc.Machine; Current = $approved[$n] }
        }
    }
}

function Disable-OmenStartupEntry {
    # Désactive (sans supprimer) via StartupApproved, comme le Gestionnaire des tâches : réversible en un clic.
    param([object[]]$Entries, [bool]$DryRun = $script:DryRun, [bool]$IsAdmin = (Test-Admin))
    foreach ($e in @($Entries)) {
        if (-not $e) { continue }
        $cur = $e.Current
        if (($cur -is [byte[]]) -and $cur.Length -gt 0 -and ($cur[0] -band 1)) { Write-Ok "Démarrage '$($e.Name)' : déjà désactivé"; continue }
        if ($e.Machine -and -not $IsAdmin -and -not $DryRun) { Write-Warn "Démarrage '$($e.Name)' (machine) : admin requis, sauté"; continue }
        if ($DryRun) { Write-Dry "démarrage '$($e.Name)' désactivé ($($e.ApprovedPath))"; continue }
        Set-RegistryValue -Path $e.ApprovedPath -Name $e.Name -Value $script:StartupDisabledValue -Type 'Binary'
        Write-Ok "Démarrage '$($e.Name)' désactivé (réactivable : Gestionnaire des tâches > Applications de démarrage)"
    }
}

function Disable-OmenHubNoise {
    # OMEN Gaming Hub MUSELÉ, PAS TUÉ : on coupe le GUI au démarrage et les notifications. AUCUN service n'est
    # touché : ventilos, RGB et écran LCD du watercooling en dépendent.
    param([bool]$DryRun = $script:DryRun, [bool]$IsAdmin = (Test-Admin))
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -Name $script:OmenHubAppxPattern -ErrorAction Stop) }
    catch { Write-Warn "Get-AppxPackage indisponible : $($_.Exception.Message)" }
    if ($pkgs.Count -eq 0) { Write-Warn "OMEN Gaming Hub (Appx '$script:OmenHubAppxPattern') introuvable : rien à museler côté Appx" }

    foreach ($t in @(Get-OmenHubTarget -Packages $pkgs)) {
        if ($t.TaskIds.Count -eq 0) {
            Write-Warn "OMEN Gaming Hub : aucune tâche de démarrage trouvée -> Paramètres > Applications > Démarrage"
        }
        foreach ($id in $t.TaskIds) {
            # State=1 = « désactivé par l'utilisateur » : l'appli ne peut pas se réactiver seule.
            $null = Sync-RegistryValue -Path "$($t.StartupKey)\$id" -Name 'State' -Value 1 `
                -Label "OMEN Gaming Hub : GUI au démarrage OFF ($id)" -DryRun $DryRun
        }
        if ($t.Aumids.Count -eq 0) {
            Write-Warn "OMEN Gaming Hub : AUMID introuvable -> notifications à couper dans Paramètres > Système > Notifications"
        }
        foreach ($aumid in $t.Aumids) {
            $null = Sync-RegistryValue -Path (Join-Path $script:NotificationRoot $aumid) -Name 'Enabled' -Value 0 `
                -Label "OMEN Gaming Hub : notifications OFF ($aumid)" -DryRun $DryRun
        }
    }
    Disable-OmenStartupEntry -Entries @(Get-OmenStartupEntry) -DryRun $DryRun -IsAdmin $IsAdmin
    Write-Step "OMEN Gaming Hub reste installé, ses services intacts (ventilos, RGB, LCD) : vérifie-les après le reboot."
}

# ============================================================================
# 5. Sécurité (lecture seule, warnings)
# ============================================================================
function Test-PathOverlap {
    # $true si $Path est $Root, l'un de ses sous-dossiers, ou l'un de ses parents (ex. exclusion de tout D:).
    param([string]$Path, [string]$Root)
    $a = "$Path".Trim().TrimEnd('*').TrimEnd('\')
    $b = "$Root".Trim().TrimEnd('\')
    if (-not $a -or -not $b) { return $false }
    if ($a -ieq $b) { return $true }
    if ($a.StartsWith("$b\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $b.StartsWith("$a\", [StringComparison]::OrdinalIgnoreCase)
}

function Test-GamingSecurity {
    # Defender temps réel ON, VBS + Memory Integrity actifs, aucune exclusion Defender sur les jeux. Ne modifie rien.
    param([string[]]$GamesRoot = @('D:\Games'))
    $ok = $true
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        if ($s.RealTimeProtectionEnabled) { Write-Ok "Defender : protection en temps réel ON" }
        else { $ok = $false; Write-Warn "Defender : protection en temps réel OFF -> Sécurité Windows > Protection contre les virus et menaces" }
    } catch { $ok = $false; Write-Warn "Defender : état illisible ($($_.Exception.Message))" }

    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop
        if ($dg.VirtualizationBasedSecurityStatus -eq 2) { Write-Ok "VBS : actif" }
        else { $ok = $false; Write-Warn "VBS : non actif (statut $($dg.VirtualizationBasedSecurityStatus)) -> à réactiver" }
        if (@($dg.SecurityServicesRunning) -contains 2) { Write-Ok "Intégrité de la mémoire (HVCI) : active" }
        else { $ok = $false; Write-Warn "Intégrité de la mémoire : INACTIVE -> Sécurité Windows > Sécurité de l'appareil > Isolation du noyau" }
    } catch { $ok = $false; Write-Warn "VBS / Memory Integrity : état illisible ($($_.Exception.Message))" }

    try {
        $ex = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ })
        if (@($ex | Where-Object { "$_" -like 'N/A*' }).Count -gt 0) {
            Write-Warn "Exclusions Defender illisibles sans admin (relance en admin pour ce contrôle)"
        } else {
            $bad = @(foreach ($e in $ex) { foreach ($r in $GamesRoot) { if (Test-PathOverlap -Path $e -Root $r) { $e; break } } })
            if ($bad.Count -gt 0) {
                $ok = $false
                Write-Warn "Exclusion(s) Defender sur les jeux : $($bad -join ', ') -> à retirer (Sécurité Windows > Paramètres > Exclusions)"
            } else { Write-Ok "Aucune exclusion Defender sous $($GamesRoot -join ', ')" }
        }
    } catch { $ok = $false; Write-Warn "Exclusions Defender illisibles ($($_.Exception.Message))" }
    return $ok
}

# ============================================================================
# Point d'entrée
# ============================================================================
function Invoke-Gaming {
    param(
        $Layout,
        [string[]]$EpicIniPath = (Get-EpicIniCandidate),
        [bool]$DryRun = $script:DryRun,
        [bool]$Auto = $script:Auto,
        [bool]$IsAdmin = (Test-Admin)
    )
    Write-Step "[1/5] Launchers"
    if (-not $Layout) {
        try { $Layout = Get-StorageLayout }
        catch { Write-Warn "Layout de stockage indisponible ($($_.Exception.Message)) -> launchers sautés." }
    }
    $gamesRoot = @('D:\Games')
    if ($Layout -and $Layout.launchers) {
        $r = @(Get-GamesRoot -Layout $Layout)
        if ($r.Count -gt 0) { $gamesRoot = $r }
        $letter = Get-GamesDriveLetter -Layout $Layout
        if (-not $letter -or -not (Test-DriveReady -Letter $letter)) {
            Write-Warn "Disque des jeux ($($letter):) absent -> launchers sautés (les tweaks continuent)."
            Write-Warn "Monte le P310 en ${letter}:, puis : .\reset.ps1 -Profile omen -Only storage,gaming"
        } else {
            Invoke-LauncherSetup -Layout $Layout -EpicIniPath $EpicIniPath -DryRun $DryRun
        }
    } elseif ($Layout) {
        Write-Warn "Aucun launcher dans le layout du profil '$($Layout.Name)' -> launchers sautés."
    }

    Write-Step "[2/5] Tweaks jeu"
    Enable-GamingTweak -DryRun $DryRun -IsAdmin $IsAdmin

    Write-Step "[3/5] Plan d'alimentation"
    $null = Confirm-BalancedPowerPlan -DryRun $DryRun -Auto $Auto

    Write-Step "[4/5] OMEN Gaming Hub (muselé, pas tué)"
    Disable-OmenHubNoise -DryRun $DryRun -IsAdmin $IsAdmin

    Write-Step "[5/5] Sécurité (lecture seule)"
    $null = Test-GamingSecurity -GamesRoot $gamesRoot
}

# --- Exécution (sautée quand le fichier est dot-sourcé, ex. par Pester) ---
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Gaming
    Write-Ok "Gaming OK"
}
