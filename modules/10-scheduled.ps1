# Tâches planifiées : winget upgrade hebdo + dark/light mode auto
. "$PSScriptRoot\00-helpers.ps1"

# === 1. winget upgrade --all (chaque dimanche 14h) ===
Write-Step "Tâche : winget upgrade hebdo (dim. 14h)"
$wingetTask = 'ResetPack-WingetUpgrade'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -Command "winget upgrade --all --silent --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2pm
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $wingetTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Ok "Tâche winget hebdo créée"

# === 2. Dark mode auto (clair 7h, sombre 20h) ===
Write-Step "Taches : dark/light auto (7h <-> 20h)"

$lightCmd = '-NoProfile -WindowStyle Hidden -Command "Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name AppsUseLightTheme -Value 1; Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name SystemUsesLightTheme -Value 1"'
$darkCmd = '-NoProfile -WindowStyle Hidden -Command "Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name AppsUseLightTheme -Value 0; Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name SystemUsesLightTheme -Value 0"'

$lightAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $lightCmd
$lightTrigger = New-ScheduledTaskTrigger -Daily -At 7am
Register-ScheduledTask -TaskName 'ResetPack-LightMode' -Action $lightAction -Trigger $lightTrigger -Principal $principal -Settings $settings -Force | Out-Null

$darkAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $darkCmd
$darkTrigger = New-ScheduledTaskTrigger -Daily -At 8pm
Register-ScheduledTask -TaskName 'ResetPack-DarkMode' -Action $darkAction -Trigger $darkTrigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Ok "Tâches dark/light créées"

# === 3. Désactiver apps de merde au startup ===
Write-Step "Désactiver apps inutiles au startup"
$startupBlock = @(
    'OneDriveSetup'      # le vrai OneDrive reste, c'est juste le setup résiduel
    'com.squirrel.Teams.Teams'
    'Discord'
    'Spotify'
    'Steam'
    'EpicGamesLauncher'
    'Skype'
)
$startupRun = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($name in $startupBlock) {
    if (Get-ItemProperty -Path $startupRun -Name $name -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $startupRun -Name $name -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed startup: $name"
    }
}
# Disable via registre StartupApproved aussi (Win10/11 Task Manager startup)
$approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
if (Test-Path $approved) {
    foreach ($name in $startupBlock) {
        if (Get-ItemProperty -Path $approved -Name $name -ErrorAction SilentlyContinue) {
            # 0x03 0x00... = disabled
            Set-ItemProperty -Path $approved -Name $name -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Force
        }
    }
}

Write-Ok "Scheduled OK"
