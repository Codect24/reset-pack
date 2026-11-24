# backup-secrets.ps1 — sauvegarde HORS OneDrive de ce que le reset détruit (SSH, .env, clés API).
# Rien n'est écrit dans OneDrive. Chiffre l'archive produite et garde-la hors ligne.
param([string]$Dest)
. "$PSScriptRoot\modules\00-helpers.ps1"
Write-Banner "BACKUP SECRETS (hors OneDrive)"

if (-not $Dest) {
    Write-Warn "Usage : .\backup-secrets.ps1 -Dest E:\ResetBackup   (clé USB / disque externe / NAS)"
    Write-Warn "Ne vise PAS un dossier OneDrive : des clés privées ne vont pas dans le cloud."
    return
}
if ($Dest -match 'OneDrive') { Write-Err "Dest dans OneDrive interdite pour des secrets. Choisis un disque hors-ligne."; return }

$stage = Join-Path $Dest ("secrets-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# 1. SSH
if (Test-Path "$env:USERPROFILE\.ssh") {
    Copy-Item "$env:USERPROFILE\.ssh" (Join-Path $stage '.ssh') -Recurse -Force
    Write-Ok "SSH -> .ssh"
} else { Write-Warn "Pas de ~/.ssh" }

# 2. Fichiers .env des projets (MCP maison atlas / tom-lefrere + autres)
$codeRoot = Join-Path $script:OneDriveRoot 'Documents\03_Projets_Code'
$envDir = Join-Path $stage 'env-files'
New-Item -ItemType Directory -Force -Path $envDir | Out-Null
if (Test-Path $codeRoot) {
    Get-ChildItem $codeRoot -Recurse -Force -Include '.env', '*.env' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' } | ForEach-Object {
            $rel = $_.FullName.Substring($codeRoot.Length).TrimStart('\') -replace '[\\/]', '__'
            Copy-Item $_.FullName (Join-Path $envDir $rel) -Force
        }
    Write-Ok ".env -> env-files"
}

# 3. Variables d'env user susceptibles de contenir des secrets (clés API wavespeed/atlas...)
Get-ChildItem Env: | Where-Object { $_.Name -match 'KEY|TOKEN|SECRET|API' } |
    ForEach-Object { "$($_.Name)=$($_.Value)" } | Set-Content (Join-Path $stage 'env-vars-sensibles.txt')
Write-Warn "env-vars-sensibles.txt : relis-le, retire ce qui ne doit pas être copié."

# 4. Rappels d'exports trop gros pour ce script
@"
À FAIRE À LA MAIN (trop volumineux) :
- WSL    : wsl --export Ubuntu  $Dest\ubuntu.tar   (+ Debian si utile)
- Docker : par volume utile ->
           docker run --rm -v <vol>:/data -v ${Dest}:/bak alpine tar czf /bak/<vol>.tgz /data
- Modèles HF : copier %USERPROFILE%\.cache\huggingface si le re-téléchargement est long.
"@ | Set-Content (Join-Path $stage 'TODO-exports.txt')

# 5. Archive
$zip = "$stage.zip"
Compress-Archive -Path "$stage\*" -DestinationPath $zip -Force
Write-Ok "Archive : $zip"
Write-Warn "CHIFFRE cette archive (7-Zip AES-256 + mot de passe, ou VeraCrypt) et garde-la HORS LIGNE."
