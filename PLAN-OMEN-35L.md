# Plan — nouveau PC HP HyperX OMEN 35L (GT18-0017nf) — prépa avant arrivée

> **Pas de reset cette fois.** On garde l'image constructeur HP, on se contente de **trier les merdes**
> sans casser la garantie, et on prépare l'optimisation pour un usage mixte :
> **projets / dev / Claude Code / « deep » + beaucoup de jeu**.
> Double SSD : **1 To HP (OS + taf)** + **Crucial P310 1 To (jeu)**.
> Accès distant depuis **EXODIUS** en déplacement + réseau **10 GbE** local.
> Pendant pour le pendant de l'audit EXODIUS → voir [AUDIT-RESET-2026.md](AUDIT-RESET-2026.md).

---

## 0. TL;DR — les décisions à prendre

1. **Garantie : aucun risque à virer les logiciels** ni à ajouter le P310 / une carte réseau. Le boîtier
   a un **accès sans outil**, les composants sont « standard » et HP range RAM/SSD en *Customer Self-Repair*.
   Seul un **dommage que tu causes** n'est pas couvert. On garde le SSD 1 To d'origine en place (il devient `C:`).
2. **Accès distant = Parsec + Tailscale (ton choix) → bon choix.** Je n'ai *jamais* conseillé le RDP : Windows 11
   Famille ne peut pas l'héberger, et pour une tour de jeu c'est de toute façon moins bon (pas d'encodage GPU
   type NVENC). **À tester en plus : Sunshine + Moonlight**, souvent meilleur et qui se marie nativement avec
   Tailscale. Comparatif + reco en §4.
3. **Le 10 GbE sert à brancher l'OMEN à ton Internet 10G maison** (l'Ethernet intégré plafonne à **2,5 GbE**).
   **TX401 en direct sur l'unique port 10G de ta Livebox 7** (câble Cat6a/Cat7). Ça ne concerne **pas** l'accès
   en déplacement (limité par la connexion du lieu où tu es). → §4
4. **Double SSD** : 1 To HP = `C:` (OS + dev + Docker/WSL + deep learning) · **P310 = `D:` = jeux**. **P310 : on
   efface** (rien à garder). Il passe de Gen3 bridé (~3500) à **Gen4 plein pot (~7100 Mo/s)**. ⚠️ Les 2 slots SSD
   seront pleins → prévoir où vont les datasets. → §3
5. **Deep learning confirmé** : RTX 5080 16 Go OK pour inférence + fine-tuning ; prévoir **CUDA sur WSL2**. RAM :
   **32 Go au départ, 64 Go plus tard**. Datasets + OneDrive **sur `C:`** (budget 1 To à surveiller). → §5 / §3
6. **OMEN Gaming Hub = à garder** (ventilos, RGB, **écran LCD** du watercooling, OMEN AI). On coupe juste ses pubs/notifs.

**Ce qu'il reste à trancher → §7.**

---

## 1. La machine (specs confirmées sur hp.com/fr-fr, fiche GT18-0017nf · 3 099 €)

