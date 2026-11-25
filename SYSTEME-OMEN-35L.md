# Système complet — nouveau PC OMEN 35L

> **Le plan de référence pour monter l'OMEN sur de bonnes bases.** Il a été conçu par **6 agents** (un par dimension),
> **critiqué** par un 7ᵉ agent qui cherchait les conflits et les trous, puis **arbitré et vérifié dans le code** du dépôt.
> Il complète [PLAN-OMEN-35L.md](PLAN-OMEN-35L.md) (les choix matériels) et **remplace sa checklist §7**.
>
> Légende : ✅ = arbitré (on part là-dessus) · ❓ = à toi de trancher · 🔍 = vérifié dans le code.

---

## 0. TL;DR

**Les 6 piliers du système :**

1. **Une seule source de vérité pour les chemins** : `config/storage-layout.json` indexé par profil (`omen` / `exodius`).
   Fini les chemins éparpillés dans les modules. → §2
2. **C: écrit, D: lit.** C: (SSD HP) = OS + dev + Docker/WSL + deep learning. D: (P310, QLC sans DRAM) = **jeux + fichiers
   froids** uniquement. Ce n'est pas qu'une convention : le QLC encaisse mal les écritures soutenues. → §2
3. **Un vrai profil `reset.ps1 -Profile omen`** : il impose sa liste et son ordre de modules, n'exécute **jamais**
   `debloat` ni `drivers` (verrouillé par un test Pester). → §4
4. **Sauvegarde 3-2-1 par type de donnée**, avec un **SSD externe USB4 dès le jour 1** : sans lui, WSL, Docker et les
   datasets ne sont sauvegardés par rien. → §3
5. **Accès distant sans aucun port ouvert** : Tailscale (`--unattended`, clé sans expiration) + Sunshine/Moonlight en
   principal, Parsec en secours, mono-écran automatique. → §7
6. **Avant de toucher quoi que ce soit** : clé USB de recovery HP, clé BitLocker sauvegardée, état installé capturé.
   C'était le grand oubli de la première checklist. → §8 / §10

**Les décisions qui t'attendent → §12** (la première bloque le code : où vivent tes projets).

---

## 1. Ce que la critique a corrigé

| Sujet | Avant | Corrigé |
|---|---|---|
| `12-storage.ps1` 🔍 | lancé tel quel sur l'OMEN | **Faux pour l'OMEN** : crée `D:\Docker`, `D:\WSL`, `D:\ml`, `D:\Code`, pose `HF_HOME=D:\...` et conseille *OneDrive sur D:*. Écrit pour EXODIUS → à rendre dépendant du profil. |
| Secrets des projets 🔍 | « couverts par `backup-secrets.ps1` » | `backup-secrets.ps1` et `pre-reset-check.ps1` ne scannent **que** `OneDrive\Documents\03_Projets_Code`. Déplace le code → ses `.env` ne sont plus sauvegardés. |
| Déplacer `03_Projets_Code` 🔍 | « mets tes projets dans `C:\Dev` » | 6 dépendances codées en dur (8 hooks Agent Monitor, skill `nouveau-projet`, `proj`/`reset-pack`, 2 backups) + la mémoire Claude Code liée au chemin. Faisable, mais avec une **vraie migration** (§3.1). |
| Budget C: | « ~400-500 Go pour les datasets » | **Trop optimiste.** En comptant pagefile, outils dev, caches et OneDrive hydraté : **~100-250 Go réalistes** pour le DL en gardant 15 % libres. |
| Checklist d'arrivée | 7 étapes | Il manquait recovery HP, clé BitLocker, onduleur, SSD externe, test d'acceptation, test remote réel. → §10 |
| Numéros de modules | 4 agents voulaient chacun un « 13 » | Carte de numérotation **figée** → §4.2 |
| `HF_HOME` | 3 valeurs différentes selon les agents | **Une seule chaîne par voie**, fixée dans le layout → §2.4 |
| Game Mode 🔍 | — | `06-tweaks` le coupe (`AutoGameModeEnabled=0`) → `gaming` doit passer **après** `tweaks`. |
| Ordre des modules 🔍 | ordre de `-Only` | `reset.ps1` suit l'**ordre du tableau**, pas celui de `-Only` → le profil doit imposer son ordre. |

---

## 2. Disques & emplacements

### 2.1 Le principe (qui sert à trancher tous les cas limites)

- **D: = Crucial P310** → QLC sans DRAM : excellent en **lecture**, mauvais en **écriture soutenue** (chute de débit une fois
  le cache SLC saturé), endurance plus faible. Parfait pour des jeux (écrits une fois, lus souvent).
