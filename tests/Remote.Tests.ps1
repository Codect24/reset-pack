# Tests Pester 5+ du lot 5 (accès distant + mono-écran). AUCUNE action réelle : pare-feu, powercfg,
# tailscale et MultiMonitorTool sont mockés (et neutralisés par des stubs), tout fichier est écrit dans $TestDrive.
#   Invoke-Pester -Path .\tests\Remote.Tests.ps1
BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:SavedEnv = @{
        RESETPACK_PROFILE    = $env:RESETPACK_PROFILE
        RESETPACK_DRYRUN     = $env:RESETPACK_DRYRUN
        RESETPACK_AUTO       = $env:RESETPACK_AUTO
        RESETPACK_REMOTE_DIR = $env:RESETPACK_REMOTE_DIR
    }
    $env:RESETPACK_DRYRUN = ''
    $env:RESETPACK_AUTO = ''

    # Filet de sécurité : ces stubs masquent les vrais exécutables pendant les tests (même sans Mock).
    function tailscale { }
    function powercfg { }
    function icacls { }

    . (Join-Path $script:Repo 'modules\17-remote.ps1') -NoRun
    . (Join-Path $script:Repo 'scripts\remote\mono-ecran-commun.ps1')
    $script:Cfg = Get-RemoteConfig
    $script:TsRanges = '100.64.0.0/10|fd7a:115c:a1e0::/48'
    # -NoTypeInformation : obligatoire en 5.1, obsolète (avertissement) en 7+
    $script:CsvArgs = @{}
    if ($PSVersionTable.PSVersion.Major -lt 6) { $script:CsvArgs.NoTypeInformation = $true }

    # --- Simulateur MultiMonitorTool : 3 écrans de tailles différentes ---------------------------
    function Initialize-SimMonitor {
        param([switch]$SameSerial)
        $s1 = 'SN-PRINCIPAL'; $s2 = 'SN-GAUCHE'; $s3 = 'SN-DROITE'
        if ($SameSerial) { $s1 = 'DUP'; $s2 = 'DUP'; $s3 = 'DUP' }
        $script:Sim = @(
            [ordered]@{ Resolution = '3440 X 1440'; Active = 'Yes'; Disconnected = 'No'; Primary = 'Yes'; Name = '\\.\DISPLAY1'
                'Monitor ID' = 'MONITOR\GSM5BBF\{4d36e96e-e325-11ce-bfc1-08002be10318}\0001'; 'Short Monitor ID' = 'GSM5BBF'
                'Monitor Name' = 'LG ULTRAGEAR'; 'Monitor Serial Number' = $s1 }
            [ordered]@{ Resolution = '2560 X 1440'; Active = 'Yes'; Disconnected = 'No'; Primary = 'No'; Name = '\\.\DISPLAY2'
                'Monitor ID' = 'MONITOR\SAM7340\{4d36e96e-e325-11ce-bfc1-08002be10318}\0002'; 'Short Monitor ID' = 'SAM7340'
                'Monitor Name' = 'Odyssey G7'; 'Monitor Serial Number' = $s2 }
            [ordered]@{ Resolution = '1920 X 1080'; Active = 'Yes'; Disconnected = 'No'; Primary = 'No'; Name = '\\.\DISPLAY3'
                'Monitor ID' = 'MONITOR\DELA0B1\{4d36e96e-e325-11ce-bfc1-08002be10318}\0003'; 'Short Monitor ID' = 'DELA0B1'
                'Monitor Name' = 'DELL P2422H'; 'Monitor Serial Number' = $s3 }
        )
        $script:MmtCalls = New-Object System.Collections.Generic.List[object]
        $script:SimNoHeader = $false
        $script:SimDisableAlsoKills = $null
        $script:SimListFails = $false
    }

    function Find-SimMonitor {
        # Comme MultiMonitorTool : un identifiant partagé (n° de série, Short ID) touche TOUS les écrans concernés.
        param([string]$Id)
        @($script:Sim | Where-Object {
                $Id -ieq $_.'Monitor Serial Number' -or $Id -ieq $_.'Monitor ID' -or $Id -ieq $_.'Short Monitor ID' -or
                $Id -ieq $_.Name -or ('\\.\DISPLAY' + $Id) -ieq $_.Name -or ($Id -ieq 'primary' -and $_.Primary -eq 'Yes')
            })
    }

    function Invoke-SimMmt {
        param([string[]]$Arguments)
        $script:MmtCalls.Add(@($Arguments))
        $verb = $Arguments[0]
        $rest = @($Arguments | Select-Object -Skip 1)
        switch ($verb) {
            '/scomma' {
                if ($script:SimListFails) { return }
                $csv = @($script:Sim | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv @script:CsvArgs)
                if ($script:SimNoHeader) { $csv = @($csv | Select-Object -Skip 1) }
                Set-Content -LiteralPath $rest[0] -Value $csv -Encoding UTF8
            }
            '/sxml' {
                if ($script:SimListFails) { return }
                $xml = '<?xml version="1.0" ?><monitors_list>'
                foreach ($m in $script:Sim) {
                    $xml += '<item>'
                    foreach ($k in $m.Keys) {
                        $tag = ($k.ToLower() -replace '[^a-z0-9]+', '_')
                        $xml += "<$tag>" + [Security.SecurityElement]::Escape([string]$m[$k]) + "</$tag>"
                    }
                    $xml += '</item>'
                }
                Set-Content -LiteralPath $rest[0] -Value ($xml + '</monitors_list>') -Encoding UTF8
            }
            '/SaveConfig' { Set-Content -LiteralPath $rest[0] -Value '[Monitor0]' }
            '/LoadConfig' { foreach ($m in $script:Sim) { $m.Active = 'Yes' } }
            '/disable' {
                foreach ($id in $rest) { foreach ($m in (Find-SimMonitor $id)) { $m.Active = 'No' } }
                if ($script:SimDisableAlsoKills) { foreach ($m in (Find-SimMonitor $script:SimDisableAlsoKills)) { $m.Active = 'No' } }
            }
            '/enable' { foreach ($id in $rest) { foreach ($m in (Find-SimMonitor $id)) { $m.Active = 'Yes' } } }
            '/SetPrimary' {
                $target = @(Find-SimMonitor $rest[0])
                if ($target.Count -eq 1) { foreach ($m in $script:Sim) { $m.Primary = 'No' }; $target[0].Primary = 'Yes' }
            }
        }
    }

    function Get-SimCall {
        param([string]$Verb)
        @($script:MmtCalls | Where-Object { $_[0] -eq $Verb })
    }

    function Get-TestSetting {
        param([string]$Keep = 'primary')
        $exe = Join-Path $TestDrive 'MultiMonitorTool.exe'
        if (-not (Test-Path $exe)) { Set-Content -LiteralPath $exe -Value 'faux' }
        [pscustomobject]@{ mmtPath = $exe; keepMonitor = $Keep; taskOn = 'T-on'; taskOff = 'T-off'; taskRescue = 'T-rescue'; settleMs = 0; timeoutSec = 5 }
    }

    function Read-JsonArray {
        # Tableau JSON -> tableau PowerShell, identique en 5.1 (qui ne déroule pas) et en 7.
        param([string]$Text)
        $out = @()
        foreach ($i in (ConvertFrom-Json -InputObject $Text)) { $out += $i }
        return , $out
    }

    function Get-AllPropertyName {
        param($Node)
        if ($null -eq $Node) { return }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) { foreach ($n in $Node) { Get-AllPropertyName $n }; return }
        if ($Node -is [pscustomobject]) {
            foreach ($p in $Node.PSObject.Properties) { $p.Name; Get-AllPropertyName $p.Value }
        }
    }
}

