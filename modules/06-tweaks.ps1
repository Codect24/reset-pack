# Tweaks Windows : Explorer, taskbar, privacy
. "$PSScriptRoot\00-helpers.ps1"

function Try-Tweak {
    param([string]$Label, [scriptblock]$Block)
    Write-Step $Label
    try { & $Block } catch { Write-Warn "Skip ($Label) : $($_.Exception.Message)" }
}

# === EXPLORER ===
$exp = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Try-Tweak "Afficher extensions de fichiers"        { Set-RegistryValue -Path $exp -Name 'HideFileExt' -Value 0 }
Try-Tweak "Afficher fichiers caches"               { Set-RegistryValue -Path $exp -Name 'Hidden' -Value 1 }

# === TASKBAR (Win11) ===
Try-Tweak "Desactiver widgets taskbar"             { Set-RegistryValue -Path $exp -Name 'TaskbarDa' -Value 0 }
Try-Tweak "Desactiver Copilot taskbar (HKCU)"      { Set-RegistryValue -Path $exp -Name 'ShowCopilotButton' -Value 0 }
Try-Tweak "Desactiver Copilot (policy HKCU)"       { Set-RegistryValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 }

# === MENU CONTEXTUEL CLASSIQUE (Win11) ===
Try-Tweak "Menu contextuel classique" {
    $ctxKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    if (-not (Test-Path $ctxKey)) { New-Item -Path $ctxKey -Force | Out-Null }
    Set-ItemProperty -Path $ctxKey -Name '(Default)' -Value '' -Force
}

# === PRIVACY / TELEMETRIE ===
Try-Tweak "Telemetrie off (HKLM Policies)"         { Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 }
Try-Tweak "Telemetrie off (HKLM CurrentVersion)"   { Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -Value 0 }

Try-Tweak "Bing search off (Start menu)"           { Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BingSearchEnabled' -Value 0 }
Try-Tweak "CortanaConsent off"                     { Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'CortanaConsent' -Value 0 }
Try-Tweak "Search box suggestions off"             { Set-RegistryValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -Value 1 }

$content = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
Try-Tweak "Suggested content off (Start)"          { Set-RegistryValue -Path $content -Name 'SubscribedContent-338388Enabled' -Value 0 }
Try-Tweak "Suggested content off (Settings)"       { Set-RegistryValue -Path $content -Name 'SubscribedContent-338389Enabled' -Value 0 }
Try-Tweak "Suggested content off (Settings 2)"     { Set-RegistryValue -Path $content -Name 'SubscribedContent-338393Enabled' -Value 0 }
Try-Tweak "Suggested content off (353694)"         { Set-RegistryValue -Path $content -Name 'SubscribedContent-353694Enabled' -Value 0 }
Try-Tweak "Suggested content off (353696)"         { Set-RegistryValue -Path $content -Name 'SubscribedContent-353696Enabled' -Value 0 }
Try-Tweak "Suggested content off (SystemPane)"     { Set-RegistryValue -Path $content -Name 'SystemPaneSuggestionsEnabled' -Value 0 }
Try-Tweak "Silent installed apps off"              { Set-RegistryValue -Path $content -Name 'SilentInstalledAppsEnabled' -Value 0 }

Try-Tweak "Win+V (clipboard history) on"           { Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Clipboard' -Name 'EnableClipboardHistory' -Value 1 }

# === GAME BAR / DVR (vire le popup 'ms-gamingoverlay' apres debloat Xbox) ===
Try-Tweak "Game DVR off (HKCU)"                    { Set-RegistryValue -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 }
Try-Tweak "Game DVR off (HKLM policy)"             { Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 }
$gb = 'HKCU:\Software\Microsoft\GameBar'
Try-Tweak "Game Bar - AppCapture off"              { Set-RegistryValue -Path $gb -Name 'AppCaptureEnabled' -Value 0 }
Try-Tweak "Game Bar - Nexus off"                   { Set-RegistryValue -Path $gb -Name 'UseNexusForGameBarEnabled' -Value 0 }
Try-Tweak "Game Bar - Startup panel off"           { Set-RegistryValue -Path $gb -Name 'ShowStartupPanel' -Value 0 }
Try-Tweak "Game Bar - Startup tip dismiss"         { Set-RegistryValue -Path $gb -Name 'GamePanelStartupTipIndex' -Value 3 }
Try-Tweak "Game Bar - AutoGameMode off"            { Set-RegistryValue -Path $gb -Name 'AutoGameModeEnabled' -Value 0 }

# === RESTART EXPLORER pour appliquer ===
Try-Tweak "Restart explorer.exe" {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process explorer.exe
}

Write-Ok "Tweaks OK"
