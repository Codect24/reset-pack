# Vire Cortana + apps preinstallees (GARDE OneDrive)
. "$PSScriptRoot\00-helpers.ps1"

# IMPORTANT : Remove-AppxPackage est irréversible -> on NE fait RIEN en dry-run.
if ($script:DryRun) { Write-Dry "debloat : désinstalle les apps préinstallées (simulation, rien supprimé)"; Write-Ok "Debloat OK (dry)"; return }

# Apps a virer
$bloat = @(
    'Microsoft.549981C3F5F10'                          # Cortana (proteged sur Win11 23H2+, peut echouer)
    'Microsoft.BingNews'
    'Microsoft.BingWeather'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MixedReality.Portal'
    'Microsoft.Office.OneNote'
    'Microsoft.People'
    'Microsoft.SkypeApp'
    'Microsoft.Wallet'
    'Microsoft.windowscommunicationsapps'              # Mail/Calendar
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxApp'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.YourPhone'
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'
    'MicrosoftCorporationII.QuickAssist'
    'Microsoft.Todos'
    'Clipchamp.Clipchamp'
    'Microsoft.PowerAutomateDesktop'
)

# A NE PAS virer (securite)
$keep = @('Microsoft.OneDrive', 'Microsoft.WindowsStore', 'Microsoft.WindowsTerminal', 'Microsoft.PowerToys', 'Microsoft.WindowsCalculator', 'Microsoft.ScreenSketch', 'Microsoft.Paint', 'Microsoft.WindowsNotepad')

foreach ($app in $bloat) {
    if ($keep -contains $app) { continue }

    $pkg = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
    if (-not $pkg) {
        Write-Step "Skip (absent): $app"
        continue
    }

    Write-Step "Uninstall: $app"
    try {
        $pkg | Remove-AppxPackage -AllUsers -ErrorAction Stop
        Write-Ok "Removed: $app"
    } catch {
        Write-Warn "Skip ($app) : $($_.Exception.Message)"
    }

    try {
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $app |
            Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null
    } catch {
        # silencieux : provisioned package peut ne pas exister
    }
}

Write-Ok "Debloat OK (OneDrive preserve)"