- **C: = SSD HP d'origine** → probablement TLC (**à vérifier avec CrystalDiskInfo au 1er boot**), mieux armé pour les écritures.
- ⇒ **Tout ce qui écrit beaucoup va sur C:** (Docker, WSL, entraînement, caches). **Tout ce qui se lit surtout va sur D:**.
- Pas de repartitionnement. **Lettre `X:` réservée** au futur SSD externe, pour que les scripts restent stables.

### 2.2 Arborescence cible ✅

```
C:\  (SSD HP 1 To — OS + travail + écritures intensives)
├─ Dev\                         # TOUT le code, HORS OneDrive (cf. §3.1)
│  └─ 03_Projets_Code\          # tes projets « journalisés » (même nom, même structure 2026\...)
├─ ML\                          # voie DL native Windows (Ollama, LM Studio…)
│  ├─ hf\  torch\  ollama\
├─ Caches\                      # recréables, purgeables sans état d'âme
│  ├─ pip\  npm\  conda-pkgs\  cargo\  nuget\
├─ WSL\Ubuntu\                  # distro WSL à emplacement connu (ext4.vhdx) — voie DL PRINCIPALE
├─ Tools\                       # MultiMonitorTool, scripts remote
├─ Downloads\                   # transitoire (Storage Sense)
└─ Users\tomle\
   ├─ OneDrive\                 # Fichiers à la demande — AUCUN code, AUCUN dataset
   └─ AppData\Local\Docker\     # VHDX Docker (défaut, reste sur C:)

D:\  (P310 1 To — jeux + froid en lecture)
├─ Games\
│  ├─ Steam\  Epic\  BattleNet\  Riot\  GOG\  EA\  Ubisoft\
├─ ISO\                         # images disque gardées volontairement
├─ Captures\                    # NVIDIA App / ShadowPlay (évite de remplir C:)
└─ ML-cold\                     # (soupape) poids/datasets STATIQUES, lecture seule

X:\  (réservé — SSD externe USB4 : sauvegardes + seule extension possible)
```

> **Pas de OneDrive sur D:** (un agent le proposait en soupape) : ça contredit « D: = jeux » et transformerait le P310 en
> disque de synchro, avec des écritures permanentes.

### 2.3 Budget C: (~931 Go réellement visibles)

| Poste | Estimation | Évolue ? |
|---|---:|---|
| Windows 11 + image HP + mises à jour | ~70 Go | non |
| Pagefile (géré par Windows) | ~20-64 Go | ↑ avec la RAM |
| Apps Windows | ~20 Go | non |
| Outils dev | ~50 Go | moyen |
| **Docker** (VHDX) | ~80 Go | **↑↑** |
| **WSL Ubuntu** (VHDX, caches DL inclus) | ~100 Go | **↑↑** |
| **OneDrive hydraté** (à la demande) | ~60 Go | **↑↑** (254 Go si tout hydraté !) |
| `C:\Dev` (code, sans data lourde) | ~40 Go | moyen |
| Caches | ~30 Go | moyen |
| Downloads | ~20 Go | non |
| **Sous-total hors DL** | **~490-540 Go** | |
| **Datasets / modèles DL** | **~100-250 Go** | **↑↑↑** |
| **Libre à garder** (santé SSD ≥ 15 %) | **~150 Go** | |

**Gains immédiats :** `powercfg /h off` (hibernation inutile sur une tour) → **+13-26 Go**. Vidage mémoire en mode
« noyau » plutôt que « complet ». Pagefile géré par Windows au départ, **plafonné à 32 Go** si C: passe sous 15 % libres.

**Soupapes, dans l'ordre (déclenchées à ~80 % de C:) :**
1. Purge : `docker system prune`, compactage du VHDX WSL (`sparseVhd`), Storage Sense, caches.
2. Poids/datasets **statiques** → `D:\ML-cold` (lecture dominante = acceptable sur QLC).
3. **SSD externe `X:`** : la vraie réponse long terme (plus aucun slot interne).

### 2.4 Variables d'environnement (chaînes exactes, fixées dans le layout) ✅

| Variable | Windows (User) | WSL (`~/.bashrc`) |
|---|---|---|
| `HF_HOME` | `C:\ML\hf` | `$HOME/ml/hf` |
| `TORCH_HOME` | `C:\ML\torch` | `$HOME/ml/torch` |
| `OLLAMA_MODELS` | `C:\ML\ollama` | — |
| `PIP_CACHE_DIR` | `C:\Caches\pip` | `$HOME/.cache/pip` |
| `NPM_CONFIG_CACHE` | `C:\Caches\npm` | `$HOME/.npm` |
| ~~`HF_HUB_ENABLE_HF_TRANSFER`~~ | **retiré au codage** | sans le paquet `hf_transfer`, un `huggingface_hub` ancien échoue ; les versions récentes passent par `hf_xet`, déjà rapide |
| `PROJETS_CODE` | `C:\Dev\03_Projets_Code` | — (cf. §3.1) |

