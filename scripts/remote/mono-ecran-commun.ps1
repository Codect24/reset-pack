# mono-ecran-commun.ps1 : fonctions partagées des scripts mono-écran (Sunshine global_prep_cmd).
# Chargé (dot-source) par mono-ecran-on.ps1, mono-ecran-off.ps1 et reactiver-ecrans.ps1.
# Compatible Windows PowerShell 5.1. Outil : NirSoft MultiMonitorTool (doc : nirsoft.net/utils/multi_monitor_tool.html).
#
# Règles d'or :
#   1. ne JAMAIS désactiver l'écran capté (keepMonitor) ; dans le doute, ne rien désactiver ;
#   2. cibler les écrans par numéro de série / Monitor ID, jamais par un \\.\DISPLAYn fixé à l'avance ;
#   3. ne jamais lever d'exception vers Sunshine (les scripts sortent toujours en 0).
#
# Données : %LOCALAPPDATA%\ResetPack\ (remote.log + mono-ecran\agencement.cfg + mono-ecran\etat.json).
# $env:RESETPACK_REMOTE_DIR remplace ce dossier (tests).

if (-not $script:MonoCaller) { $script:MonoCaller = 'mono-ecran' }

function Get-MonoDataDir {
    if ($env:RESETPACK_REMOTE_DIR) { return $env:RESETPACK_REMOTE_DIR }
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $base 'ResetPack')
}

function Get-MonoStateDir {
    $dir = Join-Path (Get-MonoDataDir) 'mono-ecran'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Write-MonoLog {
    # Journal append-only, rotation à 1 Mo. Ne lève jamais d'exception.
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    try {
        $dir = Get-MonoDataDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $log = Join-Path $dir 'remote.log'
        if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt 1MB)) {
            Move-Item -LiteralPath $log -Destination "$log.old" -Force
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] [{2}] {3}' -f (Get-Date), $Level, $script:MonoCaller, $Message
        [IO.File]::AppendAllText($log, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding $false))
    } catch {
        Write-Verbose "journal indisponible : $($_.Exception.Message)"
    }
}

function Get-MonoSetting {
    # Réglages lus dans <dossier des scripts>\settings.json (écrit par modules\17-remote.ps1), avec valeurs par défaut.
    param([Parameter(Mandatory)][string]$Dir)
    $s = [ordered]@{
        mmtPath     = [IO.Path]::GetFullPath((Join-Path $Dir '..\MultiMonitorTool\MultiMonitorTool.exe'))
        keepMonitor = 'primary'
        taskOn      = 'ResetPack-MonoEcranOn'
        taskOff     = 'ResetPack-MonoEcranOff'
        taskRescue  = 'ResetPack-ReactiverEcrans'
        settleMs    = 1500
        timeoutSec  = 20
    }
    $file = Join-Path $Dir 'settings.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if ($null -ne $p.Value -and "$($p.Value)" -ne '') { $s[$p.Name] = $p.Value }
            }
        } catch {
            Write-MonoLog "settings.json illisible ($($_.Exception.Message)) : valeurs par défaut" 'WARN'
        }
    }
    return [pscustomobject]$s
}

function Test-NeedsRelay {
    # $true si on tourne en session 0 ou en SYSTEM (service Sunshine) : MultiMonitorTool doit alors
    # s'exécuter dans la session de l'utilisateur, via une tâche planifiée.
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        return (($session -eq 0) -or ($sid -eq 'S-1-5-18'))
    } catch {
        return $false
    }
}

function Invoke-MonoRelay {
    # Lance la tâche planifiée (contexte utilisateur) qui fera le travail à notre place. Asynchrone.
    param([Parameter(Mandatory)][string]$TaskName)
    $ErrorActionPreference = 'Continue'
    Write-MonoLog "session 0 / SYSTEM : relais vers la tâche planifiée '$TaskName'"
    try {
        $out = (& schtasks.exe /run /tn $TaskName 2>&1) | Out-String
        if ($LASTEXITCODE -ne 0) { Write-MonoLog "schtasks /run '$TaskName' a échoué (code $LASTEXITCODE) : $($out.Trim())" 'ERREUR' }
    } catch {
        Write-MonoLog "relais impossible : $($_.Exception.Message)" 'ERREUR'
    }
}

