# Apps par defaut via PS-SFTA (port PowerShell de SetUserFTA - kolbi.cz est mort)
# Source : https://github.com/DanysysTeam/PS-SFTA (MIT)
. "$PSScriptRoot\00-helpers.ps1"

# Telecharge PS-SFTA si pas deja en cache
$sftaPs1 = "$script:DownloadDir\SFTA.ps1"
if (-not (Test-Path $sftaPs1)) {
    Write-Step "Download PS-SFTA"
    try {
        Invoke-Download -Url 'https://raw.githubusercontent.com/DanysysTeam/PS-SFTA/master/SFTA.ps1' -OutFile $sftaPs1
    } catch {
        Write-Err "DL PS-SFTA echec : $_"
        Write-Warn "Manuel : Settings > Apps > Default apps"
        return
    }
}

# Charge les fonctions Set-FTA / Set-PTA dans la session
. $sftaPs1

# (extension, ProgID) - les ProgIDs sont fournis par les apps installees
$ftaMappings = @(
    @{ Ext='.htm';  Prog='BraveHTML' }
    @{ Ext='.html'; Prog='BraveHTML' }
    @{ Ext='.pdf';  Prog='BraveHTML' }
    @{ Ext='.svg';  Prog='BraveHTML' }
    @{ Ext='.webp'; Prog='BraveHTML' }

    @{ Ext='.mp4';  Prog='VLC.mp4' }
    @{ Ext='.mkv';  Prog='VLC.mkv' }
    @{ Ext='.avi';  Prog='VLC.avi' }
    @{ Ext='.mov';  Prog='VLC.mov' }
    @{ Ext='.webm'; Prog='VLC.webm' }
    @{ Ext='.mp3';  Prog='VLC.mp3' }
    @{ Ext='.flac'; Prog='VLC.flac' }
    @{ Ext='.wav';  Prog='VLC.wav' }
    @{ Ext='.m4a';  Prog='VLC.m4a' }
    @{ Ext='.ogg';  Prog='VLC.ogg' }
)

foreach ($m in $ftaMappings) {
    Write-Step "$($m.Ext) -> $($m.Prog)"
    try {
        Set-FTA $m.Prog $m.Ext
    } catch {
        Write-Warn "Skip $($m.Ext) : $($_.Exception.Message)"
    }
}

# Protocoles (http/https) -> Brave
foreach ($proto in 'http','https') {
    Write-Step "$proto -> BraveHTML"
    try {
        Set-PTA BraveHTML $proto
    } catch {
        Write-Warn "Skip $proto : $($_.Exception.Message)"
    }
}

Write-Ok "Defaults OK (verifier dans Settings > Apps > Default apps)"
