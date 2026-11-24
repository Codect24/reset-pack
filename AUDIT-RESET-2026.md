# Audit pré-reset — EXODIUS (2026-11-01)

> Audit profond de la machine **avant** le reset Windows + ajout d'un SSD 1 To.
> Objectif : ne rien perdre (cloud, environnements, Docker, secrets) et savoir **quel fichier va sur quel disque**.
> Complète le `README.md` (le *quoi/comment* du Reset Pack). Ici : le *quoi garder* et le *où le mettre*.

---

## 0. TL;DR — les 6 décisions à prendre

1. ~~Format du 1 To ?~~ ✅ **Résolu : Crucial P310 1 To Gen4 NVMe M.2 2280** (rapide). Slots M.2 de l'AORUS = PCIe **Gen3** → plafond réel ~3500 Mo/s (très bien). **Plan rapide verrouillé** : Docker/WSL/projets actifs peuvent aller sur `D:`. Voir §6.
2. **Sauver AVANT reset ce que le Reset Pack NE sauve PAS aujourd'hui** : clés SSH, `atlas-mcp.mjs`, les venvs, les modèles, les data de projets, l'auth des CLI. Checklist §5. **C'est le point le plus risqué.**
3. **Docker (72,6 Go) + WSL Ubuntu (51,8 Go)** = 124 Go de VHDX. Ne pas les laisser sur `C:`. Les recréer proprement ou les déplacer sur le 1 To. §3.1 / §3.2.
4. **OneDrive = 254 Go de données** (dont ~47 Go seulement hydratés localement). Décider de déplacer tout le dossier OneDrive sur le 1 To. §6.
5. **Documents est redirigé dans OneDrive** → tes `node_modules`/`.venv` se synchronisent (bloat + fichiers "online-only" qui cassent les builds). À corriger. §4 / §8.
6. **Régénérer vs conserver les clés SSH** : tu as 3 clés liées à des serveurs distants (homelab, Home Assistant, o2switch). Les **garder** évite de re-déployer les clés publiques partout. §3.4.

---

## 1. Machine & disques

| | Actuel | Après |
|---|---|---|
| Machine | GIGABYTE **AORUS 15-X9** (laptop) — nom *EXODIUS* | idem |
| CPU | Intel **i7-8750H** (6c/12t, 2018) | idem |
| RAM | **16 Go** (2 modules) ⚠️ limite pour Docker+WSL+ML simultanés | envisager 32 Go (2×16) si slots libres |
| GPU | NVIDIA **RTX 2070 mobile** (8 Go VRAM) | idem |
| OS | Windows 11 Famille (26200) | reset propre |
| Disque | **1× NVMe 512 Go** (Intel SSDPEKKW512G8 / 760p) — `C:` **450/461 Go utilisés, 11 Go libres** 🔴 | `C:` 512 NVMe + **`D:` 1 To (neuf)** |

> L'AORUS 15-X9 a **2 slots M.2 + 1 baie 2.5" SATA**. Le 1 To ira dans le slot M.2 libre (idéal) ou la baie SATA. **Vérifier le format du SSD reçu** (voir §6).

---

## 2. Où partent les ~450 Go de `C:` aujourd'hui

Répartition **physique** (ce qui occupe réellement le disque) :

| Poste | Taille | Nature | Verdict |
|---|---:|---|---|
| `AppData` | **213 Go** | dont Docker VHDX 72,6 · WSL Ubuntu 51,8 · reste = caches apps | 🔴 énorme |
| OneDrive (hydraté local) | ~47 Go | sur **254 Go logiques** (reste en ligne) | à déplacer |
| `C:\Riot Games` | **46 Go** | LoL + Valorant + TFT | jeu → `D:` |
| `C:\Windows` | 40 Go | OS | reste |
| `C:\Program Files` (+x86) | 56 Go | apps (dont Steam 13,8 · Battle.net 1,5) | tri |
| `.cache` (HuggingFace) | **13,8 Go** | modèles ML téléchargés | → `D:` |
| `ProgramData` | 8 Go | — | reste |
| `.venvs` | **6,4 Go** | virtualenvs Python centralisés | à sauver/recréer |
| `Downloads` | 5,4 Go | — | trier |
| `$Recycle.Bin` | 2,75 Go | corbeille | 🗑️ vider |
| `.rustup` / `.cargo` | 3 Go | toolchain Rust | recréable |
| `homelab-iso` | 2,7 Go | ISO pour le homelab | sauver si utile |
| `curseforge` | 2 Go | mods Minecraft | perso |
| `gif_finder_data` / `.claude` | 1,7 / 1,2 Go | data projet / Claude Code | — |