function ConvertTo-MmtArgumentString {
    # Start-Process (PS 5.1) concatène les arguments sans les citer : on cite ceux qui contiennent des espaces.
    param([string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    return (@($parts) -join ' ')
}

function Invoke-Mmt {
    # Lance MultiMonitorTool et ATTEND sa fin (c'est une appli GUI : '&' n'attendrait pas), avec délai max.
    # Renvoie $true si l'outil s'est terminé, $false sinon. Ne lève jamais d'exception.
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSec = 20
    )
    $line = ConvertTo-MmtArgumentString -Arguments $Arguments
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $line -PassThru -WindowStyle Hidden
        $null = $p.Handle   # garde le handle : sinon ExitCode reste vide
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { Write-Verbose 'kill impossible' }
            Write-MonoLog "MultiMonitorTool $line : délai dépassé (${TimeoutSec}s), processus arrêté" 'ERREUR'
            return $false
        }
        Write-MonoLog "MultiMonitorTool $line -> code $($p.ExitCode)"
        return $true
    } catch {
        Write-MonoLog "MultiMonitorTool $line impossible : $($_.Exception.Message)" 'ERREUR'
        return $false
    }
}

function Get-MonoField {
    # Première colonne présente parmi $Names (CSV : 'Monitor ID' ; XML : 'monitor_id'). Insensible à la casse.
    param($Row, [string[]]$Names)
    foreach ($n in $Names) {
        $p = $Row.PSObject.Properties[$n]
        if ($p) { return ("$($p.Value)").Trim() }
    }
    return ''
}

function ConvertTo-MonoBool {
    param($Value)
    return ("$Value".Trim() -match '^(yes|oui|true|1)$')
}

function ConvertTo-MonitorList {
    # Lignes brutes MultiMonitorTool (/scomma ou /sxml) -> objets normalisés.
    param([object[]]$Rows)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        if ($null -eq $r) { continue }
        $name = Get-MonoField $r @('Name', 'name')
        $mid = Get-MonoField $r @('Monitor ID', 'monitor_id')
        if (-not $name -and -not $mid) { continue }
        $list.Add([pscustomobject]@{
                Name         = $name
                Active       = ConvertTo-MonoBool (Get-MonoField $r @('Active', 'active'))
                Disconnected = ConvertTo-MonoBool (Get-MonoField $r @('Disconnected', 'disconnected'))
                Primary      = ConvertTo-MonoBool (Get-MonoField $r @('Primary', 'primary'))
                MonitorId    = $mid
                ShortId      = Get-MonoField $r @('Short Monitor ID', 'short_monitor_id')
                Serial       = Get-MonoField $r @('Monitor Serial Number', 'monitor_serial_number')
                MonitorName  = Get-MonoField $r @('Monitor Name', 'monitor_name')
            })
    }
    return $list.ToArray()
}

function Get-MonitorList {
    # Liste les écrans : /scomma (CSV avec en-tête) ; si l'en-tête manque, repli sur /sxml (auto-descriptif).
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$WorkDir,
        [int]$TimeoutSec = 20
    )
    $csv = Join-Path $WorkDir 'ecrans.csv'
    Remove-Item -LiteralPath $csv -Force -ErrorAction SilentlyContinue
    if ((Invoke-Mmt -Exe $Exe -Arguments @('/scomma', $csv) -TimeoutSec $TimeoutSec) -and (Test-Path -LiteralPath $csv)) {
        try {
            $rows = @(Import-Csv -LiteralPath $csv)
            if ($rows.Count -gt 0 -and $rows[0].PSObject.Properties['Name'] -and $rows[0].PSObject.Properties['Active']) {
                return (ConvertTo-MonitorList -Rows $rows)
            }
            Write-MonoLog '/scomma sans en-tête exploitable : repli sur /sxml' 'WARN'
        } catch {
            Write-MonoLog "CSV illisible : $($_.Exception.Message)" 'WARN'
        }
    }
    $xmlPath = Join-Path $WorkDir 'ecrans.xml'
    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    if ((Invoke-Mmt -Exe $Exe -Arguments @('/sxml', $xmlPath) -TimeoutSec $TimeoutSec) -and (Test-Path -LiteralPath $xmlPath)) {
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.Load($xmlPath)
            $rows = foreach ($item in $doc.SelectNodes('//item')) {
                $h = [ordered]@{}
                foreach ($c in $item.ChildNodes) { if ($c.NodeType -eq 'Element') { $h[$c.LocalName] = $c.InnerText } }
                [pscustomobject]$h
            }
            return (ConvertTo-MonitorList -Rows @($rows))
        } catch {
            Write-MonoLog "XML illisible : $($_.Exception.Message)" 'ERREUR'
        }
    }
    return @()
}

