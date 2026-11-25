# 17-remote : accès distant de l'OMEN (cf. SYSTEME-OMEN-35L.md §7, §8 et §10 étape 17).
#   - Tailscale en --unattended (joignable dès le boot, avant toute ouverture de session) ;
#   - Sunshine (hôte) + Moonlight (client) UNIQUEMENT à travers Tailscale, Parsec en secours ;
#   - mode mono-écran automatique : global_prep_cmd de Sunshine -> scripts\remote -> NirSoft MultiMonitorTool ;
#   - durcissement : pare-feu ON, règles Sunshine limitées à Tailscale, UPnP coupé, pas d'auto-login,
#     jamais de veille sur secteur (l'écran peut s'éteindre).
# Profil autre que l'hôte (ex. exodius = le client) : n'affiche que les étapes client et ne touche à rien.
# Réglages : config\remote.json. Aucun secret dans ce module (ni mot de passe Sunshine, ni authkey Tailscale).
# Tests : `. .\modules\17-remote.ps1 -NoRun` charge les fonctions sans rien exécuter.
[CmdletBinding()]
param(
    [switch]$NoRun
)

. "$PSScriptRoot\00-helpers.ps1"

$script:MonoScripts = @('mono-ecran-commun.ps1', 'mono-ecran-on.ps1', 'mono-ecran-off.ps1', 'reactiver-ecrans.ps1')

# ============================================================================
# Configuration & chemins
# ============================================================================
function Get-RemoteConfig {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:Root 'config\remote.json' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config accès distant introuvable : $Path" }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Resolve-RemoteToken {
    # Jetons de remote.json : {Tools} (layout.tools du profil) et {ProgramFiles}.
    param([AllowEmptyString()][string]$Value, [AllowEmptyString()][string]$ToolsDir)
    if (-not $Value) { return $Value }
    return $Value.Replace('{Tools}', $ToolsDir).Replace('{ProgramFiles}', $env:ProgramFiles)
}

function Get-RemotePath {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ToolsDir)
    $mmtDir = Resolve-RemoteToken ([string]$Config.multiMonitorTool.dir) $ToolsDir
    return [pscustomobject]@{
        Tools      = $ToolsDir
        MmtDir     = $mmtDir
        MmtExe     = Join-Path $mmtDir ([string]$Config.multiMonitorTool.exe)
        ScriptsDir = Resolve-RemoteToken ([string]$Config.scriptsDir) $ToolsDir
        SourceDir  = Join-Path $script:Root 'scripts\remote'
    }
}

function Get-WindowsPowerShellPath {
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# ============================================================================
# MultiMonitorTool + scripts mono-écran + tâches planifiées
# ============================================================================
function Write-MultiMonitorToolIni {
    # Pose des clés dans la section [General] de MultiMonitorTool.cfg (idempotent, dry-run respecté).
    param([Parameter(Mandatory)][string]$Dir, $Values)
    if (-not $Values) { return }
    $ini = Join-Path $Dir 'MultiMonitorTool.cfg'
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $ini) { foreach ($l in @(Get-Content -LiteralPath $ini)) { $lines.Add([string]$l) } }
    $before = $lines -join "`n"
    $general = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq '[General]') { $general = $i; break } }
    if ($general -lt 0) { $lines.Insert(0, '[General]'); $general = 0 }
    foreach ($p in $Values.PSObject.Properties) {
        $end = $lines.Count
        for ($i = $general + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim().StartsWith('[')) { $end = $i; break } }
        $found = -1
        for ($i = $general + 1; $i -lt $end; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($p.Name) + '\s*=')) { $found = $i; break }
        }
        $line = '{0}={1}' -f $p.Name, $p.Value
        if ($found -ge 0) { $lines[$found] = $line } else { $lines.Insert($end, $line) }
    }
    if (($lines -join "`n") -ceq $before) { Write-Ok 'MultiMonitorTool.cfg déjà à jour'; return }
    if ($script:DryRun) { Write-Dry "MultiMonitorTool.cfg [General] : $(@($Values.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')"; return }
    Set-Content -LiteralPath $ini -Value $lines.ToArray() -Encoding ASCII
    Write-Ok "MultiMonitorTool.cfg : $ini"
}