> **Côté WSL, les caches restent dans l'ext4** et jamais sur `/mnt/c` : le pont 9p est très lent sur des milliers de
> petits fichiers. On accepte une petite duplication entre la voie WSL et la voie native Windows.

### 2.5 Changer les emplacements par défaut

- **Steam** : Paramètres › Stockage › + › `D:\Games\Steam` › par défaut (2 clics, on évite d'éditer le `.vdf`).
- **Epic** : scripté (`DefaultAppInstallLocation=D:\Games\Epic` dans `GameUserSettings.ini`).
- **Battle.net** : le client reste sur C: (comme aujourd'hui dans `apps.json`) ; dossier des jeux = `D:\Games\BattleNet` dans l'app.
- **Riot** : installer via le client sur `D:\Games\Riot` (winget ignore le chemin) ; **Vanguard reste sur C:**, c'est imposé.
- **Docker Desktop** : on laisse le défaut (C:) ; si un jour on déplace, uniquement via *Settings › Resources › Disk image location*.
- **WSL** : `wsl --manage Ubuntu --move C:\WSL\Ubuntu` (versions récentes), sinon `--export` / `--unregister` / `--import`.

---

## 3. Projets, OneDrive & sauvegarde 3-2-1

### 3.1 Où vivent tes projets ✅ (tranché : `C:\Dev\03_Projets_Code`)

> **Implémenté, et amélioré pendant le codage : un chemin CANONIQUE identique sur les 2 machines.**
> La variable seule ne suffisait pas : les serveurs MCP `atlas` et `tom-lefrere` (dans `.claude.json` et
> `claude_desktop_config.json`), les 8 hooks, le skill `nouveau-projet` et la commande `write-chapter` citent le chemin
> **en dur**, dans des fichiers **partagés** via OneDrive\Configs. La solution : **`C:\Dev\03_Projets_Code` partout**.
> - **OMEN** : vrai dossier, hors OneDrive (`migrate-projets.ps1 -Mode Clone`).
> - **EXODIUS** : **jonction** `C:\Dev\03_Projets_Code` → `OneDrive\Documents\03_Projets_Code` (`-Mode Junction`).
>   Rien ne bouge physiquement.
> - Les consommateurs sont réécrits une fois vers ce chemin, avec backup et revalidation JSON. `backup-configs.ps1`
>   écrit désormais ses copies avec ce chemin.
> - `PROJETS_CODE` reste posé (module `13-code`) pour `proj`, `reset-pack` et les scripts.
> - Bonus trouvé : tes **skills, commandes et `CLAUDE.md` perso n'étaient sauvegardés nulle part**. Ils le sont
>   maintenant (`backup-configs`), et l'OMEN les reçoit par symlink (`04-symlinks`).
>
> Le texte ci-dessous est la version d'origine (variable seule), gardée pour l'historique.

**Ma reco : `C:\Dev\03_Projets_Code` + une variable `PROJETS_CODE`.**

- On **garde le nom `03_Projets_Code` et sa structure** (`2026\Reset_pack`…) → ton `CLAUDE.md` et les descriptions de
  skills (qui citent le *nom*, pas le chemin) restent justes.
- On introduit **`PROJETS_CODE`** (variable d'environnement **par machine**) et on y fait pointer les consommateurs
  vérifiés 🔍 :

  | Consommateur | Aujourd'hui (en dur) | Après |
  |---|---|---|
  | 8 hooks Agent Monitor (`settings.json`) | `C:/Users/tomle/OneDrive/Documents/03_Projets_Code/...` | `process.env.PROJETS_CODE` |
  | Skill `nouveau-projet` | crée dans `OneDrive\Documents\03_Projets_Code\2026\<Nom>` | crée dans `%PROJETS_CODE%\2026\<Nom>` |
  | `profile.ps1` (`proj`, `reset-pack`) | chemin OneDrive | `$env:PROJETS_CODE` |
  | `backup-secrets.ps1`, `pre-reset-check.ps1` | `$codeRoot` OneDrive | **tableau de racines** (`PROJETS_CODE` + l'ancienne en lecture) |
  | Atlas (racine de scan) | chemin OneDrive | `PROJETS_CODE` (à vérifier dans `atlas-mcp.mjs`) |

- **Pourquoi une variable plutôt qu'un chemin** : `settings.json` est **partagé via OneDrive** entre EXODIUS et l'OMEN
  (symlinks du Reset Pack). Avec un chemin en dur, une seule des deux machines peut avoir raison. Avec `PROJETS_CODE`,
  chaque machine a sa valeur.
- **Mémoire Claude Code** : les dossiers `~/.claude/projects/<chemin-encodé>/memory` sont rangés selon le chemin du projet.
  Le script de migration les **renomme** pour que chaque projet retrouve sa mémoire.
- **Script `migrate-projets.ps1`** : il clone/copie les dépôts (remotes intacts), pose `PROJETS_CODE`, repointe les
  consommateurs, renomme les dossiers mémoire, puis **décoche** l'ancien dossier de la synchro OneDrive. Simulation (`-DryRun`) d'abord.

*Alternative (hybride)* : garder les projets légers/journalisés dans OneDrive et ne sortir que le code lourd. Moins de
migration, mais deux racines à gérer à vie, et le piège EXODIUS (placeholders, `node_modules` synchronisés) reste
possible sur la partie qui reste dans OneDrive.

### 3.2 OneDrive ✅

- **Fichiers à la demande = ON**, OneDrive **reste sur C:**.
- **Synchronisé** : documents perso, `08_Logiciels\Configs` (backup-configs), nouveau `08_Logiciels\CodeBundles`, `07_Gaming`.
- **Exclu** (synchro sélective, manuelle : OneDrive n'a pas d'exclusion par motif fiable) : l'ancien `03_Projets_Code`.
- **Jamais** « Toujours conserver sur cet appareil » sur un gros dossier.

### 3.3 La matrice 3-2-1 ✅

| Donnée | Copie 1 | Copie 2 | Copie 3 / hors-site | Outil |
|---|---|---|---|---|
| **Code** | `C:\Dev` | **git bundle** → OneDrive | **GitHub privé** | `git push` + `backup-bundles.ps1` |
| **Secrets** (.ssh, .env, clés) | poste | archive **chiffrée AES-256** sur SSD externe | 2ᵉ copie hors-ligne | `backup-secrets.ps1` (corrigé) |
| **Datasets / modèles** | `C:\ML` + ext4 WSL | miroir **SSD externe** | cloud seulement si irremplaçable | `backup-datasets.ps1` (nouveau) |
| **WSL / Docker** | VHDX sur C: | `wsl --export` + volumes `.tar` sur SSD externe | — | planifié, mensuel |
| **Configs** (git, Claude, VSCode, Sunshine, `.wslconfig`) | poste | `OneDrive\Configs` | historique OneDrive | `backup-configs.ps1` (élargi) |
| **Jeux** | D: | — | — | re-téléchargeables, rien à faire |

- **Bundles quotidiens** (13h, tâche `ResetPack-CodeBundles`) plutôt qu'hebdo : un bundle ne capture que le *committé*,
  donc plus c'est fréquent, mieux on rattrape les dépôts sans remote. Avec `git bundle verify` et une alerte au-delà de ~2 Go
  (signe qu'on a committé de la data).
- ⚠️ **Le travail non committé n'est dans aucune sauvegarde.** `pre-reset-check.ps1` liste les dépôts sales ou non poussés.

### 3.4 Restauration (une ligne par cas)

- Code : `git clone` depuis GitHub ; sinon `git clone <bundle>` puis `git remote set-url`.
- Secrets : déchiffrer l'archive (passphrase dans ton gestionnaire de mots de passe), recopier `.ssh` et les `.env`.
- Configs : `reset.ps1 -Only symlinks`.
- WSL : `wsl --import Ubuntu C:\WSL\Ubuntu <X:>\wsl\ubuntu.tar`.
- Modèles HuggingFace : souvent plus simple de les **re-télécharger** (fibre 8 Gb/s) que de les sauvegarder.

---

## 4. Environnement dev & profil Reset Pack

### 4.1 Le point d'entrée ✅

```powershell
.\reset.ps1 -Profile omen -DryRun   # toujours d'abord : on lit, on valide
.\reset.ps1 -Profile omen           # puis en réel (interactif : gh auth crée la clé SSH)
```

- `-Profile` pose `$env:RESETPACK_PROFILE` (lu par les modules qui en dépendent), fixe les catégories d'apps, et
  **impose l'ordre de sa liste** (et non celui du tableau `$modules`).
- `-Only` reste dispo pour rejouer un module seul.
- **Test Pester** : le profil `omen` n'inclut **jamais** `debloat` ni `drivers`, et `-Profile omen -DryRun` passe en CI.
- Tous les modules restent **idempotents** (vérifient avant d'agir) : relancer le profil ne casse rien.

### 4.2 Carte des modules (numérotation figée) ✅

| Fichier | Clé | Statut | Rôle |
|---|---|---|---|
| `01-apps` | apps | rejoué | stack via winget (cats `core,dev,tools,games`) |
| `02-drivers` | drivers | ❌ **jamais** | HP Support Assistant + NVIDIA App s'en chargent |
| `03-dev-setup` | dev-setup | rejoué (interactif) | WSL2, long paths, git config, `gh auth` |
| `04-symlinks` | symlinks | rejoué | configs depuis OneDrive\Configs |
| `05-vscode` | vscode | rejoué | extensions |
| `06-tweaks` | tweaks | rejoué | tweaks sûrs |
| `08-debloat` | debloat | ❌ **jamais** | trop agressif pour l'image HP → remplacé par `15-hp-triage` |
| `10-scheduled` | scheduled | **étendu** | + bundles, prune Docker, log thermique (sem. 1) |
| `11-finalize` | finalize | rejoué | Storage Sense, etc. |
| `12-storage` | storage | **refondu** | lit `storage-layout.json` ; **seul propriétaire** de l'arborescence C:/D: |
| `13-code` | code | **nouveau** | `PROJETS_CODE`, `.gitignore` global, garde-fou « pas de code dans OneDrive » |
| `14-ml` | ml | **nouveau** | `.wslconfig`, provisioning WSL, tests GPU (§5) |
| `15-hp-triage` | hp-triage | **nouveau** | capture de l'état puis tri du bloatware HP (§6) |
| `16-gaming` | gaming | **nouveau** | launchers sur D:, tweaks jeu, OMEN Hub muselé (§6) |
| `17-remote` | remote | **nouveau** | Tailscale, Sunshine, mono-écran, pare-feu (§7) |

Scripts à la racine (même style que `backup-secrets.ps1`) : `migrate-projets.ps1`, `backup-bundles.ps1`,
`backup-datasets.ps1`, **`verify-omen.ps1`** (test d'acceptation).

**Ordre du profil `omen`** (dépendances) :
`hp-triage` → `apps` → `dev-setup` → `symlinks` → `vscode` → `storage` → `code` → `tweaks` → `gaming` → `ml` → `remote` → `scheduled` → `finalize`

(`gaming` après `tweaks` pour rallumer le Game Mode ; `ml` après `dev-setup` (WSL) et `storage` (chemins) ; `scheduled`
après tout ce qui crée des tâches.)

### 4.3 `apps.json` : modifications coordonnées ✅

- **+** `LizardByte.Sunshine` (OMEN) · **+** `astral-sh.uv` (dev) · **+** NVIDIA App (*identifiant winget à confirmer au 1er boot*) ·
  *(option)* `Ollama.Ollama`.
- **Riot** : retiré du profil `omen` (installé via le client sur D:).
- **Moonlight** : dans une liste « client » séparée, pour **EXODIUS uniquement**.
- Battle.net : inchangé (client sur C:, jeux sur D:).

---

## 5. Deep learning (RTX 5080 16 Go)

✅ **WSL2 Ubuntu 24.04 en voie principale** (écosystème Linux de premier rang : bitsandbytes, Triton, vLLM, flash-attn ;
Docker GPU natif ; WSL déjà géré par le pack). Voie native Windows **secondaire** pour les outils clés en main (Ollama, LM Studio).

**Les règles qui évitent 90 % des galères :**

- ⚠️ **Piège Blackwell (sm_120)** : il faut **PyTorch ≥ 2.7 avec les wheels `cu128`** (ou plus récent). Un `pip install torch`
  par défaut peut donner un binaire sans kernel sm_120 → `no kernel image is available`.
  ```
  uv pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
  ```
- **Un seul pilote, côté Windows** (NVIDIA App). **Jamais de pilote NVIDIA Linux dans WSL** : ça casse la projection `libcuda`.
- **Pas de toolkit CUDA système au départ** : les wheels embarquent le runtime et cuDNN. Toolkit seulement pour compiler des
  kernels, via le dépôt `wsl-ubuntu` et le paquet **`cuda-toolkit-12-8`** (jamais `cuda`, qui tire un pilote).
- **uv** par défaut (lockfile committé), conda seulement si une lib système l'exige. Docker pour le lourd ou le déployable.
- **Docker Desktop** (déjà dans `apps.json`) : `--gpus all` marche directement via le backend WSL2. ❓ Alternative plus
  légère : Docker Engine dans WSL + `nvidia-container-toolkit`.
- **`.wslconfig` obligatoire** (sinon WSL prend jusqu'à 50 % de la RAM). Le module `14-ml` le **calcule** : `memory` ≈ 56 %
  de la RAM (18GB à 32 Go, 36GB à 64 Go) et `processors` = threads − 4 (20 sur le 270K). Exemple :
  ```ini
  [wsl2]
  memory=18GB
  processors=12
  swap=16GB
  [experimental]
  autoMemoryReclaim=gradual
  sparseVhd=true
  ```
  Avant une grosse session de jeu : `wsl --shutdown`.
- **16 Go de VRAM** (~14-15 Go utiles avec 3 écrans) : inférence 7-8B en 8 bits, 13B en 4 bits, SDXL/Flux, LoRA/QLoRA 7-13B.
  Pas d'entraînement complet au-delà de ~1-2B. Quand ça déborde : quantization (GGUF/AWQ/fp8), offload `device_map="auto"`.
- **RAM 64 Go plus tard** : prendre un **kit 2×32 apparié** et ne pas ajouter 2 barrettes aux 2 existantes. Avec 4 barrettes, la DDR5-6000
  redescend souvent à 5200-5600 ou devient instable.
- **Épingler le pilote qui marche** : noter sa version ; après chaque mise à jour proposée par NVIDIA App, relancer le
  **smoke-test** (`torch.cuda.is_available()` + nom du GPU + `docker run --gpus all … nvidia-smi`) avant de valider.

---

## 6. Gaming, Windows & tri HP

**Tri bloatware (`15-hp-triage`)** ✅
1. **Capture d'abord, même en simulation** : `winget list`, `Get-AppxPackage -AllUsers`, clés de registre *Uninstall*
   → fichiers horodatés. (**Jamais `Win32_Product`**, qui déclenche des reconfigurations MSI.)
2. **Garder** : OMEN Gaming Hub, HP Support Assistant, pilotes HP, Xbox + Game Bar, Defender.
3. **Retirer** (liste blanche explicite, rien d'aveugle) : McAfee (via sa `QuietUninstallString`), ExpressVPN, Dropbox promo,
   Booking & essais, appli promo grand public. **myHP / HP Smart : seulement sur confirmation**.
4. **Vérifier Defender** après McAfee (`Get-MpComputerStatus`) : McAfee le désactive souvent.

**Jeux (`16-gaming`)** ✅
- Bibliothèques sur `D:\Games\…` (§2.5) ; captures NVIDIA App sur `D:\Captures`.
- **OMEN Gaming Hub muselé, pas tué** : on coupe le *GUI au démarrage* et ses notifications, **jamais les services**
  (ventilos, RGB, écran LCD du watercooling en dépendent).
- Tweaks sûrs et réversibles : plan **Utilisation normale** (*Balanced*, corrigé au codage : Intel le recommande pour
  Arrow Lake, et la machine tourne 24/7 ; « Performances optimales » garderait les cœurs au maximum), **Game Mode ON**, **HAGS ON**, priorités
  multimédia jeux, Game DVR off (capture = NVIDIA App).
- **Sécurité intacte** : Defender temps réel ON, **VBS/Memory Integrity ON**, **aucune exclusion** `D:\Games`.

---

## 7. Réseau, accès distant & sécurité

**Réseau** ✅
- TX401 sur le port 10G de la Livebox (Cat6a), **pilote Marvell AQtion / TP-Link selon la version V1/V2** de la carte (le pilote
  générique est la cause n°1 d'un lien bloqué à 1G). MTU 1500.
- **2,5 GbE intégré : activé, câble débranché**, métrique 50 → secours en 10 s. Jamais les deux branchés sur la Livebox.
- Acceptation : `LinkSpeed` = 10 Gbps, puis speed-test multi-flux **> 2,5 Gbps** (la preuve que la carte sert).
- Thermique : la TX401 est sous l'échappement du RTX 5080 → **log de températures la 1ʳᵉ semaine**.

**Tailscale** ✅ — `tailscale up --unattended` (joignable dès le boot, avant connexion), **MagicDNS**, **expiration de clé
désactivée** pour le nœud OMEN (sinon il sort du tailnet pendant un voyage). Option : `--ssh` pour Claude Code à distance.

**Streaming** ✅ — **Sunshine (OMEN) + Moonlight (EXODIUS) en principal**, à travers Tailscale uniquement.
**Parsec en secours** (2FA obligatoire) : il ne touche pas aux écrans, donc il reste une porte d'entrée si le mono-écran déraille.

**Mono-écran automatique** ✅ — `global_prep_cmd` de Sunshine → NirSoft MultiMonitorTool :
*Do* = sauvegarde l'agencement + désactive les écrans 2 et 3 ; *Undo* = réactive tout + recharge l'agencement exact.
À valider sur la vraie machine :
- ne **jamais** désactiver l'écran capté par Sunshine ;
- cibler les écrans par **numéro de série** (les `\\.\DISPLAYn` bougent) ;
- si le service Sunshine lance les commandes en session 0, passer par une tâche planifiée en contexte utilisateur ;
- tâche de secours « réactive tous les écrans ».

**Durcissement** ✅
- **Zéro redirection de port** sur la Livebox.
- Pare-feu ON, règles Sunshine **limitées à `100.64.0.0/10`** (Tailscale).
- **Pas d'auto-login**.
- « Ne jamais mettre en veille ».
- Config Sunshine + scripts mono-écran **dans le périmètre `backup-configs`**.

**Les chemins de lockout à distance** (chacun a sa parade ci-dessus) : expiration de clé Tailscale, Tailscale pas en
`--unattended`, bureau noir après le mono-écran, machine en veille, prompt BitLocker au reboot (§8).

---

## 8. Les trous que personne n'avait couverts

| Lacune | Risque | Parade |
|---|---|---|
| **Media de recovery HP** | « on garde l'image usine » sans moyen de la restaurer | **HP Cloud Recovery Tool** sur clé USB **avant** toute modif + point de restauration |
| **Chiffrement de l'appareil / BitLocker** (souvent actif d'office sur Famille) | une mise à jour BIOS (voire l'ajout d'une carte) peut faire demander la clé au boot → **lockout**, y compris à distance | relever la clé (compte Microsoft + copie hors-ligne) **avant d'ouvrir le boîtier** ; suspendre la protection le temps des changements |
| **Onduleur** | micro-coupure = VHDX WSL/Docker, `.git` ou checkpoint d'entraînement corrompus, sur une machine allumée en permanence | onduleur *line-interactive* 1000-1500 VA |
| **SSD externe** | WSL, Docker et datasets ne sont sauvegardés par rien, et C: devient le point unique de défaillance | achat **jour 1**, pas « plus tard » |
| **Suivi thermique** | runs DL longs sans surveillance, TX401 sous le GPU | log `nvidia-smi` + LibreHardwareMonitor la 1ʳᵉ semaine, seuil d'alerte |
| **Mises à jour dans le temps** | un pilote NVIDIA casse CUDA ; une mise à jour majeure Windows réactive du bloat | pilote épinglé + smoke-test ; après une mise à jour majeure, relancer `verify-omen` (+ `hp-triage`/`tweaks`, idempotents) |
| **Mémoire Claude Code** liée au chemin | après déplacement, tes projets « oublient » leur mémoire | renommage dans `migrate-projets.ps1` (§3.1) |
| **Pas de test global** | impossible de dire « la machine est prête » | **`verify-omen.ps1`** : 10G négocié, GPU vu par torch, Docker GPU, Tailscale joignable, `HF_HOME` résolu, tâches planifiées présentes, Defender ON, % libre sur C: |

---

## 9. Achats recommandés

| Article | Priorité | Pourquoi |
|---|---|---|
| **SSD NVMe externe USB4 / Thunderbolt, 2 To** | 🔴 jour 1 | seul exutoire de sauvegarde (WSL, Docker, datasets, secrets) **et** seule extension de stockage possible |
| **Onduleur line-interactive 1000-1500 VA** | 🟠 haute | machine allumée en permanence + écritures longues ; permet un arrêt propre |
| Câble Cat6a | si besoin | 10G fiable jusqu'à la Livebox |
| Kit RAM **2×32 Go apparié** | 🟢 plus tard | quand l'offload / Docker+WSL+jeu le justifiera |

---

## 10. Ordre d'exécution — jour J

> **Version à jour = [OMEN-JOUR-J.md](OMEN-JOUR-J.md)** : les commandes exactes, dans l'ordre, avec le formatage du P310
> (`format-ssd-jeux.ps1`) et la migration des projets. La liste ci-dessous reste la référence « pourquoi ».

**A. Avant de toucher (rien installé)**
1. 1er démarrage : configuration avec ton compte Microsoft, sur le 2,5 GbE intégré pour l'instant.
2. **Capture de l'état installé** (winget, Appx, registre) — la référence avant tout tri.
3. **Clé USB de recovery HP** (HP Cloud Recovery Tool) + point de restauration.
4. **Chiffrement** : vérifier s'il est actif, **sauvegarder la clé de récupération**.
5. CrystalDiskInfo : noter le type du SSD C: (TLC/QLC).

**B. Mise à jour & tri**
6. Windows Update + HP Support Assistant (BIOS/pilotes) + **NVIDIA App** → **noter la version du pilote**. Redémarrer.
7. Tri bloatware, puis **vérifier que Defender est actif**.

**C. Matériel**
8. Protection BitLocker suspendue → **P310** dans le slot M.2 libre + **TX401** dans le PCIe x4. Refermer, redémarrer,
   réactiver la protection (clé sous la main si elle est demandée).
9. BIOS : M.2 en Gen4, XMP/EXPO, Resizable BAR ON.
10. Effacer/formater le P310 → `D:` (**aucun dossier à la main** : le module storage s'en charge).
11. Pilote TX401, câble sur le port 10G, 2,5G débranché. Vérifier 10 Gbps + speed-test > 2,5 Gbps.

**D. Données & dépôt**
12. OneDrive : Fichiers à la demande ON, **décocher l'ancien `03_Projets_Code`**.
13. Cloner le Reset Pack, **trancher §3.1**, lancer `migrate-projets.ps1 -DryRun` puis en réel.

**E. Le profil**
14. `.\reset.ps1 -Profile omen -DryRun` → lire et valider.
15. `.\reset.ps1 -Profile omen` (interactif pour `gh auth`).
16. Launchers de jeux : bibliothèques sur `D:\Games` (Steam par l'UI, Riot à la main).
17. Remote, la partie manuelle : connexion Tailscale + expiration de clé off ; Sunshine (mot de passe WebUI, écran capté,
    PIN, commandes mono-écran) ; Parsec + 2FA ; Moonlight sur EXODIUS.

**F. Filets & validation**
18. Brancher le SSD externe : 1ʳᵉ archive de secrets, 1er `wsl --export`, 1er miroir datasets, 1er bundle.
19. **`verify-omen.ps1`** → tout au vert.
20. **Test d'accès réel depuis EXODIUS en 4G/5G** (hors réseau maison) : le mono-écran et sa restauration.
21. `journal-projet` pour archiver la séance.

---

## 11. Chantier d'implémentation (ce qu'on code ensuite)

| Lot | Contenu | Pourquoi d'abord |
|---|---|---|
| **1. Fondations** | `-Profile omen` dans `reset.ps1` (liste + ordre), `config/storage-layout.json`, refonte de `12-storage`, tests Pester | tout le reste en dépend |
| **2. Code & sauvegarde** | `13-code`, `migrate-projets.ps1`, correction de `backup-secrets`/`pre-reset-check` (tableau de racines), `backup-bundles.ps1` + tâche | ferme le trou des secrets **avant** le déplacement |
| **3. Deep learning** | `14-ml`, `templates/.wslconfig`, `scripts/wsl-ml-setup.sh`, smoke-test | dépend des chemins du lot 1 |
| **4. Windows & jeu** | `15-hp-triage`, `16-gaming`, modifications d'`apps.json` | indépendant |
| **5. Remote** | `17-remote`, scripts mono-écran, pare-feu, élargissement de `backup-configs` | indépendant |
| **6. Validation** | `verify-omen.ps1`, `backup-datasets.ps1` | en dernier, il vérifie le reste |

---

## 12. Décisions à prendre

> ✅ **Toutes tranchées le 2026-11-25** : les recommandations ci-dessous ont été retenues et **codées**. Une correction a été
> faite au codage : **plan d'alimentation « Utilisation normale » (Balanced)** et non « Performances optimales ». Intel le
> recommande pour les Core Ultra 200S (Arrow Lake), et une machine allumée 24/7 n'a pas à garder ses cœurs au maximum.

| # | Question | Ma reco |
|---|---|---|
| ❓1 | **Où vivent tes projets ?** (bloque le lot 2) | **`C:\Dev\03_Projets_Code` + variable `PROJETS_CODE`** + migration scriptée (§3.1) |
| ❓2 | Achats jour 1 : SSD externe USB4 2 To + onduleur | **Oui aux deux** (le SSD est non négociable pour la sauvegarde) |
| ❓3 | Docker Desktop ou Docker Engine dans WSL ? | **Docker Desktop** (déjà en place, le GPU marche directement) |
| ❓4 | Bundles quotidiens ou hebdo ? | **Quotidiens** |
| ❓5 | Retirer myHP / HP Smart ? | à la demande seulement (pas d'imprimante HP → HP Smart peut partir) |

*Réglages par défaut que j'ai choisis (tous réversibles)* : Game Mode ON, HAGS ON, appli Game Bar gardée + DVR off,
VBS/Memory Integrity ON, aucune exclusion Defender, Parsec en secours avec 2FA, clé Tailscale sans expiration.
