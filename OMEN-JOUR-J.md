# OMEN 35L : feuille de route du jour J

> Les commandes exactes, dans l'ordre. Le « pourquoi » de chaque étape est dans [SYSTEME-OMEN-35L.md](SYSTEME-OMEN-35L.md).
> Les scripts marqués 🧪 ont tous un `-DryRun` : **lance-le toujours d'abord**, lis la sortie, puis relance sans.
> Ils sont tous idempotents : en cas de doute, tu peux relancer.

---

## 0. Sur EXODIUS, avant de passer sur l'OMEN (15 min)

Ces étapes préparent les sauvegardes que l'OMEN va récupérer via OneDrive.

```powershell
cd C:\Users\tomle\OneDrive\Documents\03_Projets_Code\2026\Reset_pack
git pull
```

1. **Bundles git** 🧪. Ils servent de copie de secours, et de source pour les dépôts qui n'ont pas de remote GitHub.
   > ⚠️ Le C: d'EXODIUS est presque plein (~10 Go libres). Le `-DryRun` affiche la taille de chaque dépôt : vérifie
   > que ça tient avant de lancer pour de vrai.
   ```powershell
   .\backup-bundles.ps1 -DryRun
   ```
   ```powershell
   .\backup-bundles.ps1
   ```
2. **Configs** : settings Claude Code avec les chemins canoniques, skills, commandes, `CLAUDE.md`, mémoire par projet.
   ```powershell
   .\backup-configs.ps1
   ```
3. **Secrets**, sur une clé USB (jamais OneDrive), puis chiffre l'archive avec 7-Zip AES-256.
   ```powershell
   .\backup-secrets.ps1 -Dest E:\ResetBackup
   ```
4. **Chemin canonique sur EXODIUS** 🧪. On crée une jonction `C:\Dev\03_Projets_Code` vers ton dossier OneDrive, puis on
   réécrit hooks, MCP et skills vers ce chemin. Rien ne bouge physiquement. **Ferme d'abord Claude Desktop et Claude Code**,
   sinon `.claude.json` et `claude_desktop_config.json` sont sautés.
   ```powershell
   .\migrate-projets.ps1 -Mode Junction -DryRun
   ```
   ```powershell
   .\migrate-projets.ps1 -Mode Junction
   ```

---

## A. Premier démarrage de l'OMEN (rien installé, boîtier fermé)

1. Configure Windows avec ton compte Microsoft, sur le **2,5 GbE intégré** pour l'instant.
   > Si possible, **appelle le compte `tomle`**, comme sur EXODIUS : les configs partagées contiennent des chemins
   > `C:\Users\tomle\...`. `verify-omen.ps1` te signale l'écart si le nom est différent.
2. **Clé USB de recovery HP** : installe *HP Cloud Recovery Tool* depuis le Microsoft Store et crée la clé (32 Go). Crée aussi
   un point de restauration (Panneau de configuration › Système › Protection du système).
3. **Clé BitLocker / chiffrement de l'appareil** : relève-la sur <https://account.microsoft.com/devices/recoverykey> et
   garde une copie hors ligne.
4. Lance Windows Update, **HP Support Assistant** (BIOS et pilotes) et **NVIDIA App**. **Note la version du pilote NVIDIA**,
   puis redémarre.

## B. Matériel (P310 + TX401)

5. Suspends BitLocker pour 1 redémarrage, dans un PowerShell **admin** :
   ```powershell
   Suspend-BitLocker -MountPoint C: -RebootCount 1
   ```
6. Éteins la machine, débranche-la, puis installe le **P310** dans le 2ᵉ slot M.2 et la **TX401** dans le PCIe x4 libre.
7. BIOS (F10) : M.2 en Gen4, **XMP**, **Resizable BAR ON**. Vérifie aussi que l'ordre de boot démarre bien sur le SSD HP.

## C. Récupérer le Reset Pack (le « pull »)

8. Installe git, puis **ouvre un nouveau terminal** :
   ```powershell
   winget install --id Git.Git -e --source winget
   ```
9. Clone le pack **directement à son emplacement définitif** :
   ```powershell
   git clone -b feat/prep-omen-35l https://github.com/Codect24/reset-pack.git C:\Dev\03_Projets_Code\2026\Reset_pack
   ```
10. Dans un PowerShell **admin**, pour toutes les étapes suivantes :
    ```powershell
    cd C:\Dev\03_Projets_Code\2026\Reset_pack; Set-ExecutionPolicy -Scope Process Bypass -Force
    ```
    Pour récupérer plus tard les mises à jour du pack : `git pull`.

## D. Effacer et reformater le P310 → `D:` « Jeux » 🧪

11. Le script ne cible **que** le disque NVMe dont le modèle contient « P310 », de 900 à 1100 Go, et qui n'est ni le
    disque système ni celui qui porte C: ou un fichier d'échange. Il te montre ce qu'il va effacer, puis il te fait taper
    `EFFACER <n°>`.
    ```powershell
    .\format-ssd-jeux.ps1 -DryRun
    ```
    ```powershell
    .\format-ssd-jeux.ps1
    ```
    Résultat : partition GPT unique, NTFS, nom « Jeux », TRIM complet. Ne crée **aucun dossier à la main** : le module
    `storage` s'en charge.

## E. Le profil OMEN 🧪

12. Simulation complète. Elle lance aussi la **capture de l'état HP installé** (dans `logs\hp-capture-*`) : c'est ta
    référence avant tout tri.
    ```powershell
    .\reset.ps1 -Profile omen -DryRun
    ```