AfterAll {
    foreach ($k in $script:SavedEnv.Keys) { Set-Item -Path "Env:$k" -Value $script:SavedEnv[$k] -ErrorAction SilentlyContinue }
}

Describe 'config/remote.json' {
    It 'est un JSON valide pour le profil hôte omen, keepMonitor renseigné' {
        $script:Cfg.hostProfile | Should -Be 'omen'
        $script:Cfg.keepMonitor | Should -Not -BeNullOrEmpty
        $script:Cfg.multiMonitorTool.url | Should -Match '^https://www\.nirsoft\.net/utils/multimonitortool-x64\.zip$'
    }
    It 'donne exactement les plages Tailscale (IPv4 CGNAT + ULA IPv6)' {
        $script:Cfg.tailscale.ipv4 | Should -Be '100.64.0.0/10'
        $script:Cfg.tailscale.ipv6 | Should -Be 'fd7a:115c:a1e0::/48'
    }
    It 'préfixe toutes les tâches par ResetPack-' {
        foreach ($p in $script:Cfg.tasks.PSObject.Properties) { $p.Value | Should -BeLike 'ResetPack-*' }
        $script:Cfg.tasks.rescue | Should -Be 'ResetPack-ReactiverEcrans'
    }
    It 'ne contient aucun secret (pas de clé password/authkey, pas de tskey-)' {
        $raw = Get-Content (Join-Path $script:Repo 'config\remote.json') -Raw
        $raw | Should -Not -Match 'tskey-'
        $names = @(Get-AllPropertyName $script:Cfg)
        ($names | Where-Object { $_ -match '(?i)pass|authkey|secret|token' }) | Should -BeNullOrEmpty
    }
}

