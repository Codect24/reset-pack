# 15-hp-triage : capture de l'état installé, puis tri du bloatware HP (liste blanche explicite)
# Réf. : SYSTEME-OMEN-35L.md §6. Remplace 08-debloat sur l'OMEN (08 n'y tourne JAMAIS : image usine conservée).
#  1. Capture TOUJOURS, même en dry-run (c'est de la lecture) -> logs\hp-capture-<yyyyMMdd-HHmmss>\
#     winget list, Appx (tous utilisateurs), Appx provisionnés (admin), clés Uninstall HKLM / WOW6432Node / HKCU.
#     Jamais Win32_Product : l'interroger fait vérifier (voire reconfigurer) chaque MSI installé.
#  2. Tri selon config\hp-triage.json : 'remove' retiré, 'confirm' seulement sur un oui interactif, tout le reste intact.
#     Garde-fou : un candidat qui matche aussi 'keep' n'est jamais retiré (warning).
#  3. Après McAfee : Defender doit avoir repris la protection en temps réel.
# Testable : dot-sourcé (. .\15-hp-triage.ps1), le fichier ne fait que définir ses fonctions.
# Racine des logs surchargeable : Invoke-HpTriage -LogRoot <dossier>, ou $env:RESETPACK_LOG_ROOT.
. "$PSScriptRoot\00-helpers.ps1"

