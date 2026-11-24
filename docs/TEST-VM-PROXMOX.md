# Tester le Reset Pack sur une VM (sans risque)

Windows 11 **Famille** n'a ni Windows Sandbox ni Hyper-V : le test grandeur nature se fait
sur une **VM Windows 11 du homelab Proxmox** (192.168.1.74), avec snapshot + rollback illimité.

## Les 3 niveaux de test (du plus rentable au plus lourd)

1. **Statique** (local, ~10 s, risque nul) : `.\tests\run-checks.ps1` → parse AST + PSScriptAnalyzer + Pester. Aussi en CI (`.github/workflows/lint.yml`).
2. **Dry-run** (local, risque nul) : `.\reset.ps1 -DryRun` → montre chaque action sans rien installer/modifier.
3. **VM Proxmox** (confiance max) : bootstrap de bout en bout, ci-dessous.

## VM Proxmox — procédure clé-en-main

### 0. ISOs sur le nœud (SSH `root@192.168.1.74`)
```bash
cd /var/lib/vz/template/iso/
# déposer Win11.iso (depuis microsoft.com) via l'UI Proxmox ou scp
wget -O virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
```

### 1. Créer la VM (UEFI + TPM 2.0 + q35 + VirtIO)
```bash
VMID=9011
qm create $VMID --name resetpack-test \
  --memory 8192 --cores 4 --cpu host \
  --bios ovmf --machine pc-q35-9.0 \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=1 \
  --tpmstate0 local-lvm:1,version=v2.0 \
  --scsihw virtio-scsi-single --scsi0 local-lvm:64,iothread=1 \
  --net0 virtio,bridge=vmbr0 \
  --cdrom local:iso/Win11.iso \
  --ide0 local:iso/virtio-win.iso,media=cdrom \
  --ostype win11 --boot order=ide2
qm start $VMID
```
À l'install : charger le driver `vioscsi` (ISO virtio, `D:\vioscsi\w11\amd64`) pour voir le disque.
Compte local Win11 Famille : `Shift+F10` → `OOBE\BYPASSNRO` (ou `start ms-cxh:localonly` selon build).

### 2. Snapshot propre (après install Windows + à jour)
```bash
qm snapshot $VMID clean-base --description "Win11 fraiche, avant bootstrap"
```

### 3. Lancer le pack dans la VM (PowerShell)
```powershell
irm https://raw.githubusercontent.com/Codect24/reset-pack/main/bootstrap.ps1 | iex
```
Profil conseillé en VM (évite GPU/jeux/symlinks-OneDrive qui n'ont pas de sens ici) :
```powershell
C:\ResetPack\reset.ps1 -Auto -Only apps,dev-setup,tweaks,defaults,debloat,scheduled,finalize
```
Vérifs : `winget list`, `Get-ScheduledTask ResetPack-*`, clés registre des tweaks, `C:\ResetPack\logs\`.

### 4. Rollback (ré-itérable à volonté)
```bash
qm rollback $VMID clean-base && qm start $VMID
# corriger le pack, git push, re-tester, re-rollback...
```
Nettoyage final : `qm stop $VMID; qm delsnapshot $VMID clean-base; qm destroy $VMID --purge`

> Piège OVMF : si `BdsDxe: No bootable option`, garder `--boot order=ide2` pour l'install,
> puis `qm set $VMID --boot order=scsi0` après installation.

## Alternative Hyper-V (seulement si passage à Windows **Pro**)
```powershell
$vm = 'ResetPackTest'
New-VM -Name $vm -Generation 2 -MemoryStartupBytes 8GB -NewVHDPath "D:\VMs\$vm.vhdx" -NewVHDSizeBytes 64GB -SwitchName 'Default Switch'
Set-VMKeyProtector -VMName $vm -NewLocalKeyProtector   # AVANT Enable-VMTPM
Enable-VMTPM -VMName $vm
Set-VMFirmware -VMName $vm -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
Add-VMDvdDrive -VMName $vm -Path 'D:\ISO\Win11.iso'
Start-VM $vm
# après install : Checkpoint-VM -Name $vm -SnapshotName 'clean-base'
# restore : Restore-VMCheckpoint -Name 'clean-base' -VMName $vm -Confirm:$false
```
