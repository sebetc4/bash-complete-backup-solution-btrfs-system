# System Restoration from Backup

Complete system restoration tool for BTRFS+LUKS systems, designed to run from a Fedora Live USB.

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Features](#-features)
- [Preparation](#-preparation)
- [Usage](#-usage)
- [Dual-Boot Safety](#-dual-boot-safety)
- [Configuration](#%EF%B8%8F-configuration)
- [Troubleshooting](#-troubleshooting)

---

## 🎯 Overview

This directory contains everything needed for **system restoration from backup**:
- `restore.sh` - Main restoration script
- `config.yml` - Configuration file

**Important**: These tools are **separate from the backup system** because they:
- Run from a **Live USB** (before the system is installed)
- Don't depend on system paths like `~/.backup/`
- Are portable and self-contained

---

## ✨ Features

### Two Restoration Modes

#### 1. Full Disk Mode (`--full-disk`)
- **Erases ENTIRE disk** and recreates partitions
- Creates: EFI (210MB) + Boot (2GB) + LUKS (rest)
- Use for: new SSD, clean install, no dual-boot
- ⚠️ **DESTROYS ALL DATA** on target disk

#### 2. Partition Mode (`--partitions`)
- **Preserves Windows** and other partitions
- Only formats Linux partitions (/boot + LUKS)
- Keeps EFI partition intact (Windows Boot Manager preserved)
- Use for: dual-boot systems, reinstalling Linux only
- ✅ **SAFE for dual-boot**

### Additional Features
- **LUKS encryption** setup and configuration
- **BTRFS subvolumes** recreation (root, home, code, vm, ai)
- **GRUB bootloader** installation
- **os-prober** integration for Windows detection
- **Configuration validation** to prevent errors
- Interactive partition selection in partition mode

---

## 🛠️ Preparation

### 1. Copy to Bootable Media

**Option A: On Backup HDD**
```bash
# The restore-system/ directory should already be on your backup HDD
ls /mnt/hdd1/backups/restore-system/
```

**Option B: On Separate USB**
```bash
# Copy entire directory to a USB stick
cp -r restore-system/ /media/usb/
```

### 2. Edit Configuration

Edit `config.yml` with your target disk:

```bash
nano restore-system/config.yml
```

**Key settings:**
- `backup.hdd_mount`: Where your backup HDD will be mounted (e.g., `/mnt/hdd1`)
- `backup.backup_root`: Path to backups on HDD (e.g., `/mnt/hdd1/backups`)
- `restore.target_disk`: Target disk for **full-disk mode only** (e.g., `/dev/nvme0n1`)

### 3. Create Fedora Live USB

Download Fedora Workstation Live ISO and create bootable USB:
```bash
sudo dd if=Fedora-Workstation-Live.iso of=/dev/sdX bs=4M status=progress
```

---

## 🚀 Usage

### Step 1: Boot from Live USB

Boot your computer from the Fedora Live USB.

### Step 2: Install Dependencies

```bash
# On Live USB, install required tools
sudo dnf install -y yq
```

### Step 3: Mount Backup HDD

```bash
# If HDD is LUKS encrypted
sudo cryptsetup luksOpen /dev/sdX hdd1
sudo mount /dev/mapper/hdd1 /mnt/hdd1

# If HDD is not encrypted
sudo mount /dev/sdX /mnt/hdd1
```

### Step 4: Navigate to Restore Directory

```bash
cd /mnt/hdd1/backups/restore-system
# or
cd /media/usb/restore-system
```

### Step 5: Choose Restoration Mode

#### Option A: Full Disk Restoration

⚠️ **WARNING: This erases EVERYTHING on the target disk!**

```bash
sudo bash restore.sh --full-disk
```

**What happens:**
1. Erases partition table on target disk
2. Creates GPT partitions (EFI + Boot + LUKS)
3. Formats all partitions
4. Sets up LUKS encryption (you'll enter a password)
5. Creates BTRFS subvolumes
6. Restores all data from backup
7. Installs GRUB bootloader
8. Configures fstab and crypttab

**Use for:**
- Brand new SSD/HDD
- Replacing failed disk
- Clean reinstall (no dual-boot)

---

#### Option B: Partition Mode (Dual-Boot Safe)

✅ **SAFE: Preserves Windows and other partitions**

```bash
sudo bash restore.sh --partitions
```

**What happens:**
1. Shows available partitions
2. Asks you to select:
   - **EFI partition** (existing, will be PRESERVED)
   - **/boot partition** (will be FORMATTED as ext4)
   - **LUKS partition** (will be FORMATTED with LUKS+BTRFS)
3. Formats ONLY the selected /boot and LUKS partitions
4. Mounts existing EFI (preserves Windows Boot Manager)
5. Restores all data
6. Installs GRUB alongside Windows
7. Runs os-prober to detect Windows for GRUB menu

**Use for:**
- Dual-boot with Windows
- Reinstalling Linux only
- Preserving other operating systems

---

## 🔒 Dual-Boot Safety

### Typical Dual-Boot Partition Layout

```
Device         Size   Type   Purpose              Action
─────────────────────────────────────────────────────────────
nvme0n1p1      512M   vfat   EFI System           ✅ PRESERVED
nvme0n1p2       16M   -      Microsoft Reserved   ✅ Untouched
nvme0n1p3      200G   ntfs   Windows C:           ✅ Untouched
nvme0n1p4        2G   ext4   Linux /boot          ❌ FORMATTED
nvme0n1p5      Rest   luks   Linux / (encrypted)  ❌ FORMATTED
```

### How It Works

**Partition Mode (`--partitions`):**
- Only touches partitions you explicitly select
- EFI partition is mounted read-write but NOT formatted
- GRUB is installed in `EFI/fedora/` subdirectory
- `EFI/Microsoft/` (Windows Boot Manager) remains intact
- Both operating systems coexist in UEFI boot menu

**After restoration:**
1. GRUB shows both Fedora and Windows
2. Windows Boot Manager still works independently
3. You can select default boot option in BIOS/UEFI

---

## ⚙️ Configuration

### config.yml Structure

```yaml
# Backup location (where your backups are stored)
backup:
  hdd_mount: /mnt/hdd1
  backup_root: /mnt/hdd1/backups

# Target disk (for --full-disk mode only)
restore:
  target_disk: /dev/nvme0n1
```

### Configuration Validation

The script validates the configuration at startup:

✅ **Valid types:**
```yaml
restore:
  target_disk: /dev/nvme0n1   # ✓ Absolute path
```

❌ **Invalid (will cause errors):**
```yaml
restore:
  target_disk: nvme0n1        # ✗ Not absolute path
  target_disk: "/dev/nvme0n1" # ✗ Don't quote paths
```

---

## 🐛 Troubleshooting

### yq not found

```bash
# Install on Live USB
sudo dnf install -y yq
```

### Configuration file not found

```
Configuration file not found

Searched in:
  - ./config.yml
  - /mnt/hdd1/backups/restore-system/config.yml
```

**Solution:** Make sure you're in the `restore-system/` directory or specify config:
```bash
sudo bash restore.sh -c /path/to/config.yml --full-disk
```

### Backup HDD not mounted

```
Error: Backup HDD not mounted on /mnt/hdd1
```

**Solution:**
```bash
# Check if HDD is detected
lsblk

# Mount HDD (adjust /dev/sdX)
sudo cryptsetup luksOpen /dev/sdX hdd1  # If encrypted
sudo mount /dev/mapper/hdd1 /mnt/hdd1
```

### Wrong partitions in dual-boot mode

If you accidentally select the wrong partition:
- Script shows partition info before formatting
- You must confirm with "yes" before any changes
- Press Ctrl+C to abort at any time

### GRUB doesn't show Windows

After restore in partition mode:
```bash
# From restored system (after reboot)
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

If os-prober doesn't detect Windows:
```bash
# Enable os-prober
sudo nano /etc/default/grub
# Add or set: GRUB_DISABLE_OS_PROBER=false

# Regenerate GRUB config
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

---

## 📖 Post-Restoration

### First Boot

1. **Remove Live USB**
2. **Reboot**: `reboot`
3. **Enter LUKS password** when prompted
4. **Select OS** from GRUB menu (Fedora or Windows)

### Verify System

```bash
# Check disk usage
df -h

# Check BTRFS subvolumes
sudo btrfs subvolume list /

# Check mounts
mount | grep btrfs

# Check LUKS
lsblk
```

### If /data disk exists

If your backup included a reference to a `/data` disk:
1. Connect the disk
2. Check `/etc/fstab` for commented entry
3. Uncomment and mount:
   ```bash
   sudo nano /etc/fstab  # Uncomment /data line
   sudo mount /data
   ```

---

## 📁 Files

```
restore-system/
├── restore.sh     # Main restoration script
├── config.yml     # Configuration file
└── README.md      # This file
```

---

## ⚠️ Important Notes

1. **Test in VM first**: If possible, test the restore process in a virtual machine before using on production
2. **Backup your backups**: Keep multiple backup copies on different drives
3. **Document your setup**: Take screenshots of your partition layout before restoration
4. **LUKS password**: Choose a strong password and **NEVER LOSE IT** - no password = no access to data
5. **Windows preservation**: In partition mode, Windows data is preserved but you should still have Windows recovery media as a precaution

---

**Version**: 3.2  
**Last Updated**: January 8, 2026

**Related**: See `../backup-system/README.md` for backup creation
