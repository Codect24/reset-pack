# Reset Pack

Automatise la réinstallation complète d'un PC Windows 11 après reset (machine *EXODIUS*).

> Audit machine + plan de tri 2 disques : voir **[AUDIT-RESET-2026.md](AUDIT-RESET-2026.md)**.

## Démarrage ultra-rapide (machine fraîchement resetée)

OneDrive (donc le pack) n'existe pas encore juste après un reset. Une seule ligne dans **PowerShell** amorce tout (installe winget + git, clone depuis GitHub dans `C:\ResetPack`, lance le pack) :

```powershell
irm https://raw.githubusercontent.com/Codect24/reset-pack/main/bootstrap.ps1 | iex
```

> Le dépôt doit être **public** pour que cette commande fonctionne.

## Utilisation

### Avant le reset (sur le PC actuel)

```powershell
.\pre-reset-check.ps1        # repère les dépôts non poussés, .env, SSH, WSL/Docker à sauver
```

```powershell
.\backup-configs.ps1         # backup des configs légères -> OneDrive\...\Configs
```

```powershell
.\backup-secrets.ps1 -Dest E:\ResetBackup   # SSH + .env + clés -> HORS OneDrive (à chiffrer)
```

### Après le reset

```powershell
.\reset.ps1                  # interactif : demande confirmation à chaque module
```

```powershell
.\reset.ps1 -DryRun          # SIMULATION : montre tout ce qui serait fait, ne modifie RIEN
```

```powershell
.\reset.ps1 -Auto            # enchaîne tout sans question
```

```powershell
.\reset.ps1 -Only apps,tweaks   # ne lancer que certains modules
```

Options : `-DryRun` (simulation), `-Auto` (non-interactif), `-Only a,b`, `-SkipReboot`, `-Fresh` (ignore la reprise).

- **Reprise** : chaque module réussi est noté dans `.state` ; relancer `reset.ps1` saute ce qui est déjà fait (`-Fresh` pour tout rejouer).
- **Log** : chaque run est enregistré dans `logs\reset-<date>.log`, et un **résumé OK/ÉCHEC** s'affiche à la fin.

## Ce qui est installé / configuré

| Module | Contenu |
|---|---|
| 01-apps | Apps winget (`config/apps.json`, catégorisé core/dev/tools/media/games) + Claude Code & wavespeed (npm) + FiraCode Nerd Font |
| 02-drivers | NVCleanstall (Nvidia, **manuel**) + SDIO (chipset/audio, **interactif**, exe x64) |
| 03-dev-setup | Long paths, WSL2 Ubuntu, Git config, `gh auth` (sauté en `-Auto`) |
| 04-symlinks | Restore configs depuis `OneDrive\...\Configs` (via `%OneDrive%`, pas de chemin codé en dur) |
| 05-vscode | Extensions VSCode (`config/vscode-extensions.txt`) |
| 06-tweaks | Explorer, taskbar, privacy/télémétrie, Game Bar off, Win+V |
| 07-defaults | Apps par défaut (Brave/VLC) — ProgID **validés** avant application |
| 08-debloat | Vire Cortana + apps préinstallées (garde OneDrive) |
| 09-games | Symlinks sauvegardes jeux |
| 10-scheduled | `winget upgrade` hebdo + dark/light auto + désactivation startup |
| 12-storage | **Config disque D:** (arbo, `HF_HOME`, guidage Docker/WSL/Steam/OneDrive) |
| 11-finalize | Storage Sense (sans purge Downloads), guide pin taskbar, Brave Sync |

## Tester sans rien casser

```powershell
.\reset.ps1 -DryRun          # simulation complète
```

```powershell
.\tests\run-checks.ps1       # parse AST + PSScriptAnalyzer + Pester (aucune install, aucun write)
```

CI : `.github/workflows/lint.yml` rejoue parse + PSScriptAnalyzer + Pester à chaque push.
Test grandeur nature : VM Windows 11 sur le homelab Proxmox (snapshot → bootstrap → rollback), cf. AUDIT §8 / notes projet.

## Notes importantes

- **SSH / secrets** : jamais dans OneDrive. Utilise `backup-secrets.ps1 -Dest <USB>` avant reset, et chiffre l'archive.
- **Tailscale** : installé par le pack (`Tailscale.Tailscale`, catégorie core). Après reset, lancer `tailscale up` et s'authentifier dans le navigateur — l'auth est liée au **compte** (tailnet), donc rien à sauvegarder avant reset. La machine rejoint le réseau ensuite.
- **OneDrive déplacé sur D:** : le pack lit `%OneDrive%` → fonctionne même si le dossier est sur `D:\OneDrive`.
- **MCP maison** (`atlas`, `tom-lefrere`) : après reset, vérifier le code + `npm run build` (CMS) + variables d'env/secrets.
- **Brave Sync** : coller le code à la fin (`brave://settings/braveSync` s'ouvre).
- **Drivers chipset/audio** : si SDIO ne trouve pas tout, site du constructeur de la carte mère.
