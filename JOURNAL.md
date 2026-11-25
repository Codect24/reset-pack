---
projet: Reset_pack
etat: en-cours
---

## 2026-11-25 — Le pack sait monter le nouveau PC OMEN 35L de bout en bout, sans le resetter

### Fait
- Plan matériel du HP OMEN 35L (Core Ultra 7 270K, RTX 5080 16 Go, 32 Go) : `PLAN-OMEN-35L.md`. Image usine HP gardée,
  Crucial P310 récupéré comme disque jeux, carte 10GbE TP-Link TX401 sur la Livebox 7, accès distant depuis EXODIUS.
- Plan système complet `SYSTEME-OMEN-35L.md`. 6 agents (un par dimension) l'ont conçu, un 7ᵉ l'a critiqué, puis j'ai
  arbitré et vérifié ses affirmations dans le code.
- `reset.ps1 -Profile omen|exodius` : le profil impose la liste ET l'ordre des modules ; `debloat` et `drivers` sont
  interdits sur l'OMEN, verrouillé par un test Pester.
- `config/storage-layout.json` : la source unique des chemins par machine (C: écrit, D: lit, X: sauvegarde).
- `format-ssd-jeux.ps1` : efface et reformate le P310 en `D:` « Jeux » (GPT, NTFS, TRIM). Les garde-fous ne sont pas
  contournables (modèle, NVMe, taille, ni disque système ni pagefile), et il faut taper `EFFACER <n°>`.
- 5 nouveaux modules : `13-code`, `14-ml` (WSL, PyTorch cu128, smoke-test GPU), `15-hp-triage`, `16-gaming` et
  `17-remote` (Tailscale, Sunshine limité à Tailscale, mode mono-écran via MultiMonitorTool).
- `migrate-projets.ps1`, `backup-bundles.ps1` (git bundle quotidien), `backup-datasets.ps1`, `verify-omen.ps1`
  (test d'acceptation en lecture seule) et la feuille de route `OMEN-JOUR-J.md`.
- Commit `236eb27` poussé sur `feat/prep-omen-35l`. Tests : 300 Pester OK, 0 erreur PSSA, et la simulation intégrale du
  profil omen passe 15 modules sur 15 sous Windows PowerShell 5.1, sans aucune écriture réelle.

### Défis
- **Le chemin des projets était codé en dur partout.** La 1ʳᵉ idée était une variable `PROJETS_CODE` ; au codage, le
  dry-run de la migration a trouvé bien plus de consommateurs :
  - 8 hooks Agent Monitor ;
  - les serveurs MCP `atlas` et `tom-lefrere`, cités 77 fois dans `.claude.json` et 115 fois dans
    `claude_desktop_config.json` ;
  - le skill `nouveau-projet` et la commande `write-chapter`.

  Plusieurs de ces fichiers sont partagés entre les deux PC via OneDrive : une variable seule ne les corrige pas.
  Levé par un **chemin canonique identique sur les deux machines** : `C:\Dev\03_Projets_Code` est un vrai dossier sur
  l'OMEN et une jonction vers OneDrive sur EXODIUS.
- **Le switch `-DryRun` des scripts racine était écrasé** par le dot-source de `00-helpers` (même variable de portée
  script). Un « dry-run » de `format-ssd-jeux.ps1` aurait pu devenir réel. Levé en capturant le switch avant le
  dot-source ; un test vérifie l'ordre dans les 4 scripts.
- **`return , $tableau` + `@(...)`** donnait un tableau imbriqué : le comptage des dépôts valait toujours 1. Les tests
  l'ont attrapé, et les fonctions émettent maintenant normalement.
- **`git status` sur des dépôts OneDrive « à la demande »** : l'index venu d'EXODIUS ferait re-hacher, donc
  télécharger, chaque fichier suivi (des dizaines de Go). La migration ne lit donc plus que `.git/config`.
- **`05-vscode` ignorait le dry-run.** La simulation a réellement installé une extension sur EXODIUS
  (`anthropic.claude-code`, déjà dans la liste voulue). Et sous PS 5.1 + `ErrorActionPreference=Stop`, un warning node
  sur stderr le faisait planter dès la 1ʳᵉ extension. Corrigé, avec un test de non-régression.

### Idées testées
- **Agents en parallèle pour le code** (ML, tri HP/jeu, remote), chacun avec ses fichiers et ses tests. Gardée :
  60, 61 et 51 tests, 0 remarque PSSA. Chaque agent a trouvé un vrai bug dans son lot ou signalé un manque ailleurs
  (le Game Mode recoupé par `06-tweaks`, Ubuntu sans compte après `wsl --install --no-launch`).
- **Plan d'alimentation « Performances optimales »** : abandonné au profit de Balanced. Intel le recommande pour Arrow
  Lake, et la machine reste allumée 24/7.
- **`HF_HUB_ENABLE_HF_TRANSFER=1`** : retiré. Sans le paquet `hf_transfer`, un `huggingface_hub` ancien échoue ;
  `hf_xet` suffit.

### Décisions
- Projets dans `C:\Dev\03_Projets_Code` hors OneDrive, plutôt qu'un modèle hybride qui obligerait à gérer deux racines
  à vie. La sauvegarde passe par GitHub et des bundles git quotidiens dans OneDrive.
- Docker Desktop plutôt que Docker Engine dans WSL : déjà en place, et le GPU marche directement.
- Sunshine + Moonlight en voie principale, Parsec en secours, sans aucun port ouvert sur la box. Le pare-feu Sunshine
  est limité à `100.64.0.0/10`.
- D: (P310 QLC sans DRAM) ne reçoit que des jeux et des données froides ; Docker, WSL et le deep learning restent sur C:.

### Pour l'article
- « Le dry-run qui n'en était pas un » : deux bugs de dry-run trouvés le même jour, dont un sur un script qui formate un
  disque.
- Le chiffre : 192 occurrences du chemin OneDrive dans les configs Claude, et une jonction qui les rend toutes justes.
- 300 tests et une simulation complète avant de toucher la vraie machine.
