# Tests Pester 5+ des fondations OMEN : profils, layout de stockage, chemins canoniques, formatage SSD,
# bundles, migration. Rien n'est installé, formaté ni modifié hors de $TestDrive.
#   Invoke-Pester -Path .\tests
BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    . "$Repo\modules\00-helpers.ps1"
}

Describe 'config/profiles.json + catalogue de reset.ps1' {
    BeforeAll {
        $script:prof = (Get-Content "$Repo\config\profiles.json" -Raw | ConvertFrom-Json).profiles
        $script:catalog = [regex]::Matches((Get-Content "$Repo\reset.ps1" -Raw), "Key='([^']+)';\s*File='([^']+)'") |
            ForEach-Object { [pscustomobject]@{ Key = $_.Groups[1].Value; File = $_.Groups[2].Value } }
    }
    It "le profil omen n'inclut JAMAIS debloat ni drivers" {
        $prof.omen.modules | Should -Not -Contain 'debloat'
        $prof.omen.modules | Should -Not -Contain 'drivers'
        $prof.omen.forbidden | Should -Contain 'debloat'
        $prof.omen.forbidden | Should -Contain 'drivers'
    }
    It 'aucun profil ne liste un module qui lui est interdit' {
        foreach ($p in $prof.PSObject.Properties) {
            @($p.Value.modules | Where-Object { $p.Value.forbidden -contains $_ }) | Should -BeNullOrEmpty -Because $p.Name
        }
    }
    It 'chaque module de profil existe dans le catalogue ET sur disque' {
        foreach ($p in $prof.PSObject.Properties) {
            foreach ($k in $p.Value.modules) {
                $m = $catalog | Where-Object Key -eq $k
                $m | Should -Not -BeNullOrEmpty -Because "$($p.Name) : $k"
                (Test-Path "$Repo\modules\$($m.File)") | Should -BeTrue -Because $m.File
            }
        }
    }
    It "respecte les dépendances d'ordre du profil omen" {
        $o = @($prof.omen.modules)
        $o[0] | Should -Be 'hp-triage'
        $o.IndexOf('gaming')    | Should -BeGreaterThan $o.IndexOf('tweaks')     # rallume le Game Mode coupé par tweaks
        $o.IndexOf('ml')        | Should -BeGreaterThan $o.IndexOf('dev-setup')  # WSL installé
        $o.IndexOf('ml')        | Should -BeGreaterThan $o.IndexOf('storage')    # chemins posés
        $o.IndexOf('scheduled') | Should -BeGreaterThan $o.IndexOf('remote')
        $o[-1] | Should -Be 'finalize'
    }
}

Describe 'config/storage-layout.json' {
    It 'omen : rien d''écriture intensive sur D: (Docker/WSL/ML chaud/code)' {
        $l = Get-StorageLayout -Name omen
        @($l.dirs | Where-Object { $_ -match '^(?i)D:\\(Docker|WSL|Code|ml\\)' }) | Should -BeNullOrEmpty
        foreach ($p in $l.env.PSObject.Properties) { $p.Value | Should -Not -Match '^(?i)D:' -Because $p.Name }
        $l.wsl.location | Should -Match '^(?i)C:'
    }
    It 'omen : SSD jeux = P310 en D:' {
        $g = (Get-StorageLayout -Name omen).gamesDisk
        $g.letter | Should -Be 'D'
        $g.modelMatch | Should -Be 'P310'
    }
    It 'les 2 profils partagent le MÊME chemin canonique des projets' {
        (Get-StorageLayout -Name omen).projetsCode    | Should -Be 'C:\Dev\03_Projets_Code'
        (Get-StorageLayout -Name exodius).projetsCode | Should -Be 'C:\Dev\03_Projets_Code'
        $script:CanonicalProjets | Should -Be 'C:\Dev\03_Projets_Code'
    }
    It 'résout les jetons {OneDrive}/{UserProfile}' {
        $raw = (Get-StorageLayout -Name exodius) | ConvertTo-Json -Depth 6
        $raw | Should -Not -Match '\{OneDrive\}|\{UserProfile\}'
        (Get-StorageLayout -Name exodius).projetsCodeJunctionTo | Should -BeLike "$script:OneDriveRoot*"
    }
    It 'refuse un profil inconnu' {
        { Get-StorageLayout -Name 'inconnu' } | Should -Throw
    }
}