| Poste | Détail | Ce que ça change pour nous |
|---|---|---|
| CPU | **Intel Core Ultra 7 270K** (Arrow Lake, LGA1851, ~20 cœurs 8P+12E) | costaud pour compile / Docker / multitâche |
| GPU | **NVIDIA GeForce RTX 5080 16 Go** (Blackwell, DLSS 4) | jeu 1440p/4K ET IA locale (16 Go VRAM) |
| RAM | **32 Go DDR5-6000** | OK jeu + dev modéré ; 64 Go plus tard si Docker+WSL+IA+jeu en même temps |
| Stockage | **1 To SSD PCIe Gen4 NVMe M.2** (d'origine) | devient `C:` |
| Slots M.2 | **3 M.2** (2 SSD + 1 WLAN) → **1 slot SSD libre** | 👉 le **P310** va là, en Gen4 |
| Slots PCIe | **1× PCIe Gen5 x16** (GPU) + **1× PCIe Gen5 x4 LIBRE** | 👉 carte **10 GbE** va là |
| Alim | **1000 W** 80+ Gold, ATX 3.1, entièrement modulaire | énorme marge pour carte réseau / upgrades |
| Refroidissement | **Watercooling 240 mm à écran LCD** | piloté par OMEN Gaming Hub |
| Réseau | **Ethernet 2,5 GbE** (Realtek RTL8125) · **Wi-Fi 7** · **BT 6.0** | onboard = 2,5 GbE → le 10 GbE sera une carte en plus |
| OS | **Windows 11 Famille** | ⚠️ pas de RDP hôte (voir §4) |
| Châssis | accès sans outil, composants standard | upgrades faciles, garantie tranquille |

> Spécifs à revérifier sur l'étiquette à la réception (GPU exact, nombre de barrettes RAM peuplées).

---

## 2. Bloatware HP — garder / optionnel / virer

**Garantie d'abord :** désinstaller un logiciel **n'a jamais** d'effet sur la garantie matérielle. En France tu as
en plus la **garantie légale de conformité (2 ans)** qu'aucun upgrade ne peut annuler. Ajouter le P310 / une carte
réseau via l'accès sans outil = autorisé (self-repair) ; seul un **dommage physique que tu provoques** sort de la
couverture. Garde les cartons/pièces, et si un jour RMA : remets l'état d'origine.

| App | Verdict | Pourquoi |
|---|---|---|
| **OMEN Gaming Hub** | ✅ **garder** | pilote ventilos, RGB, **écran LCD** du watercooling, OMEN AI, modes perf. Le virer = perdre tout ça. On coupe juste ses notifs/démarrage auto. |
| **HP Support Assistant** | ✅ garder | pilotes + **mises à jour BIOS** + statut garantie. Utile sur une machine sous garantie. |
| Pilotes HP (audio, chipset, DTS:X, System Event…) | ✅ garder | matériel |
| **myHP** | 🟡 optionnel | hub promo/support, pas critique → virable |
| **HP Smart** | 🟡 | app imprimante → vire si pas d'imprimante HP |
| **McAfee** (essai 30 j) | ❌ **virer** | nag + conflits ; **Windows Defender suffit** largement |
| ExpressVPN / Dropbox / Booking / essais divers | ❌ virer | pub préinstallée |
| Jeux/essais Store, LinkedIn, Spotify stub, etc. | ❌ virer | bloat Windows |
| Xbox / PC Game Pass (essai) | 🟡 | garde l'app Xbox si tu veux le Game Pass |

**Méthode** : `Paramètres > Applications > Applications installées` (menu `…` > Désinstaller), ou en masse via
`winget uninstall`. ⚠️ Les apps **HP** retirées **ne se réinstallent pas facilement** → décide avant.
On fera une **checklist de tri au 1er boot** (capture de la liste réelle avant/après).

---

## 3. Stratégie disques — double SSD

| Disque | Rôle | Contenu |
|---|---|---|
| **1 To HP (Gen4)** → `C:` | Système + travail | Windows + apps HP + environnement dev (Git, VSCode, Claude Code, Node, Python, **Docker/WSL**), projets `03_Projets_Code`, OneDrive |
| **Crucial P310 1 To** → `D:` | **Jeu** | bibliothèques **Steam / Battle.net / Riot / Epic**, installs de jeux |

- **Le P310 est « libéré »** : sur EXODIUS ses slots M.2 étaient **Gen3** (~3500 Mo/s plafond). Dans l'OMEN, slot
  **Gen4** → **~7100 Mo/s** plein pot. Nature QLC/sans DRAM = **parfait en disque de jeu** (lecture intensive),
  à ne **pas** utiliser comme disque système.
- Configurer **Steam/Epic/Battle.net** pour installer par défaut sur `D:`.
- **P310 : on efface** (rien à sauver dedans, décidé). Formatage propre à l'install → `D:` = jeux.
- ⚠️ **Place disque** : les **2 slots M.2 SSD seront pleins** (1 To + P310) et le slot PCIe part dans la carte
  10 GbE → **plus aucun slot interne libre** (extension future = externe USB4/TB).
- **Datasets + OneDrive → sur `C:` (décidé).** OK pour démarrer, mais budget 1 To à surveiller : Windows+HP ~70 Go,
  Docker/WSL ~120 Go, OneDrive jusqu'à **254 Go *logiques*** (cf. [audit EXODIUS](AUDIT-RESET-2026.md)). **Conseils** :
  garder OneDrive en **« Fichiers à la demande »** (ne pas tout hydrater → ~200 Go économisés) et **ne pas laisser
  tes dossiers de projets** (`node_modules`/`.venv`) se synchroniser dans OneDrive — le piège repéré dans l'audit
  (bloat + fichiers « online-only » qui cassent les builds). Il reste alors ~400-500 Go pour les datasets.

### 3.1 — Garder tes projets en sécurité **sans** les alourdir dans OneDrive

**Pourquoi la synchro OneDrive est le mauvais outil pour du code vivant :**
- `node_modules`/`.venv`/caches = des **dizaines de milliers de petits fichiers** régénérés en permanence → OneDrive
  passe son temps à re-synchroniser (CPU/IO, file d'attente qui bouchonne).
- Les **« Fichiers à la demande »** rendent des fichiers *online-only* ; un build / Node / Python / Git qui ouvre
  un placeholder → téléchargement à la volée, lenteurs, ou **build qui casse**.
- OneDrive peut synchroniser un **`.git` à moitié écrit** → **corruption du dépôt** + « copies de conflit ».
- En clair : OneDrive garde **l'état actuel des fichiers**, ce n'est **pas** un outil de versionnage/sauvegarde de code.

**Ce que tu veux vraiment = sauvegarde + historique, pas synchro.** Et le bon outil, tu l'as déjà : **Git + GitHub.**
Un dépôt poussé garde **tout l'historique** (chaque version, hors-site, gratuit) — bien **mieux** que OneDrive qui
n'a que la dernière copie. PC mort → `git clone` et tu récupères tout, l'histoire comprise. C'est *ça*, ta part
d'histoire préservée pour de vrai.

**Plan d'action :**
1. **Projets hors OneDrive** : ex. `C:\Dev\` (ou `D:\Dev\`). Builds rapides, zéro conflit de synchro.
2. **Sécurité = Git + GitHub** (dépôts **privés**) : chaque projet = un dépôt avec remote, `git push` régulier,
   `.gitignore` excluant `node_modules`/`.venv`/build/secrets.
3. **Secrets & fichiers non-git** (.env, clés, petites data) : via `backup-secrets.ps1` → OneDrive (c'est tout
   petit, ça ne bouchonne pas) ou un coffre chiffré.
4. **Ceinture + bretelles OneDrive (optionnel)** : une tâche planifiée dépose un **`git bundle --all`** de chaque
   dépôt (= **1 fichier** avec tout l'historique) dans un dossier OneDrive, 1×/semaine → copie dans OneDrive
   **sans** synchroniser l'arborescence qui bouchonne.
5. **Grosses data / datasets** (deep learning) : hors git et hors synchro → sauvegarde ciblée sur **SSD externe**
   ou cloud objet, avec exclusions.

---

## 4. Réseau — deux besoins à ne pas confondre

### 4.a — 10 GbE : brancher l'OMEN à ton Internet 10G **à la maison**
Objectif réel : exploiter ta **connexion Internet multi-gig/10G**, parce que l'Ethernet intégré de l'OMEN plafonne
à **2,5 GbE**. C'est l'OMEN qui fait tout le boulot réseau (deep learning, téléchargements, Claude Code, services).

- **Carte : TP-Link TX401 → bon choix ✅.** PCIe **3.0 x4**, port RJ45 **10GBASE-T** rétrocompatible 5G/2,5G/1G,
  pilotes Windows 11 dispo (vérifie la version matérielle **V1/V2** au téléchargement). Elle rentre sans souci
  dans le slot **PCIe Gen5 x4 libre** (rétrocompatible), et l'alim 1000 W encaisse large. Elle chauffe un peu
  (gros dissipateur) → le flux d'air du boîtier suffit.
- **Ta chaîne est bonne ✅.** La **Livebox 7** a **1 port 10 Gb/s RJ45** (+ 4 ports 1 Gb/s) → **branche la TX401
  en direct sur le port 10G** avec un câble **Cat6a** (Cat7/8 pour la marge). Tu as ~8 Gb/s dispo : avec le
  2,5 GbE intégré tu en perdrais les deux tiers, d'où l'intérêt de la carte.
- ⚠️ **Un seul port 10G sur la Livebox** (les 4 autres plafonnent à 1 Gb/s). Si un jour tu veux **plusieurs**
  appareils en >1G (ou EXODIUS en 10G à la maison), il faudra un **switch 10G** branché sur ce port 10G.
- **Option (OMEN ↔ EXODIUS en 10G local)** : secondaire (tu voyages avec EXODIUS). Un portable n'a pas de slot
  PCIe → adaptateur **Thunderbolt/USB4 → 10 GbE** + switch 10G. À garder sous le coude seulement.

### 4.b — Accès **en déplacement** (par Internet) : rien à voir avec le 10 GbE
La vitesse dépend de la connexion **du lieu où tu es** (hôtel, 4G/5G…), pas du 10G maison — tu l'as bien vu.

> **Rappel** : Windows 11 Famille ne peut pas *héberger* le Bureau à distance (RDP). Le RDP n'était donc **pas**
> ma reco — au contraire. Pour une tour de jeu, les solutions à **encodage GPU (NVENC)** sont meilleures.

**Ton choix (Parsec + Tailscale) est bon.** Voici comment ça se compare — et pourquoi Sunshine + Moonlight vaut
le coup d'être testé :

| Critère | **Parsec** | **Sunshine + Moonlight** |
|---|---|---|
| Prix | Gratuit (perso) ; 4K60 / 4:4:4 = payant | **100 % gratuit, open-source**, aucun plafond |
| Qualité / débit | Plafonne ~50 Mb/s, 1080p60 en gratuit | **4K, HDR, haut rafraîchissement, bitrate libre** |
| Latence | Excellente (NVENC) | Excellente, **léger edge en LAN/NVIDIA** |
| Réseau | **Relais intégré** (NAT auto, zéro config) | IP directe **ou ton propre VPN** → **Tailscale = parfait** |
| Mise en place | **5 min, zéro prise de tête** | Plus de config (mais faite une fois) |
| Multi-écran / co-op | Co-op multi-joueurs natif | 1 client à la fois |
| Divers | Proprio (Unity), compte requis | Pas de compte, pas de cloud tiers |

**Mon avis :** comme tu fais **déjà du Tailscale** + tu as une carte **NVIDIA** + tu veux de la qualité sans payer,
**Sunshine + Moonlight est probablement le meilleur choix final** (le seul point faible — le réseau/NAT — est
justement réglé par ton Tailscale). **Parsec reste parfait** comme solution ultra-simple / de secours, et les deux
**cohabitent** sans problème. Reco concrète : installe **Parsec** tout de suite (ça marche en 5 min), puis teste
**Sunshine + Moonlight** à tête reposée ; garde celui que tu préfères.

- **Sécurité** : dans les deux cas, **Tailscale** (WireGuard) relie EXODIUS et l'OMEN en privé → **aucun port à
  ouvrir**, aucune exposition publique. On ne met jamais le PC directement sur Internet.
- **Mode « mono-écran » à distance (automatique)** : tu auras **3 écrans** ; en remote on veut tout sur **un seul**.
  Sunshine peut lancer des **commandes au démarrage et à la fin du stream** (*prep-cmd* / Do-Undo) → on y branche
  **NirSoft MultiMonitorTool** (gratuit, portable, CLI) pour **désactiver les écrans 2 & 3** à la connexion et
  **tout restaurer** à la déconnexion. Windows rapatrie alors les fenêtres sur l'écran principal → **plus rien à
  chercher**, et ça se remet en 3 écrans tout seul quand tu te déconnectes. *(À scripter — outillage Reset Pack.)*

---

## 5. Optimisation usage mixte (dev + Claude Code + « deep » + jeu)

- **Environnement dev** : on **réutilise le Reset Pack en mode « à la carte »** (sans reset ni debloat agressif) pour
  réinstaller ta stack sur `C:` → voir §6. Tout le dev/projets/Docker/WSL sur `C:` (1 To, large).
- **Deep learning (confirmé)** sur **RTX 5080 16 Go** :
  - **CUDA sur WSL2** (Ubuntu) = la voie reco — ça colle à ta stack Reset Pack (WSL2 déjà géré), avec Docker +
    GPU (`--gpus all`) et tout l'outillage Linux (PyTorch/TF). Installer le toolkit CUDA + cuDNN côté WSL.
  - **16 Go de VRAM** = confortable pour l'**inférence** et le **fine-tuning** (LoRA/QLoRA sur modèles 7B–13B,
    Stable Diffusion, etc.). Pour l'entraînement de gros modèles, la VRAM sera la limite → quantization / offload.
  - **Datasets/modèles** → sur **`C:`** pour commencer (décidé, cf. §3), OneDrive en « Fichiers à la demande ».
    Plus aucun slot interne libre après le P310 + la carte 10 GbE → l'extension se fera en **USB4/TB**.
- **RAM : 32 Go au départ (décidé), 64 Go plus tard** quand deep learning + Docker + WSL + jeu s'empileront (ajout facile).
- **Jeu sur `D:` (P310)** : pilote via **NVIDIA App** (pas GeForce Experience), fan/RGB via **OMEN Gaming Hub**,
  mode perf + courbe ventilos dans le Hub.
- **Réglages Windows** : plan d'alim **Performances élevées/Ultimate**, Storage Sense, garder **Windows Defender**.
  On peut reprendre tes tweaks Reset Pack sûrs (Game DVR off, « Fin de tâche » dans la taskbar…). On **évite** de
  toucher à la sécurité (Memory Integrity) sauf besoin précis.
- **Thermique** : le watercooling 240 mm LCD suffit pour le 270K ; surveillance dans OMEN Gaming Hub.

---

## 6. Reset Pack — ce qu'on réutilise **sans** reset

La machine garde son image HP, donc **on ne lance PAS** `reset.ps1` en entier. Mais on peut jouer **certains modules**
pour retrouver ton environnement :

| Module | Sur l'OMEN (sans reset) ? |
|---|---|
| `01-apps` | ✅ oui — installe ta stack (tri des apps à garder) |
| `03-dev-setup` | ✅ oui — Git, WSL2, gh auth, long paths |
| `04-symlinks` | ✅ oui — tes liens de config |
| `06-tweaks` | 🟡 au cas par cas — garder les tweaks sûrs |
| `08-debloat` | ❌ **non** — conçu pour un reset, trop agressif ici |
| `02-drivers` | ❌ non — HP/NVIDIA gèrent déjà les pilotes |

> À faire : ajouter un **mode « nouveau PC sans reset »** au Reset Pack (ex. `reset.ps1 -Only apps,dev-setup,symlinks`)
> et documenter le tri bloatware HP comme module optionnel.

---

## 7. Décisions — toutes prises ✅

- « deep » = **deep learning** · **P310 → on efface** · accès distant = **Parsec + Tailscale** (+ test Sunshine + Moonlight)
- carte 10 GbE = **TP-Link TX401** sur le **port 10G de la Livebox 7** (Cat6a/7) · **OMEN Gaming Hub gardé**
- **RAM 32 Go** au départ, 64 Go plus tard · **datasets + OneDrive sur `C:`** (Fichiers à la demande)

### À faire à l'arrivée du PC (checklist)

1. **1er boot** : capturer la liste des apps, puis **trier le bloatware** (§2 — virer McAfee & co, garder HP Support Assistant + OMEN Gaming Hub).
2. **Mises à jour** : Windows Update + BIOS/pilotes via HP Support Assistant + **NVIDIA App**.
3. **Monter le matériel** (accès sans outil) : **P310** dans le 2ᵉ slot M.2, **TX401** dans le slot PCIe x4.
4. **Disques** : formater le P310 → `D:` (jeux), régler Steam/Epic/Battle.net pour installer sur `D:`.
5. **Réseau** : TX401 sur le **port 10G Livebox** (Cat6a/7), vérifier le débit ; OneDrive en « Fichiers à la demande ».
6. **Dev** : rejouer les modules Reset Pack à la carte (`-Only apps,dev-setup,symlinks`), puis **CUDA sur WSL2**.
7. **Accès distant** : **Tailscale** sur l'OMEN + EXODIUS, puis **Parsec** (rapide) et test **Sunshine + Moonlight**.

> En fin de séance : skill `journal-projet` pour archiver ça dans le `JOURNAL.md` du projet.
