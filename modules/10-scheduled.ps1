# Tâches planifiées : winget upgrade hebdo + dark/light mode auto
. "$PSScriptRoot\00-helpers.ps1"

# === 1. winget upgrade --all (chaque dimanche 14h) ===
Write-Step "Tâche : winget upgrade hebdo (dim. 14h)"
$wingetTask = 'ResetPack-WingetUpgrade'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -Command "winget upgrade --all --silent --accept-package-agreements --accept-source-agreements --include-unknown --disable-interactivity"'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2pm
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTaskSafe -Params @{ TaskName=$wingetTask; Action=$action; Trigger=$trigger; Principal=$principal; Settings=$settings }
Write-Ok "Tâche winget hebdo créée"

# === 2. Dark mode auto (clair 7h, sombre 20h) ===
Write-Step "Taches : dark/light auto (7h <-> 20h)"

$lightCmd = '-NoProfile -WindowStyle Hidden -Command "Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name AppsUseLightTheme -Value 1; Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name SystemUsesLightTheme -Value 1"'
$darkCmd = '-NoProfile -WindowStyle Hidden -Command "Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name AppsUseLightTheme -Value 0; Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name SystemUsesLightTheme -Value 0"'

$lightAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $lightCmd
$lightTrigger = New-ScheduledTaskTrigger -Daily -At 7am
Register-ScheduledTaskSafe -Params @{ TaskName='ResetPack-LightMode'; Action=$lightAction; Trigger=$lightTrigger; Principal=$principal; Settings=$settings }

$darkAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $darkCmd
$darkTrigger = New-ScheduledTaskTrigger -Daily -At 8pm
Register-ScheduledTaskSafe -Params @{ TaskName='ResetPack-DarkMode'; Action=$darkAction; Trigger=$darkTrigger; Principal=$principal; Settings=$settings }

Write-Ok "Tâches dark/light créées"

# === 2b. Bundles git quotidiens 13h (copie n°2 du code, cf. backup-bundles.ps1) ===
Write-Step "Tâche : bundles git quotidiens (13h)"
$bundleScript = Join-Path $script:Root 'backup-bundles.ps1'
$bundleAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bundleScript`" -Quiet"
$bundleTrigger = New-ScheduledTaskTrigger -Daily -At 1pm
Register-ScheduledTaskSafe -Params @{ TaskName='ResetPack-CodeBundles'; Action=$bundleAction; Trigger=$bundleTrigger; Principal=$principal; Settings=$settings }
Write-Ok "Tâche bundles créée (log : %LOCALAPPDATA%\ResetPack\bundles.log)"

if ((Get-ResetProfile) -eq 'omen') {
    # === 2c. Docker : purge LÉGÈRE hebdo (images orphelines + cache de build > 30 j ; jamais conteneurs ni volumes) ===
    Write-Step "Tâche : purge Docker légère (dim. 15h)"
    $dockerCmd = '-NoProfile -WindowStyle Hidden -Command "if (Get-Command docker -ErrorAction SilentlyContinue) { docker image prune -f; docker builder prune -f --filter until=720h }"'
    $dockerAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $dockerCmd
    $dockerTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3pm
    Register-ScheduledTaskSafe -Params @{ TaskName='ResetPack-DockerPrune'; Action=$dockerAction; Trigger=$dockerTrigger; Principal=$principal; Settings=$settings }

    # === 2d. Log thermique la 1re SEMAINE (TX401 sous l'échappement du RTX 5080, runs DL longs) ===
    Write-Step "Tâche : log thermique toutes les 5 min pendant 7 jours"
    $thermalScript = Join-Path $script:Root 'scripts\thermal-log.ps1'
    $thermalAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$thermalScript`""
    $thermalTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 7)
    $thermalSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTaskSafe -Params @{ TaskName='ResetPack-ThermalLog'; Action=$thermalAction; Trigger=$thermalTrigger; Principal=$principal; Settings=$thermalSettings }
    Write-Ok "Tâches Docker + thermique créées (log : %LOCALAPPDATA%\ResetPack\thermal)"
}

# === 3. Désactiver apps de merde au startup ===
# NOTE : ces entrées (Discord/Spotify/Steam/Teams/Epic) ne sont créées qu'au 1er lancement
# de chaque app. Sur une machine fraîche elles n'existent pas encore -> ce bloc ne désarme
# que ce qui est déjà présent (utile en re-run / usage courant, quasi no-op juste après reset).
Write-Step "Désactiver apps inutiles au startup (si déjà présentes)"
if ($script:DryRun) { Write-Dry "désactivation startup (skip en dry-run)"; Write-Ok "Scheduled OK"; return }
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