Describe 'mono-écran : MultiMonitorTool simulé (3 écrans)' {
    BeforeEach {
        Initialize-SimMonitor
        $env:RESETPACK_REMOTE_DIR = Join-Path $TestDrive ('data-' + [guid]::NewGuid().ToString('N'))
        Mock Invoke-Mmt { Invoke-SimMmt -Arguments $Arguments; $true }
        Mock Start-Sleep { }
    }

    It 'keepMonitor = primary : garde le principal, désactive les 2 autres par n° de série' {
        Invoke-MonoEcranOn -Settings (Get-TestSetting 'primary') | Should -Be 'ok'
        $dis = @(Get-SimCall '/disable')
        $dis.Count | Should -Be 1
        @($dis[0] | Select-Object -Skip 1) | Should -Be @('SN-GAUCHE', 'SN-DROITE')
        $script:Sim[0].Active | Should -Be 'Yes'
        $script:Sim[1].Active | Should -Be 'No'
        $script:Sim[2].Active | Should -Be 'No'
    }

    It "n'envoie JAMAIS l'écran gardé à /disable (keepMonitor = <_>)" -ForEach @(
        'primary'
        'SN-GAUCHE'
        'MONITOR\DELA0B1\{4d36e96e-e325-11ce-bfc1-08002be10318}\0003'
        'DELL P2422H'
    ) {
        $keep = $_
        # (le nom EDID 'Monitor Name' n'est pas un identifiant MultiMonitorTool : lookup côté test)
        $kept = @($script:Sim | Where-Object { ($keep -eq 'primary' -and $_.Primary -eq 'Yes') -or (@($_.Values) -contains $keep) })[0]
        $keptIds = @($kept.'Monitor Serial Number', $kept.'Monitor ID', $kept.'Short Monitor ID', $kept.Name, $kept.'Monitor Name')
        Invoke-MonoEcranOn -Settings (Get-TestSetting $keep) | Should -Be 'ok'
        $dis = @(Get-SimCall '/disable')
        $dis.Count | Should -Be 1
        foreach ($id in @($dis[0] | Select-Object -Skip 1)) { $keptIds | Should -Not -Contain $id }
        $kept.Active | Should -Be 'Yes'
        @($script:Sim | Where-Object { $_.Active -eq 'Yes' }).Count | Should -Be 1
    }

    It "fait de l'écran gardé l'écran principal avant de désactiver l'ancien principal" {
        Invoke-MonoEcranOn -Settings (Get-TestSetting 'SN-GAUCHE') | Should -Be 'ok'
        $verbs = @($script:MmtCalls | ForEach-Object { $_[0] })
        $verbs.IndexOf('/SetPrimary') | Should -BeLessThan $verbs.IndexOf('/disable')
        @(Get-SimCall '/SetPrimary')[0][1] | Should -Be 'SN-GAUCHE'
    }

    It 'sauvegarde l''agencement AVANT /disable' {
        Invoke-MonoEcranOn -Settings (Get-TestSetting) | Out-Null
        $verbs = @($script:MmtCalls | ForEach-Object { $_[0] })
        $verbs.IndexOf('/SaveConfig') | Should -BeGreaterOrEqual 0
        $verbs.IndexOf('/SaveConfig') | Should -BeLessThan $verbs.IndexOf('/disable')
    }

    It 'n° de série identiques : cible par Monitor ID, jamais par le n° partagé' {
        Initialize-SimMonitor -SameSerial
        Invoke-MonoEcranOn -Settings (Get-TestSetting 'primary') | Should -Be 'ok'
        $ids = @(@(Get-SimCall '/disable')[0] | Select-Object -Skip 1)
        $ids | Should -Not -Contain 'DUP'
        $ids | ForEach-Object { $_ | Should -BeLike 'MONITOR\*' }
        $script:Sim[0].Active | Should -Be 'Yes'
    }

    It 'keepMonitor introuvable : ne sauvegarde rien et ne désactive rien' {
        Invoke-MonoEcranOn -Settings (Get-TestSetting 'SN-INCONNU') | Should -Be 'ecran-garde-introuvable'
        @(Get-SimCall '/disable').Count | Should -Be 0
        @(Get-SimCall '/SaveConfig').Count | Should -Be 0
    }

    It 'keepMonitor ambigu (Short Monitor ID partagé) : ne désactive rien' {
        foreach ($m in $script:Sim) { $m.'Short Monitor ID' = 'GSM0000' }
        Invoke-MonoEcranOn -Settings (Get-TestSetting 'GSM0000') | Should -Be 'ecran-garde-introuvable'
        @(Get-SimCall '/disable').Count | Should -Be 0
    }

    It 'liste illisible : ne désactive rien' {
        $script:SimListFails = $true
        Invoke-MonoEcranOn -Settings (Get-TestSetting) | Should -Be 'liste-vide'
        @(Get-SimCall '/disable').Count | Should -Be 0
    }

    It 'CSV sans en-tête : repli sur /sxml, sans jamais toucher l''écran gardé' {
        $script:SimNoHeader = $true
        Invoke-MonoEcranOn -Settings (Get-TestSetting) | Should -Be 'ok'
        @(Get-SimCall '/sxml').Count | Should -BeGreaterThan 0
        $script:Sim[0].Active | Should -Be 'Yes'
        @(@(Get-SimCall '/disable')[0] | Select-Object -Skip 1) | Should -Be @('SN-GAUCHE', 'SN-DROITE')
    }

    It 'un second « do » ne remplace pas l''agencement d''origine' {
        $s = Get-TestSetting
        Invoke-MonoEcranOn -Settings $s | Should -Be 'ok'
        Invoke-MonoEcranOn -Settings $s | Should -Be 'deja-mono'
        @(Get-SimCall '/SaveConfig').Count | Should -Be 1
    }

    It "écran gardé perdu après /disable : restauration immédiate de tous les écrans" {
        $script:SimDisableAlsoKills = 'SN-PRINCIPAL'
        Invoke-MonoEcranOn -Settings (Get-TestSetting) | Should -Be 'restaure'
        @(Get-SimCall '/LoadConfig').Count | Should -Be 1
        @($script:Sim | Where-Object { $_.Active -eq 'Yes' }).Count | Should -Be 3
    }

    It 'undo : réactive les écrans désactivés puis recharge l''agencement exact' {
        $s = Get-TestSetting
        Invoke-MonoEcranOn -Settings $s | Out-Null
        Invoke-MonoEcranOff -Settings $s | Should -Be 'ok'
        $en = @(Get-SimCall '/enable')
        $en.Count | Should -Be 1
        @($en[0] | Select-Object -Skip 1) | Should -Contain 'SN-GAUCHE'
        @($en[0] | Select-Object -Skip 1) | Should -Contain 'SN-DROITE'
        $verbs = @($script:MmtCalls | ForEach-Object { $_[0] })
        [array]::LastIndexOf($verbs, '/enable') | Should -BeLessThan ([array]::LastIndexOf($verbs, '/LoadConfig'))
        @($script:Sim | Where-Object { $_.Active -eq 'Yes' }).Count | Should -Be 3
        Test-Path (Join-Path $env:RESETPACK_REMOTE_DIR 'mono-ecran\etat.json') | Should -BeFalse
    }

    It 'undo sans mono-écran engagé : ne touche à rien' {
        Invoke-MonoEcranOff -Settings (Get-TestSetting) | Should -Be 'rien'
        $script:MmtCalls.Count | Should -Be 0
    }

    It 'secours : /enable de TOUS les écrans puis /LoadConfig, même sans état' {
        $s = Get-TestSetting
        Invoke-MonoEcranOn -Settings $s | Out-Null
        Remove-Item (Join-Path $env:RESETPACK_REMOTE_DIR 'mono-ecran\etat.json') -Force
        $script:MmtCalls.Clear()
        Invoke-MonoEcranOff -Settings $s -Rescue | Should -Be 'ok'
        @(@(Get-SimCall '/enable')[0] | Select-Object -Skip 1).Count | Should -Be 3
        @(Get-SimCall '/LoadConfig').Count | Should -Be 1
        @($script:Sim | Where-Object { $_.Active -eq 'Yes' }).Count | Should -Be 3
    }

    It 'secours sans liste ni état : tente /enable 1 à 6' {
        $script:SimListFails = $true
        Invoke-MonoEcranOff -Settings (Get-TestSetting) -Rescue | Should -Be 'ok'
        @(@(Get-SimCall '/enable')[0] | Select-Object -Skip 1) | Should -Be @('1', '2', '3', '4', '5', '6')
    }

    It 'outil absent : ne lève pas d''exception et journalise' {
        $s = Get-TestSetting
        $s.mmtPath = Join-Path $TestDrive 'absent\MultiMonitorTool.exe'
        { Invoke-MonoEcranOn -Settings $s } | Should -Not -Throw
        Invoke-MonoEcranOn -Settings $s | Should -Be 'outil-absent'
        Get-Content (Join-Path $env:RESETPACK_REMOTE_DIR 'remote.log') -Raw | Should -Match 'introuvable'
    }
}

