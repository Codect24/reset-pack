# 13-code : où vivent les projets + garde-fous git (cf. SYSTEME-OMEN-35L.md §3).
#   - PROJETS_CODE (User) = chemin CANONIQUE C:\Dev\03_Projets_Code (identique sur toutes les machines)
#   - gitignore global (~/.config/git/ignore : lu par git sans config) : secrets, caches, poids de modèles
#   - diagnostic : chemin canonique prêt ? consommateurs (hooks, MCP, skills) encore sur l'ancien chemin ?
# Le déplacement des dépôts lui-même = migrate-projets.ps1 (jamais fait implicitement par un module).
. "$PSScriptRoot\00-helpers.ps1"

$layout = Get-StorageLayout
$canon = $layout.projetsCode

# --- 1. Le chemin canonique existe-t-il ? ---
$item = Get-Item -LiteralPath $canon -Force -ErrorAction SilentlyContinue
$skipEnv = $false
if (-not $item) {
    if ($layout.PSObject.Properties.Name -contains 'projetsCodeJunctionTo' -and $layout.projetsCodeJunctionTo) {
        Write-Warn "$canon absent. Sur $($layout.Name), c'est une jonction vers $($layout.projetsCodeJunctionTo) :"
        Write-Warn "  .\migrate-projets.ps1 -Mode Junction -DryRun   puis sans -DryRun"
        $skipEnv = $true   # ne pas pointer PROJETS_CODE vers un chemin qui n'existe pas encore
    } else {
        Write-Warn "$canon absent : .\migrate-projets.ps1 -Mode Clone -DryRun   puis sans -DryRun"
        New-DirectorySafe -Path $canon | Out-Null
    }
} elseif ($item.LinkType) {
    Write-Ok "$canon = $($item.LinkType) -> $(@($item.Target)[0])"
} else {
    Write-Ok "$canon = dossier réel"
}

# --- 2. PROJETS_CODE (par machine ; lu par profile.ps1, les backups, migrate-projets) ---
if ($skipEnv) { Write-Warn "PROJETS_CODE non posé (jonction absente)." }
else { Set-UserEnvVar -Name 'PROJETS_CODE' -Value $canon }

# --- 3. Garde-fou : pas de code dans OneDrive sur l'OMEN ---
if ($layout.Name -eq 'omen') {
    if ($canon -match '(?i)\\OneDrive') { Write-Warn "projetsCode pointe DANS OneDrive ($canon) : contraire au plan (node_modules/.venv synchronisés)." }
    foreach ($old in @($layout.legacyProjetsRoots)) {
        if ($old -and (Test-Path -LiteralPath $old)) {
            Write-Warn "L'ancien $old est encore présent sur ce PC : une fois migrate-projets.ps1 validé,"
            Write-Warn "  OneDrive > Paramètres > Compte > Choisir les dossiers > DÉCOCHE 03_Projets_Code."
        }
    }
}