Describe 'ConvertTo-CanonicalProjetsPath' {
    It 'réécrit le style <_>' -ForEach @(
        @{ In = 'C:\Users\tomle\OneDrive\Documents\03_Projets_Code\2026\X';            Out = 'C:\Dev\03_Projets_Code\2026\X' }
        @{ In = 'C:\\Users\\tomle\\OneDrive\\Documents\\03_Projets_Code\\2026\\X';     Out = 'C:\\Dev\\03_Projets_Code\\2026\\X' }
        @{ In = 'C:/Users/tomle/OneDrive/Documents/03_Projets_Code/Claude/hook.js';    Out = 'C:/Dev/03_Projets_Code/Claude/hook.js' }
        @{ In = 'c:\users\Autre.Nom\OneDrive\Documents\03_Projets_Code';               Out = 'C:\Dev\03_Projets_Code' }
    ) {
        ConvertTo-CanonicalProjetsPath -Text $In | Should -BeExactly $Out
    }
    It 'ne touche pas aux autres chemins OneDrive' {
        $t = 'C:\Users\tomle\OneDrive\Documents\08_Logiciels\Configs ; C:\Users\tomle\.claude\x'
        ConvertTo-CanonicalProjetsPath -Text $t | Should -BeExactly $t
    }
    It 'garde un JSON valide' {
        $j = '{"args":["C:\\Users\\tomle\\OneDrive\\Documents\\03_Projets_Code\\2026\\Atlas\\poste\\atlas-mcp.mjs"]}'
        ((ConvertTo-CanonicalProjetsPath -Text $j) | ConvertFrom-Json).args[0] | Should -Be 'C:\Dev\03_Projets_Code\2026\Atlas\poste\atlas-mcp.mjs'
    }
}

Describe 'Get-ProjetsRoots / Find-GitRepos' {
    BeforeAll {
        $script:real = Join-Path $TestDrive 'OneDriveProjets'
        foreach ($d in '2026\A\.git', '2026\B\sub\.git', '2026\A\node_modules\dep\.git', 'Divers\notes') {
            New-Item -ItemType Directory -Force -Path (Join-Path $real $d) | Out-Null
        }
        $script:junction = Join-Path $TestDrive 'Dev\03_Projets_Code'
        New-Item -ItemType Directory -Force -Path (Split-Path $junction) | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $real | Out-Null
    }
    It 'trouve les dépôts sans descendre dans un dépôt ni dans node_modules' {
        $r = @(Find-GitRepos -Root $real -MaxDepth 3)
        $r.Count | Should -Be 2
        @(Find-GitRepos -Root (Join-Path $TestDrive 'absent')).Count | Should -Be 0
        ($r -join '|') | Should -Not -Match 'node_modules'
    }
    It 'dédoublonne une jonction et sa cible' {
        Mock Get-StorageLayout { [pscustomobject]@{ projetsCode = $junction; legacyProjetsRoots = @($real) } }
        $env:PROJETS_CODE = $junction
        try {
            $mine = @(Get-ProjetsRoots) | Where-Object { $_ -like "$TestDrive*" }
            @($mine).Count | Should -Be 1
        }
        finally { $env:PROJETS_CODE = $null }
    }
}