$script:HpTriageConfigPath = Join-Path $script:Root 'config\hp-triage.json'
$script:UninstallRoots = @(
    @{ Hive = 'HKLM';         Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' }
    @{ Hive = 'HKLM-WOW6432'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' }
    @{ Hive = 'HKCU';         Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' }
)
$script:YesPattern = '^\s*(o|oui|y|yes)\s*$'

# ============================================================================
# Configuration
# ============================================================================
function Get-HpTriageConfig {
    # Charge et valide config\hp-triage.json. Throw si invalide : on ne trie jamais à l'aveugle.
    param([string]$Path = $script:HpTriageConfigPath)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config de tri introuvable : $Path" }
    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($section in 'keep', 'remove', 'confirm') {
        if ($null -eq $cfg.$section) { throw "hp-triage.json : section '$section' manquante" }
        foreach ($e in @($cfg.$section)) {
            if (-not $e.name -or -not $e.pattern) { throw "hp-triage.json [$section] : entrée sans 'name' ou 'pattern'" }
            if (@('appx', 'win32') -notcontains $e.type) {
                throw "hp-triage.json [$section] '$($e.name)' : type '$($e.type)' invalide (appx|win32)"
            }
        }
    }
    return $cfg
}

function Get-HpTriageLogRoot {
    # Racine des captures : paramètre > $env:RESETPACK_LOG_ROOT > <repo>\logs.
    param([string]$LogRoot)
    if ($LogRoot) { return $LogRoot }
    if ($env:RESETPACK_LOG_ROOT) { return $env:RESETPACK_LOG_ROOT }
    return (Join-Path $script:Root 'logs')
}

function Test-NameMatch {
    # $true si l'un des noms matche le motif (-like : jokers, insensible à la casse).
    param([string[]]$Name, [string]$Pattern)
    foreach ($n in $Name) {
        if ($n -and ($n -like $Pattern)) { return $true }
    }
    return $false
}

function Find-KeepRule {
    # Première règle 'keep' qui matche l'un des noms du candidat. Tous types confondus : garde-fou volontairement large.
    param([string[]]$Name, [Parameter(Mandatory)]$Config)
    foreach ($k in @($Config.keep)) {
        if (Test-NameMatch -Name $Name -Pattern $k.pattern) { return $k }
    }
    return $null
}

# ============================================================================
# Inventaire (lecture seule)
# ============================================================================
function Get-UninstallEntry {
    # Programmes Win32 déclarés dans les clés Uninstall (HKLM, HKLM WOW6432Node, HKCU). Jamais Win32_Product.
    foreach ($root in $script:UninstallRoots) {
        foreach ($i in @(Get-ItemProperty -Path $root.Path -ErrorAction SilentlyContinue)) {
            if (-not $i -or -not $i.DisplayName) { continue }
            [pscustomobject]@{
                Hive                 = $root.Hive
                KeyName              = $i.PSChildName
                DisplayName          = $i.DisplayName
                DisplayVersion       = $i.DisplayVersion
                Publisher            = $i.Publisher
                InstallDate          = $i.InstallDate
                InstallLocation      = $i.InstallLocation
                SystemComponent      = $i.SystemComponent
                UninstallString      = $i.UninstallString
                QuietUninstallString = $i.QuietUninstallString
                RegistryPath         = $i.PSPath
            }
        }
    }
}

function Get-AppxInventory {
    # Paquets Appx : utilisateur courant (cible du retrait), ou tous les utilisateurs pour la capture (admin).
    param([bool]$AllUsers)
    try {
        if ($AllUsers) { return @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
        return @(Get-AppxPackage -ErrorAction Stop)
    } catch {
        Write-Warn "Get-AppxPackage indisponible : $($_.Exception.Message)"
        return @()
    }
}

function Get-ProvisionedInventory {
    # Paquets provisionnés (installés pour chaque nouveau compte). Admin requis.
    try { return @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) }
    catch {
        Write-Warn "Get-AppxProvisionedPackage indisponible : $($_.Exception.Message)"
        return @()
    }
}

function Invoke-WingetList {
    # Texte brut de 'winget list' (lecture seule). $null si winget est absent.
    if (-not (Test-CommandExists winget)) { return $null }
    $ErrorActionPreference = 'Continue'   # PS 5.1 : un stderr natif ne doit pas devenir une exception
    $prevEnc = $null
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 }
    catch { Write-Verbose "Encodage console inchangé : $($_.Exception.Message)" }
    try {
        return (& winget list --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
    } finally {
        if ($prevEnc) {
            try { [Console]::OutputEncoding = $prevEnc } catch { Write-Verbose "Encodage console non restauré" }
        }
    }
}

function Export-CaptureCsv {
    # Export CSV UTF-8 ; écrit un fichier même vide (la capture doit prouver qu'on a regardé).
    param([Parameter(Mandatory)][string]$Path, [object[]]$InputObject)
    $rows = @($InputObject | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value '(aucune entrée)' -Encoding UTF8
        return
    }
    $csv = @{ LiteralPath = $Path; Encoding = 'UTF8' }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $csv.NoTypeInformation = $true }   # PS 7 : défaut, et obsolète
    $rows | Export-Csv @csv
}

function Export-HpCapture {
    # Capture horodatée de l'état installé. Écrit MÊME en dry-run : lecture du système + écriture de logs uniquement.
    param(
        [Parameter(Mandatory)][string]$Directory,
        [bool]$IsAdmin,
        [string]$Prefix = '',
        [switch]$SkipWinget
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Force -Path $Directory -ErrorAction Stop | Out-Null
    }

    if (-not $SkipWinget) {
        $txt = Invoke-WingetList
        if ($null -eq $txt) {
            Write-Warn "winget absent : capture 'winget list' sautée"
            $txt = '(winget absent : rien capturé)'
        }
        Set-Content -LiteralPath (Join-Path $Directory "${Prefix}winget-list.txt") -Value $txt -Encoding UTF8
    }

    $appxFile = 'appx-user.csv'
    if ($IsAdmin) { $appxFile = 'appx-allusers.csv' }
    $appx = @(Get-AppxInventory -AllUsers $IsAdmin)
    Export-CaptureCsv -Path (Join-Path $Directory "$Prefix$appxFile") -InputObject @($appx |
        Select-Object Name, PackageFullName, PackageFamilyName, Version, Publisher, Architecture,
                      IsFramework, NonRemovable, SignatureKind, InstallLocation)

    if ($IsAdmin) {
        $prov = @(Get-ProvisionedInventory)
        Export-CaptureCsv -Path (Join-Path $Directory "${Prefix}appx-provisioned.csv") -InputObject @($prov |
            Select-Object DisplayName, PackageName, Version)
    } else {
        Write-Warn "Pas admin : Appx provisionnés non capturés"
    }

    $win32 = @(Get-UninstallEntry)
    Export-CaptureCsv -Path (Join-Path $Directory "${Prefix}uninstall-registry.csv") -InputObject $win32

    return [pscustomobject]@{ Directory = $Directory; Appx = $appx.Count; Win32 = $win32.Count }
}

# ============================================================================
# Désinstallation Win32
# ============================================================================
function ConvertFrom-CommandLine {
    # '"C:\x\u.exe" /a /b' -> { FilePath = 'C:\x\u.exe' ; Arguments = '/a /b' }. Gère le chemin sans guillemets.
    param([string]$CommandLine)
    if (-not $CommandLine -or -not $CommandLine.Trim()) { return $null }
    $s = $CommandLine.Trim()
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -lt 1) { return $null }
        return [pscustomobject]@{ FilePath = $s.Substring(1, $end - 1); Arguments = $s.Substring($end + 1).Trim() }
    }
    $m = [regex]::Match($s, '^(?<exe>.+?\.exe)(?:\s+(?<rest>.*))?$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
        return [pscustomobject]@{ FilePath = $m.Groups['exe'].Value; Arguments = $m.Groups['rest'].Value.Trim() }
    }
    $parts = $s -split '\s+', 2
    $rest = ''
    if ($parts.Count -gt 1) { $rest = $parts[1] }
    return [pscustomobject]@{ FilePath = $parts[0]; Arguments = $rest }
}