# --- 4. gitignore global (bloc balisé, idempotent) ---
# Fichier = core.excludesFile s'il est configuré (le .gitconfig est partagé via Configs), sinon ~/.config/git/ignore
# (lu par git sans aucune config). S'il manque sur ce PC, on repart de la copie sauvegardée par backup-configs.
$xf = ''
if (Test-CommandExists git) { $xf = "$(git config --global --get core.excludesFile 2>$null)".Trim() }
$ignoreFile = if ($xf) { ($xf -replace '^~', $env:USERPROFILE) -replace '/', '\' } else { Join-Path $env:USERPROFILE '.config\git\ignore' }
$savedIgnore = Join-Path $script:ConfigsRoot 'Git\gitignore_global'
if (-not (Test-Path $ignoreFile) -and (Test-Path $savedIgnore)) {
    if ($script:DryRun) { Write-Dry "restaure $ignoreFile depuis Configs\Git\gitignore_global" }
    else { New-Item -ItemType Directory -Force -Path (Split-Path $ignoreFile) | Out-Null; Copy-Item $savedIgnore $ignoreFile; Write-Ok "gitignore global restauré depuis Configs" }
}
$begin = '# >>> reset-pack (13-code) >>>'
$end   = '# <<< reset-pack (13-code) <<<'
$block = @"
$begin
# Géré par le Reset Pack : modifie plutôt modules/13-code.ps1. N'affecte pas les fichiers DÉJÀ suivis.
# OS / éditeurs
Thumbs.db
desktop.ini
.DS_Store
*.swp
# Secrets (filet de sécurité ; les modèles .example/.sample/.template restent committables)
.env
.env.*
!.env.example
!.env.sample
!.env.template
.claude/settings.local.json
# Python / Node
__pycache__/
*.py[cod]
.venv/
.ipynb_checkpoints/
node_modules/
# Deep learning : poids, checkpoints, runs (sinon les bundles explosent ; versionner avec git-lfs si voulu)
*.safetensors
*.ckpt
*.pt
*.pth
*.onnx
*.gguf
wandb/
mlruns/
lightning_logs/
$end
"@
$current = if (Test-Path $ignoreFile) { Get-Content $ignoreFile -Raw -Encoding UTF8 } else { '' }
$pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
$next = if ($current -match $pattern) { [regex]::Replace($current, $pattern, $block.TrimEnd().Replace('$', '$$')) }
        else { ($current.TrimEnd() + "`r`n`r`n" + $block).TrimStart() }
if ($next.TrimEnd() -eq $current.TrimEnd()) { Write-Ok "gitignore global déjà à jour ($ignoreFile)" }
elseif ($script:DryRun) { Write-Dry "écrire le bloc reset-pack dans $ignoreFile" }
else {
    New-Item -ItemType Directory -Force -Path (Split-Path $ignoreFile) | Out-Null
    [IO.File]::WriteAllText($ignoreFile, $next.TrimEnd() + "`r`n", (New-Object Text.UTF8Encoding $false))
    Write-Ok "gitignore global écrit ($ignoreFile)"
}
# --- 5. Git : chemins longs (node_modules profonds sous C:\Dev) ---
if (Test-CommandExists git) {
    $lp = git config --global --get core.longpaths 2>$null
    if ("$lp" -ne 'true') {
        if ($script:DryRun) { Write-Dry "git config --global core.longpaths true" }
        else { git config --global core.longpaths true; Write-Ok "git core.longpaths = true" }
    } else { Write-Ok "git core.longpaths déjà actif" }
}

# --- 6. Diagnostic des consommateurs encore sur l'ancien chemin (lecture seule) ---
$consumers = @(
    "$env:USERPROFILE\.claude\settings.json",
    "$env:USERPROFILE\.claude.json",
    "$env:APPDATA\Claude\claude_desktop_config.json",
    "$env:USERPROFILE\.claude\skills",
    "$env:USERPROFILE\.claude\CLAUDE.md"
)
$stale = @()
foreach ($c in $consumers) {
    if (-not (Test-Path -LiteralPath $c)) { continue }
    $files = if ((Get-Item -LiteralPath $c -Force).PSIsContainer) { Get-ChildItem -LiteralPath $c -Recurse -File -Include *.md, *.json -ErrorAction SilentlyContinue } else { Get-Item -LiteralPath $c -Force }
    foreach ($f in $files) {
        $t = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -and ((ConvertTo-CanonicalProjetsPath -Text $t) -ne $t)) { $stale += $f.FullName }
    }
}
if ($stale) {
    Write-Warn "Fichiers qui citent encore l'ancien chemin OneDrive des projets :"
    $stale | ForEach-Object { Write-Warn "  $_" }
    Write-Warn "-> .\migrate-projets.ps1 -ConsumersOnly -DryRun   (Claude Desktop/Code fermés pour le réel)"
} else { Write-Ok "Aucun consommateur sur l'ancien chemin" }

Write-Ok "Code OK (PROJETS_CODE = $canon)"