function Install-MultiMonitorTool {
    # Zip x64 officiel NirSoft (absent de winget) -> <tools>\MultiMonitorTool. Signature Authenticode vérifiée.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Paths)
    $exe = $Paths.MmtExe
    if (Test-Path -LiteralPath $exe) {
        Write-Ok "MultiMonitorTool déjà présent : $exe"
    } else {
        $zip = Join-Path $script:DownloadDir 'multimonitortool-x64.zip'
        Invoke-Download -Url ([string]$Config.multiMonitorTool.url) -OutFile $zip
        if ($script:DryRun) {
            Write-Dry "extraction $zip -> $($Paths.MmtDir)"
        } else {
            $tmp = Join-Path $script:DownloadDir 'multimonitortool-x64'
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $cand = Join-Path $tmp ([string]$Config.multiMonitorTool.exe)
            if (-not (Test-Path -LiteralPath $cand)) { Write-Err "Archive MultiMonitorTool inattendue : $cand absent"; return $null }
            if ($Config.multiMonitorTool.requireSignature) {
                $sig = Get-AuthenticodeSignature -FilePath $cand
                if ("$($sig.Status)" -ne 'Valid') {
                    Write-Err "Signature de MultiMonitorTool invalide ($($sig.Status)) : NON installé. Retélécharge-le depuis nirsoft.net."
                    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                    return $null
                }
                Write-Ok "Signature valide : $($sig.SignerCertificate.Subject)"
            }
            New-DirectorySafe -Path $Paths.MmtDir | Out-Null
            Copy-Item -Path (Join-Path $tmp '*') -Destination $Paths.MmtDir -Recurse -Force
            Write-Ok "MultiMonitorTool installé : $exe"
        }
    }
    Write-MultiMonitorToolIni -Dir $Paths.MmtDir -Values $Config.multiMonitorTool.ini
    return $exe
}

