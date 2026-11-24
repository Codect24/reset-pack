# Checklist de reset — EXODIUS

> Document **actionnable** à suivre avant / pendant / après le reset.
> Le *pourquoi* détaillé est dans [AUDIT-RESET-2026.md](AUDIT-RESET-2026.md) ; le *comment* du pack dans [README.md](README.md).
> **Dernière vérif machine : 2026-11-13.**

Légende : ✅ fait/vérifié · ⬜ à faire (toi) · 🤖 fait par le pack · 🔴 critique · ⏳ en cours

---

## 0. La règle d'or (lis ça d'abord, ça calme)

Un **« Reset this PC »** de Windows ne réinstalle que **`C:`**. Tout ce qui est :

- **dans git ET poussé sur GitHub** → safe (sur le cloud),
- **dans OneDrive ET synchronisé** (icône verte) → safe (sur le cloud),
- **sur un autre disque physique** (`D:`) → safe **tant que tu ne formates pas `D:`**,

ne craint rien. Le **seul** danger, c'est **l'entre-deux** : fichiers locaux jamais poussés ni synchronisés (clés SSH, `.env`, venvs, contenu WSL, volumes Docker, data de projets). Toute cette checklist sert à couvrir cet entre-deux.

---

## 1. État des lieux vérifié (2026-11-13)

| Élément | État | Note |
|---|---|---|
| `C:` (Windows) | 🔴 **461 Go / 11 Go libres** | plein — le reset repart propre |
| `D:` (SSD 1 To) | ✅ **931 Go / 896 Go libres, déjà monté** | **le 1 To est déjà là** (contient déjà `Jeux`). Cible de backup idéale. |
| Tailscale | ✅ **ajouté au pack** (était absent) | `Tailscale.Tailscale` v1.104.7, catégorie core. Auth = compte → rien à sauver. |
| WSL | ⬜ Ubuntu + docker-desktop + Debian | **Ubuntu ~52 Go à exporter** avant reset |
| SSH | ⬜ 3 clés + config (`homelab`, `homeassistant`, `o2switch`) | **non couvert par le backup OneDrive** → `backup-secrets.ps1` |
| Projets non poussés | ⏳ scan en cours | section §2 complétée dès la fin du scan |

> **Nuance clé sur Tailscale** : ton `~/.ssh/config` utilise `homelab.local` / `homeassistant.local` (mDNS **LAN**), pas d'adresse Tailscale (`100.x` / `*.ts.net`). Donc Tailscale te sert pour l'accès **à distance** / mesh, pas pour le SSH quand tu es chez toi. Après reset : réinstall (auto) + `tailscale up` + login navigateur, et tu rejoins le tailnet.

---

## 2. Projets de code — qui risque quelque chose ? ⏳

> Rempli automatiquement par `pre-reset-check.ps1` (lecture seule, lancé le 2026-11-13).
> Pour chaque dépôt « sale » / « non-poussé » : `git add -A && git commit && git push`.
> Pour chaque « pas-de-remote » : créer un repo GitHub et pousser, **sinon la seule copie est locale**.

```
⏳ Scan en cours — résultats injectés ici.
```

---

## 3. AVANT le reset (sur le PC actuel, dans l'ordre)

- ⬜ **3.1** `.\pre-reset-check.ps1` → agir sur chaque dépôt signalé (commit + push). 🔴
- 🤖 **3.2** `.\backup-configs.ps1` → copie les configs légères dans `OneDrive\...\Configs` (git, Claude Code/Desktop, VSCode, Terminal, PowerToys, Obsidian).
- ⬜ **3.3** `.\backup-secrets.ps1 -Dest D:\ResetBackup` → SSH + `.env` + variables d'env sensibles **hors OneDrive**. **Puis chiffrer l'archive** (7-Zip AES-256 / VeraCrypt). 🔴
- ⬜ **3.4** **WSL** : exporter Ubuntu (~52 Go) →
  ```powershell
  wsl --shutdown
  wsl --export Ubuntu D:\WSL\ubuntu-backup.tar
  ```
  (Debian aussi si son contenu compte.) 🔴