**Les 3 gros leviers de place** : Docker (72,6) + WSL (51,8) + modèles ML (13,8) = **~138 Go** qui n'ont rien à faire sur un disque système plein.

---

## 3. Environnements & dépendances à préserver

### 3.1 Docker
- Docker Desktop **4.71** installé. **Démon arrêté** au moment de l'audit → images/containers/volumes non énumérables à chaud.
- Données : `AppData\Local\Docker\wsl\disk\docker_data.vhdx` = **72,6 Go** (images + volumes + build cache confondus).
- ⚠️ **Avant reset** : si des **volumes Docker** contiennent des données uniques (bases de données, state de conteneurs), les **exporter** (`docker volume` → `tar`, ou `docker commit`/`save` pour les images maison). Un reset détruit le VHDX.
- Le reset pack réinstalle Docker Desktop mais **ne restaure aucun volume/image** → tout est reconstruit depuis zéro. OK pour des images publiques, **pas** pour des données locales.

### 3.2 WSL — 3 distributions
| Distro | État | VHDX | Rôle probable |
|---|---|---:|---|
| **Ubuntu** (défaut) | Stopped | **51,8 Go** | environnement de dev principal |
| docker-desktop | Stopped | 0,16 Go | backend Docker (recréé auto) |
| Debian | Stopped | 0,34 Go | secondaire / test |
- ⚠️ **Ubuntu = 51,8 Go de dev non versionné potentiellement** (fichiers hors git, configs, bases locales, clés). **À exporter avant reset** : `wsl --export Ubuntu D:\backup\ubuntu.tar`. Réimport après : `wsl --import`.
- Le reset pack réinstalle **une Ubuntu vierge** → tu perds le contenu actuel si non exporté.

### 3.3 MCP & connecteurs (le "cloud" de ton quotidien)
Deux natures, à ne pas confondre :

**a) Serveurs MCP LOCAUX (code Node sur la machine — à préserver)**
| Serveur | Lancement | Dépendance |
|---|---|---|
| `atlas` | `node …\2026\atlas-mcp.mjs` | **fichier unique** `atlas-mcp.mjs` (infra/secrets/techno/projets). Dans OneDrive ✅ mais **vérifier qu'il est sauvé + ses secrets/env**. |
| `tom-lefrere` | `node …\refresh_tom-lefrere.fr\site\mcp-server\dist\index.js` | CMS de ton site. Nécessite **Node + `npm run build`** du projet après reset. |
- Défini dans `~/.claude.json` (global) et `claude_desktop_config.json` (Claude Desktop). **Ces 2 fichiers sont déjà dans le backup du reset pack** ✅ — mais ils **pointent vers du code** qui doit exister + être **buildé** + avoir ses **variables d'env/secrets**.

**b) Connecteurs CLOUD (liés au compte Claude — survivent au reset)**
- `finary` (patrimoine), Google Drive, Canva, Claude Docs, scheduled-tasks… → **rien à sauver**, ils se reconnectent via ton compte. À juste **re-autoriser** après réinstall.

### 3.4 Homelab / Home Assistant / o2switch + SSH 🔑
Détecté via les origines réseau autorisées et les clés SSH :
- **Homelab** : `homelab.local` → **192.168.1.74** (Glances sur :61208, service sur :8088). ISO dans `~\homelab-iso`.
- **Home Assistant** : `homeassistant.local:8123` → **192.168.1.41**.
- **o2switch** : hébergement web (clé `o2switch_audit`).
- `~/.ssh` contient : `config`, `known_hosts`, et **3 paires de clés** : `homelab_claude`, `ha_claude`, `o2switch_audit`.

🔴 **Le reset pack ne sauvegarde PAS `~/.ssh`** (choix volontaire : *"clés privées hors OneDrive, régénère une nouvelle clé"*). Conséquence : après reset, tu dois **re-déployer une nouvelle clé publique sur chaque serveur** (homelab, HA, o2switch, GitHub). Si tu préfères **ne pas tout re-déployer**, sauvegarde `~/.ssh` **hors OneDrive** (clé USB chiffrée / gestionnaire de secrets). Voir §5.