function Get-Win32UninstallCommand {
    # Commande SILENCIEUSE, dans cet ordre : QuietUninstallString > MSI (/x /qn) > UninstallString + flags
    # connus (knownFlags du JSON). $null si rien de silencieux n'est connu.
    param([Parameter(Mandatory)]$Entry, $Rule)
    if ($Entry.QuietUninstallString) {
        $q = ConvertFrom-CommandLine $Entry.QuietUninstallString
        if ($q) { return [pscustomobject]@{ FilePath = $q.FilePath; Arguments = $q.Arguments; Source = 'QuietUninstallString' } }
    }
    $u = ConvertFrom-CommandLine $Entry.UninstallString
    if (-not $u) { return $null }
    $leaf = Split-Path $u.FilePath -Leaf
    if ($leaf -match '^msiexec(\.exe)?$') {
        $guid = [regex]::Match("$($u.Arguments) $($Entry.KeyName)", '\{[0-9A-Fa-f-]{36}\}').Value
        if ($guid) {
            return [pscustomobject]@{ FilePath = 'msiexec.exe'; Arguments = "/x $guid /qn /norestart"; Source = 'MSI /qn' }
        }
    }
    if ($Rule) {
        foreach ($f in @($Rule.knownFlags)) {
            if (-not $f -or -not $f.exe -or -not ($leaf -like $f.exe)) { continue }
            $argLine = $u.Arguments
            if ($argLine -notmatch ('(^|\s)' + [regex]::Escape($f.args) + '(\s|$)')) { $argLine = ("$argLine $($f.args)").Trim() }
            return [pscustomobject]@{ FilePath = $u.FilePath; Arguments = $argLine; Source = "UninstallString + $($f.args)" }
        }
    }
    return $null
}

function Invoke-UninstallProcess {
    # Lance un désinstalleur et attend au plus $TimeoutSec. Renvoie 'ok' | 'reboot' | 'timeout' | 'echec:<code>'.
    param([Parameter(Mandatory)]$Command, [int]$TimeoutSec = 900)
    $sp = @{ FilePath = $Command.FilePath; PassThru = $true; ErrorAction = 'Stop' }
    if ($Command.Arguments) { $sp.ArgumentList = $Command.Arguments }
    $p = Start-Process @sp
    if (-not $p) { return 'echec:processus non démarré' }
    try { $null = $p.Handle } catch { Write-Verbose 'Handle indisponible' }   # sinon ExitCode reste vide (PS 5.1)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { return 'timeout' }
    $code = $p.ExitCode
    if ($code -eq 3010 -or $code -eq 1641) { return 'reboot' }
    if ($null -eq $code -or $code -eq 0) { return 'ok' }
    return "echec:$code"
}