function Format-MonoMonitor {
    param($Monitor)
    $flags = @()
    if ($Monitor.Active) { $flags += 'actif' } else { $flags += 'inactif' }
    if ($Monitor.Primary) { $flags += 'principal' }
    if ($Monitor.Disconnected) { $flags += 'débranché' }
    return ('{0} [{1}] sn={2} id={3}' -f $Monitor.Name, ($flags -join ','), $Monitor.Serial, $Monitor.MonitorId)
}

function Test-SameMonitor {
    param($A, $B)
    if ($A.MonitorId -and $B.MonitorId) { return ($A.MonitorId -ieq $B.MonitorId) }
    return ($A.Name -and ($A.Name -ieq $B.Name))
}

function Find-KeptMonitor {
    # L'écran à garder : 'primary' (ou vide) = l'écran principal actif ; sinon correspondance EXACTE et UNIQUE
    # sur le numéro de série, le Monitor ID, le Short Monitor ID, le nom d'écran ou \\.\DISPLAYn. Ambigu -> $null.
    param([object[]]$Monitors, [string]$Keep)
    $connected = @($Monitors | Where-Object { -not $_.Disconnected })
    if ((-not $Keep) -or ($Keep -ieq 'primary')) {
        $p = @($connected | Where-Object { $_.Primary -and $_.Active })
        if ($p.Count -eq 1) { return $p[0] }
        return $null
    }
    $hits = @($connected | Where-Object {
            ($Keep -ieq $_.Serial) -or ($Keep -ieq $_.MonitorId) -or ($Keep -ieq $_.ShortId) -or
            ($Keep -ieq $_.Name) -or ($Keep -ieq $_.MonitorName)
        })
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -gt 1) { Write-MonoLog "keepMonitor '$Keep' désigne $($hits.Count) écrans (ambigu) : mets le Monitor ID complet" 'ERREUR' }
    return $null
}

function Get-MonitorTargetId {
    # Identifiant à passer à MultiMonitorTool : numéro de série s'il est UNIQUE, sinon Monitor ID, sinon nom
    # (\\.\DISPLAYn, résolu à l'instant : jamais stocké dans la config). $null si rien de fiable.
    param([Parameter(Mandatory)]$Monitor, [object[]]$Monitors)
    foreach ($field in @('Serial', 'MonitorId', 'Name')) {
        $v = "$($Monitor.$field)".Trim()
        if ((-not $v) -or ($v -match '^(0+|n/?a|-|none)$')) { continue }
        $same = @($Monitors | Where-Object { "$($_.$field)".Trim() -ieq $v })
        if ($same.Count -eq 1) { return $v }
    }
    return $null
}