function Copy-MonoEcranScript {
    # Copie scripts\remote\*.ps1 dans <tools>\remote (si différents) + settings.json résolu, lu par les scripts.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Paths)
    New-DirectorySafe -Path $Paths.ScriptsDir | Out-Null
    foreach ($f in $script:MonoScripts) {
        $src = Join-Path $Paths.SourceDir $f
        $dst = Join-Path $Paths.ScriptsDir $f
        if (-not (Test-Path -LiteralPath $src)) { throw "Script source manquant : $src" }
        if ((Test-Path -LiteralPath $dst) -and ((Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash)) { continue }
        if ($script:DryRun) { Write-Dry "copie $f -> $($Paths.ScriptsDir)"; continue }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Unblock-File -LiteralPath $dst -ErrorAction SilentlyContinue
        Write-Ok "Script : $dst"
    }
    $settings = [ordered]@{
        mmtPath     = $Paths.MmtExe
        keepMonitor = [string]$Config.keepMonitor
        taskOn      = [string]$Config.tasks.on
        taskOff     = [string]$Config.tasks.off
        taskRescue  = [string]$Config.tasks.rescue
        settleMs    = [int]$Config.monoEcran.settleMs
        timeoutSec  = [int]$Config.monoEcran.timeoutSec
    }
    $json = $settings | ConvertTo-Json
    $file = Join-Path $Paths.ScriptsDir 'settings.json'
    $cur = ''
    if (Test-Path -LiteralPath $file) { $cur = [string](Get-Content -LiteralPath $file -Raw -Encoding UTF8) }
    if ($cur.Trim() -eq $json.Trim()) { Write-Ok "settings.json à jour (keepMonitor = $($settings.keepMonitor))"; return }
    if ($script:DryRun) { Write-Dry "settings.json -> $file (keepMonitor = $($settings.keepMonitor))"; return }
    [IO.File]::WriteAllText($file, $json, (New-Object Text.UTF8Encoding $false))
    Write-Ok "settings.json écrit (keepMonitor = $($settings.keepMonitor))"
}

function Protect-MonoEcranDir {
    # Les scripts peuvent être lancés par Sunshine en SYSTEM (avant relais) : sous C:\ ils hériteraient
    # d'une écriture « Utilisateurs authentifiés ». On réserve l'écriture aux admins et à SYSTEM.
    param([Parameter(Mandatory)][string]$Path)
    if ($script:DryRun) { Write-Dry "ACL $Path : Administrateurs/SYSTEM contrôle total, Utilisateurs lecture/exécution"; return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $ErrorActionPreference = 'Continue'
    $out = (& icacls $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1) | Out-String
    if ($LASTEXITCODE -eq 0) { Write-Ok "ACL verrouillées : $Path (écriture réservée aux admins)" }
    else { Write-Warn "icacls a échoué (code $LASTEXITCODE) : $($out.Trim())" }
}

function Register-RemoteTask {
    # Tâches SANS déclencheur (à la demande), contexte utilisateur, non élevées :
    #   - secours « réactiver tous les écrans » (Parsec, tailscale ssh : schtasks /run /tn ...) ;
    #   - relais on/off utilisés par les scripts quand Sunshine les lance en session 0 / SYSTEM.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Paths)
    $ps = Get-WindowsPowerShellPath
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $defs = @(
        @{ Name = [string]$Config.tasks.rescue; Script = 'reactiver-ecrans.ps1'; Desc = "Reset Pack : réactive TOUS les écrans puis recharge l'agencement (secours, à la demande)." }
        @{ Name = [string]$Config.tasks.on; Script = 'mono-ecran-on.ps1'; Desc = 'Reset Pack : mono-écran Sunshine (relais hors session utilisateur).' }
        @{ Name = [string]$Config.tasks.off; Script = 'mono-ecran-off.ps1'; Desc = 'Reset Pack : fin du mono-écran Sunshine (relais hors session utilisateur).' }
    )
    foreach ($d in $defs) {
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NoRelay' -f (Join-Path $Paths.ScriptsDir $d.Script)
        $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
        Register-ScheduledTaskSafe -Params @{ TaskName = $d.Name; Action = $action; Principal = $principal; Settings = $settings; Description = $d.Desc }
        if (-not $script:DryRun) { Write-Ok "Tâche $($d.Name) (à la demande, contexte utilisateur)" }
    }
}

# ============================================================================
# Sunshine : sunshine.conf (format « clé = valeur », valeur JSON pour global_prep_cmd)
# ============================================================================
function Find-SunshineInstall {
    param([Parameter(Mandatory)]$Config)
    foreach ($d in @($Config.sunshine.installDirs)) {
        $dir = Resolve-RemoteToken ([string]$d) ''
        $exe = Join-Path $dir ([string]$Config.sunshine.exe)
        if (Test-Path -LiteralPath $exe) {
            return [pscustomobject]@{ Dir = $dir; Exe = $exe; Conf = (Join-Path $dir ([string]$Config.sunshine.conf)) }
        }
    }
    return $null
}

function Get-SunshineBracketDepth {
    param([AllowEmptyString()][string]$Text)
    return ([regex]::Matches($Text, '\[').Count - [regex]::Matches($Text, '\]').Count)
}

function Find-SunshineConfEntry {
    # Occurrences d'une clé, comme le parseur de Sunshine : '#' ouvre un commentaire jusqu'à la fin de ligne,
    # une valeur qui commence par '[' peut courir sur plusieurs lignes jusqu'au crochet fermant.
    param([AllowNull()][AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][string]$Key)
    $found = New-Object System.Collections.Generic.List[object]
    if (-not $Lines) { return $found.ToArray() }
    $i = 0
    while ($i -lt $Lines.Count) {
        $text = ([string]$Lines[$i] -replace '#.*$', '')
        if ($text -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$' -and $Matches[1] -eq $Key) {
            $start = $i
            $value = $Matches[2]
            if ($value.StartsWith('[')) {
                while ((Get-SunshineBracketDepth $value) -gt 0 -and ($i + 1) -lt $Lines.Count) {
                    $i++
                    $value += "`n" + ([string]$Lines[$i] -replace '#.*$', '').Trim()
                }
            }
            $found.Add([pscustomobject]@{ Start = $start; End = $i; Value = $value })
        }
        $i++
    }
    return $found.ToArray()
}

function Get-SunshineConfValue {
    # Valeur effective d'une clé (Sunshine garde la PREMIÈRE occurrence), $null si absente.
    param([AllowNull()][AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][string]$Key)
    $e = @(Find-SunshineConfEntry -Lines $Lines -Key $Key)
    if ($e.Count -eq 0) { return $null }
    return $e[0].Value
}

function Edit-SunshineConfLine {
    # Renvoie les lignes avec « Key = Value » à la place de la 1re occurrence (doublons retirés), ou ajouté à la fin.
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $newLine = "$Key = $Value"
    $out = New-Object System.Collections.Generic.List[string]
    $entries = @(Find-SunshineConfEntry -Lines $Lines -Key $Key)
    if ($Lines) {
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $inEntry = $false
            foreach ($e in $entries) { if ($i -ge $e.Start -and $i -le $e.End) { $inEntry = $true; break } }
            if ($inEntry) {
                if ($i -eq $entries[0].Start) { $out.Add($newLine) }
                continue
            }
            $out.Add([string]$Lines[$i])
        }
    }
    if ($entries.Count -eq 0) { $out.Add($newLine) }
    return , $out.ToArray()
}

function ConvertTo-SunshineJsonString {
    # Chaîne JSON minimale (\ et " échappés) : lisible, sans les \u0027 de ConvertTo-Json en PS 5.1.
    param([AllowEmptyString()][string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq [char]'"') { [void]$sb.Append('\"') }
        elseif ($ch -eq [char]'\') { [void]$sb.Append('\\') }
        elseif ($code -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-SunshinePrepJson {
    param([object[]]$Items)
    $parts = foreach ($it in $Items) {
        $elev = 'false'
        if ($it.elevated) { $elev = 'true' }
        '{{"do":{0},"undo":{1},"elevated":{2}}}' -f (ConvertTo-SunshineJsonString ([string]$it.'do')), (ConvertTo-SunshineJsonString ([string]$it.'undo')), $elev
    }
    return ('[' + (@($parts) -join ',') + ']')
}

function Get-MonoEcranPrepCmd {
    # Entrée global_prep_cmd du mode mono-écran. elevated=false : MultiMonitorTool tourne en contexte utilisateur.
    param([Parameter(Mandatory)][string]$ScriptsDir, [string]$PowerShellExe)
    if (-not $PowerShellExe) { $PowerShellExe = Get-WindowsPowerShellPath }
    $fmt = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"'
    return [pscustomobject]@{
        'do'     = $fmt -f $PowerShellExe, (Join-Path $ScriptsDir 'mono-ecran-on.ps1')
        'undo'   = $fmt -f $PowerShellExe, (Join-Path $ScriptsDir 'mono-ecran-off.ps1')
        elevated = $false
    }
}

function Merge-SunshinePrepCmd {
    # Garde les commandes existantes de l'utilisateur, remplace notre ancienne entrée, renvoie le JSON (1 ligne).
    param([AllowNull()][AllowEmptyString()][string]$Existing, [Parameter(Mandatory)]$Entry)
    $items = New-Object System.Collections.Generic.List[object]
    if ($Existing -and $Existing.Trim()) {
        $parsed = $null
        try { $parsed = ConvertFrom-Json -InputObject $Existing -ErrorAction Stop }
        catch { Write-Warn "global_prep_cmd actuel illisible : remplacé (l'ancien reste dans le backup)" }
        foreach ($p in @($parsed)) {
            if ($null -eq $p) { continue }
            $do = [string]$p.'do'
            $undo = [string]$p.'undo'
            if (($do + ' ' + $undo) -match 'mono-ecran-(on|off)\.ps1') { continue }
            $elev = ($p.elevated -eq $true) -or ("$($p.elevated)" -ieq 'true')
            $items.Add([pscustomobject]@{ 'do' = $do; 'undo' = $undo; elevated = $elev })
        }
    }
    $items.Add($Entry)
    return (ConvertTo-SunshinePrepJson -Items $items.ToArray())
}

function Install-SunshinePrepCmd {
    # Écrit global_prep_cmd (+ valeurs imposées) dans sunshine.conf : idempotent, backup horodaté, UTF-8 sans BOM
    # (un BOM rendrait la 1re clé illisible pour Sunshine). Renvoie $true si le fichier change (ou changerait).
    param(
        [Parameter(Mandatory)][string]$ConfPath,
        [Parameter(Mandatory)][string]$ScriptsDir,
        $Enforce,
        [string]$PowerShellExe
    )
    $lines = @()
    if (Test-Path -LiteralPath $ConfPath) { $lines = @([IO.File]::ReadAllLines($ConfPath)) }
    $entry = Get-MonoEcranPrepCmd -ScriptsDir $ScriptsDir -PowerShellExe $PowerShellExe
    foreach ($c in @($entry.'do', $entry.'undo')) {
        if ($c.Contains('#')) { throw "Chemin contenant '#' : Sunshine le lirait comme un commentaire ($c)" }
    }
    $json = Merge-SunshinePrepCmd -Existing (Get-SunshineConfValue -Lines $lines -Key 'global_prep_cmd') -Entry $entry
    $new = Edit-SunshineConfLine -Lines $lines -Key 'global_prep_cmd' -Value $json
    if ($Enforce) {
        foreach ($p in $Enforce.PSObject.Properties) { $new = Edit-SunshineConfLine -Lines $new -Key $p.Name -Value ([string]$p.Value) }
    }
    if ("$(Get-SunshineConfValue -Lines $new -Key 'origin_web_ui_allowed')" -ieq 'wan') {
        Write-Warn "origin_web_ui_allowed = wan (WebUI ouverte à Internet) -> ramené à lan"
        $new = Edit-SunshineConfLine -Lines $new -Key 'origin_web_ui_allowed' -Value 'lan'
    }
    if ((@($new) -join "`n") -ceq (@($lines) -join "`n")) { Write-Ok 'sunshine.conf déjà à jour'; return $false }
    if ($script:DryRun) { Write-Dry "sunshine.conf <- global_prep_cmd = $json"; return $true }
    if (Test-Path -LiteralPath $ConfPath) {
        $bak = "$ConfPath.before-resetpack-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item -LiteralPath $ConfPath -Destination $bak -Force
        Write-Ok "Backup : $bak"
    } else {
        New-DirectorySafe -Path (Split-Path $ConfPath -Parent) | Out-Null
    }
    [IO.File]::WriteAllLines($ConfPath, [string[]]$new, (New-Object Text.UTF8Encoding $false))
    Write-Ok "sunshine.conf : global_prep_cmd -> mono-écran ($ConfPath)"
    return $true
}

function Invoke-SunshineRestart {
    # Sunshine ne relit sa config qu'au démarrage.
    param([Parameter(Mandatory)][string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Warn "Service $ServiceName introuvable : redémarre Sunshine à la main pour appliquer sunshine.conf"; return }
    if ("$($svc.Status)" -ne 'Running') { return }
    if ($script:DryRun) { Write-Dry "Restart-Service $ServiceName"; return }
    Restart-Service -Name $ServiceName -Force
    Write-Ok "Service $ServiceName redémarré (config relue)"
}

# ============================================================================
# Pare-feu, alimentation, ouverture de session
# ============================================================================
function Get-SunshinePort {
    param([Parameter(Mandatory)]$Config, [int]$BasePort)
    if (-not $BasePort) { $BasePort = [int]$Config.sunshine.basePort }
    return [pscustomobject]@{
        Tcp = @($Config.sunshine.tcpOffsets | ForEach-Object { [string]($BasePort + [int]$_) })
        Udp = @($Config.sunshine.udpOffsets | ForEach-Object { [string]($BasePort + [int]$_) })
    }
}

function Invoke-RemoteFirewall {
    # Pare-feu ON ; règles larges de l'installeur Sunshine désactivées ; règles ResetPack-Sunshine-TCP/UDP
    # limitées aux plages Tailscale (créées ou remises en conformité). Renvoie les règles voulues.
    param([Parameter(Mandatory)]$Config, [string]$SunshineExe, [int]$BasePort)
    $prefix = [string]$Config.firewall.rulePrefix
    $remote = @(@([string]$Config.tailscale.ipv4, [string]$Config.tailscale.ipv6) | Where-Object { $_ })

    try {
        $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { "$($_.Enabled)" -ne 'True' })
        foreach ($p in $off) {
            if ($script:DryRun) { Write-Dry "pare-feu : réactiver le profil $($p.Name)" }
            else { Set-NetFirewallProfile -Name $p.Name -Enabled True; Write-Warn "Pare-feu du profil $($p.Name) était COUPÉ -> réactivé" }
        }
        if ($off.Count -eq 0) { Write-Ok 'Pare-feu actif sur tous les profils' }
    } catch {
        Write-Warn "État du pare-feu illisible : $($_.Exception.Message)"
    }

    $wide = @(Get-NetFirewallRule -DisplayName @($Config.firewall.installerRuleDisplayNames) -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name -notlike "$prefix*") -and ("$($_.Direction)" -eq 'Inbound') -and ("$($_.Enabled)" -eq 'True') })
    foreach ($r in $wide) {
        if ($script:DryRun) { Write-Dry "désactiver la règle large '$($r.DisplayName)' ($($r.Name))"; continue }
        Set-NetFirewallRule -Name $r.Name -Enabled False
        Write-Ok "Règle large de l'installeur désactivée : $($r.DisplayName)"
    }

    $ports = Get-SunshinePort -Config $Config -BasePort $BasePort
    $wanted = New-Object System.Collections.Generic.List[object]
    foreach ($proto in @('TCP', 'UDP')) {
        $name = "${prefix}Sunshine-$proto"
        $lp = $ports.Udp
        if ($proto -eq 'TCP') { $lp = $ports.Tcp }
        $common = @{
            Direction     = 'Inbound'
            Action        = 'Allow'
            Protocol      = $proto
            LocalPort     = $lp
            RemoteAddress = $remote
            Profile       = 'Any'
            Enabled       = 'True'
            Description   = "Reset Pack : Sunshine via Tailscale uniquement ($($remote -join ', '))"
        }
        if ($SunshineExe) { $common.Program = $SunshineExe }
        $exists = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
        if ($script:DryRun) {
            Write-Dry "règle $name : $proto $($lp -join ',') depuis $($remote -join ', ')"
        } elseif ($exists) {
            Set-NetFirewallRule -Name $name @common
            Write-Ok "Règle $name remise en conformité ($proto $($lp -join ','))"
        } else {
            New-NetFirewallRule -Name $name -DisplayName $name @common | Out-Null
            Write-Ok "Règle $name créée ($proto $($lp -join ','), Tailscale uniquement)"
        }
        $wanted.Add([pscustomobject]@{ Name = $name; Protocol = $proto; LocalPort = $lp; RemoteAddress = $remote })
    }
    return $wanted.ToArray()
}

function Invoke-RemotePower {
    # Jamais de veille ni d'hibernation sur secteur (l'écran, lui, peut s'éteindre).
    param([Parameter(Mandatory)]$Config)
    foreach ($p in $Config.power.PSObject.Properties) {
        $v = [int]$p.Value
        if ($script:DryRun) { Write-Dry "powercfg /change $($p.Name) $v"; continue }
        & powercfg /change $p.Name $v
        if ($LASTEXITCODE -eq 0) { Write-Ok "powercfg $($p.Name) = $v (jamais)" }
        else { Write-Warn "powercfg /change $($p.Name) a échoué (code $LASTEXITCODE)" }
    }
}

function Test-AutoLogon {
    # Alerte seulement (ne modifie rien) : l'auto-login offrirait la session à quiconque allume la machine.
    param([string]$Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon')
    $wl = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($wl -and ("$($wl.AutoAdminLogon)" -eq '1')) {
        Write-Warn "AUTO-LOGIN ACTIF (AutoAdminLogon=1) : quiconque allume l'OMEN arrive dans ta session."
        Write-Warn "  -> à couper : netplwiz (coche « Les utilisateurs doivent entrer un nom... ») ou Autologon (Sysinternals) > Disable."
        if ($wl.PSObject.Properties['DefaultPassword']) { Write-Warn '  -> DefaultPassword existe dans Winlogon (mot de passe EN CLAIR) : supprime cette valeur.' }
        return $false
    }
    Write-Ok "Pas d'auto-login"
    return $true
}

# ============================================================================
# Tailscale
# ============================================================================
function Resolve-TailscaleCli {
    # $true si 'tailscale' est appelable (ajoute le dossier d'install au PATH du process si besoin).
    param([string]$Fallback)
    if (Test-CommandExists 'tailscale') { return $true }
    if ($Fallback -and (Test-Path -LiteralPath $Fallback)) {
        $env:Path = "$env:Path;$(Split-Path $Fallback -Parent)"
        return $true
    }
    return $false
}

function Get-TailscaleState {
    $ErrorActionPreference = 'Continue'
    try {
        $raw = (& tailscale status --json 2>$null) | Out-String
        if (-not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Verbose "tailscale status illisible : $($_.Exception.Message)"
        return $null
    }
}

function Invoke-TailscaleUnattended {
    # Connecté : unattended via « tailscale set » (ne touche pas aux autres réglages) si la CLI le connaît,
    # sinon « tailscale up --unattended ». Pas connecté : connexion interactive proposée, jamais en Auto.
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Continue'
    $fallback = Resolve-RemoteToken ([string]$Config.tailscale.cli) ''
    if (-not (Resolve-TailscaleCli -Fallback $fallback)) {
        Write-Warn "Tailscale absent : winget install --id $($Config.client.tailscaleWingetId) -e, puis .\reset.ps1 -Only remote"
        return 'absent'
    }
    $st = Get-TailscaleState
    $state = ''
    if ($st) { $state = [string]$st.BackendState }
    $loggedIn = @('Running', 'Starting', 'Stopped', 'NeedsMachineAuth') -contains $state

    if (-not $loggedIn) {
        Write-Warn "Tailscale n'est pas connecté (état : '$state')."
        if ($script:DryRun) { Write-Dry 'tailscale up --unattended (connexion interactive dans le navigateur)'; return 'dry-login' }
        if (-not $script:Auto) {
            $r = Read-Host "Connecter Tailscale maintenant (le navigateur s'ouvre) ? [O/n]"
            if ($r -ne 'n') {
                & tailscale up --unattended
                if ($LASTEXITCODE -eq 0) { Write-Ok 'Tailscale connecté en mode unattended'; return 'up' }
                Write-Warn "tailscale up --unattended a échoué (code $LASTEXITCODE)"
            }
        }
        Write-Warn "  -> à faire : tailscale up --unattended (session admin), connexion dans le navigateur, puis .\reset.ps1 -Only remote"
        return 'needs-login'
    }

    $help = (& tailscale set --help 2>&1) | Out-String
    $tsArgs = @('up', '--unattended')
    if ($help -match '--unattended') { $tsArgs = @('set', '--unattended=true') }
    if ($script:DryRun) {
        Write-Dry "tailscale $($tsArgs -join ' ')"
    } else {
        & tailscale @tsArgs
        if ($LASTEXITCODE -eq 0) { Write-Ok "Tailscale : mode unattended (tailscale $($tsArgs -join ' '))" }
        else { Write-Warn "tailscale $($tsArgs -join ' ') a échoué (code $LASTEXITCODE) : relance-le à la main" }
    }
    if ($state -eq 'Stopped') {
        if ($script:DryRun) { Write-Dry 'tailscale up (nœud arrêté)' }
        else { & tailscale up; if ($LASTEXITCODE -eq 0) { Write-Ok 'Tailscale relancé' } else { Write-Warn 'tailscale up a échoué' } }
    }
    if ($st.Self -and $st.Self.KeyExpiry) {
        Write-Warn "La clé de ce nœud expire le $($st.Self.KeyExpiry) : désactive l'expiration (console admin > Machines > ... > Disable key expiry)."
    }
    if ($st.CurrentTailnet -and $st.CurrentTailnet.PSObject.Properties['MagicDNSEnabled'] -and (-not $st.CurrentTailnet.MagicDNSEnabled)) {
        Write-Warn 'MagicDNS désactivé : console admin > DNS > Enable MagicDNS.'
    }
    if ($st.Self) { Write-Ok "Nœud Tailscale : $($st.Self.DNSName) $(@($st.Self.TailscaleIPs) -join ' ')" }
    return 'ok'
}

# ============================================================================
# Affichage : checklist manuelle (hôte) et étapes client
# ============================================================================
function Show-RemoteChecklist {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Paths, [int]$BasePort)
    if (-not $BasePort) { $BasePort = [int]$Config.sunshine.basePort }
    $web = $BasePort + 1
    Write-Banner 'ACCÈS DISTANT — à finir à la main (SYSTEME-OMEN-35L.md §10, étape 17)'
    Write-Host @"
  SUNSHINE (cet OMEN)
   1. WebUI https://localhost:$web : crée l'identifiant + un mot de passe FORT, rangé dans ton gestionnaire
      (jamais dans un fichier ni dans ce dépôt).
   2. Écran capté : laisse 'output_name' vide (= écran principal) ou règle keepMonitor dans config\remote.json
      sur le n° de série / Monitor ID de l'écran capté, puis .\reset.ps1 -Only remote.
      Pour lister les écrans :  & "$($Paths.MmtExe)" /scomma "`$env:TEMP\ecrans.csv"
   3. Configuration > General > Command Preparations : mono-ecran-on / mono-ecran-off doivent y figurer.
   4. Teste le mono-écran EN LOCAL avant tout : lance puis quitte un stream ; journal :
      $env:LOCALAPPDATA\ResetPack\remote.log

  MOONLIGHT (EXODIUS)
   5. Moonlight installé (winget install --id $($Config.client.moonlightWingetId) -e), Tailscale connecté.
   6. Ajoute l'hôte par son nom MagicDNS (ou son IP 100.x), puis saisis le PIN dans la WebUI > PIN.
   7. Toujours « Quitter » l'app en fin de session : l'undo (écrans restaurés) ne joue qu'à la fermeture.

  TAILSCALE (console admin : https://login.tailscale.com/admin)
   8. Machines > OMEN > ... > Disable key expiry.
   9. DNS > MagicDNS activé.

  PARSEC (secours : il ne touche pas aux écrans)
  10. Compte Parsec avec 2FA OBLIGATOIRE, hébergement activé sur l'OMEN.
  11. Écrans perdus ?  schtasks /run /tn $($Config.tasks.rescue)   (depuis Parsec ou tailscale ssh)

  RÉSEAU
  12. Livebox : AUCUNE redirection de port, UPnP coupé (Sunshine : upnp = disabled, posé ici).

  TEST RÉEL (obligatoire)
  13. Depuis EXODIUS en partage de connexion 4G/5G (Wi-Fi maison coupé) : tailscale ping de l'OMEN,
      Moonlight -> bureau, les 2 autres écrans s'éteignent ; « Quitter » -> les 3 reviennent à l'identique.
  14. Redémarre l'OMEN SANS ouvrir de session : tailscale ping répond (unattended), Moonlight montre
      l'écran de connexion Windows. Vérifie aussi la tâche de secours (point 11).
"@ -ForegroundColor Gray
}

function Show-ClientStep {
    param([Parameter(Mandatory)]$Config, [string]$ProfileName)
    $label = $ProfileName
    if (-not $label) { $label = 'inconnu' }
    $fallback = Resolve-RemoteToken ([string]$Config.tailscale.cli) ''
    $hasTs = (Test-CommandExists 'tailscale') -or ($fallback -and (Test-Path -LiteralPath $fallback))
    $tsLine = 'à installer : winget install --id ' + $Config.client.tailscaleWingetId + ' -e'
    if ($hasTs) { $tsLine = 'installé : connecte-le au MÊME tailnet que l''OMEN (tailscale up)' }
    $hasMl = Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe')
    $mlLine = 'à installer : winget install --id ' + $Config.client.moonlightWingetId + ' -e'
    if ($hasMl) { $mlLine = 'installé' }
    Write-Banner "ACCÈS DISTANT — poste CLIENT ($label) : rien n'est configuré côté hôte ici"
    Write-Host @"
   1. Tailscale : $tsLine
   2. Moonlight : $mlLine
   3. Moonlight > Ajouter un PC : nom MagicDNS de l'OMEN (ou son IP 100.x), jamais l'IP publique.
   4. Pairing : Moonlight affiche un PIN -> saisis-le dans la WebUI Sunshine de l'OMEN (onglet PIN).
   5. Parsec en secours (winget install --id $($Config.client.parsecWingetId) -e), compte avec 2FA.
   6. Test réel en 4G/5G (partage de connexion, Wi-Fi maison coupé) : connexion, mono-écran, « Quitter ».
"@ -ForegroundColor Gray
}

# ============================================================================
# Point d'entrée
# ============================================================================
function Invoke-RemoteModule {
    param([string]$ProfileName, [string]$ToolsDir, [string]$ConfigPath)
    if (-not $ProfileName) { $ProfileName = Get-ResetProfile }
    $cfg = Get-RemoteConfig -Path $ConfigPath
    if ($ProfileName -ne [string]$cfg.hostProfile) {
        Show-ClientStep -Config $cfg -ProfileName $ProfileName
        Write-Ok "Remote : profil '$ProfileName' = poste client, hôte non configuré"
        return 'client'
    }
    if ((-not $script:DryRun) -and (-not (Test-Admin))) {
        throw 'Module remote : droits administrateur requis (pare-feu, Program Files, powercfg).'
    }
    if (-not $ToolsDir) {
        $ToolsDir = [string](Get-StorageLayout -Name $ProfileName).tools
        if (-not $ToolsDir) { $ToolsDir = 'C:\Tools'; Write-Warn "layout.tools absent : $ToolsDir par défaut" }
    }
    $paths = Get-RemotePath -Config $cfg -ToolsDir $ToolsDir

    Write-Step '[1/7] MultiMonitorTool (NirSoft, zip x64 officiel)'
    $null = Install-MultiMonitorTool -Config $cfg -Paths $paths

    Write-Step "[2/7] Scripts mono-écran -> $($paths.ScriptsDir)"
    Copy-MonoEcranScript -Config $cfg -Paths $paths
    Protect-MonoEcranDir -Path $paths.ScriptsDir

    Write-Step '[3/7] Tâches planifiées (à la demande, contexte utilisateur)'
    Register-RemoteTask -Config $cfg -Paths $paths

    Write-Step '[4/7] Sunshine : global_prep_cmd (mono-écran) + UPnP coupé'
    $basePort = [int]$cfg.sunshine.basePort
    $sun = Find-SunshineInstall -Config $cfg
    if ($sun) {
        $lines = @()
        if (Test-Path -LiteralPath $sun.Conf) { $lines = @([IO.File]::ReadAllLines($sun.Conf)) }
        $p = [string](Get-SunshineConfValue -Lines $lines -Key 'port')
        if ($p -match '^\d+$') { $basePort = [int]$p }
        $out = [string](Get-SunshineConfValue -Lines $lines -Key 'output_name')
        if ($out -and ([string]$cfg.keepMonitor -ieq 'primary')) {
            Write-Warn "sunshine.conf capte l'écran '$out' mais keepMonitor = primary : vérifie que c'est le même écran."
        }
        $changed = Install-SunshinePrepCmd -ConfPath $sun.Conf -ScriptsDir $paths.ScriptsDir -Enforce $cfg.sunshine.enforce
        if ($changed -and $cfg.sunshine.restartAfterChange) { Invoke-SunshineRestart -ServiceName ([string]$cfg.sunshine.service) }
    } else {
        Write-Warn 'Sunshine non installé (LizardByte.Sunshine) : relance .\reset.ps1 -Only remote après son installation.'
    }

    Write-Step '[5/7] Pare-feu : Sunshine joignable par Tailscale uniquement'
    $exe = $null
    if ($sun) { $exe = $sun.Exe }
    $null = Invoke-RemoteFirewall -Config $cfg -SunshineExe $exe -BasePort $basePort

    Write-Step '[6/7] Alimentation (jamais de veille sur secteur) + auto-login'
    Invoke-RemotePower -Config $cfg
    $null = Test-AutoLogon

    Write-Step '[7/7] Tailscale (unattended)'
    $null = Invoke-TailscaleUnattended -Config $cfg

    Show-RemoteChecklist -Config $cfg -Paths $paths -BasePort $basePort
    Write-Ok 'Remote OK (finis la checklist ci-dessus)'
    return 'host'
}

if (-not $NoRun) { $null = Invoke-RemoteModule }