Describe 'format-ssd-jeux.ps1 (aucun disque réel touché)' {
    BeforeAll {
        . "$Repo\format-ssd-jeux.ps1"
        function New-FakeDisk($n, $name, $gb, [switch]$Boot, [switch]$Sys, $bus = 'NVMe') {
            [pscustomobject]@{ Number = $n; FriendlyName = $name; Model = $name; Serial = "S$n"; BusType = $bus; SizeGB = $gb
                PartitionStyle = 'GPT'; IsBoot = [bool]$Boot; IsSystem = [bool]$Sys; IsOffline = $false; IsReadOnly = $false
                Letters = @(); HasSystemDrive = [bool]$Sys; HasPagefile = $false; Partitions = @() }
        }
        $script:sys  = New-FakeDisk 0 'HP SSD EX950 1TB' 954 -Boot -Sys
        $script:p310 = New-FakeDisk 1 'CT1000P310SSD8' 932
    }
    It 'choisit le P310 et lui seul' {
        (Select-GamesDisk -Inventory @($sys, $p310) -Match 'P310').Number | Should -Be 1
    }
    It 'refuse le disque système même si -DiskNumber le désigne' {
        { Select-GamesDisk -Inventory @($sys, $p310) -Match 'P310' -Number 0 } | Should -Throw '*Aucun disque acceptable*'
    }
    It 'refuse un disque système qui matcherait le modèle' {
        $evil = New-FakeDisk 0 'CT1000P310SSD8' 932 -Boot -Sys
        (Get-GamesDiskRefusal -Disk $evil -Match 'P310') | Should -Contain 'disque système'
        { Select-GamesDisk -Inventory @($evil) -Match 'P310' } | Should -Throw
    }
    It 'refuse une clé USB / une taille incohérente' {
        (Get-GamesDiskRefusal -Disk (New-FakeDisk 2 'P310 USB' 932 -bus 'USB') -Match 'P310') -join ',' | Should -Match 'bus USB'
        (Get-GamesDiskRefusal -Disk (New-FakeDisk 3 'CT2000P310SSD8' 1863) -Match 'P310') -join ',' | Should -Match 'taille'
    }
    It "exige -DiskNumber s'il y a 2 candidats" {
        { Select-GamesDisk -Inventory @($p310, (New-FakeDisk 4 'CT1000P310SSD8' 932)) -Match 'P310' } | Should -Throw '*-DiskNumber*'
    }
    It "en dry-run, n'efface ni ne formate rien" {
        Mock Clear-Disk { }; Mock Initialize-Disk { }; Mock New-Partition { }; Mock Format-Volume { }; Mock Optimize-Volume { }; Mock Set-Disk { }
        $DryRun = $true
        Invoke-FormatGamesDisk -Disk $p310 -Letter 'D' -VolumeLabel 'Jeux'
        Should -Invoke Clear-Disk -Times 0 -Exactly
        Should -Invoke Format-Volume -Times 0 -Exactly
    }
    It "le switch -DryRun n'est pas écrasé par 00-helpers (bug de portée)" {
        $src = Get-Content "$Repo\format-ssd-jeux.ps1" -Raw
        $src | Should -Match '\$isDry = \$DryRun\.IsPresent'
        $src.IndexOf('$isDry = $DryRun.IsPresent') | Should -BeLessThan $src.IndexOf('modules\00-helpers.ps1"')
    }
}

Describe 'Scripts racine : le switch -DryRun survit au dot-source de 00-helpers' {
    It '<_> capture -DryRun avant 00-helpers' -ForEach @('backup-bundles.ps1', 'migrate-projets.ps1', 'backup-datasets.ps1', 'format-ssd-jeux.ps1') {
        $src = Get-Content (Join-Path $Repo $_) -Raw
        $src.IndexOf('$isDry = $DryRun.IsPresent') | Should -BeGreaterThan -1
        $src.IndexOf('$isDry = $DryRun.IsPresent') | Should -BeLessThan $src.IndexOf('modules\00-helpers.ps1"')
    }
}

