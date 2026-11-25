# Tests Pester 5+ — lot 4 : 15-hp-triage (tri du bloatware HP) et 16-gaming.
# RIEN n'est désinstallé, retiré ni écrit dans le registre : les commandes système sont mockées et les fichiers
# vont dans $TestDrive. Les modules sont dot-sourcés : leur partie exécutable ne tourne pas.
#   Invoke-Pester -Path .\tests\HpTriage-Gaming.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Stubs de commandes système : leurs paramètres ne servent qu''au binding des mocks.')]
param()

BeforeAll {
    $script:Repo       = Split-Path $PSScriptRoot -Parent
    $script:TriageFile = Join-Path $Repo 'modules\15-hp-triage.ps1'
    $script:GamingFile = Join-Path $Repo 'modules\16-gaming.ps1'
    $script:TriageJson = Join-Path $Repo 'config\hp-triage.json'
    $script:UltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $script:BalancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'

    # Pester ne mocke qu'une commande qui existe : stubs si un module système manque (CI minimale).
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue))  { function global:Get-AppxPackage { param([string]$Name, [switch]$AllUsers) } }
    if (-not (Get-Command Remove-AppxPackage -ErrorAction SilentlyContinue)) { function global:Remove-AppxPackage { param([string]$Package) } }
    if (-not (Get-Command Get-AppxPackageManifest -ErrorAction SilentlyContinue)) { function global:Get-AppxPackageManifest { param([string]$Package) } }
    if (-not (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue)) { function global:Get-AppxProvisionedPackage { param([switch]$Online) } }
    if (-not (Get-Command Remove-AppxProvisionedPackage -ErrorAction SilentlyContinue)) { function global:Remove-AppxProvisionedPackage { param([switch]$Online, [string]$PackageName) } }
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) { function global:Get-MpComputerStatus { param() } }
    if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) { function global:Set-MpPreference { param([bool]$DisableRealtimeMonitoring) } }
    if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { function global:Get-MpPreference { param() } }

    function script:Get-ExecutableCode {
        # Texte du script SANS les commentaires (les commentaires peuvent citer ce qu'on s'interdit).
        param([string]$Path)
        $tokens = $null; $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs) | Out-Null
        return (($tokens | Where-Object { $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment } |
                ForEach-Object { $_.Text }) -join ' ')
    }
    function script:Get-CommandNameInFile {
        param([string]$Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }
    function script:New-FakeAppx {
        param([string]$Name)
        return [pscustomobject]@{
            Name = $Name; PackageFullName = "${Name}_1.0.0.0_x64__testpfn"; PackageFamilyName = "${Name}_testpfn"
            Version = '1.0.0.0'; Publisher = 'CN=Test'; NonRemovable = $false; InstallLocation = $null
        }
    }
    function script:New-FakeProcess {
        param([int]$ExitCode = 0, [bool]$Finished = $true)
        $p = [pscustomobject]@{ ExitCode = $ExitCode; Handle = 1; Finished = $Finished }
        $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $this.Finished }   # WaitForExit(ms) : arg ignoré
        return $p
    }
    function script:New-McAfeeEntry {
        return [pscustomobject]@{
            PSChildName          = 'McAfee.LiveSafe'
            DisplayName          = 'McAfee LiveSafe'
            Publisher            = 'McAfee, LLC'
            UninstallString      = '"C:\Program Files\McAfee\MSC\mcuihost.exe" /body:misp://MSCJsRes.dll::uninstall.html /id:uninstall'
            QuietUninstallString = '"C:\Program Files\McAfee\MSC\mcuihost.exe" /body:misp://MSCJsRes.dll::uninstall.html /id:uninstall /quiet'
            PSPath               = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\ResetPackPesterAbsent\McAfee'
        }
    }
}