function Get-MonitorToDisable {
    # Identifiants des écrans à désactiver : actifs, branchés, différents de l'écran gardé. L'identifiant choisi
    # ne doit désigner AUCUN attribut de l'écran gardé (sinon MultiMonitorTool pourrait l'éteindre aussi).
    param([object[]]$Monitors, [Parameter(Mandatory)]$Kept)
    $keptKeys = @(@($Kept.Serial, $Kept.MonitorId, $Kept.ShortId, $Kept.Name, $Kept.MonitorName) | Where-Object { $_ })
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($m in $Monitors) {
        if (Test-SameMonitor $m $Kept) { continue }
        if ((-not $m.Active) -or $m.Disconnected) { continue }
        $id = Get-MonitorTargetId -Monitor $m -Monitors $Monitors
        if (-not $id) { Write-MonoLog "écran $($m.Name) sans identifiant fiable : laissé actif" 'WARN'; continue }
        if ($keptKeys -contains $id) { Write-MonoLog "l'identifiant '$id' désigne aussi l'écran gardé : $($m.Name) laissé actif" 'WARN'; continue }
        $ids.Add($id)
    }
    return $ids.ToArray()
}

function Save-MonoState {
    param([Parameter(Mandatory)][string]$Path, [string]$Kept, [string[]]$Disabled)
    $state = [ordered]@{ date = (Get-Date).ToString('s'); kept = $Kept; disabled = @($Disabled) }
    [IO.File]::WriteAllText($Path, ($state | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}

function Read-MonoState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Invoke-MonoEcranOn {
    # « Do » : sauvegarde l'agencement, puis désactive tous les écrans sauf celui capté. Renvoie un statut.
    param([Parameter(Mandatory)]$Settings)
    $exe = [string]$Settings.mmtPath
    $timeout = [int]$Settings.timeoutSec
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-MonoLog "MultiMonitorTool introuvable ($exe) : aucun écran touché" 'ERREUR'
        return 'outil-absent'
    }
    $stateDir = Get-MonoStateDir
    $cfg = Join-Path $stateDir 'agencement.cfg'
    $stateFile = Join-Path $stateDir 'etat.json'

    $mons = @(Get-MonitorList -Exe $exe -WorkDir $stateDir -TimeoutSec $timeout)
    if ($mons.Count -eq 0) {
        Write-MonoLog 'liste des écrans vide ou illisible : aucun écran touché' 'ERREUR'
        return 'liste-vide'
    }
    Write-MonoLog ('écrans : ' + (($mons | ForEach-Object { Format-MonoMonitor $_ }) -join ' | '))

    $kept = Find-KeptMonitor -Monitors $mons -Keep ([string]$Settings.keepMonitor)
    if (-not $kept) {
        Write-MonoLog "écran à garder '$($Settings.keepMonitor)' introuvable, ambigu ou inactif : aucun écran touché" 'ERREUR'
        return 'ecran-garde-introuvable'
    }
    $targets = @(Get-MonitorToDisable -Monitors $mons -Kept $kept)
    if ($targets.Count -eq 0) {
        Write-MonoLog "déjà en mono-écran ($($kept.Name)) : rien à faire"
        return 'deja-mono'
    }

    # Sauvegarde de l'agencement COMPLET. Si un mono-écran est déjà engagé (undo jamais joué), on garde
    # la sauvegarde d'origine : en refaire une figerait l'agencement réduit.
    $inactive = @($mons | Where-Object { (-not $_.Active) -and (-not $_.Disconnected) })
    if ((Test-Path -LiteralPath $stateFile) -and (Test-Path -LiteralPath $cfg) -and ($inactive.Count -gt 0)) {
        Write-MonoLog "mono-écran déjà engagé : agencement d'origine conservé"
    } else {
        Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
        $null = Invoke-Mmt -Exe $exe -Arguments @('/SaveConfig', $cfg) -TimeoutSec $timeout
        if (-not (Test-Path -LiteralPath $cfg)) {
            Write-MonoLog "sauvegarde de l'agencement impossible : aucun écran touché" 'ERREUR'
            return 'sauvegarde-ko'
        }
    }

    $keptId = Get-MonitorTargetId -Monitor $kept -Monitors $mons
    if (-not $keptId) { $keptId = $kept.Name }
    if (-not $kept.Primary) {
        # Windows ne peut pas désactiver l'écran principal : l'écran gardé le devient d'abord.
        $null = Invoke-Mmt -Exe $exe -Arguments @('/SetPrimary', $keptId) -TimeoutSec $timeout
    }
    # L'état est écrit AVANT /disable : l'undo et le secours sauront quoi réactiver même si la suite plante.
    Save-MonoState -Path $stateFile -Kept $keptId -Disabled $targets
    $null = Invoke-Mmt -Exe $exe -Arguments (@('/disable') + $targets) -TimeoutSec $timeout
    Write-MonoLog "désactivés : $($targets -join ', ') ; gardé : $keptId"

    # Contrôle : l'écran gardé doit rester actif, sinon restauration immédiate (pas de bureau noir).
    Start-Sleep -Milliseconds ([int]$Settings.settleMs)
    $after = @(Get-MonitorList -Exe $exe -WorkDir $stateDir -TimeoutSec $timeout)
    if ($after.Count -eq 0) {
        Write-MonoLog 'contrôle après /disable impossible (liste vide)' 'WARN'
        return 'ok-non-verifie'
    }
    $k2 = @($after | Where-Object { Test-SameMonitor $_ $kept }) | Select-Object -First 1
    if ((-not $k2) -or (-not $k2.Active)) {
        Write-MonoLog "ALERTE : l'écran gardé n'est plus actif après /disable -> restauration complète" 'ERREUR'
        $null = Invoke-MonoEcranOff -Settings $Settings -Rescue
        return 'restaure'
    }
    return 'ok'
}

function Invoke-MonoEcranOff {
    # « Undo » : réactive les écrans puis recharge l'agencement exact.
    # -Rescue (reactiver-ecrans) : réactive TOUS les écrans, même sans état mémorisé, puis tente /LoadConfig.
    param([Parameter(Mandatory)]$Settings, [switch]$Rescue)
    $exe = [string]$Settings.mmtPath
    $timeout = [int]$Settings.timeoutSec
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-MonoLog "MultiMonitorTool introuvable ($exe) : rien restauré" 'ERREUR'
        return 'outil-absent'
    }
    $stateDir = Get-MonoStateDir
    $cfg = Join-Path $stateDir 'agencement.cfg'
    $stateFile = Join-Path $stateDir 'etat.json'
    $state = Read-MonoState -Path $stateFile
    if ((-not $Rescue) -and (-not $state)) {
        Write-MonoLog "aucun mono-écran engagé (pas d'état) : rien à restaurer"
        return 'rien'
    }

    $ids = New-Object System.Collections.Generic.List[string]
    if ($state) {
        foreach ($d in @($state.disabled)) { if ($d -and -not $ids.Contains([string]$d)) { $ids.Add([string]$d) } }
    }
    $mons = @(Get-MonitorList -Exe $exe -WorkDir $stateDir -TimeoutSec $timeout)
    foreach ($m in $mons) {
        if ($m.Disconnected) { continue }
        if ($m.Active -and -not $Rescue) { continue }
        $id = Get-MonitorTargetId -Monitor $m -Monitors $mons
        if ($id -and -not $ids.Contains($id)) { $ids.Add($id) }
    }
    if ($Rescue -and $mons.Count -eq 0 -and $ids.Count -eq 0) {
        Write-MonoLog 'liste illisible et aucun état : on tente /enable 1 à 6' 'WARN'
        foreach ($n in 1..6) { $ids.Add([string]$n) }
    }
    if ($ids.Count -gt 0) {
        $null = Invoke-Mmt -Exe $exe -Arguments (@('/enable') + $ids.ToArray()) -TimeoutSec $timeout
        Write-MonoLog "réactivés : $($ids -join ', ')"
    } else {
        Write-MonoLog 'aucun écran désactivé détecté'
    }

    if (Test-Path -LiteralPath $cfg) {
        Start-Sleep -Milliseconds ([int]$Settings.settleMs)
        $null = Invoke-Mmt -Exe $exe -Arguments @('/LoadConfig', $cfg) -TimeoutSec $timeout
        Write-MonoLog "agencement rechargé ($cfg)"
    } else {
        Write-MonoLog "pas d'agencement sauvegardé : écrans réactivés sans recharger la disposition" 'WARN'
    }
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    return 'ok'
}
