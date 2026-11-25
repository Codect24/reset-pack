# Tests Pester 5+ du lot 3 (deep learning) : modules/14-ml.ps1, scripts/ml-smoke-test.ps1,
# scripts/wsl-ml-setup.sh, templates/wslconfig.ini.
# wsl / nvidia-smi / docker sont remplacés par des stubs (une fonction passe avant l'exe) puis mockés :
# aucun exe réel n'est lancé, tout ce qui s'écrit va dans $TestDrive.
#   Invoke-Pester -Path .\tests\Ml.Tests.ps1
BeforeDiscovery {
    $script:GitBash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    # Fichiers du lot scannés pour les paquets interdits (ce fichier de test est exclu : il contient les motifs).
    $script:LotFiles = @('modules/14-ml.ps1', 'scripts/ml-smoke-test.ps1', 'scripts/wsl-ml-setup.sh', 'templates/wslconfig.ini')
}

Describe 'Lot 3 - deep learning (14-ml)' {
    BeforeAll {
        $script:Repo = Split-Path $PSScriptRoot -Parent
        $script:SavedEnv = @{
            Profile = $env:RESETPACK_PROFILE; DryRun = $env:RESETPACK_DRYRUN; Auto = $env:RESETPACK_AUTO; WslUtf8 = $env:WSL_UTF8
        }
        $env:RESETPACK_PROFILE = 'omen'
        $env:RESETPACK_DRYRUN = ''
        $env:RESETPACK_AUTO = ''

        # Garde-fou : si un mock manquait, le stub échoue au lieu de lancer le vrai wsl / docker.
        foreach ($n in 'wsl', 'nvidia-smi', 'docker') {
            Set-Item -Path "Function:script:$n" -Value ([scriptblock]::Create("throw 'appel réel de $n interdit dans les tests'"))
        }

        . "$script:Repo\modules\14-ml.ps1"
        $script:DownloadDir = Join-Path $TestDrive 'dl'

        # Vrai %USERPROFILE%\.wslconfig : on vérifie à la fin qu'il n'a pas bougé.
        $script:RealWslConfig = Join-Path $env:USERPROFILE '.wslconfig'
        $script:RealWslConfigHash = $null
        if (Test-Path $script:RealWslConfig) { $script:RealWslConfigHash = (Get-FileHash $script:RealWslConfig).Hash }

        function Set-FakeExitCode {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
            param([int]$Code)
            Set-Variable -Name LASTEXITCODE -Value $Code -Scope Global
        }

        function Get-AptInstallViolation {
            # Paquets interdits (pilote NVIDIA Linux, cuda-drivers, méta-paquet cuda) visés par une commande apt install.
            param([string]$Text)
            $joined = $Text -replace '\\\r?\n', ' '   # continuations de ligne bash
            $bad = @()
            foreach ($line in ($joined -split '\r?\n')) {
                $m = [regex]::Match($line, '\bapt(?:-get)?\b(?:\s+-{1,2}[\w-]+(?:=\S+)?)*\s+install\b(?<rest>.*)$')
                if (-not $m.Success) { continue }
                foreach ($tok in ($m.Groups['rest'].Value -split '[\s;|&()]+')) {
                    $t = $tok.Trim('"', "'")
                    if ($t -match '^(nvidia-driver.*|cuda-drivers.*|cuda)([=:].*)?$') { $bad += "$t <= $($line.Trim())" }
                }
            }
            return $bad
        }

        function Invoke-GitBash {
            param([string[]]$Arguments)
            $out = & $script:GitBashExe @Arguments 2>&1 | ForEach-Object { "$_" }
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
        }

        function ConvertTo-LfFile {
            param([string]$Path, [string[]]$Lines)
            [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
            return $Path
        }

        $script:GitBashExe = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") |
            Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }

    AfterAll {
        $env:RESETPACK_PROFILE = $script:SavedEnv.Profile
        $env:RESETPACK_DRYRUN = $script:SavedEnv.DryRun
        $env:RESETPACK_AUTO = $script:SavedEnv.Auto
        $env:WSL_UTF8 = $script:SavedEnv.WslUtf8
    }

    BeforeEach {
        $env:RESETPACK_PROFILE = 'omen'
        $script:DryRun = $false
        $script:Auto = $false
        $script:Fake = @{
            SmiExit        = 0
            SmiOut         = @('NVIDIA GeForce RTX 5080, 581.57')
            Distros        = @('Ubuntu', 'docker-desktop')
            IdU            = '1000'
            ProvisionExit  = 0
            SmokeExit      = 0
            SmokeOut       = @('  -> bla', 'RESETPACK_SMOKE torch=2.9.1+cu128', 'RESETPACK_SMOKE cuda=1',
                'RESETPACK_SMOKE gpu=NVIDIA GeForce RTX 5080', 'RESETPACK_SMOKE capability=12.0')
            DockerInfoExit = 0
            DockerRunExit  = 0
        }
        # Dans les mocks : $Fake SANS 'script:' -> recherche dans la chaîne des portées. Appelé depuis
        # '& ml-smoke-test.ps1', '$script:' désignerait la portée de CE script (où Fake n'existe pas).
        Mock nvidia-smi { Set-FakeExitCode $Fake.SmiExit; $Fake.SmiOut }
        Mock wsl {
            $line = "$args"
            if ($line -match '--list') { Set-FakeExitCode 0; return $Fake.Distros }
            if ($line -match '--exec id -u') { Set-FakeExitCode 0; return $Fake.IdU }
            if ($line -match '--smoke-only') { Set-FakeExitCode $Fake.SmokeExit; return $Fake.SmokeOut }
            if ($line -match '--exec bash') { Set-FakeExitCode $Fake.ProvisionExit; return }
            Set-FakeExitCode 1
        }
        Mock docker {
            $line = "$args"
            if ($line -match '^info') { Set-FakeExitCode $Fake.DockerInfoExit; return '27.3.1' }
            if ($line -match '^run ') { Set-FakeExitCode $Fake.DockerRunExit; return 'GPU 0: RTX 5080' }
            Set-FakeExitCode 1
        }
        Mock Get-PhysicalMemoryGB { 32 }
        Mock Get-LogicalProcessorCount { 24 }
        Mock Test-NvidiaAdapter { $true }
        Mock Get-WslDistroRegistration { [pscustomobject]@{ Name = 'Ubuntu'; BasePath = 'C:\WSL\Ubuntu'; DefaultUid = 1000 } }
    }

    Context 'calcul memory / processors' {
        It '<Total> Go de RAM -> memory=<Expected>GB' -ForEach @(
            @{ Total = 32; Expected = 18 }, @{ Total = 64; Expected = 36 }, @{ Total = 16; Expected = 9 }, @{ Total = 48; Expected = 27 }
        ) {
            Get-WslMemoryGB -TotalGB $Total | Should -Be $Expected
        }
        It 'ne descend jamais sous 2 Go' {
            Get-WslMemoryGB -TotalGB 2 | Should -Be 2
        }
        It '<Logical> cœurs logiques -> processors=<Expected>' -ForEach @(
            @{ Logical = 24; Expected = 20 }, @{ Logical = 16; Expected = 13 }, @{ Logical = 12; Expected = 9 },
            @{ Logical = 8; Expected = 6 }, @{ Logical = 4; Expected = 2 }, @{ Logical = 1; Expected = 1 }
        ) {
            Get-WslProcessorCount -LogicalProcessors $Logical | Should -Be $Expected
        }
        It 'laisse toujours 2 à 4 cœurs logiques à Windows (6 à 64 cœurs)' {
            foreach ($l in 6..64) {
                $reserve = $l - (Get-WslProcessorCount -LogicalProcessors $l)
                $reserve | Should -BeGreaterOrEqual 2
                $reserve | Should -BeLessOrEqual 4
            }
        }
    }

    Context 'templates/wslconfig.ini -> .wslconfig' {
        BeforeAll {
            $script:Cfg = Get-WslConfigContent -Template ([IO.File]::ReadAllText("$script:Repo\templates\wslconfig.ini")) -MemoryGB 18 -Processors 20
            # mini-parseur ini : clé -> section
            $script:Sections = @{}
            $section = ''
            foreach ($l in ($script:Cfg -split "`r`n")) {
                if ($l -match '^\[(.+)\]$') { $section = $Matches[1] }
                elseif ($l -match '^([A-Za-z]+)=(.*)$') { $script:Sections["$($Matches[1])=$($Matches[2])"] = $section }
            }
        }
        It 'remplace les jetons (memory=18GB, processors=20) sans en laisser' {
            $script:Sections['memory=18GB'] | Should -Be 'wsl2'
            $script:Sections['processors=20'] | Should -Be 'wsl2'
            $script:Cfg | Should -Not -Match '\{\{'
        }
        It 'garde swap=16GB dans [wsl2]' {
            $script:Sections['swap=16GB'] | Should -Be 'wsl2'
        }
        It 'contient sparseVhd=true et autoMemoryReclaim=gradual dans [experimental]' {
            $script:Sections['sparseVhd=true'] | Should -Be 'experimental'
            $script:Sections['autoMemoryReclaim=gradual'] | Should -Be 'experimental'
        }
        It 'est en CRLF de bout en bout' {
            ($script:Cfg -replace "`r`n", '') | Should -Not -Match "`n"
        }
        It 'refuse un modèle avec un jeton inconnu' {
            { Get-WslConfigContent -Template "memory={{MEMORY}}`nfoo={{FOO}}" -MemoryGB 1 -Processors 1 } | Should -Throw '*FOO*'
        }
    }

    Context 'Write-WslConfigFile' {
        It 'dry-run : ne crée aucun fichier' {
            $script:DryRun = $true
            $p = Join-Path $TestDrive 'w-dry\.wslconfig'
            New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
            Write-WslConfigFile -Path $p -Content "[wsl2]`r`nmemory=18GB`r`n" 6>$null | Should -Be 'dry'
            Test-Path $p | Should -BeFalse
        }
        It 'crée le fichier (UTF-8 sans BOM) puis le laisse tel quel s''il est identique' {
            $p = Join-Path $TestDrive 'w-idem\.wslconfig'
            New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
            Write-WslConfigFile -Path $p -Content "[wsl2]`r`nmemory=18GB`r`n" 6>$null | Should -Be 'created'
            ([IO.File]::ReadAllBytes($p))[0] | Should -Not -Be 0xEF
            Write-WslConfigFile -Path $p -Content "[wsl2]`r`nmemory=18GB`r`n" 6>$null | Should -Be 'unchanged'
            @(Get-ChildItem (Split-Path $p) -Force).Count | Should -Be 1
        }
        It 'sauvegarde un .wslconfig différent (même à la casse près) avant de le réécrire' {
            $p = Join-Path $TestDrive 'w-diff\.wslconfig'
            New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
            Set-Content -Path $p -Value "[wsl2]`r`nmemory=18gb" -NoNewline
            Write-WslConfigFile -Path $p -Content "[wsl2]`r`nmemory=18GB`r`n" 6>$null | Should -Be 'updated'
            $bak = @(Get-ChildItem (Split-Path $p) -Force -Filter '.wslconfig.before-resetpack-*')
            $bak.Count | Should -Be 1
            Get-Content $bak[0].FullName -Raw | Should -BeExactly "[wsl2]`r`nmemory=18gb"
            Get-Content $p -Raw | Should -Match 'memory=18GB'
        }
    }

    Context 'Invoke-MlModule (wsl / nvidia-smi / docker mockés)' {
        BeforeEach {
            $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Case 'ML') | Out-Null
            $script:CfgPath = Join-Path $script:Case '.wslconfig'
            $script:PinPath = Join-Path $script:Case 'ML\driver-pin.txt'
        }

        It 'dry-run : aucun fichier créé, ni provisioning ni docker run' {
            $script:DryRun = $true
            # pas d'Out-String : sous PS 5.1 il coupe les lignes à la largeur de la console
            $out = (Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>&1 | ForEach-Object { "$_" }) -join "`n"
            Test-Path $script:CfgPath | Should -BeFalse
            Test-Path $script:PinPath | Should -BeFalse
            @(Get-ChildItem $script:Case -Recurse -File -Force).Count | Should -Be 0
            Should -Invoke wsl -Times 0 -ParameterFilter { "$args" -match '--exec bash' }
            Should -Invoke docker -Times 0 -ParameterFilter { "$args" -match '^run' }
            $out | Should -Match '\[dry\] wsl -d Ubuntu --cd ~ --exec bash /mnt/[a-z]/\S*wsl-ml-setup\.sh --smoke-test'
            $out | Should -Match '\[dry\] docker run --rm --gpus all nvidia/cuda:12\.8\.0-base-ubuntu24\.04 nvidia-smi'
        }

        It 'réel : .wslconfig, provisioning avec les variables du layout, Docker GPU, pilote épinglé' {
            Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null
            $cfg = Get-Content $script:CfgPath -Raw
            $cfg | Should -Match '(?m)^memory=18GB\r?$'
            $cfg | Should -Match '(?m)^processors=20\r?$'
            Should -Invoke wsl -Times 1 -Exactly -ParameterFilter {
                $l = "$args"
                $l -match '^-d Ubuntu --cd ~ --exec bash /mnt/[a-z]/\S*wsl-ml-setup\.sh --smoke-test' -and
                $l -match '--env HF_HOME=\$HOME/ml/hf' -and $l -match '--env TORCH_HOME=\$HOME/ml/torch' -and
                $l -notmatch 'HF_HUB_ENABLE_HF_TRANSFER' -and $l -notmatch '--non-interactive'
            }
            Should -Invoke docker -Times 1 -Exactly -ParameterFilter { "$args" -eq 'run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi' }
            Get-Content $script:PinPath | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \| pilote 581\.57 \| NVIDIA GeForce RTX 5080 \| torch-wsl=ok \| docker-gpu=ok$'
            $script:MlLastResult.TorchCuda | Should -BeTrue
            $script:MlLastResult.DockerGpu | Should -BeTrue
        }

        It 'est idempotent : 2e passage sans réécriture ni backup du .wslconfig' {
            Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null
            Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null
            $script:MlLastResult.WslConfig | Should -Be 'unchanged'
            @(Get-ChildItem $script:Case -Force -Filter '.wslconfig.before-resetpack-*').Count | Should -Be 0
            @(Get-Content $script:PinPath).Count | Should -Be 2
        }

        It 'Auto : passe --non-interactive au script WSL (sudo -n, jamais de prompt bloquant)' {
            $script:Auto = $true
            Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null
            Should -Invoke wsl -Times 1 -Exactly -ParameterFilter { "$args" -match '--smoke-test --non-interactive' }
        }

        It 'distro hors de layout.wsl.location : affiche --move, ne déplace rien, provisionne quand même' {
            Mock Get-WslDistroRegistration { [pscustomobject]@{ Name = 'Ubuntu'; BasePath = 'C:\Users\x\AppData\Local\wsl\{9ad1}'; DefaultUid = 1000 } }
            $out = (Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>&1 | ForEach-Object { "$_" }) -join "`n"
            $out | Should -Match ([regex]::Escape('wsl --manage Ubuntu --move C:\WSL\Ubuntu'))
            $out | Should -Match ([regex]::Escape('wsl --import Ubuntu C:\WSL\Ubuntu C:\WSL\Ubuntu-export.tar'))
            Should -Invoke wsl -Times 0 -ParameterFilter { "$args" -match '--move|--unregister|--import|--export|--shutdown' }
            Should -Invoke wsl -Times 1 -Exactly -ParameterFilter { "$args" -match '--exec bash' }
        }

        It 'distro absente : avertit sans provisionner ni échouer' {
            $script:Fake.Distros = @('Debian')
            { Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null } | Should -Not -Throw
            Should -Invoke wsl -Times 0 -ParameterFilter { "$args" -match '--exec bash' }
            Test-Path $script:CfgPath | Should -BeTrue
        }

        It 'distro sans compte (root par défaut) : ne provisionne pas' {
            Mock Get-WslDistroRegistration { [pscustomobject]@{ Name = 'Ubuntu'; BasePath = 'C:\WSL\Ubuntu'; DefaultUid = 0 } }
            $script:Fake.IdU = '0'
            Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null
            Should -Invoke wsl -Times 1 -Exactly -ParameterFilter { "$args" -match '--exec id -u' }
            Should -Invoke wsl -Times 0 -ParameterFilter { "$args" -match '--exec bash' }
        }

        It 'Docker muet : warning, jamais un échec' {
            $script:Fake.DockerInfoExit = 1
            { Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null } | Should -Not -Throw
            Should -Invoke docker -Times 0 -ParameterFilter { "$args" -match '^run' }
            $script:MlLastResult.DockerGpu | Should -BeNullOrEmpty
            Get-Content $script:PinPath | Should -Match 'docker-gpu=n/a$'
        }

        It 'Docker GPU KO : warning, jamais un échec' {
            $script:Fake.DockerRunExit = 125
            { Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null } | Should -Not -Throw
            $script:MlLastResult.DockerGpu | Should -BeFalse
        }

        It 'CUDA KO dans WSL (code 2) : le module échoue, le pilote est quand même noté' {
            $script:Fake.ProvisionExit = 2
            { Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null } | Should -Throw '*GPU*'
            Get-Content $script:PinPath | Should -Match 'torch-wsl=KO'
        }

        It 'provisioning en échec (code 1) : le module échoue' {
            $script:Fake.ProvisionExit = 1
            { Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null } | Should -Throw '*provisioning*'
        }

        It 'profil non omen sans GPU NVIDIA : return propre sans rien toucher' {
            $env:RESETPACK_PROFILE = 'exodius'
            $script:Fake.SmiExit = 9
            Mock Test-NvidiaAdapter { $false }
            { Invoke-MlModule -WslConfigPath $script:CfgPath -DriverPinPath $script:PinPath 6>$null } | Should -Not -Throw
            Should -Invoke wsl -Times 0
            Should -Invoke docker -Times 0
            Test-Path $script:CfgPath | Should -BeFalse
        }
    }

    Context 'helpers WSL' {
        It 'ConvertTo-WslPath : C:\a\b c\x.sh -> /mnt/c/a/b c/x.sh' {
            ConvertTo-WslPath 'C:\a\b c\x.sh' | Should -BeExactly '/mnt/c/a/b c/x.sh'
            ConvertTo-WslPath 'D:\Dev\x.sh' | Should -BeExactly '/mnt/d/Dev/x.sh'
        }
        It 'Get-WslRunnableScript : copie LF si le .sh a été extrait en CRLF' {
            $crlf = Join-Path $TestDrive 'crlf.sh'
            [IO.File]::WriteAllText($crlf, "#!/usr/bin/env bash`r`nset -euo pipefail`r`necho ok`r`n")
            $lf = Get-WslRunnableScript -Path $crlf -TempDir (Join-Path $TestDrive 'lfcopy') 6>$null
            $lf | Should -Not -Be $crlf
            [IO.File]::ReadAllText($lf) | Should -Not -Match "`r"
        }
        It 'Get-WslSetupArgumentList : ignore les clés _comment, garde l''ordre' {
            $envMap = [pscustomobject]@{ _comment = 'x'; HF_HOME = '$HOME/ml/hf'; B = '1' }
            $a = Get-WslSetupArgumentList -Distro 'Ubuntu' -ScriptWslPath '/mnt/c/s.sh' -EnvMap $envMap -SmokeTest
            ($a -join ' ') | Should -BeExactly '-d Ubuntu --cd ~ --exec bash /mnt/c/s.sh --smoke-test --env HF_HOME=$HOME/ml/hf --env B=1'
        }
        It 'Get-WslDistroList : lit la sortie de wsl --list (UTF-8 ou UTF-16 brut)' {
            $script:Fake.Distros = @("U`0b`0u`0n`0t`0u`0", 'Debian ')
            Get-WslDistroList | Should -Be @('Ubuntu', 'Debian')
        }
        It 'Get-MlRoot : parent de HF_HOME (C:\ML\hf -> C:\ML)' {
            Get-MlRoot -Layout (Get-StorageLayout -Name 'omen') | Should -Be 'C:\ML'
        }
    }

    Context 'scripts/ml-smoke-test.ps1' {
        BeforeAll { $script:Smoke = Join-Path $script:Repo 'scripts\ml-smoke-test.ps1' }

        It 'renvoie Gpu / DriverVersion / TorchCuda / DockerGpu' {
            $r = & $script:Smoke -Distro Ubuntu -Quiet
            $r.Gpu | Should -BeTrue
            $r.GpuName | Should -Be 'NVIDIA GeForce RTX 5080'
            $r.DriverVersion | Should -Be '581.57'
            $r.TorchCuda | Should -BeTrue
            $r.TorchVersion | Should -Be '2.9.1+cu128'
            $r.DockerGpu | Should -BeTrue
            Should -Invoke wsl -Times 1 -Exactly -ParameterFilter { "$args" -match '--exec bash /mnt/[a-z]/\S*wsl-ml-setup\.sh --smoke-only$' }
        }
        It 'CUDA KO (2) -> TorchCuda $false ; venv absent (3) -> $null ; docker muet -> $null' {
            $script:Fake.SmokeExit = 2
            (& $script:Smoke -Distro Ubuntu -Quiet).TorchCuda | Should -BeFalse
            $script:Fake.SmokeExit = 3
            $script:Fake.DockerInfoExit = 1
            $r = & $script:Smoke -Distro Ubuntu -Quiet
            $r.TorchCuda | Should -BeNullOrEmpty
            $r.DockerGpu | Should -BeNullOrEmpty
            # un seul docker run : celui du 1er appel (Docker répondait), aucun quand Docker est muet
            Should -Invoke docker -Times 1 -Exactly -ParameterFilter { "$args" -match '^run' }
        }
        It 'nvidia-smi en échec -> Gpu $false, DriverVersion $null' {
            $script:Fake.SmiExit = 9
            $r = & $script:Smoke -Distro Ubuntu -Quiet
            $r.Gpu | Should -BeFalse
            $r.DriverVersion | Should -BeNullOrEmpty
        }
        It 'distro absente -> TorchCuda $null sans lancer le script WSL' {
            $script:Fake.Distros = @('Debian')
            (& $script:Smoke -Distro Ubuntu -Quiet).TorchCuda | Should -BeNullOrEmpty
            Should -Invoke wsl -Times 0 -ParameterFilter { "$args" -match '--exec bash' }
        }
        It '-Quiet : aucun affichage, seulement l''objet' {
            $all = @(& $script:Smoke -Distro Ubuntu -Quiet 6>&1)
            @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
            $all.Count | Should -Be 1
            $verbose = @(& $script:Smoke -Distro Ubuntu 6>&1)
            @($verbose | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'scripts/wsl-ml-setup.sh (lecture statique)' {
        BeforeAll {
            $script:ShPath = Join-Path $script:Repo 'scripts\wsl-ml-setup.sh'
            $script:Sh = [IO.File]::ReadAllText($script:ShPath)
        }
        It 'commence par un shebang bash et set -euo pipefail, sans BOM' {
            ([IO.File]::ReadAllBytes($script:ShPath))[0] | Should -Be ([byte][char]'#')
            $script:Sh | Should -Match '^#!/usr/bin/env bash'
            $script:Sh | Should -Match '(?m)^set -euo pipefail$'
        }
        It 'est en LF dans la copie de travail (sinon .gitattributes manquant : 14-ml fait une copie LF)' {
            if ($script:Sh.Contains("`r")) { Set-ItResult -Inconclusive -Because 'checkout CRLF (core.autocrlf) : ajouter *.sh text eol=lf' }
            $script:Sh | Should -Not -Match "`r"
        }
        It 'balise le bloc ~/.bashrc et y exporte HF_HOME, TORCH_HOME (sans HF_HUB_ENABLE_HF_TRANSFER)' {
            $script:Sh | Should -Match ([regex]::Escape("BEGIN_MARK='# >>> reset-pack ml >>>'"))
            $script:Sh | Should -Match ([regex]::Escape("END_MARK='# <<< reset-pack ml <<<'"))
            $script:Sh | Should -Match ([regex]::Escape("ENV_NAMES=(HF_HOME TORCH_HOME)"))
        }
        It 'installe torch depuis l''index cu128 et le toolkit depuis le dépôt wsl-ubuntu' {
            $script:Sh | Should -Match ([regex]::Escape("TORCH_INDEX_URL='https://download.pytorch.org/whl/cu128'"))
            $script:Sh | Should -Match "(?m)^CUDA_TOOLKIT_PKG='cuda-toolkit-12-8'$"
            $script:Sh | Should -Match 'developer\.download\.nvidia\.com/compute/cuda/repos/wsl-ubuntu/'
            $script:Sh | Should -Match ([regex]::Escape("UV_INSTALL_URL='https://astral.sh/uv/install.sh'"))
        }
        It 'ses listes de paquets ne contiennent aucun pilote' {
            $pkgs = [regex]::Match($script:Sh, '(?m)^APT_PKGS=\((?<p>[^)]*)\)').Groups['p'].Value -split '\s+' | Where-Object { $_ }
            foreach ($p in 'build-essential', 'git', 'python3-venv') { $pkgs | Should -Contain $p }
            @($pkgs | Where-Object { $_ -match '^(nvidia-.*|libnvidia-.*|cuda-drivers.*|cuda)$' }).Count | Should -Be 0
        }
    }

    Context 'aucun pilote NVIDIA Linux installé par le lot' {
        It 'le détecteur repère les commandes interdites (et laisse passer le toolkit)' {
            Get-AptInstallViolation 'sudo apt-get install -y cuda' | Should -Not -BeNullOrEmpty
            Get-AptInstallViolation 'apt install nvidia-driver-570' | Should -Not -BeNullOrEmpty
            Get-AptInstallViolation 'sudo apt-get -y install cuda-drivers' | Should -Not -BeNullOrEmpty
            Get-AptInstallViolation "apt-get install -y \`n  git cuda=12.8.0-1" | Should -Not -BeNullOrEmpty
            Get-AptInstallViolation 'sudo apt-get install -y cuda-toolkit-12-8 build-essential' | Should -BeNullOrEmpty
            Get-AptInstallViolation 'sudo apt-get purge nvidia-driver-570' | Should -BeNullOrEmpty
        }
        It '<_> : aucune commande apt install ne vise nvidia-driver*, cuda-drivers ou cuda seul' -ForEach $script:LotFiles {
            $text = [IO.File]::ReadAllText((Join-Path $script:Repo $_))
            Get-AptInstallViolation $text | Should -BeNullOrEmpty
        }
    }

    Context 'scripts/wsl-ml-setup.sh sous Git Bash' -Skip:(-not $script:GitBash) {
        BeforeAll {
            $script:DryRun = $false
            $script:ShLf = Get-WslRunnableScript -Path (Join-Path $script:Repo 'scripts\wsl-ml-setup.sh') -TempDir (Join-Path $TestDrive 'shlf') 6>$null
            $script:Tmp = Join-Path $TestDrive 'bashtmp'
            New-Item -ItemType Directory -Force -Path $script:Tmp | Out-Null
            # run.sh <home> <script> args... : HOME et TMPDIR dans $TestDrive
            $script:Runner = ConvertTo-LfFile (Join-Path $TestDrive 'run.sh') @(
                'export HOME="$(cygpath -u "$1")"; shift'
                'export TMPDIR="$(cygpath -u "$1")"; shift'
                'script="$(cygpath -u "$1")"; shift'
                'exec bash "$script" "$@"'
            )
        }
        BeforeEach {
            $script:FakeHome = Join-Path $TestDrive ('home-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $script:FakeHome | Out-Null
        }

        It 'bash -n : syntaxe valide' {
            $r = Invoke-GitBash @('-n', $script:ShLf)
            $r.Output | Should -BeNullOrEmpty
            $r.ExitCode | Should -Be 0
        }
        It '--dry-run --smoke-test --with-cuda-toolkit : affiche le plan, n''écrit rien dans HOME' {
            $r = Invoke-GitBash @($script:Runner, $script:FakeHome, $script:Tmp, $script:ShLf, '--dry-run', '--smoke-test', '--with-cuda-toolkit',
                '--env', 'HF_HOME=$HOME/ml/hf')
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match '\[dry\] .*apt-get install -y --no-install-recommends .*build-essential'
            $r.Output | Should -Match '\[dry\] .*apt-get install -y --no-install-recommends cuda-toolkit-12-8'
            $r.Output | Should -Match '\[dry\] .*pip install --python \S+/ml/\.smoke/bin/python torch --index-url https://download\.pytorch\.org/whl/cu128'
            $r.Output | Should -Match '\[dry\] ecrire le bloc reset-pack dans ~/\.bashrc'
            @(Get-ChildItem $script:FakeHome -Recurse -Force).Count | Should -Be 0
        }
        It '--smoke-only sans venv : code 3 (non testé), rien installé' {
            $r = Invoke-GitBash @($script:Runner, $script:FakeHome, $script:Tmp, $script:ShLf, '--smoke-only')
            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'RESETPACK_SMOKE status=no-venv'
            @(Get-ChildItem $script:FakeHome -Recurse -Force).Count | Should -Be 0
        }
        It 'refuse une option inconnue (code 64)' {
            (Invoke-GitBash @($script:Runner, $script:FakeHome, $script:Tmp, $script:ShLf, '--dry-run', '--nope')).ExitCode | Should -Be 64
        }
        It '--env : refuse les valeurs qui sortiraient des guillemets du bloc ~/.bashrc (code 64)' {
            # Valeurs testées DANS bash (source) : la ligne de commande Windows (PS 5.1) ne les déforme pas.
            $t = Join-Path $TestDrive 'env-test.sh'
            [IO.File]::WriteAllText($t, (@'
source "$(cygpath -u "$1")"
for v in 'X=$(touch pwned)' 'X="; rm -rf ~; "' 'X=`id`' 'X=a\b' '1BAD=x' 'SANS_EGAL' 'HF_HOME=$HOME/ml/hf' 'A=${HOME}/x' 'B=1'; do
  if (set_env_kv "$v") >/dev/null 2>&1; then echo "OK $v"; else echo "REFUSE[$?] $v"; fi
done
'@ -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
            $r = Invoke-GitBash @($t, $script:ShLf)
            foreach ($v in 'X=$(touch pwned)', 'X="; rm -rf ~; "', 'X=`id`', 'X=a\b', '1BAD=x', 'SANS_EGAL') {
                $r.Output | Should -Match "(?m)^REFUSE\[64\] $([regex]::Escape($v))$"
            }
            foreach ($v in 'HF_HOME=$HOME/ml/hf', 'A=${HOME}/x', 'B=1') {
                $r.Output | Should -Match "(?m)^OK $([regex]::Escape($v))$"
            }
            Test-Path (Join-Path $script:Repo 'pwned') | Should -BeFalse
        }
        It 'bloc ~/.bashrc : remplacé en place, jamais dupliqué, le reste du fichier intact' {
            $t = ConvertTo-LfFile (Join-Path $TestDrive 'bashrc-test.sh') @(
                'set -euo pipefail'
                'export HOME="$(cygpath -u "$1")"'
                'export TMPDIR="$(cygpath -u "$2")"'
                'source "$(cygpath -u "$3")"'
                'printf ''alias ll="ls -l"\n'' > "$HOME/.bashrc"'
                'write_bashrc_block >/dev/null'
                'echo "RUN2: $(write_bashrc_block)"'
                'printf ''echo apres\n'' >> "$HOME/.bashrc"'
                'set_env_kv ''HF_HOME=$HOME/autre/hf'''
                'write_bashrc_block >/dev/null'
                'echo "=== BASHRC"'
                'cat "$HOME/.bashrc"'
            )
            $r = Invoke-GitBash @($t, $script:FakeHome, $script:Tmp, $script:ShLf)
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'RUN2: .*deja a jour'
            $rc = ($r.Output -split '=== BASHRC', 2)[1]
            ([regex]::Matches($rc, '(?m)^# >>> reset-pack ml >>>$')).Count | Should -Be 1
            ([regex]::Matches($rc, '(?m)^# <<< reset-pack ml <<<$')).Count | Should -Be 1
            $rc | Should -Match '(?m)^export HF_HOME="\$HOME/autre/hf"$'
            $rc | Should -Not -Match 'ml/hf"'
            $rc | Should -Match '(?m)^export TORCH_HOME="\$HOME/ml/torch"$'
            $rc | Should -Not -Match 'HF_HUB_ENABLE_HF_TRANSFER'
            # ordre conservé : alias, bloc, puis la ligne ajoutée après
            $rc.IndexOf('alias ll=') | Should -BeLessThan $rc.IndexOf('# >>> reset-pack ml >>>')
            $rc.IndexOf('# <<< reset-pack ml <<<') | Should -BeLessThan $rc.IndexOf('echo apres')
        }
        It 'assert_allowed_pkg refuse les pilotes et le méta-paquet, accepte le toolkit' {
            $t = ConvertTo-LfFile (Join-Path $TestDrive 'pkg-test.sh') @(
                'source "$(cygpath -u "$1")"'
                'for p in cuda cuda=12.8.0-1 cuda-drivers cuda-drivers-570 nvidia-driver-570 nvidia-utils-570 cuda-toolkit-12-8 build-essential; do'
                '  if (assert_allowed_pkg "$p") 2>/dev/null; then echo "OK $p"; else echo "REFUSE $p"; fi'
                'done'
            )
            $r = Invoke-GitBash @($t, $script:ShLf)
            foreach ($p in 'cuda', 'cuda=12.8.0-1', 'cuda-drivers', 'cuda-drivers-570', 'nvidia-driver-570', 'nvidia-utils-570') {
                $r.Output | Should -Match "(?m)^REFUSE $([regex]::Escape($p))$"
            }
            $r.Output | Should -Match '(?m)^OK cuda-toolkit-12-8$'
            $r.Output | Should -Match '(?m)^OK build-essential$'
        }
    }

    Context 'garde-fou final' {
        It 'n''a pas touché au vrai %USERPROFILE%\.wslconfig' {
            if ($null -eq $script:RealWslConfigHash) { Test-Path $script:RealWslConfig | Should -BeFalse }
            else { (Get-FileHash $script:RealWslConfig).Hash | Should -Be $script:RealWslConfigHash }
        }
    }
}