# ============================================================================
Describe 'config/hp-triage.json' {
    BeforeAll {
        . $TriageFile
        $script:cfg = Get-Content $TriageJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:keepPatterns = @($cfg.keep | ForEach-Object { $_.pattern })
    }

    It 'est un JSON valide avec keep / remove / confirm non vides' {
        $cfg.keep    | Should -Not -BeNullOrEmpty
        $cfg.remove  | Should -Not -BeNullOrEmpty
        $cfg.confirm | Should -Not -BeNullOrEmpty
        { Get-HpTriageConfig -Path $TriageJson } | Should -Not -Throw
    }
    It 'donne un name, un type appx|win32 et un motif à chaque entrée' {
        foreach ($e in @($cfg.keep) + @($cfg.remove) + @($cfg.confirm)) {
            $e.name    | Should -Not -BeNullOrEmpty
            $e.pattern | Should -Not -BeNullOrEmpty
            $e.type    | Should -BeIn @('appx', 'win32')
        }
    }
    It "aucune entrée remove ne matche un motif keep" {
        foreach ($r in $cfg.remove) {
            foreach ($k in $keepPatterns) {
                ($r.pattern -like $k) | Should -BeFalse -Because "remove '$($r.pattern)' recouvre keep '$k'"
                ($k -like $r.pattern) | Should -BeFalse -Because "keep '$k' recouvre remove '$($r.pattern)'"
            }
            foreach ($ex in @($r.examples)) {
                (Find-KeepRule -Name @($ex) -Config $cfg) | Should -BeNullOrEmpty -Because "l'exemple '$ex' (remove) matche keep"
            }
        }
    }
    It "aucune entrée confirm ne matche un motif keep" {
        foreach ($c in $cfg.confirm) {
            foreach ($ex in @($c.examples)) {
                (Find-KeepRule -Name @($ex) -Config $cfg) | Should -BeNullOrEmpty -Because "l'exemple '$ex' (confirm) matche keep"
            }
        }
    }
    It 'chaque exemple matche bien son propre motif' {
        foreach ($e in @($cfg.keep) + @($cfg.remove) + @($cfg.confirm)) {
            foreach ($ex in @($e.examples)) { ($ex -like $e.pattern) | Should -BeTrue -Because "'$ex' devrait matcher '$($e.pattern)'" }
        }
    }
    It 'met myHP et HP Smart dans confirm, jamais dans remove' {
        foreach ($n in 'AD2F1837.myHP', 'AD2F1837.HPPrinterControl') {
            @($cfg.confirm | Where-Object { $n -like $_.pattern }).Count | Should -BeGreaterThan 0
            @($cfg.remove  | Where-Object { $n -like $_.pattern }).Count | Should -Be 0
        }
    }
    It 'protège OMEN Gaming Hub, HP Support Assistant, pilotes HP, Xbox, Game Bar, Defender et NVIDIA' {
        foreach ($n in 'AD2F1837.OMENCommandCenter', 'HP Support Assistant', 'AD2F1837.HPSupportAssistant',
                       'HP Hotkey Driver', 'AD2F1837.HPSystemEventUtilityHost', 'Microsoft.GamingApp',
                       'Microsoft.XboxGamingOverlay', 'Microsoft.SecHealthUI', 'NVIDIA Graphics Driver 581.57',
                       'Microsoft.DesktopAppInstaller') {
            (Find-KeepRule -Name @($n) -Config $cfg) | Should -Not -BeNullOrEmpty -Because "'$n' doit être gardé"
        }
    }
    It 'retire McAfee (Win32) et prévoit le contrôle Defender' {
        $m = @($cfg.remove | Where-Object { $_.type -eq 'win32' -and 'McAfee LiveSafe' -like $_.pattern })
        $m.Count | Should -Be 1
        $m[0].postCheck | Should -Be 'defender'
    }
}

