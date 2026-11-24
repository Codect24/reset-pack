# tests/run-checks.ps1 — vérifs SANS RISQUE : parse AST + PSScriptAnalyzer + Pester.
# N'installe rien, ne modifie rien. Usage : .\tests\run-checks.ps1
param([switch]$SkipPester)
$repo = Split-Path $PSScriptRoot -Parent
$ok = $true

Write-Host "== Parse AST ==" -ForegroundColor Cyan
Get-ChildItem $repo -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\logs\\' } | ForEach-Object {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
    if ($e) { $ok = $false; Write-Host "  SYNTAX KO  $($_.Name)" -ForegroundColor Red; $e.Message | ForEach-Object { "     $_" } }
    else    { Write-Host "  ok  $($_.Name)" -ForegroundColor DarkGreen }
}

Write-Host "`n== PSScriptAnalyzer ==" -ForegroundColor Cyan
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer
    $res = Invoke-ScriptAnalyzer -Path $repo -Recurse -Severity Warning, Error -ErrorAction SilentlyContinue
    if ($res) { $res | Group-Object RuleName | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize | Out-Host }
    if ($res.Severity -contains 'Error') { $ok = $false; Write-Host "  Erreurs PSSA !" -ForegroundColor Red }
    else { Write-Host "  Pas d'erreur (warnings éventuels ci-dessus)." -ForegroundColor DarkGreen }
} else {
    Write-Host "  PSScriptAnalyzer absent : Install-Module PSScriptAnalyzer -Scope CurrentUser -Force" -ForegroundColor Yellow
}

if (-not $SkipPester) {
    Write-Host "`n== Pester ==" -ForegroundColor Cyan
    $p = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0' }
    if ($p) { Invoke-Pester -Path $PSScriptRoot -Output Detailed }
    else { Write-Host "  Pester v5 absent : Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck" -ForegroundColor Yellow }
}

Write-Host ""
if ($ok) { Write-Host "OK : aucune erreur bloquante (syntaxe + PSSA)." -ForegroundColor Green }
else { Write-Host "KO : corrige les erreurs ci-dessus." -ForegroundColor Red; exit 1 }