Describe 'scripts mono-écran : exécution réelle sous Windows PowerShell 5.1 (faux MultiMonitorTool)' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $script:Run = Join-Path $TestDrive 'run'
        $script:Tools = Join-Path $script:Run 'remote'
        New-Item -ItemType Directory -Force -Path $script:Tools | Out-Null
        foreach ($f in $script:MonoScripts) { Copy-Item (Join-Path $script:Repo "scripts\remote\$f") $script:Tools }
        # Faux MultiMonitorTool (.cmd) : renvoie une liste de 3 écrans, journalise ses arguments.
        $fake = Join-Path $script:Run 'fakemmt'
        New-Item -ItemType Directory -Force -Path $fake | Out-Null
        Initialize-SimMonitor
        $script:Sim | ForEach-Object { [pscustomobject]$_ } | Export-Csv -LiteralPath (Join-Path $fake 'ecrans.csv') -Encoding ASCII @script:CsvArgs
        $cmd = @(
            '@echo off'
            'echo %*>>"%~dp0appels.txt"'
            'if /i "%~1"=="/scomma" copy /y "%~dp0ecrans.csv" "%~2" >nul'
            'if /i "%~1"=="/SaveConfig" echo [Monitor0]>"%~2"'
            'exit /b 0'
        )
        Set-Content -LiteralPath (Join-Path $fake 'MultiMonitorTool.cmd') -Value $cmd -Encoding ASCII
        $script:Fake = $fake
        $script:WinPs = (Get-Command powershell.exe).Source

        function Invoke-WinPsScript {
            param([string]$Script, [string]$MmtPath, [string]$DataDir)
            [ordered]@{ mmtPath = $MmtPath; keepMonitor = 'primary'; settleMs = 0; timeoutSec = 10 } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $script:Tools 'settings.json') -Encoding UTF8
            $env:RESETPACK_REMOTE_DIR = $DataDir
            & $script:WinPs -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Tools $Script) -NoRelay | Out-Null
            return $LASTEXITCODE
        }
    }

    It 'mono-ecran-on.ps1 sort en 0 même sans MultiMonitorTool, et journalise l''échec' {
        $data = Join-Path $script:Run 'data-absent'
        Invoke-WinPsScript -Script 'mono-ecran-on.ps1' -MmtPath (Join-Path $script:Run 'nulle-part\MultiMonitorTool.exe') -DataDir $data | Should -Be 0
        Get-Content (Join-Path $data 'remote.log') -Raw -Encoding UTF8 | Should -Match 'MultiMonitorTool introuvable'
    }

    It 'bout en bout : on puis off, l''écran principal jamais désactivé, sortie 0' {
        $data = Join-Path $script:Run 'data-e2e'
        $mmt = Join-Path $script:Fake 'MultiMonitorTool.cmd'
        Invoke-WinPsScript -Script 'mono-ecran-on.ps1' -MmtPath $mmt -DataDir $data | Should -Be 0
        $calls = @(Get-Content (Join-Path $script:Fake 'appels.txt'))
        ($calls | Where-Object { $_ -like '/SaveConfig*' }) | Should -Not -BeNullOrEmpty
        $dis = @($calls | Where-Object { $_ -like '/disable*' })
        $dis.Count | Should -Be 1
        $dis[0] | Should -Match 'SN-GAUCHE'
        $dis[0] | Should -Match 'SN-DROITE'
        $dis[0] | Should -Not -Match 'SN-PRINCIPAL|DISPLAY1|GSM5BBF'
        Test-Path (Join-Path $data 'mono-ecran\etat.json') | Should -BeTrue

        Invoke-WinPsScript -Script 'mono-ecran-off.ps1' -MmtPath $mmt -DataDir $data | Should -Be 0
        $calls = @(Get-Content (Join-Path $script:Fake 'appels.txt'))
        ($calls | Where-Object { $_ -like '/enable*' }) | Should -Match 'SN-GAUCHE'
        ($calls | Where-Object { $_ -like '/LoadConfig*' }) | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $data 'mono-ecran\etat.json') | Should -BeFalse
        Get-Content (Join-Path $data 'remote.log') -Raw -Encoding UTF8 | Should -Match 'désactivés : SN-GAUCHE, SN-DROITE'
    }

    It 'reactiver-ecrans.ps1 sort en 0' {
        $data = Join-Path $script:Run 'data-rescue'
        Invoke-WinPsScript -Script 'reactiver-ecrans.ps1' -MmtPath (Join-Path $script:Fake 'MultiMonitorTool.cmd') -DataDir $data | Should -Be 0
    }
}