Describe 'migrate-projets.ps1 (TestDrive)' {
    BeforeAll { . "$Repo\migrate-projets.ps1" }
    It 'préfère le remote, puis le bundle, puis le dossier local' {
        (Get-CloneSource -Item ([pscustomobject]@{ Remote = 'git@x:r.git'; Bundle = 'b'; SourcePath = 's' })).Kind | Should -Be 'remote'
        (Get-CloneSource -Item ([pscustomobject]@{ Remote = ''; Bundle = 'b'; SourcePath = 's' })).Kind | Should -Be 'bundle'
        (Get-CloneSource -Item ([pscustomobject]@{ Remote = ''; Bundle = $null; SourcePath = 's' })).Kind | Should -Be 'local'
    }
    It 'réécrit un JSON consommateur, garde un backup et un JSON valide' {
        $f = Join-Path $TestDrive 'settings.json'
        '{"hooks":{"Stop":[{"command":"node \"C:/Users/tomle/OneDrive/Documents/03_Projets_Code/Claude-Code-Agent-Monitor/scripts/hook-handler.js\" Stop"}]}}' |
            Set-Content $f -Encoding UTF8
        $DryRun = $false
        Update-ConsumerFile -Path $f -Real $f -AppRunning $false | Should -Be 'réécrit'
        (Get-Content $f -Raw | ConvertFrom-Json).hooks.Stop[0].command | Should -Match 'C:/Dev/03_Projets_Code/'
        @(Get-ChildItem $TestDrive -Filter 'settings.json.before-migrate-*').Count | Should -Be 1
    }
    It 'saute .claude.json quand Claude est ouvert' {
        $f = Join-Path $TestDrive '.claude.json'
        '{"p":"C:\\Users\\tomle\\OneDrive\\Documents\\03_Projets_Code\\x"}' | Set-Content $f -Encoding UTF8
        $DryRun = $false
        Update-ConsumerFile -Path $f -Real $f -AppRunning $true | Should -Be 'sauté'
        Get-Content $f -Raw | Should -Match 'OneDrive'
    }
    It 'rattache la mémoire Claude Code au nouveau chemin' {
        $old = $env:USERPROFILE
        try {
            $env:USERPROFILE = Join-Path $TestDrive 'home'
            $script:ConfigsRoot = Join-Path $TestDrive 'Configs'
            $src = Join-Path $env:USERPROFILE '.claude\projects\C--Users-tomle-OneDrive-Documents-03-Projets-Code-2026-Reset-pack\memory'
            New-Item -ItemType Directory -Force -Path $src | Out-Null
            'fait' | Set-Content (Join-Path $src 'MEMORY.md')
            $DryRun = $false
            Copy-ClaudeMemory -NewRoot 'C:\Dev\03_Projets_Code'
            Test-Path (Join-Path $env:USERPROFILE '.claude\projects\C--Dev-03-Projets-Code-2026-Reset-pack\memory\MEMORY.md') | Should -BeTrue
        } finally { $env:USERPROFILE = $old }
    }
}

Describe 'backup-bundles.ps1 (dépôt git jetable)' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        . "$Repo\backup-bundles.ps1"
        $script:root = Join-Path $TestDrive 'projets'
        $script:repo = Join-Path $root '2026\Demo'
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        git -C $repo init -q 2>$null
        'x' | Set-Content (Join-Path $repo 'a.txt')
        git -C $repo add . 2>$null
        git -C $repo -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init 2>$null
        $script:out = Join-Path $TestDrive 'bundles'
        Mock Get-ProjetsRoots { $root }
    }
    It 'crée un bundle vérifié et le manifest' {
        $Dest = $out; $DryRun = $false; $Quiet = $true; $Force = $false; $WarnSizeMB = 2048; $MaxSizeMB = 8192
        Invoke-BackupBundles
        Test-Path (Join-Path $out '2026__Demo.bundle') | Should -BeTrue
        $m = Get-Content (Join-Path $out 'manifest.json') -Raw | ConvertFrom-Json
        $m.entries[0].rel | Should -Be '2026\Demo'
    }
    It "ne refait pas un bundle si les refs n'ont pas bougé" {
        $Dest = $out; $DryRun = $false; $Quiet = $true; $Force = $false; $WarnSizeMB = 2048; $MaxSizeMB = 8192
        $before = (Get-Item (Join-Path $out '2026__Demo.bundle')).LastWriteTimeUtc
        Start-Sleep -Milliseconds 1100
        Invoke-BackupBundles
        (Get-Item (Join-Path $out '2026__Demo.bundle')).LastWriteTimeUtc | Should -Be $before
    }
}

Describe 'Encodage' {
    It '<_> est en UTF-8 AVEC BOM (sinon PowerShell 5.1 casse les accents)' -ForEach (
        Get-ChildItem (Split-Path $PSScriptRoot -Parent) -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\logs\\' } | ForEach-Object FullName) {
        $b = [IO.File]::ReadAllBytes($_)
        ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
    }
    It '<_> est en LF (bash dans WSL)' -AllowNullOrEmptyForEach -ForEach (
        @(Get-ChildItem (Split-Path $PSScriptRoot -Parent) -Recurse -Filter *.sh | ForEach-Object FullName)) {
        [IO.File]::ReadAllText($_) | Should -Not -Match "`r"
    }
}