### 3.5 Toolchains de dev installées
Node 24.15 · npm 11.12 · Python 3.12.10 · Rust 1.97 (rustup) · Java 21 (Temurin) · .NET SDK 9 · Git 2.54 · gh 2.92 · kubectl · WSL 2.6 · GCC (WinLibs) · FFmpeg.
- **Absents** (donc pas de dépendance) : pnpm, yarn, conda, go, deno, bun, et **aucun CLI cloud** (aws/gcloud/az/vercel/supabase…). Ton cloud passe par MCP/web, pas par des CLI → rien à migrer de ce côté.
- npm global : `@anthropic-ai/claude-code`, `@wavespeed/cli`.
- Caches recréables (ne PAS sauvegarder, juste nettoyer avant reset) : pip 6,6 Go · npm 1 Go · cargo/rustup 3 Go · nuget 0,07 Go.
- **À préserver** : les **modèles HuggingFace** (`.cache\huggingface` 12,5 Go) si téléchargement long/coûteux → sinon re-téléchargeables.

### 3.6 Secrets & authentification à re-faire après reset
- `gh` : ré-auth (`gh auth login`) — déjà prévu par le pack.
- Clés SSH : §3.4.
- Tokens/env des MCP maison (`atlas` secrets, API du CMS `tom-lefrere`, clé `@wavespeed`) : **vérifier où ils sont** (fichier `.env` ? variables système ?) — **non couverts par le backup actuel**.
- Dashlane (gestionnaire de mdp) : à réinstaller + reconnecter (coffre dans le cloud ✅).

---

## 4. Cartographie des projets de code