# ============================================================================
# Tri
# ============================================================================
function Find-TriageCandidate {
    # Éléments installés qui matchent une règle : Appx (utilisateur + provisionné) ou entrées Uninstall Win32.
    param([Parameter(Mandatory)]$Rule, [Parameter(Mandatory)]$Inventory)
    if ($Rule.type -eq 'appx') {
        foreach ($p in @($Inventory.Appx)) {
            if (-not $p) { continue }
            $names = @($p.Name, $p.PackageFamilyName, $p.PackageFullName)
            if (Test-NameMatch -Name $names -Pattern $Rule.pattern) {
                [pscustomobject]@{ Kind = 'appx'; Label = "$($p.Name)"; Names = $names; Item = $p }
            }
        }
        foreach ($p in @($Inventory.Provisioned)) {
            if (-not $p) { continue }
            $names = @($p.DisplayName, $p.PackageName)
            if (Test-NameMatch -Name $names -Pattern $Rule.pattern) {
                [pscustomobject]@{ Kind = 'provisioned'; Label = "$($p.DisplayName) (provisionné)"; Names = $names; Item = $p }
            }
        }
        return
    }
    foreach ($e in @($Inventory.Win32)) {
        if (-not $e) { continue }
        $names = @($e.DisplayName, $e.KeyName)
        if (Test-NameMatch -Name $names -Pattern $Rule.pattern) {
            [pscustomobject]@{ Kind = 'win32'; Label = "$($e.DisplayName)"; Names = $names; Item = $e }
        }
    }
}

function ConvertTo-TriageStatus {
    param([string]$State, [string]$Reason)
    return [pscustomobject]@{ State = $State; Reason = $Reason }
}