- ⬜ **3.5** **Docker** : si des **volumes** contiennent des données uniques (bases, state), les exporter vers `D:`. Sinon rien (images publiques reconstruites).
- ⬜ **3.6** **Data non versionnée** → copier sur `D:` : `gif_finder_data`, bases LightRAG, DB locales, et tout dossier `data/` non suivi par git.
- ⬜ **3.7** **Gros projet `Mutinerie` (~97 Go)** : vérifier qu'il est **soit** 100 % synchronisé OneDrive **soit** copié sur `D:\Archives`. 🔴
- ⬜ **3.8** **Modèles HuggingFace** (optionnel, gain de temps) : copier `%USERPROFILE%\.cache\huggingface` vers `D:\ml\huggingface` si le re-téléchargement est long.
- ⬜ **3.9** **OneDrive 100 % à jour** : icône OneDrive → « À jour » (aucune flèche de synchro). Forcer « Toujours conserver sur cet appareil » sur les dossiers critiques. 🔴
- ⬜ **3.10** **Licences / codes à noter** : code **Brave Sync**, compte Microsoft (Windows s'y rattache ✅), comptes des launchers de jeux, licence Office.
- ⬜ **3.11** **Dépôt `reset-pack` public sur GitHub** : indispensable pour que `bootstrap.ps1` (le `irm ... | iex`) marche sur la machine vierge. À vérifier avant.

---

## 4. PENDANT le reset

- ⬜ **4.1** 🔴 **NE PAS formater / supprimer `D:`.** Choisir « réinstaller Windows » **uniquement sur `C:`**. (`D:` = tes jeux + tes backups → doit rester intact.)
- ⬜ **4.2** Garder le disque de backup accessible (`D:` interne suffit ; une copie USB/NAS des **secrets** chiffrés en plus = ceinture + bretelles).
- ⬜ **4.3** Reset Windows propre (ISO à jour).

---

## 5. APRÈS le reset

- 🤖 **5.1** Amorce : dans PowerShell →
  ```powershell
  irm https://raw.githubusercontent.com/Codect24/reset-pack/main/bootstrap.ps1 | iex
  ```
  (installe winget + git, clone dans `C:\ResetPack`, lance `reset.ps1`).
- 🤖 **5.2** `.\reset.ps1` (teste d'abord `.\reset.ps1 -DryRun`) : apps, drivers, WSL2, configs, tweaks, defaults, debloat, stockage `D:`, finalize.
- ⬜ **5.3** **Tailscale** : `tailscale up` + login navigateur → rejoint le tailnet.
- ⬜ **5.4** **OneDrive** → le reconfigurer sur `D:\OneDrive` (ou garder `C:` + sync sélective pour ne pas hydrater `Mutinerie`).
- ⬜ **5.5** **Docker** data-root → `D:\Docker` (Settings > Resources > Disk image location). **WSL** : `wsl --import Ubuntu D:\WSL\Ubuntu D:\WSL\ubuntu-backup.tar`.
- ⬜ **5.6** **Restaurer** : `~/.ssh` (depuis l'archive chiffrée), `.env`/secrets des MCP, venvs (ou `pip install -r`), modèles HF.
- ⬜ **5.7** **MCP maison** : `atlas-mcp.mjs` présent + ses secrets ; `tom-lefrere` → `npm i && npm run build`.
- ⬜ **5.8** `gh auth login` · reconnecter connecteurs cloud (Finary, Drive, Canva…) · Dashlane · **Brave Sync** (coller le code).
- ⬜ **5.9** **Jeux** : les fichiers sur `D:\Jeux` survivent ; re-pointer les launchers (Steam → « ajouter un dossier de bibliothèque » `D:\...`).

---

## 6. Qui fait quoi — pack vs toi

| Le pack fait (🤖) | Reste manuel (⬜) |
|---|---|
| Installer apps (dont **Tailscale** désormais), drivers, WSL2, toolchains dev | Login Tailscale, `gh auth`, reconnexion comptes cloud |
| Restaurer configs légères depuis OneDrive | Restaurer SSH / `.env` / secrets (hors OneDrive) |
| Tweaks Windows, debloat, defaults, tâches planifiées | Export/import WSL, déplacement Docker data-root |
| Préparer l'arbo `D:` + `HF_HOME` | Choix emplacement OneDrive, réinstall jeux sur `D:` |
| Backup des configs légères (`backup-configs.ps1`) | Backup secrets + data lourde (`backup-secrets.ps1`, copies `D:`) |

---

## 7. Décisions en attente (voir conversation)

- Cible de staging des backups : **`D:\ResetBackup`** (dispo, survit au reset) vs USB/NAS externe.
- Faut-il que je lance dès maintenant `backup-configs.ps1` et te guide pour l'export WSL / secrets ?
- Date de reset prévue ?