- **~30+ projets actifs** sous `OneDrive\Documents\03_Projets_Code\2026\`.
- ⚠️ **`Documents` est redirigé dans OneDrive** (Known Folder Move) → **tout `03_Projets_Code` se synchronise**, `node_modules`/`.venv` compris. C'est ce qui crée les fichiers *online-only* (placeholders) qui ont fait échouer la lecture de certains fichiers pendant cet audit, et qui peuvent **casser des builds** (fichiers pas réellement présents).

**Total `03_Projets_Code` ≈ 165 Go logiques** (dont **2026 = 152,6 Go**). Très déséquilibré — un seul projet pèse les deux tiers :

| Projet (2026) | Taille | Note |
|---|---:|---|
| **Mutinerie** | **96,9 Go** 🔴 | à lui seul **64 %** du dossier 2026 — contient sûrement data/médias/modèles, pas que du code. **Candidat n°1 à sortir d'OneDrive → `D:\Archives` ou `D:\Code`.** |
| install_lib_nexus | 11,8 Go | |
| Pokemon_TCG_Challenge | 10,4 Go | |
| Transcription_Reunion | 7,4 Go | audio / transcripts |
| TTS_test | 4,8 Go | |
| PC_Booster | 4,0 Go | |
| TrouveLocMaison | 3,0 Go | |
| analyse_anime_langue | 2,1 Go | |
| LightRAG | 1,9 Go | a son propre `.mcp.json` |
| MAILBOT · Discord_Recap · refresh_tom-lefrere.fr | 1–1,6 Go | le CMS `tom-lefrere` (MCP) est ici |
| ~20 autres projets | < 1 Go chacun | |

🔴 **Bloat de synchro** : **48 dossiers `node_modules`/`.venv` = 19 Go** se synchronisent inutilement dans OneDrive (lenteur de sync, placeholders, builds cassés). → correctif §8.3.

**Vaults Obsidian** (2) :
- `08_Logiciels\Obsidian\Histoire Panthera` (projet d'écriture + RAG).
- `03_Projets_Code\2026\Obsidian_School`.

---

## 5. ⚠️ Checklist CRITIQUE — à sauver AVANT le reset

Ce que le Reset Pack sauve déjà (via `backup-configs.ps1`) : ✅ `.gitconfig`, Claude Code (settings/plugins/`.claude.json`), Claude Desktop (`claude_desktop_config.json`), Windsurf, Windows Terminal, PowerToys, Obsidian global, extensions VSCode.

Ce qu'il **NE sauve PAS** et qui disparaîtra au reset — **à faire à la main** :

| # | À sauver | Où c'est | Pourquoi / sinon |
|---|---|---|---|
| 1 | **`~/.ssh`** (clés + config) | `C:\Users\tomle\.ssh` | Sinon re-déploiement des clés publiques sur homelab/HA/o2switch/GitHub. **Hors OneDrive** (USB chiffrée). |
| 2 | **Volumes Docker** utiles | VHDX Docker | DB/état de conteneurs perdus au reset. `docker volume`→tar. |
| 3 | **WSL Ubuntu** (si contenu unique) | distro 51,8 Go | `wsl --export Ubuntu D:\ubuntu.tar`. |
| 4 | **Secrets/env des MCP maison** | `atlas-mcp.mjs` + `.env` du CMS | `atlas` (secrets) et `tom-lefrere` ne marchent pas sans. |
| 5 | **`.venvs`** (ou juste les `requirements.txt`) | `C:\Users\tomle\.venvs` 6,4 Go | Recréables si chaque projet a un `requirements.txt`/`pyproject.toml` à jour. Sinon sauver. |
| 6 | **Data de projets** non versionnée | `gif_finder_data`, data LightRAG, DB locales… | Pas dans git → perdu. |
| 7 | **Modèles ML** (optionnel) | `.cache\huggingface` 12,5 Go | Gain de temps vs re-téléchargement. |
| 8 | **`homelab-iso`** si encore utile | `C:\Users\tomle\homelab-iso` 2,7 Go | ISO du homelab. |
| 9 | **Vérifier que TOUT OneDrive est "sync à jour"** | icône OneDrive | Un fichier *online-only* non synchronisé ET supprimé localement = OK, mais un fichier *local-only* jamais uploadé = perdu. **Forcer "Toujours conserver sur cet appareil"** sur les dossiers critiques avant reset. |
| 10 | **Clé produit / licences** | Office, Windows (lié au compte MS ✅), jeux | Vérifier avant. |

> **Règle d'or** : tout ce qui est dans **git + poussé sur GitHub** et tout ce qui est **synchronisé OneDrive** est safe. Le danger, c'est l'**entre-deux** : fichiers locaux jamais poussés/synchronisés (clés, `.env`, venvs, volumes Docker, WSL, data).

---

## 6. Plan de tri 2 disques — quoi va où

**Principe** : `C:` (512 NVMe, rapide) = OS + apps + ce qui doit être rapide. `D:` (1 To) = tout le volumineux + les données.

> ✅ **1 To = Crucial P310 NVMe M.2 2280** (Gen4, bridé Gen3 par le laptop → ~3500 Mo/s). Assez rapide pour y mettre **Docker, WSL et projets actifs** sans perte notable. **Plan rapide verrouillé ci-dessous.**

### Plan verrouillé (1 To = NVMe `D:`)

| Catégorie | Disque | Comment |
|---|:--:|---|
| Windows + Program Files + apps | `C:` | reset normal |
| Dossier **OneDrive** entier | **`D:`** | à l'install OneDrive, choisir `D:\OneDrive` comme emplacement. Libère `C:` et héberge les 254 Go de data. |
| **Docker** (data-root) | **`D:`** | Docker Desktop → Settings → *Disk image location* = `D:\Docker`. |
| **WSL** distros | **`D:`** | `wsl --import … D:\WSL\Ubuntu`. |
| **Jeux** (Steam/Riot/Battle.net/Epic/Ankama) | **`D:`** | Steam : nouvelle *Library folder* sur `D:`. Riot/Blizzard : réinstaller sur `D:`. |
| **Modèles ML / caches HF** | **`D:`** | var. d'env `HF_HOME=D:\ml\huggingface`. |
| Projets **actifs** (dev quotidien) | `C:` | hors OneDrive idéalement (voir §8), rapides. |
| Projets **archivés** / gros data | **`D:`** | `D:\Archives\`. |
| Médias (photos/vidéos/ISO) | **`D:`** | `D:\Media`, `D:\homelab-iso`. |
| Downloads | `C:` ou `D:` | au choix ; `D:` si tu télécharges gros. |

### Objectif d'occupation
- `C:` 512 : viser **~250–300 Go utilisés max** (garder 40 % libre → santé SSD + Windows respire).
- `D:` 1 To : OneDrive (~60–150 selon hydratation) + jeux (~62) + Docker (~73) + WSL (~52) + ML (~20) ≈ **350–450 Go**, large.

---

## 7. Procédure de reset recommandée (ordre)

**AVANT reset (sur le PC actuel) :**
1. `.\backup-configs.ps1` (ce que le pack gère).
2. Checklist §5 à la main (SSH, Docker volumes, WSL export, secrets MCP, data) → sur **une cible hors `C:`** (le futur `D:` branché, ou USB/NAS).
3. Vérifier OneDrive **100 % synchronisé** (clic droit icône → "à jour").
4. `git status` + `git push` sur **tous** les projets non poussés (script possible, voir §8).
5. Noter licences/codes (Brave Sync code, etc.).

**Reset + install physique :**
6. Monter le **1 To** (slot M.2 ou baie 2.5"). Si possible le faire **avant** le reset pour l'avoir comme cible de backup.
7. Reset Windows propre (ISO à jour).
8. Formater/initialiser `D:`.

**APRÈS reset :**
9. `.\reset.ps1` (apps, dev-setup, tweaks…).
10. Rediriger OneDrive → `D:\OneDrive`, laisser sync.
11. Déplacer Docker data-root + importer WSL sur `D:`.
12. Restaurer : `.ssh`, secrets MCP, venvs/data, modèles.
13. Rebuild les MCP maison (`tom-lefrere` : `npm i && npm run build` ; vérifier `atlas-mcp.mjs`).
14. Réinstaller jeux sur `D:`.
15. `gh auth login`, re-déployer clé SSH si non restaurée, reconnecter connecteurs cloud + Dashlane.

---

## 8. Améliorations à apporter au Reset Pack

À intégrer pour que le **prochain** reset soit sans angoisse :
1. **`backup-configs.ps1`** : ajouter une sauvegarde (chiffrée, hors OneDrive) de `~/.ssh`, des `.env`/secrets MCP, et un **export auto** WSL + liste des volumes Docker.
2. **Script "pre-reset check"** : parcourt tous les repos de `03_Projets_Code`, liste ceux avec des commits non poussés ou un working tree sale, et les `.env`/data non versionnés.
3. **Sortir le dev de OneDrive** : déplacer les projets actifs hors `Documents` redirigé (ex. `D:\Code`) OU exclure `node_modules`/`.venv` de la sync (OneDrive n'a pas d'exclude natif fiable → mieux vaut sortir le dossier). Évite le bloat et les placeholders.
4. **`apps.json` incomplet** : plusieurs apps installées ne sont pas dans le pack → elles manqueront après reset. Candidates à ajouter : Visual Studio 2022, Temurin JDK, .NET SDK, Rustup, FFmpeg, OBS Studio, Parsec, Handy, WinDirStat, CrystalDiskInfo, LibreOffice, Teams, Outlook, GOG Galaxy, Epic, balenaEtcher, Philips Hue Sync, GCC/WinLibs. (À trier selon ce que tu veux vraiment réinstaller.)
5. **Module "storage setup"** : nouveau module qui configure les emplacements `D:` (Docker, WSL, HF_HOME, Steam library) automatiquement.

---

### Annexe A — Répartition OneDrive (254 Go logiques)

Physiquement ~47 Go hydratés sur `C:`, le reste en *online-only*.

| Dossier OneDrive | Taille | Contenu |
|---|---:|---|
| **Documents** | **222 Go** | détail ci-dessous |
| Images | 23 Go | photos |
| Applications | 8 Go | — |
| (Bureau, pièces jointes, Music…) | < 0,2 Go | — |

**Détail `Documents` (222 Go) :**

| Sous-dossier | Taille | Destination conseillée |
|---|---:|---|
| `03_Projets_Code` | **165,5 Go** | dont **Mutinerie 96,9** → `D:` (code + data lourde) |
| `02_Etudes` | 32,4 Go | `D:` (peu modifié) |
| `05_Perso` | 21,4 Go | `D:` |
| `08_Logiciels` | 1,0 Go | vault Obsidian *Histoire Panthera* + backup `Configs\` du reset pack |
| `09_Archives` | 1,0 Go | `D:` |
| `07_Gaming` · `01_Professionnel` · autres | < 0,6 Go | — |

→ En déplaçant **tout le dossier OneDrive sur `D:`** (§6), ces 254 Go vivent sur le 1 To et `C:` respire. La **sync sélective** OneDrive permet de ne garder hydraté sur disque que l'utile (ex. ne pas hydrater `Mutinerie` en permanence).