function Invoke-TriageRemoval {
    # Retire UN candidat (respecte le dry-run). Renvoie { State = 'removed' | 'skipped' ; Reason }.
    param(
        [Parameter(Mandatory)]$Candidate,
        $Rule,
        [bool]$DryRun,
        [bool]$Auto,
        [bool]$IsAdmin,
        [int]$TimeoutSec = 900
    )
    $c = $Candidate
    if ($c.Kind -eq 'appx') {
        if ($c.Item.NonRemovable) { return (ConvertTo-TriageStatus 'skipped' 'paquet système non retirable') }
        if ($DryRun) {
            Write-Dry "Remove-AppxPackage $($c.Item.PackageFullName)"
            return (ConvertTo-TriageStatus 'removed' 'simulation')
        }
        try {
            Remove-AppxPackage -Package $c.Item.PackageFullName -ErrorAction Stop
            Write-Ok "Retiré : $($c.Label)"
            return (ConvertTo-TriageStatus 'removed' 'Remove-AppxPackage')
        } catch {
            Write-Warn "Échec du retrait de $($c.Label) : $($_.Exception.Message)"
            return (ConvertTo-TriageStatus 'skipped' "échec : $($_.Exception.Message)")
        }
    }

    if ($c.Kind -eq 'provisioned') {
        if (-not $IsAdmin) { return (ConvertTo-TriageStatus 'skipped' 'admin requis (provisionné)') }
        if ($DryRun) {
            Write-Dry "Remove-AppxProvisionedPackage -Online $($c.Item.PackageName)"
            return (ConvertTo-TriageStatus 'removed' 'simulation')
        }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $c.Item.PackageName -ErrorAction Stop | Out-Null
            Write-Ok "Retiré (provisionné) : $($c.Label)"
            return (ConvertTo-TriageStatus 'removed' 'Remove-AppxProvisionedPackage')
        } catch {
            Write-Warn "Échec du retrait (provisionné) de $($c.Label) : $($_.Exception.Message)"
            return (ConvertTo-TriageStatus 'skipped' "échec : $($_.Exception.Message)")
        }
    }

    # --- Win32 ---
    $e = $c.Item
    if (($e.Hive -like 'HKLM*') -and -not $IsAdmin) { return (ConvertTo-TriageStatus 'skipped' 'admin requis (programme machine)') }
    $cmd = Get-Win32UninstallCommand -Entry $e -Rule $Rule
    if (-not $cmd) {
        $hint = 'désinstalle-le via Paramètres > Applications.'
        if ($Rule -and $Rule.manualHint) { $hint = $Rule.manualHint }
        if ($Auto -or $DryRun) {
            Write-Warn "$($c.Label) : pas de désinstallation silencieuse connue. $hint"
            return (ConvertTo-TriageStatus 'skipped' "pas de désinstallation silencieuse ($hint)")
        }
        $ans = Read-Host "$($c.Label) : pas de désinstallation silencieuse. Lancer son désinstalleur (fenêtre interactive) ? [o/N]"
        if ($ans -notmatch $script:YesPattern) { return (ConvertTo-TriageStatus 'skipped' "laissé en place ($hint)") }
        $i = ConvertFrom-CommandLine $e.UninstallString
        if (-not $i) { return (ConvertTo-TriageStatus 'skipped' 'UninstallString illisible') }
        $cmd = [pscustomobject]@{ FilePath = $i.FilePath; Arguments = $i.Arguments; Source = 'UninstallString (interactif)' }
    }
    if ($DryRun) {
        Write-Dry "désinstalle '$($c.Label)' via $($cmd.Source) : `"$($cmd.FilePath)`" $($cmd.Arguments)"
        return (ConvertTo-TriageStatus 'removed' 'simulation')
    }
    Write-Step "Désinstallation : $($c.Label) ($($cmd.Source), timeout $TimeoutSec s)"
    try { $r = Invoke-UninstallProcess -Command $cmd -TimeoutSec $TimeoutSec }
    catch { return (ConvertTo-TriageStatus 'skipped' "échec au lancement : $($_.Exception.Message)") }
    if ($r -eq 'timeout') {
        Write-Warn "$($c.Label) : pas fini après $TimeoutSec s (désinstalleur laissé en cours, vérifie à la main)"
        return (ConvertTo-TriageStatus 'skipped' "timeout ($TimeoutSec s)")
    }
    if ($r -like 'echec:*') {
        Write-Warn "$($c.Label) : désinstallation en échec (code $($r.Substring(6)))"
        return (ConvertTo-TriageStatus 'skipped' "échec (code $($r.Substring(6)))")
    }
    if ($e.RegistryPath -and (Test-Path -LiteralPath $e.RegistryPath)) {
        Write-Warn "$($c.Label) : toujours déclaré après la désinstallation (redémarrage requis ?)"
    }
    $why = $cmd.Source
    if ($r -eq 'reboot') { $why = "$why, redémarrage requis" }
    Write-Ok "Désinstallé : $($c.Label) ($why)"
    return (ConvertTo-TriageStatus 'removed' $why)
}

function Test-DefenderAfterAv {
    # Après le retrait de McAfee : Defender doit reprendre la protection en temps réel (McAfee la désactive).
    param([bool]$DryRun)
    try { $s = Get-MpComputerStatus -ErrorAction Stop }
    catch {
        Write-Warn "Defender : état illisible ($($_.Exception.Message)) -> vérifie Sécurité Windows à la main."
        return $false
    }
    if ($s.RealTimeProtectionEnabled) {
        Write-Ok "Defender : protection en temps réel ACTIVE (mode : $($s.AMRunningMode))"
        return $true
    }
    Write-Warn "DEFENDER : PROTECTION EN TEMPS RÉEL DÉSACTIVÉE (mode : $($s.AMRunningMode)) -- la machine n'est plus protégée !"
    if ($DryRun) {
        Write-Dry "Set-MpPreference -DisableRealtimeMonitoring `$false"
        return $false
    }
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        $s = Get-MpComputerStatus -ErrorAction Stop
    } catch {
        Write-Warn "Réactivation de Defender impossible : $($_.Exception.Message)"
    }
    if ($s -and $s.RealTimeProtectionEnabled) {
        Write-Ok "Defender : protection en temps réel RÉACTIVÉE"
        return $true
    }
    Write-Warn "Toujours OFF : redémarre (Defender reprend la main au boot après un antivirus tiers), puis Sécurité Windows > Protection contre les virus et menaces."
    return $false
}

