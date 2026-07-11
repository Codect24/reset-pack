# Reset Pack

Automatise la réinstallation complète d'un PC Windows 11 après reset.

## Utilisation

### Premier setup (sur ton PC actuel, avant reset)

```powershell
# Backup tes configs actuelles vers OneDrive
.\backup-configs.ps1
```

### Après reset Windows

```powershell
# Lance tout (installer winget si absent, puis tout le reste)
.\reset.ps1
```

Le script demande confirmation à chaque module. Pour tout enchaîner sans question :

```powershell
.\reset.ps1 -Auto
```

Pour ne lancer qu'un module :

```powershell
.\reset.ps1 -Only apps
.\reset.ps1 -Only tweaks,defaults
```

## Ce qui est installé / configuré

| Module | Contenu |
|---|---|
| 01-apps | Brave, 7zip, Everything, Git, Obsidian, Signal, Steam, Discord, VLC, Python, PowerToys, VSCode, Claude Desktop, Claude Code (npm), Docker Desktop, Windows Terminal, Node, gh, LoL EUW, Battle.net |
| 02-drivers | NVCleanstall (Nvidia) + SDIO (chipset, audio…) — téléchargés, lancés en mode silent |
| 03-dev-setup | Git config (Codect / contact@tom-lefrere.fr), WSL2 Ubuntu, long paths, gh auth (SSH key + GitHub) |
| 04-symlinks | Restore configs depuis `OneDrive\Documents\08_Logiciels\Configs\` |
| 05-vscode | Installe extensions depuis `config/vscode-extensions.txt` |
| 06-tweaks | Extensions de fichiers visibles, fichiers cachés, menu contextuel classique, widgets/Copilot off, télémétrie off, Win+V on |
| 07-defaults | Brave par défaut (web/pdf/html), VLC pour multimédia (via SetUserFTA) |
| 08-debloat | Vire Cortana + apps préinstallées (garde OneDrive) |
| 09-games | Symlinks Saved Games + My Games + LoL/Overwatch/Dofus |
| 10-scheduled | Tâche `winget upgrade --all` hebdo + dark/light auto (7h↔20h) |
| 11-finalize | Pin taskbar (Brave/Explorer/Terminal/Claude), Storage Sense, ouvre Brave Sync (blocage pubs délégué à Brave Shields + DNS filtrant) |

## Notes importantes

- **SSH** : pas de symlink (clés privées hors OneDrive). Utilise `gh auth login` après reset, génère une nouvelle clé.
- **Brave Sync** : à la fin du script, `brave://settings/braveSync` s'ouvre — colle ton code sync.
- **Drivers chipset/audio** : si SDIO ne trouve pas tout, va sur le site du constructeur de ta carte mère.
- **Apps par défaut** : nécessite SetUserFTA (téléchargé automatiquement).