# ============================================================================
Describe 'modules/15-hp-triage.ps1 (mocké)' {
    BeforeAll {
        . $TriageFile
        $script:cfg = Get-HpTriageConfig -Path $TriageJson
    }
    BeforeEach {
        Mock Write-Host { }
        Mock Invoke-WingetList { "Nom            ID              Version`nFake App       Fake.App        1.0" }
        Mock Get-AppxPackage { }
        Mock Get-AppxProvisionedPackage { }
        Mock Remove-AppxPackage { }
        Mock Remove-AppxProvisionedPackage { }
        Mock Get-ItemProperty { }
        Mock Start-Process { New-FakeProcess -ExitCode 0 }
        Mock Get-MpComputerStatus { [pscustomobject]@{ RealTimeProtectionEnabled = $true; AMRunningMode = 'Normal' } }
        Mock Set-MpPreference { }
        Mock Read-Host { 'n' }
        $script:logRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'ne lance rien quand il est dot-sourcé' {
        . $TriageFile
        Should -Invoke Get-AppxPackage -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'dry-run : ne supprime rien mais écrit la capture complète dans $TestDrive' {
        Mock Get-AppxPackage { New-FakeAppx 'C27EB4BA.DropboxOEM'; New-FakeAppx 'AD2F1837.OMENCommandCenter'; New-FakeAppx 'AD2F1837.myHP' }
        Mock Get-AppxProvisionedPackage { [pscustomobject]@{ DisplayName = 'C27EB4BA.DropboxOEM'; PackageName = 'C27EB4BA.DropboxOEM_1.0_neutral_~_x' } }
        Mock Get-ItemProperty -ParameterFilter { "$Path" -like 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall*' } { New-McAfeeEntry }

        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $true -Auto $true -IsAdmin $true

        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Set-MpPreference -Times 0 -Exactly

        $r.CaptureDir | Should -BeLike "$logRoot\hp-capture-*"
        foreach ($f in 'winget-list.txt', 'appx-allusers.csv', 'appx-provisioned.csv', 'uninstall-registry.csv', 'triage-resultat.txt') {
            Join-Path $r.CaptureDir $f | Should -Exist
        }
        (Import-Csv (Join-Path $r.CaptureDir 'uninstall-registry.csv')).DisplayName | Should -Contain 'McAfee LiveSafe'
        (Import-Csv (Join-Path $r.CaptureDir 'appx-allusers.csv')).Name | Should -Contain 'AD2F1837.OMENCommandCenter'
        Get-Content (Join-Path $r.CaptureDir 'winget-list.txt') -Raw | Should -Match 'Fake.App'

        ($r.Retire -join "`n") | Should -Match 'McAfee LiveSafe'
        ($r.Retire -join "`n") | Should -Match 'DropboxOEM'
        ($r.Garde -join "`n")  | Should -Match 'OMENCommandCenter'
        ($r.AConfirmer -join "`n") | Should -Match 'myHP'
    }

    It 'capture même en dry-run sans admin (Appx utilisateur, pas de provisionné)' {
        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $true -Auto $true -IsAdmin $false
        Join-Path $r.CaptureDir 'appx-user.csv' | Should -Exist
        Join-Path $r.CaptureDir 'appx-provisioned.csv' | Should -Not -Exist
        Should -Invoke Get-AppxProvisionedPackage -Times 0 -Exactly
    }

    It 'désinstalle McAfee via sa QuietUninstallString, puis vérifie Defender' {
        Mock Get-ItemProperty -ParameterFilter { "$Path" -like 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall*' } { New-McAfeeEntry }

        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $true -IsAdmin $true -TimeoutSec 5

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Program Files\McAfee\MSC\mcuihost.exe' -and "$ArgumentList" -like '*/id:uninstall /quiet'
        }
        Should -Invoke Get-MpComputerStatus -Times 1
        Should -Invoke Set-MpPreference -Times 0 -Exactly
        ($r.Retire -join "`n") | Should -Match 'McAfee LiveSafe.*QuietUninstallString'
        $r.DefenderOk | Should -BeTrue
    }

    It 'réactive le temps réel Defender s''il est OFF après McAfee' {
        Mock Get-ItemProperty -ParameterFilter { "$Path" -like 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall*' } { New-McAfeeEntry }
        Mock Get-MpComputerStatus { [pscustomobject]@{ RealTimeProtectionEnabled = $false; AMRunningMode = 'Passive Mode' } }
        Mock Write-Warn { }

        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $true -IsAdmin $true -TimeoutSec 5

        Should -Invoke Set-MpPreference -Times 1 -Exactly -ParameterFilter { $DisableRealtimeMonitoring -eq $false }
        Should -Invoke Write-Warn -ParameterFilter { $msg -like '*TEMPS R*DÉSACTIVÉE*' } -Times 1
        $r.DefenderOk | Should -BeFalse
    }

    It 'ne compte pas McAfee comme retiré si le désinstalleur dépasse le timeout' {
        Mock Get-ItemProperty -ParameterFilter { "$Path" -like 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall*' } { New-McAfeeEntry }
        Mock Start-Process { New-FakeProcess -ExitCode 0 -Finished $false }

        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $true -IsAdmin $true -TimeoutSec 1

        ($r.Ignore -join "`n") | Should -Match 'McAfee LiveSafe.*timeout'
        ($r.Retire -join "`n") | Should -Not -Match 'McAfee'
        Should -Invoke Get-MpComputerStatus -Times 0 -Exactly
    }

    It "ne retire jamais myHP en mode Auto (ni HP Smart), et ne pose aucune question" {
        Mock Get-AppxPackage { New-FakeAppx 'AD2F1837.myHP'; New-FakeAppx 'AD2F1837.HPPrinterControl' }
        Mock Get-AppxProvisionedPackage { [pscustomobject]@{ DisplayName = 'AD2F1837.myHP'; PackageName = 'AD2F1837.myHP_1.0_neutral_~_x' } }

        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $true -IsAdmin $true

        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        ($r.AConfirmer -join "`n") | Should -Match 'myHP'
        ($r.AConfirmer -join "`n") | Should -Match 'HPPrinterControl'
    }

    It 'retire myHP seulement après un oui interactif' {
        Mock Get-AppxPackage { New-FakeAppx 'AD2F1837.myHP' }
        Mock Read-Host { 'o' }

        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $false -IsAdmin $false

        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly -ParameterFilter { $Package -like 'AD2F1837.myHP_*' }
        ($r.Retire -join "`n") | Should -Match 'myHP'
    }

    It 'garde myHP si la réponse interactive est non' {
        Mock Get-AppxPackage { New-FakeAppx 'AD2F1837.myHP' }
        Mock Read-Host { '' }

        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $false -IsAdmin $false

        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        ($r.Garde -join "`n") | Should -Match 'myHP.*à ta demande'
    }

    It 'garde-fou : un candidat qui matche aussi keep n''est jamais retiré (warning)' {
        $badCfg = [pscustomobject]@{
            uninstallTimeoutSec = 5
            keep    = @([pscustomobject]@{ name = 'OMEN Gaming Hub'; type = 'appx'; pattern = 'AD2F1837.OMEN*' })
            remove  = @([pscustomobject]@{ name = 'Règle trop large'; type = 'appx'; pattern = 'AD2F1837.*' })
            confirm = @()
        }
        Mock Get-AppxPackage { New-FakeAppx 'AD2F1837.OMENCommandCenter' }
        Mock Write-Warn { }

        $r = Invoke-HpTriage -Config $badCfg -LogRoot $logRoot -DryRun $false -Auto $true -IsAdmin $true

        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $msg -like '*GARDE-FOU*OMENCommandCenter*' }
        ($r.Garde -join "`n") | Should -Match 'garde-fou'
    }

    It 'retire une appli promo Appx (utilisateur + provisionné) hors dry-run' {
        Mock Get-AppxPackage { New-FakeAppx 'C27EB4BA.DropboxOEM' }
        Mock Get-AppxProvisionedPackage { [pscustomobject]@{ DisplayName = 'C27EB4BA.DropboxOEM'; PackageName = 'C27EB4BA.DropboxOEM_1.0_neutral_~_x' } }

        $null = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $true -IsAdmin $true

        Should -Invoke Remove-AppxPackage -Times 1 -Exactly -ParameterFilter { $Package -like 'C27EB4BA.DropboxOEM_*' }
        Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter { $PackageName -like 'C27EB4BA.DropboxOEM_*' }
    }

    It 'saute un programme machine (HKLM) sans admin' {
        Mock Get-ItemProperty -ParameterFilter { "$Path" -like 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall*' } { New-McAfeeEntry }

        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $true -IsAdmin $false

        Should -Invoke Start-Process -Times 0 -Exactly
        ($r.Ignore -join "`n") | Should -Match 'McAfee LiveSafe.*admin requis'
    }

    It 'en Auto, ne lance pas de désinstalleur interactif quand rien de silencieux n''est connu' {
        Mock Get-ItemProperty -ParameterFilter { "$Path" -like 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall*' } {
            [pscustomobject]@{ PSChildName = 'McAfee.TP'; DisplayName = 'McAfee Total Protection'
                UninstallString = '"C:\Program Files\McAfee\MSC\mcuihost.exe" /body:misp://MSCJsRes.dll::uninstall.html /id:uninstall'
                PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\ResetPackPesterAbsent\TP' }
        }
        $r = Invoke-HpTriage -Config $cfg -LogRoot $logRoot -DryRun $false -Auto $true -IsAdmin $true

        Should -Invoke Start-Process -Times 0 -Exactly
        ($r.Ignore -join "`n") | Should -Match 'McAfee Total Protection.*MCPR'
    }

    Context 'commandes de désinstallation Win32' {
        It 'préfère la QuietUninstallString à l''UninstallString' {
            $c = Get-Win32UninstallCommand -Entry ([pscustomobject]@{ UninstallString = '"C:\a\u.exe"'; QuietUninstallString = '"C:\a\u.exe" /quiet' })
            $c.FilePath | Should -Be 'C:\a\u.exe'
            $c.Arguments | Should -Be '/quiet'
            $c.Source | Should -Be 'QuietUninstallString'
        }
        It 'transforme un MSI en msiexec /x {GUID} /qn /norestart' {
            $c = Get-Win32UninstallCommand -Entry ([pscustomobject]@{ UninstallString = 'MsiExec.exe /I{12345678-1234-1234-1234-123456789ABC}'; KeyName = 'x' })
            $c.FilePath | Should -Be 'msiexec.exe'
            $c.Arguments | Should -Be '/x {12345678-1234-1234-1234-123456789ABC} /qn /norestart'
        }
        It 'ajoute les flags connus du JSON (McAfee WebAdvisor)' {
            $rule = $cfg.remove | Where-Object { $_.type -eq 'win32' -and 'McAfee WebAdvisor' -like $_.pattern }
            $c = Get-Win32UninstallCommand -Entry ([pscustomobject]@{ UninstallString = '"C:\Program Files\McAfee\WebAdvisor\Uninstaller.exe"' }) -Rule $rule
            $c.FilePath | Should -Be 'C:\Program Files\McAfee\WebAdvisor\Uninstaller.exe'
            $c.Arguments | Should -Be '/s'
        }
        It 'renvoie $null si aucune désinstallation silencieuse n''est connue' {
            Get-Win32UninstallCommand -Entry ([pscustomobject]@{ UninstallString = '"C:\x\setup.exe" /remove' }) | Should -BeNullOrEmpty
        }
        It 'découpe un chemin sans guillemets contenant des espaces' {
            $c = ConvertFrom-CommandLine 'C:\Program Files\Foo Bar\unins000.exe /SILENT'
            $c.FilePath | Should -Be 'C:\Program Files\Foo Bar\unins000.exe'
            $c.Arguments | Should -Be '/SILENT'
        }
    }

    It 'honore RESETPACK_LOG_ROOT pour la racine des captures' {
        $old = $env:RESETPACK_LOG_ROOT
        try {
            $env:RESETPACK_LOG_ROOT = $logRoot
            Get-HpTriageLogRoot | Should -Be $logRoot
            Get-HpTriageLogRoot -LogRoot 'C:\ailleurs' | Should -Be 'C:\ailleurs'
        } finally { $env:RESETPACK_LOG_ROOT = $old }
    }

    It "n'utilise jamais Win32_Product" {
        Get-ExecutableCode $TriageFile | Should -Not -Match 'Win32_Product'
    }
}

# ============================================================================
Describe 'modules/16-gaming.ps1 (mocké)' {
    BeforeAll {
        . $GamingFile
        $script:GamingCode = Get-ExecutableCode $GamingFile
        $script:GamingCommands = Get-CommandNameInFile $GamingFile
        $script:OmenManifest = @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5">
  <Identity Name="AD2F1837.OMENCommandCenter" Publisher="CN=Test" Version="1.0.0.0" />
  <Applications>
    <Application Id="App" Executable="OmenCommandCenter.exe" EntryPoint="Windows.FullTrustApplication">
      <Extensions>
        <uap5:Extension Category="windows.startupTask">
          <uap5:StartupTask TaskId="OmenCommandCenterStartup" Enabled="true" DisplayName="OMEN Gaming Hub" />
        </uap5:Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
'@
        $script:OmenPfn = 'AD2F1837.OMENCommandCenter_v10z8vjag6ke6'
    }
    BeforeEach {
        Mock Write-Host { }
        Mock Set-RegistryValue { }
        Mock Get-ItemProperty { }
        Mock Get-Process { }
        Mock Read-Host { 'n' }
        Mock Invoke-PowerCfg { "GUID du mode de gestion de l'alimentation : $BalancedGuid  (Utilisation normale)" }
        Mock Get-AppxPackage { }
        Mock Get-MpComputerStatus { [pscustomobject]@{ RealTimeProtectionEnabled = $true } }
        Mock Get-MpPreference { [pscustomobject]@{ ExclusionPath = @() } }
        Mock Set-MpPreference { }
        Mock Get-CimInstance { [pscustomobject]@{ VirtualizationBasedSecurityStatus = 2; SecurityServicesRunning = @(2) } }
    }

    Context 'garde-fous statiques' {
        It "n'appelle aucune commande de service (Stop-Service, Set-Service, sc.exe config)" {
            $forbidden = 'Stop-Service', 'Set-Service', 'Suspend-Service', 'Restart-Service', 'sc', 'sc.exe'
            @($GamingCommands | Where-Object { $forbidden -contains $_ }) | Should -BeNullOrEmpty
            $GamingCode | Should -Not -Match '(?i)\b(Stop-Service|Set-Service)\b'
            $GamingCode | Should -Not -Match '(?i)\bsc(\.exe)?\s+config\b'
        }
        It 'ne crée pas de plan Ultimate (GUID absent du code exécutable)' {
            $GamingCode | Should -Not -Match $UltimateGuid
            $GamingCode | Should -Not -Match '(?i)duplicatescheme'
            $GamingCode | Should -Match $BalancedGuid
        }
        It 'ne modifie jamais Defender (contrôles en lecture seule)' {
            @($GamingCommands | Where-Object { $_ -in 'Set-MpPreference', 'Add-MpPreference', 'Remove-MpPreference' }) | Should -BeNullOrEmpty
        }
        It 'ne lance rien quand il est dot-sourcé' {
            . $GamingFile
            Should -Invoke Set-RegistryValue -Times 0 -Exactly
            Should -Invoke Invoke-PowerCfg -Times 0 -Exactly
        }
    }

    Context 'tweaks jeu' {
        It 'remet le Game Mode à 1 (AutoGameModeEnabled + AllowAutoGameMode) sans toucher au Game DVR' {
            Enable-GamingTweak -DryRun $false -IsAdmin $true
            Should -Invoke Set-RegistryValue -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'HKCU:\Software\Microsoft\GameBar' -and $Name -eq 'AutoGameModeEnabled' -and $Value -eq 1 }
            Should -Invoke Set-RegistryValue -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'HKCU:\Software\Microsoft\GameBar' -and $Name -eq 'AllowAutoGameMode' -and $Value -eq 1 }
            Should -Invoke Set-RegistryValue -Times 0 -Exactly -ParameterFilter {
                $Name -in 'GameDVR_Enabled', 'AllowGameDVR', 'AppCaptureEnabled' }
        }
        It 'active HAGS (HwSchMode=2) et les priorités multimédia jeux' {
            Enable-GamingTweak -DryRun $false -IsAdmin $true
            Should -Invoke Set-RegistryValue -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -and $Name -eq 'HwSchMode' -and $Value -eq 2 }
            $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
            Should -Invoke Set-RegistryValue -Times 1 -ParameterFilter { $Path -eq $mm -and $Name -eq 'GPU Priority' -and $Value -eq 8 }
            Should -Invoke Set-RegistryValue -Times 1 -ParameterFilter { $Path -eq $mm -and $Name -eq 'Priority' -and $Value -eq 6 }
            Should -Invoke Set-RegistryValue -Times 1 -ParameterFilter { $Path -eq $mm -and $Name -eq 'Scheduling Category' -and $Value -eq 'High' -and $Type -eq 'String' }
            Should -Invoke Set-RegistryValue -Times 1 -ParameterFilter { $Path -eq $mm -and $Name -eq 'SFIO Priority' -and $Value -eq 'High' -and $Type -eq 'String' }
        }
        It "est idempotent : n'écrit pas une valeur déjà correcte" {
            Mock Get-ItemProperty -ParameterFilter { $LiteralPath -eq 'HKCU:\Software\Microsoft\GameBar' } {
                [pscustomobject]@{ AutoGameModeEnabled = 1; AllowAutoGameMode = 1 } }
            Enable-GamingTweak -DryRun $false -IsAdmin $true
            Should -Invoke Set-RegistryValue -Times 0 -Exactly -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\GameBar' }
        }
        It "dry-run : n'écrit rien" {
            Enable-GamingTweak -DryRun $true -IsAdmin $true
            Should -Invoke Set-RegistryValue -Times 0 -Exactly
        }
        It "sans admin : Game Mode oui, HKLM non" {
            Enable-GamingTweak -DryRun $false -IsAdmin $false
            Should -Invoke Set-RegistryValue -Times 2 -Exactly
            Should -Invoke Set-RegistryValue -Times 0 -Exactly -ParameterFilter { $Path -like 'HKLM:*' }
        }
    }

    Context "plan d'alimentation" {
        It 'Balanced déjà actif : ne change rien' {
            Confirm-BalancedPowerPlan -DryRun $false -Auto $false | Should -BeTrue
            Should -Invoke Invoke-PowerCfg -Times 0 -Exactly -ParameterFilter { $Arguments -contains '/setactive' }
            Should -Invoke Read-Host -Times 0 -Exactly
        }
        It 'autre plan en Auto : avertit sans rien changer' {
            Mock Invoke-PowerCfg { 'GUID : 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (Performances élevées)' }
            Confirm-BalancedPowerPlan -DryRun $false -Auto $true | Should -BeFalse
            Should -Invoke Invoke-PowerCfg -Times 0 -Exactly -ParameterFilter { $Arguments -contains '/setactive' }
            Should -Invoke Read-Host -Times 0 -Exactly
        }
        It 'autre plan en interactif + oui : rétablit Balanced (et rien d''autre)' {
            Mock Invoke-PowerCfg { 'GUID : 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (Performances élevées)' }
            Mock Read-Host { 'o' }
            $null = Confirm-BalancedPowerPlan -DryRun $false -Auto $false
            Should -Invoke Invoke-PowerCfg -Times 1 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq "/setactive $BalancedGuid" }
        }
        It 'dry-run : ne change jamais le plan' {
            Mock Invoke-PowerCfg { 'GUID : 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (Performances élevées)' }
            Mock Read-Host { 'o' }
            $null = Confirm-BalancedPowerPlan -DryRun $true -Auto $false
            Should -Invoke Invoke-PowerCfg -Times 0 -Exactly -ParameterFilter { $Arguments -contains '/setactive' }
        }
    }

    Context 'Epic (GameUserSettings.ini dans $TestDrive)' {
        BeforeEach { $script:ini = Join-Path $TestDrive ("GameUserSettings-{0}.ini" -f [guid]::NewGuid().ToString('N')) }

        It 'pose DefaultAppInstallLocation dans [Launcher], avec backup, puis ne retouche plus rien' {
            Set-Content -LiteralPath $ini -Value "[Launcher]`r`nSomeKey=1`r`n`r`n[Other]`r`nX=2" -Encoding ASCII
            Invoke-EpicDefaultLocation -Target 'D:\Games\Epic' -IniPath @($ini) -DryRun $false | Should -Be 'ecrit'
            $txt = Get-Content -LiteralPath $ini -Raw
            $txt | Should -Match '\[Launcher\]\r\nSomeKey=1\r\nDefaultAppInstallLocation=D:\\Games\\Epic\r\n'
            $txt | Should -Match '\[Other\]\r\nX=2'
            @(Get-ChildItem "$ini.before-resetpack-*").Count | Should -Be 1

            Invoke-EpicDefaultLocation -Target 'D:\Games\Epic' -IniPath @($ini) -DryRun $false | Should -Be 'ok'
            @(Get-ChildItem "$ini.before-resetpack-*").Count | Should -Be 1
        }
        It 'remplace une ancienne valeur et crée la section si elle manque' {
            Set-Content -LiteralPath $ini -Value "[Launcher]`nDefaultAppInstallLocation=C:\Program Files\Epic Games" -Encoding ASCII
            $null = Invoke-EpicDefaultLocation -Target 'D:\Games\Epic' -IniPath @($ini) -DryRun $false
            (Get-Content -LiteralPath $ini) | Should -Contain 'DefaultAppInstallLocation=D:\Games\Epic'
            (Get-Content -LiteralPath $ini) | Should -Not -Contain 'DefaultAppInstallLocation=C:\Program Files\Epic Games'

            $m = Merge-IniSetting -Lines @('[Other]', 'X=1') -Section 'Launcher' -Key 'DefaultAppInstallLocation' -Value 'D:\Games\Epic'
            $m.Changed | Should -BeTrue
            ($m.Lines -join '|') | Should -Be '[Other]|X=1||[Launcher]|DefaultAppInstallLocation=D:\Games\Epic'
        }
        It "conserve l'encodage UTF-16 du fichier" {
            [IO.File]::WriteAllText($ini, "[Launcher]`r`nA=1`r`n", [Text.Encoding]::Unicode)
            $null = Invoke-EpicDefaultLocation -Target 'D:\Games\Epic' -IniPath @($ini) -DryRun $false
            $b = [IO.File]::ReadAllBytes($ini)
            ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) | Should -BeTrue
            [IO.File]::ReadAllText($ini, [Text.Encoding]::Unicode) | Should -Match 'DefaultAppInstallLocation=D:\\Games\\Epic'
        }
        It "dry-run : ne touche pas au fichier" {
            Set-Content -LiteralPath $ini -Value "[Launcher]`r`nA=1" -Encoding ASCII
            $before = Get-Content -LiteralPath $ini -Raw
            Invoke-EpicDefaultLocation -Target 'D:\Games\Epic' -IniPath @($ini) -DryRun $true | Should -Be 'dry'
            Get-Content -LiteralPath $ini -Raw | Should -Be $before
            @(Get-ChildItem "$ini.before-resetpack-*" -ErrorAction SilentlyContinue).Count | Should -Be 0
        }
        It "fichier absent : instruction, aucun fichier créé" {
            Invoke-EpicDefaultLocation -Target 'D:\Games\Epic' -IniPath @($ini) -DryRun $false | Should -Be 'absent'
            $ini | Should -Not -Exist
        }
        It "Epic ouvert : n'écrit pas (il écraserait le fichier en quittant)" {
            Set-Content -LiteralPath $ini -Value "[Launcher]`r`nA=1" -Encoding ASCII
            Mock Get-Process { [pscustomobject]@{ Name = 'EpicGamesLauncher' } }
            Invoke-EpicDefaultLocation -Target 'D:\Games\Epic' -IniPath @($ini) -DryRun $false | Should -Be 'ouvert'
            (Get-Content -LiteralPath $ini -Raw) | Should -Not -Match 'DefaultAppInstallLocation'
        }
    }

    Context 'OMEN Gaming Hub muselé, pas tué' {
        BeforeEach {
            Mock Get-AppxPackage { [pscustomobject]@{
                Name = 'AD2F1837.OMENCommandCenter'; PackageFullName = "AD2F1837.OMENCommandCenter_1.0.0.0_x64__v10z8vjag6ke6"
                PackageFamilyName = $OmenPfn; InstallLocation = $null } }
            Mock Get-AppxPackageManifest { [xml]$OmenManifest }
            Mock Test-Path -ParameterFilter { "$LiteralPath" -like 'HKCU:\*' } { $false }
        }
        It 'désactive la tâche de démarrage GUI (State=1) et les notifications (Enabled=0)' {
            Disable-OmenHubNoise -DryRun $false -IsAdmin $true
            Should -Invoke Set-RegistryValue -Times 1 -Exactly -ParameterFilter {
                $Path -like "*\AppModel\SystemAppData\$OmenPfn\OmenCommandCenterStartup" -and $Name -eq 'State' -and $Value -eq 1 }
            Should -Invoke Set-RegistryValue -Times 1 -Exactly -ParameterFilter {
                $Path -like "*\Notifications\Settings\$OmenPfn!App" -and $Name -eq 'Enabled' -and $Value -eq 0 }
        }
        It 'désactive (sans supprimer) les entrées Run qui matchent OMEN, et seulement elles' {
            Mock Get-ItemProperty -ParameterFilter { $LiteralPath -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' } {
                [pscustomobject]@{ OmenOverlay = 'C:\Program Files\HP\OMEN\overlay.exe'; OneDrive = 'C:\x\OneDrive.exe'; Women = 'C:\x\w.exe' } }
            Mock Remove-ItemProperty { }
            Disable-OmenHubNoise -DryRun $false -IsAdmin $true
            Should -Invoke Set-RegistryValue -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -and $Name -eq 'OmenOverlay' -and $Type -eq 'Binary' }
            Should -Invoke Set-RegistryValue -Times 0 -Exactly -ParameterFilter { $Name -in 'OneDrive', 'Women' }
            Should -Invoke Remove-ItemProperty -Times 0 -Exactly
        }
        It "ne réécrit pas une entrée déjà désactivée" {
            Mock Get-ItemProperty -ParameterFilter { $LiteralPath -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' } {
                [pscustomobject]@{ OmenOverlay = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) } }
            Disable-OmenHubNoise -DryRun $false -IsAdmin $true
            Should -Invoke Set-RegistryValue -Times 0 -Exactly -ParameterFilter { $Name -eq 'OmenOverlay' }
        }
        It "dry-run : n'écrit rien" {
            Disable-OmenHubNoise -DryRun $true -IsAdmin $true
            Should -Invoke Set-RegistryValue -Times 0 -Exactly
        }
    }

    Context 'sécurité (lecture seule)' {
        It 'signale une exclusion Defender sous D:\Games' {
            Mock Get-MpPreference { [pscustomobject]@{ ExclusionPath = @('D:\Games\Steam\steamapps', 'C:\Temp') } }
            Mock Write-Warn { }
            Test-GamingSecurity -GamesRoot @('D:\Games') | Should -BeFalse
            Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $msg -like '*D:\Games\Steam\steamapps*' -and $msg -notlike '*C:\Temp*' }
            Should -Invoke Set-MpPreference -Times 0 -Exactly
        }
        It 'signale Memory Integrity inactive' {
            Mock Get-CimInstance { [pscustomobject]@{ VirtualizationBasedSecurityStatus = 2; SecurityServicesRunning = @(1) } }
            Mock Write-Warn { }
            Test-GamingSecurity -GamesRoot @('D:\Games') | Should -BeFalse
            Should -Invoke Write-Warn -Times 1 -ParameterFilter { $msg -like '*Intégrité de la mémoire*INACTIVE*' }
        }
        It 'tout est vert : aucun warning' {
            Mock Write-Warn { }
            Test-GamingSecurity -GamesRoot @('D:\Games') | Should -BeTrue
            Should -Invoke Write-Warn -Times 0 -Exactly
        }
        It 'détecte les recouvrements de chemins (parent, enfant, joker)' {
            Test-PathOverlap -Path 'D:\' -Root 'D:\Games' | Should -BeTrue
            Test-PathOverlap -Path 'D:\Games\*' -Root 'D:\Games' | Should -BeTrue
            Test-PathOverlap -Path 'd:\games\epic' -Root 'D:\Games' | Should -BeTrue
            Test-PathOverlap -Path 'D:\GamesOld' -Root 'D:\Games' | Should -BeFalse
            Test-PathOverlap -Path 'C:\Temp' -Root 'D:\Games' | Should -BeFalse
        }
    }

    Context 'Invoke-Gaming (disque des jeux)' {
        BeforeEach {
            $script:layout = [pscustomobject]@{
                Name = 'omen'; gamesDisk = [pscustomobject]@{ letter = 'Q' }
                launchers = [pscustomobject]@{ Steam = "$TestDrive\Games\Steam"; Epic = "$TestDrive\Games\Epic" }
                captures = "$TestDrive\Captures"
            }
            Mock Invoke-LauncherSetup { }
        }
        It 'D: absent : saute les launchers avec un warning mais fait quand même les tweaks' {
            Mock Test-DriveReady { $false }
            Mock Write-Warn { }
            Invoke-Gaming -Layout $layout -EpicIniPath @("$TestDrive\absent.ini") -DryRun $false -Auto $true -IsAdmin $true
            Should -Invoke Invoke-LauncherSetup -Times 0 -Exactly
            Should -Invoke Write-Warn -ParameterFilter { $msg -like '*absent*launchers saut*' } -Times 1
            Should -Invoke Set-RegistryValue -Times 1 -Exactly -ParameterFilter { $Name -eq 'AutoGameModeEnabled' -and $Value -eq 1 }
        }
        It 'D: présent : configure les launchers' {
            Mock Test-DriveReady { $true }
            Invoke-Gaming -Layout $layout -EpicIniPath @("$TestDrive\absent.ini") -DryRun $false -Auto $true -IsAdmin $true
            Should -Invoke Invoke-LauncherSetup -Times 1 -Exactly
        }
        It 'passe toutes les racines de jeux (liste à plat) au contrôle des exclusions' {
            Mock Test-DriveReady { $true }
            Mock Test-GamingSecurity { $true }
            $two = [pscustomobject]@{ Name = 'x'; launchers = [pscustomobject]@{ Steam = 'D:\Games\Steam'; Other = 'E:\Jeux\Other' } }
            Invoke-Gaming -Layout $two -EpicIniPath @("$TestDrive\absent.ini") -DryRun $true -Auto $true -IsAdmin $true
            Should -Invoke Test-GamingSecurity -Times 1 -Exactly -ParameterFilter {
                $GamesRoot.Count -eq 2 -and $GamesRoot[0] -eq 'D:\Games' -and $GamesRoot[1] -eq 'E:\Jeux' }
        }
        It 'déduit la racine des jeux du layout (parent commun des launchers)' {
            (@(Get-GamesRoot -Layout ([pscustomobject]@{ launchers = [pscustomobject]@{ Steam = 'D:\Games\Steam'; Epic = 'D:\Games\Epic' } })) -join '|') |
                Should -Be 'D:\Games'
            (@(Get-GamesRoot -Layout ([pscustomobject]@{ launchers = [pscustomobject]@{ Steam = 'D:\SteamLibrary' } })) -join '|') |
                Should -Be 'D:\SteamLibrary'
        }
    }
}

# ============================================================================
Describe 'config/profiles.json (place des modules du lot 4)' {
    BeforeAll { $script:omen = (Get-Content "$Repo\config\profiles.json" -Raw | ConvertFrom-Json).profiles.omen }

    It 'lance hp-triage en premier dans le profil omen' {
        $omen.modules[0] | Should -Be 'hp-triage'
    }
    It 'lance gaming après tweaks (pour rallumer le Game Mode)' {
        $mods = @($omen.modules)
        [array]::IndexOf($mods, 'gaming') | Should -BeGreaterThan ([array]::IndexOf($mods, 'tweaks'))
        [array]::IndexOf($mods, 'tweaks') | Should -BeGreaterOrEqual 0
    }
}
