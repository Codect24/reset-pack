# migrate-projets.ps1 — met les projets au chemin CANONIQUE  C:\Dev\03_Projets_Code  (cf. SYSTEME-OMEN-35L.md §3.1).
#
# Pourquoi un chemin canonique : hooks Claude Code, serveurs MCP (atlas, tom-lefrere), skills et configs Claude sont
# PARTAGÉS entre machines via OneDrive\Configs. Avec le même chemin partout, un seul texte est juste sur les deux PC.
#
#   -Mode Junction  (EXODIUS, À FAIRE EN PREMIER) : C:\Dev\03_Projets_Code devient une JONCTION vers le dossier
#                   OneDrive actuel. Rien ne bouge physiquement, tout continue de marcher.
#   -Mode Clone     (OMEN) : vrai dossier C:\Dev\03_Projets_Code, HORS OneDrive. Chaque dépôt est cloné depuis son
#                   remote GitHub, sinon depuis son bundle (backup-bundles.ps1) ; les .env sont recopiés si la source
#                   OneDrive est présente. Les dossiers sans git sont listés (-CopyNonGit pour les copier).
#   Dans les 2 modes : PROJETS_CODE, mémoire Claude Code (dossiers ~/.claude/projects/<clé> renommés selon le
#   nouveau chemin), puis réécriture des consommateurs (sauf -SkipConsumers). -ConsumersOnly = cette dernière étape seule.
#
# Toujours :  .\migrate-projets.ps1 -DryRun   d'abord. Claude Desktop / Claude Code FERMÉS pour le réel
# (sinon .claude.json et claude_desktop_config.json sont sautés : ces apps les réécrivent en continu).
[CmdletBinding()]
param(
    [ValidateSet('Clone', 'Junction')][string]$Mode,
    [switch]$DryRun,
    [switch]$ConsumersOnly,
    [switch]$SkipConsumers,
    [switch]$CopyNonGit,
    [string]$Source,
    [string]$Dest
)
# 00-helpers pose $script:DryRun depuis l'env : on capture le switch avant, on le réapplique après.
$isDry = $DryRun.IsPresent -or ($env:RESETPACK_DRYRUN -eq '1')
. "$PSScriptRoot\modules\00-helpers.ps1"
$DryRun = $isDry; $script:DryRun = $isDry

$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Report = New-Object System.Collections.Generic.List[string]
function Add-Report([string]$m) { $script:Report.Add($m); Write-Warn $m }