Describe 'Sunshine : global_prep_cmd dans sunshine.conf' {
    BeforeEach {
        $script:DryRun = $false
        Mock Write-Host { }
        $script:ConfDir = Join-Path $TestDrive ('sun-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:ConfDir | Out-Null
        $script:Conf = Join-Path $script:ConfDir 'sunshine.conf'
    }

    It 'génère un JSON valide qui pointe vers les bons scripts' {
        $entry = Get-MonoEcranPrepCmd -ScriptsDir 'C:\Tools\remote'
        $json = Merge-SunshinePrepCmd -Existing $null -Entry $entry
        $parsed = Read-JsonArray $json
        $parsed.Count | Should -Be 1
        $parsed[0].do | Should -Match ([regex]::Escape('-File "C:\Tools\remote\mono-ecran-on.ps1"'))
        $parsed[0].undo | Should -Match ([regex]::Escape('-File "C:\Tools\remote\mono-ecran-off.ps1"'))
        $parsed[0].do | Should -Match ([regex]::Escape('WindowsPowerShell\v1.0\powershell.exe"'))
        $parsed[0].elevated | Should -BeFalse
        $json | Should -Not -Match "`n"
    }

    It 'écrit sunshine.conf (backup, UTF-8 sans BOM, upnp coupé) puis reste idempotent' {
        Set-Content -LiteralPath $script:Conf -Value @('# config Sunshine', 'sunshine_name = OMEN', 'port = 47989') -Encoding ASCII
        Install-SunshinePrepCmd -ConfPath $script:Conf -ScriptsDir 'C:\Tools\remote' -Enforce $script:Cfg.sunshine.enforce | Should -BeTrue
        $lines = @([IO.File]::ReadAllLines($script:Conf))
        $lines | Should -Contain 'sunshine_name = OMEN'
        $lines | Should -Contain 'port = 47989'
        $lines | Should -Contain 'upnp = disabled'
        $value = Get-SunshineConfValue -Lines $lines -Key 'global_prep_cmd'
        (Read-JsonArray $value)[0].do | Should -Match 'mono-ecran-on\.ps1'
        $bytes = [IO.File]::ReadAllBytes($script:Conf)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        @(Get-ChildItem $script:ConfDir -Filter 'sunshine.conf.before-resetpack-*').Count | Should -Be 1

        Install-SunshinePrepCmd -ConfPath $script:Conf -ScriptsDir 'C:\Tools\remote' -Enforce $script:Cfg.sunshine.enforce | Should -BeFalse
        @(Get-ChildItem $script:ConfDir -Filter 'sunshine.conf.before-resetpack-*').Count | Should -Be 1
    }

    It 'garde les commandes de l''utilisateur, remplace notre ancienne entrée (valeur multi-ligne, doublon)' {
        Set-Content -LiteralPath $script:Conf -Encoding ASCII -Value @(
            'global_prep_cmd = [{"do":"nircmd.exe setdisplay 1920 1080 32","undo":"nircmd.exe setdisplay 3440 1440 32","elevated":true},'
            '  {"do":"powershell.exe -File \"D:\\old\\mono-ecran-on.ps1\"","undo":"powershell.exe -File \"D:\\old\\mono-ecran-off.ps1\"","elevated":false}]'
            'min_log_level = info'
            'global_prep_cmd = []'
        )
        Install-SunshinePrepCmd -ConfPath $script:Conf -ScriptsDir 'C:\Tools\remote' | Should -BeTrue
        $lines = @([IO.File]::ReadAllLines($script:Conf))
        @($lines | Where-Object { $_ -like 'global_prep_cmd*' }).Count | Should -Be 1
        $lines | Should -Contain 'min_log_level = info'
        $items = Read-JsonArray (Get-SunshineConfValue -Lines $lines -Key 'global_prep_cmd')
        $items.Count | Should -Be 2
        $items[0].do | Should -BeLike 'nircmd.exe*'
        $items[0].elevated | Should -BeTrue
        $items[1].do | Should -Match ([regex]::Escape('C:\Tools\remote\mono-ecran-on.ps1'))
        ($lines -join "`n") | Should -Not -Match 'D:\\\\old'
    }

    It 'dry-run : n''écrit pas sunshine.conf (ni backup)' {
        Set-Content -LiteralPath $script:Conf -Value @('sunshine_name = OMEN') -Encoding ASCII
        $hash = (Get-FileHash $script:Conf).Hash
        $script:DryRun = $true
        Install-SunshinePrepCmd -ConfPath $script:Conf -ScriptsDir 'C:\Tools\remote' -Enforce $script:Cfg.sunshine.enforce | Should -BeTrue
        (Get-FileHash $script:Conf).Hash | Should -Be $hash
        @(Get-ChildItem $script:ConfDir).Count | Should -Be 1
    }

    It 'dry-run : ne crée pas sunshine.conf absent' {
        $script:DryRun = $true
        Install-SunshinePrepCmd -ConfPath $script:Conf -ScriptsDir 'C:\Tools\remote' | Should -BeTrue
        Test-Path $script:Conf | Should -BeFalse
    }

    It 'ramène origin_web_ui_allowed = wan à lan' {
        Set-Content -LiteralPath $script:Conf -Value @('origin_web_ui_allowed = wan') -Encoding ASCII
        Install-SunshinePrepCmd -ConfPath $script:Conf -ScriptsDir 'C:\Tools\remote' | Out-Null
        Get-SunshineConfValue -Lines ([IO.File]::ReadAllLines($script:Conf)) -Key 'origin_web_ui_allowed' | Should -Be 'lan'
    }
}

Describe 'pare-feu (mocké : aucune règle réelle)' {
    BeforeEach {
        $script:DryRun = $false
        Mock Write-Host { }
        $script:Created = New-Object System.Collections.Generic.List[object]
        Mock Get-NetFirewallProfile {
            @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True' }, [pscustomobject]@{ Name = 'Private'; Enabled = 'True' }, [pscustomobject]@{ Name = 'Public'; Enabled = 'True' })
        }
        Mock Set-NetFirewallProfile { }
        Mock Get-NetFirewallRule -ParameterFilter { $DisplayName } {
            @(
                [pscustomobject]@{ Name = '{wide-tcp}'; DisplayName = 'Sunshine'; Direction = 'Inbound'; Enabled = 'True' }
                [pscustomobject]@{ Name = '{wide-udp}'; DisplayName = 'Sunshine'; Direction = 'Inbound'; Enabled = 'True' }
                [pscustomobject]@{ Name = '{out}'; DisplayName = 'Sunshine'; Direction = 'Outbound'; Enabled = 'True' }
                [pscustomobject]@{ Name = '{deja-off}'; DisplayName = 'sunshine.exe'; Direction = 'Inbound'; Enabled = 'False' }
            )
        }
        Mock Get-NetFirewallRule -ParameterFilter { $Name } { $null }
        Mock New-NetFirewallRule { $script:Created.Add([pscustomobject]@{ Name = $Name; Protocol = $Protocol; LocalPort = @($LocalPort); RemoteAddress = @($RemoteAddress); Program = $Program }) }
        Mock Set-NetFirewallRule { }
    }

    It 'crée 2 règles dont les RemoteAddress sont UNIQUEMENT les plages Tailscale' {
        Invoke-RemoteFirewall -Config $script:Cfg -SunshineExe 'C:\Program Files\Sunshine\sunshine.exe' | Out-Null
        $script:Created.Count | Should -Be 2
        foreach ($r in $script:Created) {
            ((@($r.RemoteAddress) | Sort-Object) -join '|') | Should -Be $script:TsRanges
            $r.Name | Should -BeLike 'ResetPack-*'
            $r.Program | Should -Be 'C:\Program Files\Sunshine\sunshine.exe'
        }
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly -ParameterFilter { ((@($RemoteAddress) | Sort-Object) -join '|') -ne '100.64.0.0/10|fd7a:115c:a1e0::/48' }
    }

    It 'ouvre les ports Sunshine (TCP 47984/47989/47990/48010, UDP 47998-48000)' {
        Invoke-RemoteFirewall -Config $script:Cfg | Out-Null
        $tcp = ($script:Created | Where-Object Protocol -EQ 'TCP').LocalPort
        $udp = ($script:Created | Where-Object Protocol -EQ 'UDP').LocalPort
        foreach ($p in '47984', '47989', '47990', '48010') { $tcp | Should -Contain $p }
        foreach ($p in '47998', '47999', '48000') { $udp | Should -Contain $p }
    }

    It 'suit le port de base de sunshine.conf' {
        Invoke-RemoteFirewall -Config $script:Cfg -BasePort 50000 | Out-Null
        ($script:Created | Where-Object Protocol -EQ 'TCP').LocalPort | Should -Contain '49995'
    }

    It 'désactive les règles larges ENTRANTES actives de l''installeur, et elles seules' {
        Invoke-RemoteFirewall -Config $script:Cfg | Out-Null
        Should -Invoke Set-NetFirewallRule -Times 2 -Exactly -ParameterFilter { "$Enabled" -eq 'False' }
        Should -Invoke Set-NetFirewallRule -Times 1 -Exactly -ParameterFilter { $Name -eq '{wide-tcp}' }
        Should -Invoke Set-NetFirewallRule -Times 0 -Exactly -ParameterFilter { $Name -eq '{out}' -or $Name -eq '{deja-off}' }
    }

    It 'idempotent : règles déjà présentes remises en conformité, sans doublon' {
        Mock Get-NetFirewallRule -ParameterFilter { $Name } { [pscustomobject]@{ Name = $Name } }
        Invoke-RemoteFirewall -Config $script:Cfg | Out-Null
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
        Should -Invoke Set-NetFirewallRule -Times 2 -Exactly -ParameterFilter { $Name -like 'ResetPack-*' -and ((@($RemoteAddress) | Sort-Object) -join '|') -eq '100.64.0.0/10|fd7a:115c:a1e0::/48' }
    }

    It 'réactive un profil de pare-feu coupé' {
        Mock Get-NetFirewallProfile { @([pscustomobject]@{ Name = 'Public'; Enabled = 'False' }) }
        Invoke-RemoteFirewall -Config $script:Cfg | Out-Null
        Should -Invoke Set-NetFirewallProfile -Times 1 -Exactly -ParameterFilter { $Name -eq 'Public' }
    }

    It 'dry-run : aucune règle créée ni modifiée' {
        $script:DryRun = $true
        Invoke-RemoteFirewall -Config $script:Cfg | Out-Null
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
        Should -Invoke Set-NetFirewallRule -Times 0 -Exactly
        Should -Invoke Set-NetFirewallProfile -Times 0 -Exactly
    }
}

Describe 'alimentation, auto-login, Tailscale (mockés)' {
    BeforeEach {
        $script:DryRun = $false
        $script:Auto = $true
        Mock Write-Host { }
        Mock powercfg { $global:LASTEXITCODE = 0 }
        Mock Resolve-TailscaleCli { $true }
        $script:TsState = 'Running'
        $script:TsHelp = "USAGE`n  --unattended, --unattended=false`n    run in Unattended Mode"
        Mock tailscale {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'status') { return ('{"BackendState":"' + $script:TsState + '","Self":{"DNSName":"omen.tailnet.ts.net.","TailscaleIPs":["100.101.102.103"]},"CurrentTailnet":{"MagicDNSEnabled":true}}') }
            if ($args[0] -eq 'set' -and $args -contains '--help') { return $script:TsHelp }
        }
    }

    It 'powercfg : jamais de veille ni d''hibernation sur secteur' {
        Invoke-RemotePower -Config $script:Cfg
        Should -Invoke powercfg -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq '/change standby-timeout-ac 0' }
        Should -Invoke powercfg -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq '/change hibernate-timeout-ac 0' }
        Should -Invoke powercfg -Times 0 -Exactly -ParameterFilter { ($args -join ' ') -match 'monitor' }
    }

    It 'powercfg : rien en dry-run' {
        $script:DryRun = $true
        Invoke-RemotePower -Config $script:Cfg
        Should -Invoke powercfg -Times 0 -Exactly
    }

    It 'auto-login actif : alerte (renvoie $false) sans rien modifier' {
        Mock Get-ItemProperty { [pscustomobject]@{ AutoAdminLogon = '1'; DefaultPassword = 'x' } }
        Mock Set-ItemProperty { }
        Test-AutoLogon | Should -BeFalse
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It 'pas d''auto-login : renvoie $true' {
        Mock Get-ItemProperty { [pscustomobject]@{ AutoAdminLogon = '0' } }
        Test-AutoLogon | Should -BeTrue
    }

    It 'Tailscale connecté : tailscale set --unattended=true, jamais up' {
        Invoke-TailscaleUnattended -Config $script:Cfg | Should -Be 'ok'
        Should -Invoke tailscale -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'set --unattended=true' }
        Should -Invoke tailscale -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'up' }
    }

    It 'Tailscale ancienne CLI (set sans --unattended) : repli sur tailscale up --unattended' {
        $script:TsHelp = 'USAGE  --ssh'
        Invoke-TailscaleUnattended -Config $script:Cfg | Out-Null
        Should -Invoke tailscale -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'up --unattended' }
    }

    It 'Tailscale pas connecté en mode Auto : affiche les instructions, ne lance ni up ni set' {
        $script:TsState = 'NeedsLogin'
        Invoke-TailscaleUnattended -Config $script:Cfg | Should -Be 'needs-login'
        Should -Invoke tailscale -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'up' -or ($args[0] -eq 'set' -and $args -notcontains '--help') }
    }

    It 'Tailscale en dry-run : ne modifie rien' {
        $script:DryRun = $true
        Invoke-TailscaleUnattended -Config $script:Cfg | Out-Null
        Should -Invoke tailscale -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'up' -or ($args[0] -eq 'set' -and $args -notcontains '--help') }
    }
}