function Format-HpTriageSummary {
    # Lignes du résumé (affichées et écrites dans la capture).
    param([Parameter(Mandatory)]$Result, [bool]$DryRun)
    $retLabel = 'retiré'
    if ($DryRun) { $retLabel = 'retiré (simulé)' }
    $groups = [ordered]@{}
    $groups[$retLabel] = $Result.Retire
    $groups['gardé'] = $Result.Garde
    $groups['ignoré'] = $Result.Ignore
    $groups['à confirmer'] = $Result.AConfirmer
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($k in $groups.Keys) {
        $items = @($groups[$k])
        $lines.Add(('{0,-16} : {1}' -f $k, $items.Count))
        foreach ($it in $items) { $lines.Add("    . $it") }
    }
    return , $lines.ToArray()
}

function Invoke-HpTriage {
    # Point d'entrée : capture -> inventaire -> tri (remove puis confirm) -> Defender -> résumé.
    param(
        $Config,
        [string]$ConfigPath = $script:HpTriageConfigPath,
        [string]$LogRoot,
        [bool]$DryRun = $script:DryRun,
        [bool]$Auto = $script:Auto,
        [bool]$IsAdmin = (Test-Admin),
        [int]$TimeoutSec = 0
    )
    if (-not $Config) { $Config = Get-HpTriageConfig -Path $ConfigPath }
    if ($TimeoutSec -le 0) {
        $TimeoutSec = 900
        if ($Config.uninstallTimeoutSec) { $TimeoutSec = [int]$Config.uninstallTimeoutSec }
    }
    $result = [pscustomobject]@{
        CaptureDir = $null
        Retire     = New-Object System.Collections.Generic.List[string]
        Garde      = New-Object System.Collections.Generic.List[string]
        Ignore     = New-Object System.Collections.Generic.List[string]
        AConfirmer = New-Object System.Collections.Generic.List[string]
        DefenderOk = $null
    }

    # --- 1. Capture d'abord (aussi en dry-run) ---
    $dir = Join-Path (Get-HpTriageLogRoot -LogRoot $LogRoot) ('hp-capture-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    Write-Step "Capture de l'état installé -> $dir"
    try {
        $cap = Export-HpCapture -Directory $dir -IsAdmin $IsAdmin
        $result.CaptureDir = $dir
        Write-Ok "Capture : $($cap.Appx) paquets Appx, $($cap.Win32) programmes Win32"
    } catch {
        Write-Err "Capture impossible ($($_.Exception.Message)) -> AUCUN tri sans état de référence."
        return $result
    }
    if (-not $IsAdmin) { Write-Warn "Session non élevée : provisionnés et programmes machine (HKLM) ne seront pas retirés." }

    # --- 2. Inventaire (le retrait vise l'utilisateur courant + le provisionné) ---
    $inventory = [pscustomobject]@{
        Appx        = @(Get-AppxInventory -AllUsers $false)
        Provisioned = @(if ($IsAdmin) { Get-ProvisionedInventory })
        # Composants masqués (SystemComponent=1) : c'est le désinstalleur parent qui s'en charge.
        Win32       = @(Get-UninstallEntry | Where-Object { "$($_.SystemComponent)" -ne '1' })
    }

    $seen = @{}
    foreach ($k in @($Config.keep)) {
        foreach ($c in @(Find-TriageCandidate -Rule $k -Inventory $inventory)) {
            $tag = "$($k.name) : $($c.Label)"
            if (-not $seen.ContainsKey($tag)) { $seen[$tag] = $true; $result.Garde.Add($tag) }
        }
    }

    # --- 3. Tri ---
    $needDefender = $false
    $done = @{}
    foreach ($section in 'remove', 'confirm') {
        foreach ($rule in @($Config.$section)) {
            $cands = @(Find-TriageCandidate -Rule $rule -Inventory $inventory)
            if ($cands.Count -eq 0) {
                $result.Ignore.Add("$($rule.name) [$($rule.type) '$($rule.pattern)'] : absent")
                continue
            }
            foreach ($c in $cands) {
                $tag = "$($rule.name) : $($c.Label)"
                $key = "$($c.Kind)|$($c.Label)|$($c.Item.UninstallString)"
                if ($done.ContainsKey($key)) { continue }   # même programme déclaré dans deux ruches
                $done[$key] = $true

                $keep = Find-KeepRule -Name $c.Names -Config $Config
                if ($keep) {
                    Write-Warn "GARDE-FOU : '$($c.Label)' matche aussi keep '$($keep.pattern)' ($($keep.name)) -> on n'y touche pas."
                    $result.Garde.Add("$tag (garde-fou : $($keep.name))")
                    continue
                }
                if ($section -eq 'confirm') {
                    if ($Auto -or $DryRun) {
                        Write-Step "À confirmer (non retiré) : $tag"
                        $result.AConfirmer.Add($tag)
                        continue
                    }
                    $ans = Read-Host "Retirer $tag ? ($($rule.why)) [o/N]"
                    if ($ans -notmatch $script:YesPattern) {
                        $result.Garde.Add("$tag (gardé à ta demande)")
                        continue
                    }
                }
                $st = Invoke-TriageRemoval -Candidate $c -Rule $rule -DryRun $DryRun -Auto $Auto -IsAdmin $IsAdmin -TimeoutSec $TimeoutSec
                if ($st.State -eq 'removed') {
                    $result.Retire.Add("$tag ($($st.Reason))")
                    if ($rule.postCheck -eq 'defender') { $needDefender = $true }
                } else {
                    $result.Ignore.Add("$tag : $($st.Reason)")
                }
            }
        }
    }

    # --- 4. Defender après McAfee ---
    if ($needDefender) {
        Write-Step "Vérification de Defender après le retrait de McAfee"
        $result.DefenderOk = Test-DefenderAfterAv -DryRun $DryRun
    }

    # --- 5. Capture « après » + résumé ---
    if (-not $DryRun -and $result.Retire.Count -gt 0) {
        try { Export-HpCapture -Directory $dir -IsAdmin $IsAdmin -Prefix 'apres-' -SkipWinget | Out-Null }
        catch { Write-Warn "Capture 'après' impossible : $($_.Exception.Message)" }
    }
    $lines = Format-HpTriageSummary -Result $result -DryRun $DryRun
    Write-Banner "TRI HP -- RÉSUMÉ"
    foreach ($l in $lines) { Write-Step $l }
    try { Set-Content -LiteralPath (Join-Path $dir 'triage-resultat.txt') -Value $lines -Encoding UTF8 }
    catch { Write-Warn "Résumé non écrit dans la capture : $($_.Exception.Message)" }
    if ($result.AConfirmer.Count -gt 0) {
        Write-Warn "À confirmer : relance en interactif -> .\reset.ps1 -Profile omen -Only hp-triage"
    }
    Write-Ok "Capture de référence : $dir"
    return $result
}

# --- Exécution (sautée quand le fichier est dot-sourcé, ex. par Pester) ---
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-HpTriage | Out-Null
    Write-Ok "Tri HP OK"
}
