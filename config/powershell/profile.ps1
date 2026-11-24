# PowerShell profile - Reset Pack
# Symlinke vers $PROFILE par modules/04-symlinks.ps1

# History smart navigation
Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle ListView
Set-PSReadLineOption -EditMode Windows -BellStyle None
Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete

# Aliases
Set-Alias g  git
Set-Alias ll Get-ChildItem
function .. { Set-Location .. }
function ... { Set-Location ../.. }
function gs { git status $args }
function gp { git pull $args }
function gco { git checkout $args }
function code-here { code . }
function explorer-here { explorer . }

# Fast nav vers projets (OneDrive dynamique : marche même si déplacé sur D:)
$OneDriveRoot = if ($env:OneDrive) { $env:OneDrive } else { "$env:USERPROFILE\OneDrive" }
function proj { Set-Location "$OneDriveRoot\Documents\03_Projets_Code" }
function reset-pack { Set-Location "$OneDriveRoot\Documents\03_Projets_Code\2026\Reset_pack" }

# Prompt minimal avec git branch
function prompt {
    $loc = (Get-Location).Path.Replace($env:USERPROFILE, '~')
    $branch = ''
    try {
        $b = git branch --show-current 2>$null
        if ($b) { $branch = " [$b]" }
    } catch {}
    Write-Host "$loc" -NoNewline -ForegroundColor Cyan
    Write-Host "$branch" -NoNewline -ForegroundColor Yellow
    Write-Host " >" -NoNewline -ForegroundColor White
    return ' '
}

# Welcome
Write-Host "PowerShell ready" -ForegroundColor DarkGray