13. En réel. C'est interactif : `gh auth` ouvre le navigateur, et chaque module te demande `[O/n/q]`.
    ```powershell
    .\reset.ps1 -Profile omen
    ```
    Ordre : tri HP → apps → dev (WSL, git, gh) → symlinks → VSCode → stockage → code → tweaks → apps par défaut → jeu →
    sauvegardes de jeux → deep learning → remote → tâches planifiées → finalisation.
    > **WSL** : `dev-setup` installe Ubuntu **sans compte Linux**. Le module `ml` le voit, saute le provisioning et
    > affiche un warning. Après le profil, lance une fois `wsl -d Ubuntu` pour créer ton utilisateur (et redémarre si
    > WSL le demande), puis : `.\reset.ps1 -Profile omen -Only ml`. C'est ce qui provisionne WSL et lance le smoke-test
    > GPU : torch cu128 sur le RTX 5080, plus Docker `--gpus all`.
    > Le fichier `.state` permet la reprise : un module déjà réussi est sauté.

## F. Projets → `C:\Dev\03_Projets_Code` 🧪

14. Chaque dépôt est cloné depuis GitHub, sinon depuis son bundle. Les `.env` sont recopiés si l'ancien dossier OneDrive
    est encore là. La mémoire Claude Code est rattachée au nouveau chemin.
    ```powershell
    .\migrate-projets.ps1 -DryRun
    ```
    ```powershell
    .\migrate-projets.ps1
    ```
    Les dossiers **sans git** sont seulement listés ; ajoute `-CopyNonGit` pour les copier aussi.
15. Vérifie quelques projets, puis **OneDrive › Paramètres › Compte › Choisir les dossiers** et **décoche
    `Documents\03_Projets_Code`**.

## G. Réseau 10G

16. Installe le pilote de la TX401 : **Marvell AQtion** pour une V1, pilote TP-Link pour une V2 (la version est sur
    l'étiquette). Branche le câble sur le port 10G de la Livebox et **débranche le 2,5G**, mais laisse-le activé.
17. Vérifie que `Get-NetAdapter` annonce **10 Gbps**, puis fais un speed-test multi-flux : il doit dépasser **2,5 Gbps**.

## H. Remote : la partie manuelle

Le module `remote` a déjà fait le gros du travail :
- installé MultiMonitorTool et les scripts mono-écran dans `C:\Tools` ;
- branché `global_prep_cmd` et coupé l'UPnP dans `sunshine.conf` ;
- limité le pare-feu Sunshine à Tailscale (`100.64.0.0/10`) ;
- coupé la veille sur secteur ;
- créé les tâches `ResetPack-MonoEcranOn/Off` et `ResetPack-ReactiverEcrans`.

Il reste à faire à la main :

- **Tailscale** : connecte-toi, puis dans la console admin (login.tailscale.com) **désactive l'expiration de clé** du
  nœud OMEN et active **MagicDNS**.
- **Sunshine** : WebUI <https://localhost:47990>.
  - Crée le mot de passe et range-le dans Dashlane.
  - Choisis l'écran capté : par défaut l'écran **principal**, réglable dans `config\remote.json` › `keepMonitor`.
- **Moonlight sur EXODIUS** (installé par le profil `exodius`, sinon `winget install --id MoonlightGameStreamingProject.Moonlight -e`) :
  ajoute l'OMEN par son nom MagicDNS, puis entre le PIN dans la WebUI Sunshine.
- **Parsec** (secours) : connexion, **2FA obligatoire**.
- **Ferme toujours la session par « Quitter » dans Moonlight** : c'est ce qui rallume les 2 autres écrans. Si tu te
  déconnectes sans quitter, ils restent éteints ; la parade est la tâche `ResetPack-ReactiverEcrans`.
- ⚠️ Une mise à jour de Sunshine (winget hebdo) peut recréer ses règles de pare-feu larges. `verify-omen` le détecte,
  et `.\reset.ps1 -Profile omen -Only remote` corrige.

## I. Filets et validation

18. Branche le **SSD externe**. Ses commandes ont un `-DryRun`, **sauf la première** (elle n'écrit que sur la clé, jamais
    dans OneDrive) :
    ```powershell
    .\backup-secrets.ps1 -Dest X:\ResetPack-Backup
    ```
    ```powershell
    .\backup-datasets.ps1 -WslExport -DryRun
    ```
    ```powershell
    .\backup-bundles.ps1
    ```
19. **Test d'acceptation** : tout doit passer au vert. Il ne modifie rien.
    ```powershell
    .\verify-omen.ps1
    ```
20. **Test réel depuis EXODIUS en 4G/5G** (hors de ton réseau) : connexion Moonlight, passage en mono-écran, puis
    restauration des 3 écrans à la déconnexion.
21. Lance `journal-projet` pour archiver la séance.

---

### Si quelque chose déraille

| Symptôme | Parade |
|---|---|
| Écran noir après une session distante | Parsec → tâche planifiée `ResetPack-ReactiverEcrans` (ou `scripts\remote\reactiver-ecrans.ps1`) |
| Le lien reste à 1 Gbps | pilote générique : installe le pilote Marvell/TP-Link (§G) |
| `no kernel image is available` (CUDA) | PyTorch ≥ 2.7 en `cu128` (voir `scripts\wsl-ml-setup.sh --smoke-test`) |
| La clé BitLocker est demandée au boot | elle est sur account.microsoft.com/devices/recoverykey (étape 3) |
| Un hook / MCP Claude ne répond plus | `.\migrate-projets.ps1 -ConsumersOnly -DryRun` (Claude fermé pour le réel) |
| Après une grosse mise à jour Windows | `.\verify-omen.ps1`, puis `.\reset.ps1 -Profile omen -Only hp-triage,tweaks,gaming` |