# ---------------------------------------------------------------------------- inventaire
function Get-MigrationInventory {
    # Liste des dépôts à reconstruire : depuis le dossier source (OneDrive) s'il est là, + manifest.json des bundles.
    # PAS de `git status` / `rev-list` ici : sur l'OMEN la source est en « fichiers à la demande » et l'index vient
    # d'EXODIUS -> git re-hacherait chaque fichier suivi et HYDRATERAIT tout (des dizaines de Go). Seul .git/config est lu.
    # L'état sale / non poussé se vérifie sur EXODIUS avec pre-reset-check.ps1.
    param([string]$From, [string]$BundlesDir)
    $items = New-Object System.Collections.Generic.List[object]
    if ($From -and (Test-Path -LiteralPath $From)) {
        foreach ($repo in (Find-GitRepos -Root $From -MaxDepth 3)) {
            $rel = $repo.Substring($From.TrimEnd('\').Length).TrimStart('\')
            $remote = "$(git -C $repo config --get remote.origin.url 2>$null)".Trim()
            $items.Add([pscustomobject]@{ Rel = $rel; Remote = $remote; SourcePath = $repo; Bundle = $null
                                          Dirty = 0; Ahead = '' })
        }
    }
    $manifest = Join-Path $BundlesDir 'manifest.json'
    if (Test-Path $manifest) {
        $byRel = @{}; foreach ($i in $items) { $byRel[$i.Rel.ToLower()] = $i }
        foreach ($e in @((Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json).entries)) {
            $b = Join-Path $BundlesDir $e.bundle
            if (-not (Test-Path $b)) { continue }
            $k = "$($e.rel)".ToLower()
            if ($byRel.ContainsKey($k)) { $byRel[$k].Bundle = $b; continue }
            $items.Add([pscustomobject]@{ Rel = $e.rel; Remote = $e.remote; SourcePath = $null; Bundle = $b; Dirty = 0; Ahead = '' })
        }
    }
    return , $items.ToArray()
}

function Get-CloneSource {
    # Ordre : remote (GitHub) > bundle > dossier source local. Pure : testable.
    param([Parameter(Mandatory)]$Item)
    if ($Item.Remote) { return [pscustomobject]@{ Kind = 'remote'; Url = $Item.Remote } }
    if ($Item.Bundle) { return [pscustomobject]@{ Kind = 'bundle'; Url = $Item.Bundle } }
    if ($Item.SourcePath) { return [pscustomobject]@{ Kind = 'local'; Url = $Item.SourcePath } }
    return $null
}

# ---------------------------------------------------------------------------- mode Clone
function Invoke-CloneRepos {
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string]$To)
    $n = @{ clones = 0; presents = 0; echecs = 0 }
    foreach ($it in $Items) {
        $target = Join-Path $To $it.Rel
        if (Test-Path -LiteralPath (Join-Path $target '.git')) { $n.presents++; continue }
        if ($it.Dirty -gt 0) { Add-Report "$($it.Rel) : $($it.Dirty) fichier(s) NON committé(s) dans la source -> ils ne suivront pas le clone." }
        if ($it.Ahead -and $it.Ahead -ne '0') { Add-Report "$($it.Rel) : $($it.Ahead) commit(s) NON poussé(s) -> pousse depuis la source." }
        $src = Get-CloneSource -Item $it
        if (-not $src) { Add-Report "$($it.Rel) : aucune source (ni remote, ni bundle, ni dossier)."; $n.echecs++; continue }
        if ($DryRun) { Write-Dry "git clone [$($src.Kind)] $($src.Url) -> $target"; $n.clones++; continue }

        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        git clone --quiet $src.Url $target 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -and $src.Kind -eq 'remote' -and $it.Bundle) {
            Write-Warn "$($it.Rel) : clone GitHub KO -> repli sur le bundle"
            Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
            git clone --quiet $it.Bundle $target 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { git -C $target remote set-url origin $it.Remote }
        }
        if ($LASTEXITCODE -ne 0) { Write-Err "$($it.Rel) : clone KO"; $n.echecs++; continue }
        if ($src.Kind -ne 'remote') {
            git -C $target remote remove origin 2>$null
            Add-Report "$($it.Rel) : PAS de remote GitHub (cloné depuis $($src.Kind)) -> crée un dépôt privé et pousse."
        }
        Copy-EnvFile -FromRepo $it.SourcePath -ToRepo $target
        Write-Ok "$($it.Rel) [$($src.Kind)]"
        $n.clones++
    }
    Write-Ok ("Dépôts : {0} cloné(s), {1} déjà présent(s), {2} échec(s)" -f $n.clones, $n.presents, $n.echecs)
}

