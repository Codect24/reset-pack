# Tests Pester v5 — valident la LOGIQUE sans rien installer ni modifier le système.
#   Invoke-Pester -Path .\tests
BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
}

Describe 'config/apps.json' {
    BeforeAll { $script:cfg = Get-Content "$Repo\config\apps.json" -Raw | ConvertFrom-Json }

    It 'est un JSON valide avec un tableau apps non vide' {
        $cfg.apps | Should -Not -BeNullOrEmpty
    }
    It 'donne un id + name + category à chaque app' {
        foreach ($a in $cfg.apps) {
            $a.id       | Should -Not -BeNullOrEmpty
            $a.name     | Should -Not -BeNullOrEmpty
            $a.category | Should -Not -BeNullOrEmpty
        }
    }
    It "n'a aucun id winget en double" {
        $ids = $cfg.apps.id
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
    }
}

Describe 'modules/00-helpers.ps1' {
    BeforeAll { . "$Repo\modules\00-helpers.ps1" }

    It 'résout une racine OneDrive non vide' {
        Get-OneDriveRoot | Should -Not -BeNullOrEmpty
    }
    It 'expose les fonctions clés' {
        foreach ($fn in 'Invoke-Winget','Register-ScheduledTaskSafe','Set-RegistryValue','New-SymLinkSafe','Test-Admin','Update-SessionPath') {
            (Get-Command $fn -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because "$fn doit exister"
        }
    }
    It 'Invoke-Winget ne lance rien en dry-run et renvoie 0' {
        $script:DryRun = $true
        Invoke-Winget -Arguments @('install','--id','Fake.App') | Should -Be 0
    }
}

Describe 'tous les .ps1 se parsent (AST)' {
    It '<_> parse sans erreur' -ForEach (Get-ChildItem "$Repo" -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\logs\\' } | ForEach-Object FullName) {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$null, [ref]$errs) | Out-Null
        $errs | Should -BeNullOrEmpty
    }
}

Describe 'modules/05-vscode.ps1 respecte le dry-run (régression : il installait des extensions en simulation)' {
    BeforeAll {
        $script:codeCalls = New-Object System.Collections.Generic.List[string]
        # Faux CLI `code` : écrit sur stderr comme le vrai (warning node) et journalise les appels.
        function global:code { $script:codeCalls.Add("$args"); [Console]::Error.WriteLine('(node) DeprecationWarning'); if ("$args" -eq '--list-extensions') { 'deja.installee' } }
    }
    AfterAll { Remove-Item function:\code -ErrorAction SilentlyContinue; $env:RESETPACK_DRYRUN = '' }
    It "n'appelle jamais --install-extension en dry-run, même sous ErrorActionPreference=Stop" {
        $env:RESETPACK_DRYRUN = '1'
        $ErrorActionPreference = 'Stop'
        { . "$Repo\modules\05-vscode.ps1" } | Should -Not -Throw
        @($script:codeCalls | Where-Object { $_ -match '--install-extension' }).Count | Should -Be 0
    }
}

Describe 'modules/10-scheduled.ps1 (mocké, aucune tâche réelle créée)' {
    BeforeAll { . "$Repo\modules\00-helpers.ps1" }
    BeforeEach {
        $env:RESETPACK_DRYRUN = ''   # exercer le vrai chemin, mais avec le cmdlet Register mocké
        $script:DryRun = $false
        # On NE mocke PAS New-ScheduledTask* : ils construisent de vrais objets CIM (sans admin)
        # qui se lient correctement. Seul Register-ScheduledTask (qui exige admin) est neutralisé.
        Mock Register-ScheduledTask { }
        Mock Get-ItemProperty       { $null }   # startup block : rien à désarmer
        Mock Set-ItemProperty       { }
        Mock Remove-ItemProperty    { }
    }
    AfterEach { $env:RESETPACK_PROFILE = $null }
    It 'enregistre 4 tâches hors OMEN (winget, clair, sombre, bundles)' {
        $env:RESETPACK_PROFILE = 'exodius'
        . "$Repo\modules\10-scheduled.ps1"
        Should -Invoke Register-ScheduledTask -Times 4 -Exactly
    }
    It "enregistre 6 tâches sur l'OMEN (+ purge Docker légère + log thermique)" {
        $env:RESETPACK_PROFILE = 'omen'
        . "$Repo\modules\10-scheduled.ps1"
        Should -Invoke Register-ScheduledTask -Times 6 -Exactly
        Should -Invoke Register-ScheduledTask -ParameterFilter { $TaskName -eq 'ResetPack-ThermalLog' } -Times 1
    }
    It 'crée la tâche de bundles git quotidienne' {
        $env:RESETPACK_PROFILE = 'exodius'
        . "$Repo\modules\10-scheduled.ps1"
        Should -Invoke Register-ScheduledTask -ParameterFilter { $TaskName -eq 'ResetPack-CodeBundles' } -Times 1
    }
    It 'crée la tâche winget-upgrade hebdomadaire' {
        $env:RESETPACK_PROFILE = 'exodius'
        . "$Repo\modules\10-scheduled.ps1"
        Should -Invoke Register-ScheduledTask -ParameterFilter { $TaskName -eq 'ResetPack-WingetUpgrade' } -Times 1
    }
}
