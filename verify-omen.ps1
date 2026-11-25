# verify-omen.ps1 — TEST D'ACCEPTATION de l'OMEN (cf. SYSTEME-OMEN-35L.md §8 / §10 étape 19).
# Lecture seule : ne modifie RIEN. À relancer après chaque grosse mise à jour Windows / pilote NVIDIA.
#   .\verify-omen.ps1            # tableau PASS / WARN / FAIL / SKIP
#   .\verify-omen.ps1 -SkipGpu   # sans les tests GPU (torch dans WSL + Docker = lents)
#   .\verify-omen.ps1 -Json      # + export logs\verify-omen-<date>.json
# Code de sortie 1 s'il reste au moins un FAIL.
[CmdletBinding()]
param([switch]$SkipGpu, [switch]$Json)
. "$PSScriptRoot\modules\00-helpers.ps1"

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Check {
    param([string]$Area, [string]$Name, [ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP')][string]$Status, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Domaine = $Area; Test = $Name; Statut = $Status; Detail = $Detail })
}
function Invoke-Check {
    # Exécute un bloc de test ; une exception = SKIP (outil absent, droits…), jamais un plantage du script.
    param([string]$Area, [string]$Name, [scriptblock]$Block)
    try { & $Block } catch { Add-Check $Area $Name 'SKIP' $_.Exception.Message }
}

function Get-PowerAcIndex {
    # Valeur AC (secteur) d'un paramètre powercfg, indépendante de la langue : 1re ligne '0x…' des 2 dernières.
    param([string]$Sub, [string]$Setting)
    $hex = @(powercfg /q SCHEME_CURRENT $Sub $Setting 2>$null | Select-String '0x[0-9a-fA-F]{8}\s*$')
    if ($hex.Count -lt 2) { return $null }
    return [Convert]::ToInt64(($hex[-2].Line -replace '.*(0x[0-9a-fA-F]{8})\s*$', '$1'), 16)
}

function Invoke-Verify {
    $layout = Get-StorageLayout -Name 'omen'
    Write-Banner "VERIFY OMEN (lecture seule)"

    # ---------------------------------------------------------------- Profil & disques
    Invoke-Check 'Profil' 'Machine détectée = omen' {
        $p = Get-ResetProfile
        Add-Check 'Profil' 'Machine détectée = omen' $(if ($p -eq 'omen') { 'PASS' } else { 'WARN' }) "profil : $p"
    }
    Invoke-Check 'Disques' "C: >= 15 % libres" {
        $c = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $pct = [math]::Round(100 * $c.SizeRemaining / $c.Size, 1)
        Add-Check 'Disques' "C: >= 15 % libres" $(if ($pct -ge 15) { 'PASS' } else { 'FAIL' }) ("{0} % ({1:N0} Go libres)" -f $pct, ($c.SizeRemaining / 1GB))
    }
    Invoke-Check 'Disques' 'D: = SSD jeux (P310)' {
        $gd = $layout.gamesDisk
        $disk = Get-Partition -DriveLetter $gd.letter -ErrorAction Stop | Get-Disk
        $ok = "$($disk.FriendlyName) $($disk.Model)" -match [regex]::Escape($gd.modelMatch)
        Add-Check 'Disques' 'D: = SSD jeux (P310)' $(if ($ok) { 'PASS' } else { 'FAIL' }) "$($gd.letter): = $($disk.FriendlyName)"
    }
    Invoke-Check 'Disques' 'Arborescence du layout' {
        $miss = @(@($layout.dirs) | Where-Object { -not (Test-Path $_) })
        Add-Check 'Disques' 'Arborescence du layout' $(if (-not $miss) { 'PASS' } else { 'FAIL' }) $(if ($miss) { "manquants : $($miss -join ', ')" } else { "$(@($layout.dirs).Count) dossiers" })
    }
    Invoke-Check 'Disques' 'Hibernation off' {
        $h = Test-Path "$env:SystemDrive\hiberfil.sys"
        Add-Check 'Disques' 'Hibernation off' $(if (-not $h) { 'PASS' } else { 'WARN' }) $(if ($h) { 'hiberfil.sys présent (powercfg /h off)' } else { '' })
    }

    # ---------------------------------------------------------------- Variables & projets
    foreach ($p in $layout.env.PSObject.Properties) {
        $v = [Environment]::GetEnvironmentVariable($p.Name, 'User')
        Add-Check 'Env' $p.Name $(if ($v -eq $p.Value) { 'PASS' } else { 'FAIL' }) "attendu '$($p.Value)', trouvé '$v'"
    }
    Invoke-Check 'Projets' 'PROJETS_CODE = chemin canonique (dossier réel)' {
        $v = [Environment]::GetEnvironmentVariable('PROJETS_CODE', 'User')
        $it = Get-Item -LiteralPath $layout.projetsCode -Force -ErrorAction SilentlyContinue
        $ok = ($v -eq $layout.projetsCode) -and $it -and -not $it.LinkType
        $n = if ($it) { @(Find-GitRepos -Root $layout.projetsCode -MaxDepth 3).Count } else { 0 }
        Add-Check 'Projets' 'PROJETS_CODE = chemin canonique (dossier réel)' $(if ($ok) { 'PASS' } else { 'FAIL' }) "PROJETS_CODE='$v', $n dépôt(s)"
    }
    Invoke-Check 'Projets' 'Ancien 03_Projets_Code décoché de OneDrive' {
        $old = @($layout.legacyProjetsRoots)[0]
        $present = $old -and (Test-Path -LiteralPath $old)
        Add-Check 'Projets' 'Ancien 03_Projets_Code décoché de OneDrive' $(if (-not $present) { 'PASS' } else { 'WARN' }) $(if ($present) { "$old encore synchronisé ici" } else { '' })
    }
    Invoke-Check 'Projets' 'Consommateurs sur le chemin canonique' {
        $stale = @()
        foreach ($f in @("$env:USERPROFILE\.claude\settings.json", "$env:USERPROFILE\.claude.json", "$env:APPDATA\Claude\claude_desktop_config.json")) {
            if (Test-Path $f) { $t = Get-Content $f -Raw; if ((ConvertTo-CanonicalProjetsPath -Text $t) -ne $t) { $stale += (Split-Path $f -Leaf) } }
        }
        Add-Check 'Projets' 'Consommateurs sur le chemin canonique' $(if (-not $stale) { 'PASS' } else { 'FAIL' }) $(if ($stale) { "ancien chemin dans : $($stale -join ', ') -> migrate-projets.ps1 -ConsumersOnly" } else { '' })
    }
    Invoke-Check 'Projets' 'Configs partagées = ce profil utilisateur' {
        # Les configs viennent d'EXODIUS : un C:\Users\<autre>\ y casse les chemins si le compte de l'OMEN porte un autre nom.
        $bad = @()
        foreach ($f in @("$env:USERPROFILE\.claude\settings.json", "$env:USERPROFILE\.claude.json")) {
            if (-not (Test-Path $f)) { continue }
            $users = [regex]::Matches((Get-Content $f -Raw), '(?i)C:(?:\\\\|\\|/)Users(?:\\\\|\\|/)([^\\/"]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            $bad += @($users | Where-Object { $_ -ine $env:USERNAME -and $_ -notin 'Public', 'Default' })
        }
        $bad = @($bad | Sort-Object -Unique)
        Add-Check 'Projets' 'Configs partagées = ce profil utilisateur' $(if (-not $bad) { 'PASS' } else { 'WARN' }) $(if ($bad) { "chemins vers C:\Users\$($bad -join ', C:\Users\') (ce compte : $env:USERNAME)" } else { '' })
    }
    Invoke-Check 'Sauvegarde' 'Bundles git < 48 h' {
        $m = Join-Path $layout.bundlesDir 'manifest.json'
        if (-not (Test-Path $m)) { Add-Check 'Sauvegarde' 'Bundles git < 48 h' 'FAIL' 'manifest.json absent (backup-bundles.ps1)'; return }
        $age = (Get-Date) - (Get-Item $m).LastWriteTime
        Add-Check 'Sauvegarde' 'Bundles git < 48 h' $(if ($age.TotalHours -lt 48) { 'PASS' } else { 'WARN' }) ("dernier : il y a {0:N0} h" -f $age.TotalHours)
    }
    Invoke-Check 'Sauvegarde' "SSD externe $($layout.backupDrive) branché" {
        $x = Test-Path "$($layout.backupDrive)\"
        Add-Check 'Sauvegarde' "SSD externe $($layout.backupDrive) branché" $(if ($x) { 'PASS' } else { 'WARN' }) $(if (-not $x) { 'achat jour 1 : seule copie de WSL/Docker/datasets' } else { '' })
    }

    # ---------------------------------------------------------------- Réseau
    Invoke-Check 'Réseau' 'Lien 10 Gbps actif' {
        $up = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up')
        $ten = @($up | Where-Object { $_.ReceiveLinkSpeed -ge 10e9 -or $_.LinkSpeed -match '^10 Gbps' })
        $desc = ($up | ForEach-Object { "$($_.Name)=$($_.LinkSpeed)" }) -join ', '
        Add-Check 'Réseau' 'Lien 10 Gbps actif' $(if ($ten) { 'PASS' } else { 'FAIL' }) $desc
    }
    Invoke-Check 'Réseau' '2,5 GbE intégré activé (secours)' {
        $rt = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.InterfaceDescription -match 'Realtek' -and $_.InterfaceDescription -match '2\.5|8125' })
        if (-not $rt) { Add-Check 'Réseau' '2,5 GbE intégré activé (secours)' 'SKIP' 'adaptateur Realtek 2.5G non trouvé'; return }
        Add-Check 'Réseau' '2,5 GbE intégré activé (secours)' $(if ($rt[0].Status -ne 'Disabled') { 'PASS' } else { 'WARN' }) "état : $($rt[0].Status)"
    }
    Invoke-Check 'Remote' 'Tailscale connecté' {
        $ts = Get-Command tailscale -ErrorAction Stop
        $st = & $ts.Source status --json 2>$null | ConvertFrom-Json
        $ok = $st.BackendState -eq 'Running'
        $exp = if ($st.Self.PSObject.Properties.Name -contains 'KeyExpiry' -and $st.Self.KeyExpiry) { " | clé expire le $($st.Self.KeyExpiry) -> désactive l'expiration" } else { '' }
        Add-Check 'Remote' 'Tailscale connecté' $(if ($ok -and -not $exp) { 'PASS' } elseif ($ok) { 'WARN' } else { 'FAIL' }) "$($st.BackendState) $($st.Self.DNSName)$exp"
    }
    Invoke-Check 'Remote' 'Sunshine (service actif)' {
        $svc = Get-Service -Name 'SunshineService' -ErrorAction Stop
        Add-Check 'Remote' 'Sunshine (service actif)' $(if ($svc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) "$($svc.Status) / $($svc.StartType)"
    }
    Invoke-Check 'Remote' 'Pare-feu Sunshine limité à Tailscale' {
        $rules = @(Get-NetFirewallRule -DisplayName 'ResetPack-Sunshine*' -ErrorAction Stop | Where-Object Enabled -eq 'True')
        $wide = @($rules | Where-Object { @(($_ | Get-NetFirewallAddressFilter).RemoteAddress) -contains 'Any' })
        Add-Check 'Remote' 'Pare-feu Sunshine limité à Tailscale' $(if ($rules -and -not $wide) { 'PASS' } else { 'FAIL' }) "$($rules.Count) règle(s) ResetPack, $($wide.Count) ouverte(s) à 'Any'"
    }
    Invoke-Check 'Remote' 'Aucune règle Sunshine large (installeur)' {
        $wide = @(Get-NetFirewallRule -DisplayName 'Sunshine*' -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True')
        Add-Check 'Remote' 'Aucune règle Sunshine large (installeur)' $(if (-not $wide) { 'PASS' } else { 'FAIL' }) $(if ($wide) { "$($wide.Count) active(s) : mise à jour Sunshine ? -> .\reset.ps1 -Profile omen -Only remote" } else { '' })
    }
    Invoke-Check 'Remote' 'sunshine.conf : mono-écran + UPnP off' {
        $conf = Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.conf'
        $t = if (Test-Path $conf) { Get-Content $conf -Raw } else { '' }
        $ok = ($t -match 'mono-ecran-on\.ps1') -and ($t -match '(?m)^\s*upnp\s*=\s*disabled')
        Add-Check 'Remote' 'sunshine.conf : mono-écran + UPnP off' $(if ($ok) { 'PASS' } else { 'FAIL' }) $(if (-not $t) { "$conf absent" } elseif (-not $ok) { 'global_prep_cmd ou upnp manquant -> -Only remote' } else { '' })
    }
    Invoke-Check 'Remote' 'MultiMonitorTool installé' {
        $mmt = Join-Path $layout.tools 'MultiMonitorTool\MultiMonitorTool.exe'
        Add-Check 'Remote' 'MultiMonitorTool installé' $(if (Test-Path $mmt) { 'PASS' } else { 'FAIL' }) $mmt
    }
    Invoke-Check 'Remote' 'Jamais de veille sur secteur' {
        $v = Get-PowerAcIndex -Sub 'SUB_SLEEP' -Setting 'STANDBYIDLE'
        Add-Check 'Remote' 'Jamais de veille sur secteur' $(if ($v -eq 0) { 'PASS' } elseif ($null -eq $v) { 'SKIP' } else { 'FAIL' }) "veille AC : $v s"
    }
    Invoke-Check 'Remote' 'Pas d''auto-login' {
        $a = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop).AutoAdminLogon
        Add-Check 'Remote' 'Pas d''auto-login' $(if ("$a" -ne '1') { 'PASS' } else { 'FAIL' }) "AutoAdminLogon=$a"
    }

    # ---------------------------------------------------------------- Sécurité
    Invoke-Check 'Sécurité' 'Defender temps réel ON' {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Add-Check 'Sécurité' 'Defender temps réel ON' $(if ($mp.RealTimeProtectionEnabled) { 'PASS' } else { 'FAIL' }) "AM : $($mp.AMRunningMode)"
    }
    Invoke-Check 'Sécurité' 'Aucune exclusion Defender sur D:\Games' {
        $ex = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ -match '(?i)^D:\\Games' })
        Add-Check 'Sécurité' 'Aucune exclusion Defender sur D:\Games' $(if (-not $ex) { 'PASS' } else { 'WARN' }) ($ex -join ', ')
    }
    Invoke-Check 'Sécurité' 'VBS / Memory Integrity' {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $hvci = @($dg.SecurityServicesRunning) -contains 2
        Add-Check 'Sécurité' 'VBS / Memory Integrity' $(if ($dg.VirtualizationBasedSecurityStatus -eq 2 -and $hvci) { 'PASS' } else { 'WARN' }) "VBS=$($dg.VirtualizationBasedSecurityStatus) HVCI=$hvci"
    }
    Invoke-Check 'Sécurité' 'Pare-feu actif (3 profils)' {
        $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled })
        Add-Check 'Sécurité' 'Pare-feu actif (3 profils)' $(if (-not $off) { 'PASS' } else { 'FAIL' }) $(if ($off) { "désactivé : $($off.Name -join ', ')" } else { '' })
    }
    Invoke-Check 'Sécurité' 'Chiffrement C: (clé de récupération sauvegardée ?)' {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $on = "$($bl.ProtectionStatus)" -eq 'On'
        Add-Check 'Sécurité' 'Chiffrement C: (clé de récupération sauvegardée ?)' $(if ($on) { 'PASS' } else { 'WARN' }) "protection : $($bl.ProtectionStatus) -> clé relevée sur account.microsoft.com/devices/recoverykey + copie hors ligne ?"
    }

    # ---------------------------------------------------------------- Jeu
    Invoke-Check 'Jeu' 'Game Mode ON' {
        $g = (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -ErrorAction Stop).AutoGameModeEnabled
        Add-Check 'Jeu' 'Game Mode ON' $(if ("$g" -ne '0') { 'PASS' } else { 'WARN' }) "AutoGameModeEnabled=$g"
    }
    Invoke-Check 'Jeu' 'HAGS ON' {
        $h = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop).HwSchMode
        Add-Check 'Jeu' 'HAGS ON' $(if ("$h" -eq '2') { 'PASS' } else { 'WARN' }) "HwSchMode=$h"
    }

    Invoke-Check 'Jeu' 'Plan d''alimentation Balanced' {
        $act = "$(powercfg /getactivescheme 2>$null)"
        $ok = $act -match '381b4222-f694-41f0-9685-ff5bb260df2e'
        Add-Check 'Jeu' 'Plan d''alimentation Balanced' $(if ($ok) { 'PASS' } else { 'WARN' }) ($act -replace '^.*?:\s*', '')
    }

    # ---------------------------------------------------------------- Tri HP
    Invoke-Check 'HP' 'Capture de référence (hp-capture-*)' {
        $cap = @(Get-ChildItem (Join-Path $PSScriptRoot 'logs') -Directory -Filter 'hp-capture-*' -ErrorAction SilentlyContinue)
        Add-Check 'HP' 'Capture de référence (hp-capture-*)' $(if ($cap) { 'PASS' } else { 'WARN' }) $(if ($cap) { "$($cap.Count) capture(s)" } else { '.\reset.ps1 -Profile omen -Only hp-triage -DryRun' })
    }
    Invoke-Check 'HP' 'McAfee absent' {
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $mc = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { "$($_.DisplayName)" -match 'McAfee' })
        Add-Check 'HP' 'McAfee absent' $(if (-not $mc) { 'PASS' } else { 'WARN' }) (($mc | ForEach-Object DisplayName) -join ', ')
    }
    Invoke-Check 'HP' 'OMEN Gaming Hub présent (ventilos/RGB/LCD)' {
        $o = @(Get-AppxPackage -Name 'AD2F1837.OMEN*' -ErrorAction Stop)
        Add-Check 'HP' 'OMEN Gaming Hub présent (ventilos/RGB/LCD)' $(if ($o) { 'PASS' } else { 'WARN' }) (($o | ForEach-Object Name) -join ', ')
    }

    # ---------------------------------------------------------------- Deep learning
    Invoke-Check 'DL' '.wslconfig présent' {
        $f = Join-Path $env:USERPROFILE '.wslconfig'
        $ok = (Test-Path $f) -and ((Get-Content $f -Raw) -match '(?m)^\s*memory\s*=')
        Add-Check 'DL' '.wslconfig présent' $(if ($ok) { 'PASS' } else { 'FAIL' }) $(if (-not $ok) { 'module ml : .\reset.ps1 -Profile omen -Only ml' } else { '' })
    }
    $smoke = Join-Path $PSScriptRoot 'scripts\ml-smoke-test.ps1'
    if ($SkipGpu) { Add-Check 'DL' 'GPU / torch / Docker' 'SKIP' '-SkipGpu' }
    elseif (-not (Test-Path $smoke)) { Add-Check 'DL' 'GPU / torch / Docker' 'SKIP' 'scripts\ml-smoke-test.ps1 absent' }
    else {
        Invoke-Check 'DL' 'GPU / torch / Docker' {
            $r = & $smoke -Quiet
            foreach ($k in 'Gpu', 'TorchCuda', 'DockerGpu') {
                $v = $r.$k
                Add-Check 'DL' $k $(if ($v -eq $true) { 'PASS' } elseif ($null -eq $v) { 'SKIP' } else { 'FAIL' }) $(if ($k -eq 'Gpu' -and $r.DriverVersion) { "pilote $($r.DriverVersion)" } else { '' })
            }
        }
    }

    # ---------------------------------------------------------------- Tâches planifiées
    foreach ($t in 'ResetPack-WingetUpgrade', 'ResetPack-CodeBundles', 'ResetPack-ReactiverEcrans', 'ResetPack-MonoEcranOn', 'ResetPack-MonoEcranOff') {
        Invoke-Check 'Tâches' $t {
            $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Add-Check 'Tâches' $t $(if ($task) { 'PASS' } else { 'FAIL' }) $(if ($task) { "$($task.State)" } else { 'absente' })
        }
    }

    # ---------------------------------------------------------------- Résultat
    $script:Results | Format-Table Domaine, Test, Statut, Detail -AutoSize -Wrap | Out-Host
    $c = $script:Results | Group-Object Statut -NoElement | ForEach-Object { "$($_.Count) $($_.Name)" }
    $fails = @($script:Results | Where-Object Statut -eq 'FAIL').Count
    if ($fails -eq 0) { Write-Ok "OMEN prête ($($c -join ', '))" } else { Write-Err "$fails échec(s) ($($c -join ', '))" }
    if ($Json) {
        $out = Join-Path $PSScriptRoot ("logs\verify-omen-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
        New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
        $script:Results | ConvertTo-Json -Depth 3 | Set-Content $out -Encoding UTF8
        Write-Ok "Export : $out"
    }
    return $fails
}

if ($MyInvocation.InvocationName -ne '.') {
    $f = Invoke-Verify
    if ($f -gt 0) { exit 1 }
}
