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
    It 'enregistre exactement 3 tâches planifiées' {
        . "$Repo\modules\10-scheduled.ps1"
        Should -Invoke Register-ScheduledTask -Times 3 -Exactly
    }
    It 'crée la tâche winget-upgrade hebdomadaire' {
        . "$Repo\modules\10-scheduled.ps1"
        Should -Invoke Register-ScheduledTask -ParameterFilter { $TaskName -eq 'ResetPack-WingetUpgrade' } -Times 1
    }
}