function Copy-EnvFile {
    # Les .env ne sont jamais dans git : on les recopie de la source (si présente) vers le clone.
    param([string]$FromRepo, [Parameter(Mandatory)][string]$ToRepo)
    if (-not $FromRepo -or -not (Test-Path -LiteralPath $FromRepo)) { return }
    Get-ChildItem -LiteralPath $FromRepo -Recurse -Force -File -Include '.env', '.env.*', '*.env' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|\.venv|\.git)\\' -and $_.Name -notmatch '\.(example|sample|template)$' } |
        ForEach-Object {
            $dst = Join-Path $ToRepo $_.FullName.Substring($FromRepo.TrimEnd('\').Length).TrimStart('\')
            if (Test-Path -LiteralPath $dst) { return }
            if ($DryRun) { Write-Dry "copie secret $($_.Name) -> $dst"; return }
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $dst
        }
}

function Show-NonGitFolder {
    # Dossiers de projets SANS git (1er niveau, et 1er niveau des dossiers 'année') : listés, copiés si -CopyNonGit.
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To, [object[]]$Items)
    $repoRels = @($Items | ForEach-Object { $_.Rel.ToLower() })
    $cands = @()
    foreach ($top in @(Get-ChildItem -LiteralPath $From -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($top.Name -match '^\d{4}(-\d{4})?$') { $cands += @(Get-ChildItem -LiteralPath $top.FullName -Directory -Force -ErrorAction SilentlyContinue) }
        else { $cands += $top }
    }
    foreach ($d in $cands) {
        $rel = $d.FullName.Substring($From.TrimEnd('\').Length).TrimStart('\')
        $low = $rel.ToLower()
        if (@($repoRels | Where-Object { $_ -eq $low -or $_.StartsWith("$low\") }).Count) { continue }   # dépôt ou contient des dépôts
        $mb = [math]::Round((Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
               Measure-Object Length -Sum).Sum / 1MB, 0)
        if (-not $CopyNonGit) { Add-Report "Sans git (reste dans OneDrive) : $rel  (~$mb Mo)"; continue }
        $dst = Join-Path $To $rel
        if ($DryRun) { Write-Dry "robocopy $rel (~$mb Mo, hors node_modules/.venv)"; continue }
        robocopy $d.FullName $dst /E /XD node_modules .venv venv __pycache__ .next dist build /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Err "$rel : robocopy KO ($LASTEXITCODE)" } else { Write-Ok "$rel copié (~$mb Mo)" }
    }
}

# ---------------------------------------------------------------------------- mode Junction
function Invoke-CreateJunction {
    param([Parameter(Mandatory)][string]$Link, [Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) { throw "Cible introuvable : $Target" }
    $it = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($it) {
        if ($it.LinkType -eq 'Junction' -and "$(@($it.Target)[0])".TrimEnd('\') -ieq $Target.TrimEnd('\')) { Write-Ok "Jonction déjà en place : $Link -> $Target"; return }
        throw "$Link existe déjà ($(if ($it.LinkType) { $it.LinkType } else { 'dossier réel' })) : rien n'est touché."
    }
    if ($DryRun) { Write-Dry "jonction $Link -> $Target"; return }
    New-Item -ItemType Directory -Force -Path (Split-Path $Link) | Out-Null
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    Write-Ok "Jonction créée : $Link -> $Target"
}

# ---------------------------------------------------------------------------- mémoire Claude Code
function Copy-ClaudeMemory {
    # ~/.claude/projects/<clé-ancien-chemin>/memory -> <clé-nouveau-chemin>/memory (copie : l'ancienne reste).
    # Sources : ce PC, puis la sauvegarde OneDrive\Configs\Claude-Code\memory (faite par backup-configs.ps1).
    param([Parameter(Mandatory)][string]$NewRoot)
    $projects = Join-Path $env:USERPROFILE '.claude\projects'
    $newPrefix = ConvertTo-ClaudeProjectKey -Path $NewRoot
    $rx = '^[A-Za-z]--Users-.+?-OneDrive-Documents-03-Projets-Code'
    $sources = @()
    if (Test-Path $projects) {
        $sources += @(Get-ChildItem $projects -Directory | Where-Object { $_.Name -match $rx -and (Test-Path (Join-Path $_.FullName 'memory')) } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Memory = (Join-Path $_.FullName 'memory') } })
    }
    $bak = Join-Path $script:ConfigsRoot 'Claude-Code\memory'
    if (Test-Path $bak) {
        $sources += @(Get-ChildItem $bak -Directory | Where-Object { $_.Name -match $rx } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Memory = $_.FullName } })
    }
    $done = 0
    foreach ($s in $sources) {
        $newName = [regex]::Replace($s.Name, $rx, $newPrefix)
        $dst = Join-Path $projects "$newName\memory"
        if ((Test-Path $dst) -and @(Get-ChildItem $dst -Force -ErrorAction SilentlyContinue).Count) { continue }
        if ($DryRun) { Write-Dry "mémoire Claude : $($s.Name) -> $newName"; $done++; continue }
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item -Path (Join-Path $s.Memory '*') -Destination $dst -Recurse -Force
        $done++
    }
    Write-Ok "Mémoire Claude Code : $done projet(s) rattaché(s) au nouveau chemin"
}

# ---------------------------------------------------------------------------- consommateurs
function Get-ConsumerFile {
    # Fichiers qui citent le chemin des projets, dédoublonnés sur leur cible réelle (beaucoup sont des symlinks vers Configs).
    $c = @(
        "$env:USERPROFILE\.claude\settings.json",
        "$env:USERPROFILE\.claude.json",
        "$env:APPDATA\Claude\claude_desktop_config.json",
        "$env:USERPROFILE\.claude\CLAUDE.md",
        "$script:ConfigsRoot\Claude-Code\.claude\settings.json",
        "$script:ConfigsRoot\Claude-Code\.claude.json",
        "$script:ConfigsRoot\Claude-Code\.claude\CLAUDE.md",
        "$script:ConfigsRoot\Claude-Desktop\claude_desktop_config.json"
    )
    foreach ($dir in @("$env:USERPROFILE\.claude\skills", "$env:USERPROFILE\.claude\commands",
                       "$script:ConfigsRoot\Claude-Code\.claude\skills", "$script:ConfigsRoot\Claude-Code\.claude\commands")) {
        if (Test-Path $dir) { $c += @(Get-ChildItem $dir -Recurse -File -Include *.md -ErrorAction SilentlyContinue | ForEach-Object FullName) }
    }
    $seen = @{}
    foreach ($p in $c) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $it = Get-Item -LiteralPath $p -Force
        $real = if ($it.LinkType -eq 'SymbolicLink') { "$(@($it.Target)[0])" } else { $it.FullName }
        if ($seen.ContainsKey($real.ToLower())) { continue }
        $seen[$real.ToLower()] = $true
        [pscustomobject]@{ Path = $p; Real = $real }
    }
}

function Update-ConsumerFile {
    # Réécrit l'ancien chemin OneDrive -> canonique. Backup horodaté, UTF-8 SANS BOM, JSON revalidé (sinon restauration).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Real, [bool]$AppRunning)
    $text = [IO.File]::ReadAllText($Real)
    $new = ConvertTo-CanonicalProjetsPath -Text $text
    if ($new -eq $text) { return 'inchangé' }
    $hits = ([regex]::Matches($text, '(?i)OneDrive[\\/]+Documents[\\/]+03_Projets_Code')).Count
    $live = ($Real -match '\\\.claude\.json$|claude_desktop_config\.json$')
    if ($live -and $AppRunning) { Add-Report "$Path : SAUTÉ (Claude ouvert, $hits occurrence(s)) -> ferme Claude et relance : .\migrate-projets.ps1 -ConsumersOnly"; return 'sauté' }
    if ($DryRun) { Write-Dry "$Path : $hits occurrence(s) -> C:\Dev\03_Projets_Code"; return 'à faire' }
    $bak = "$Real.before-migrate-$script:Stamp"
    Copy-Item -LiteralPath $Real -Destination $bak -Force
    [IO.File]::WriteAllText($Real, $new, (New-Object Text.UTF8Encoding $false))
    if ($Real -like '*.json') {
        try { $null = $new | ConvertFrom-Json -ErrorAction Stop }
        catch { Copy-Item -LiteralPath $bak -Destination $Real -Force; Write-Err "$Path : JSON invalide après réécriture -> restauré"; return 'échec' }
    }
    Write-Ok "$Path : $hits occurrence(s) réécrite(s) (backup : $(Split-Path $bak -Leaf))"
    return 'réécrit'
}

function Invoke-UpdateConsumers {
    Write-Banner "CONSOMMATEURS -> C:\Dev\03_Projets_Code"
    # Claude Desktop (Claude.exe), Claude Code natif (claude.exe) ou installé via npm (node ... claude-code).
    $running = [bool](Get-Process -Name 'claude' -ErrorAction SilentlyContinue)
    if (-not $running) {
        $running = [bool](Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'claude-code' })
    }
    if ($running) { Write-Warn "Claude (Desktop ou Code) est ouvert : .claude.json et claude_desktop_config.json seront sautés." }
    foreach ($f in @(Get-ConsumerFile)) { Update-ConsumerFile -Path $f.Path -Real $f.Real -AppRunning $running | Out-Null }
}

# ---------------------------------------------------------------------------- main
function Invoke-Main {
    $layout = Get-StorageLayout
    $to = if ($Dest) { $Dest } else { $layout.projetsCode }
    $from = if ($Source) { $Source } else { @($layout.legacyProjetsRoots)[0] }
    $m = if ($Mode) { $Mode } elseif ($layout.Name -eq 'exodius') { 'Junction' } else { 'Clone' }
    Write-Banner "MIGRATION PROJETS ($m$(if ($ConsumersOnly) { ', consommateurs seuls' })$(if ($DryRun) { ', DRY-RUN' }))"
    Write-Step "Profil $($layout.Name) | source : $from | cible : $to"
    if ($to -ine $script:CanonicalProjets) { Write-Warn "Cible ≠ chemin canonique ($script:CanonicalProjets) : les configs partagées ne suivront pas." }

    if (-not $ConsumersOnly) {
        if ($m -eq 'Junction') {
            Invoke-CreateJunction -Link $to -Target $from
        } else {
            if (-not (Test-CommandExists git)) { throw "git absent : lance d'abord .\reset.ps1 -Profile omen (apps + gh auth)." }
            $inv = Get-MigrationInventory -From $from -BundlesDir $layout.bundlesDir
            if (-not $inv.Count) { throw "Rien à migrer : ni $from, ni $($layout.bundlesDir)\manifest.json (lance backup-bundles.ps1 sur EXODIUS)." }
            Write-Step "$($inv.Count) dépôt(s) : $(@($inv | Where-Object Remote).Count) avec remote, $(@($inv | Where-Object { -not $_.Remote }).Count) sans"
            Write-Warn "Le travail NON committé / NON poussé ne suit pas : vérifie-le sur EXODIUS avec .\pre-reset-check.ps1"
            New-DirectorySafe -Path $to | Out-Null
            Invoke-CloneRepos -Items $inv -To $to
            if (Test-Path -LiteralPath $from) { Show-NonGitFolder -From $from -To $to -Items $inv }
        }
        Set-UserEnvVar -Name 'PROJETS_CODE' -Value $to
        Copy-ClaudeMemory -NewRoot $to
    }
    if (-not $SkipConsumers) { Invoke-UpdateConsumers }

    Write-Banner "À RETENIR"
    if ($script:Report.Count -eq 0) { Write-Ok "Rien à signaler." } else { $script:Report | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow } }
    if ($m -eq 'Clone' -and -not $ConsumersOnly) {
        Write-Host @"

  Ensuite (à la main) :
   1. Vérifie quelques projets dans $to (git status, .env présents).
   2. OneDrive > Paramètres > Compte > Choisir les dossiers > DÉCOCHE Documents\03_Projets_Code
      (OneDrive libère alors la place sur ce PC ; rien n'est supprimé dans le cloud).
   3. Ouvre désormais tes projets depuis $to (la mémoire Claude Code y a été rattachée).
"@ -ForegroundColor Gray
    }
    Write-Warn "Rouvre tes terminaux pour voir PROJETS_CODE."
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Main } catch { Write-Err $_.Exception.Message; exit 1 }
}