Describe 'Invoke-RemoteModule (bout en bout, tout mocké)' {
    BeforeEach {
        $script:Auto = $true
        Mock Write-Host { }
        Mock New-NetFirewallRule { }
        Mock Set-NetFirewallRule { }
        Mock Set-NetFirewallProfile { }
        Mock Get-NetFirewallProfile { @([pscustomobject]@{ Name = 'Public'; Enabled = 'True' }) }
        Mock Get-NetFirewallRule { $null }
        Mock powercfg { $global:LASTEXITCODE = 0 }
        Mock tailscale {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'status') { return '{"BackendState":"Running","Self":{"DNSName":"omen.","TailscaleIPs":["100.64.1.2"]}}' }
            if ($args -contains '--help') { return '--unattended' }
        }
        Mock Resolve-TailscaleCli { $true }
        Mock Register-ScheduledTask { }
        Mock Invoke-WebRequest { }
        Mock Expand-Archive { }
        Mock Get-Service { $null }
        Mock Restart-Service { }
        Mock Test-AutoLogon { $true }
        Mock icacls { $global:LASTEXITCODE = 0 }
        $script:SunDir = Join-Path $TestDrive ('Sunshine-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:SunDir 'config') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SunDir 'config\sunshine.conf') -Value 'sunshine_name = OMEN' -Encoding ASCII
        Mock Find-SunshineInstall {
            [pscustomobject]@{ Dir = $script:SunDir; Exe = (Join-Path $script:SunDir 'sunshine.exe'); Conf = (Join-Path $script:SunDir 'config\sunshine.conf') }
        }
        $script:ToolsDir = Join-Path $TestDrive ('Tools-' + [guid]::NewGuid().ToString('N'))
    }

    It 'profil exodius (client) : aucune règle de pare-feu, aucun powercfg, aucun tailscale, aucune tâche' {
        $script:DryRun = $false
        Invoke-RemoteModule -ProfileName 'exodius' -ToolsDir $script:ToolsDir | Should -Be 'client'
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
        Should -Invoke Set-NetFirewallRule -Times 0 -Exactly
        Should -Invoke Set-NetFirewallProfile -Times 0 -Exactly
        Should -Invoke powercfg -Times 0 -Exactly
        Should -Invoke tailscale -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'up' -or $args[0] -eq 'set' }
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        Should -Invoke icacls -Times 0 -Exactly
        Test-Path $script:ToolsDir | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $script:SunDir 'config\sunshine.conf')).Trim() | Should -Be 'sunshine_name = OMEN'
    }

    It 'profil lu dans RESETPACK_PROFILE (exodius) : sortie propre côté client' {
        $script:DryRun = $false
        $env:RESETPACK_PROFILE = 'exodius'
        try { Invoke-RemoteModule | Should -Be 'client' } finally { $env:RESETPACK_PROFILE = $script:SavedEnv.RESETPACK_PROFILE }
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
    }

    It 'profil omen en dry-run : rien écrit, rien exécuté' {
        $script:DryRun = $true
        $conf = Join-Path $script:SunDir 'config\sunshine.conf'
        $hash = (Get-FileHash $conf).Hash
        Invoke-RemoteModule -ProfileName 'omen' -ToolsDir $script:ToolsDir | Should -Be 'host'
        (Get-FileHash $conf).Hash | Should -Be $hash
        Test-Path $script:ToolsDir | Should -BeFalse
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
        Should -Invoke Set-NetFirewallRule -Times 0 -Exactly
        Should -Invoke powercfg -Times 0 -Exactly
        Should -Invoke tailscale -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'up' -or ($args[0] -eq 'set' -and $args -notcontains '--help') }
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        Should -Invoke icacls -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Restart-Service -Times 0 -Exactly
    }

    It 'profil omen, mutations mockées : scripts + settings.json, tâche de secours à la demande, sunshine.conf, règles Tailscale' {
        $script:DryRun = $false
        Mock Test-Admin { $true }
        Mock Install-MultiMonitorTool { }
        Invoke-RemoteModule -ProfileName 'omen' -ToolsDir $script:ToolsDir | Should -Be 'host'

        foreach ($f in $script:MonoScripts) { Test-Path (Join-Path $script:ToolsDir "remote\$f") | Should -BeTrue }
        $settings = Get-Content (Join-Path $script:ToolsDir 'remote\settings.json') -Raw | ConvertFrom-Json
        $settings.mmtPath | Should -Be (Join-Path $script:ToolsDir 'MultiMonitorTool\MultiMonitorTool.exe')
        $settings.keepMonitor | Should -Be 'primary'

        # Dossier des scripts : écriture réservée aux admins/SYSTEM, Utilisateurs en lecture/exécution seulement
        Should -Invoke icacls -Times 1 -Exactly -ParameterFilter {
            ($args -contains '/inheritance:r') -and ($args -contains '*S-1-5-32-545:(OI)(CI)RX') -and -not ($args -match 'S-1-5-32-545:\(OI\)\(CI\)[FM]')
        }

        Should -Invoke Register-ScheduledTask -Times 3 -Exactly
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'ResetPack-ReactiverEcrans' -and $null -eq $Trigger -and $Action.Arguments -match 'reactiver-ecrans\.ps1' -and $Principal.RunLevel -eq 'Limited'
        }

        $lines = [IO.File]::ReadAllLines((Join-Path $script:SunDir 'config\sunshine.conf'))
        $items = Read-JsonArray (Get-SunshineConfValue -Lines $lines -Key 'global_prep_cmd')
        $items[0].do | Should -Match ([regex]::Escape((Join-Path $script:ToolsDir 'remote\mono-ecran-on.ps1')))

        Should -Invoke New-NetFirewallRule -Times 2 -Exactly -ParameterFilter { ((@($RemoteAddress) | Sort-Object) -join '|') -eq '100.64.0.0/10|fd7a:115c:a1e0::/48' }
        Should -Invoke New-NetFirewallRule -Times 2 -Exactly
        Should -Invoke powercfg -Times 2 -Exactly
        Should -Invoke tailscale -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'set --unattended=true' }
    }
}
