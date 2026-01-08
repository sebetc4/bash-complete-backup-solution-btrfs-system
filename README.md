# Complete Backup Solution for Linux BTRFS Systems

Professional backup and restore scripts for Fedora Linux with BTRFS and LUKS encryption.

---

## 📦 What's Included

This repository contains **4 independent backup tools**:

| Tool | Purpose | Config | Command |
|------|---------|--------|---------|
| **backup-system** | System backup (/, /home, /code) | `~/.backup/config-system.yml` | `backup-system` |
| **backup-hdd** | Simple HDD mirror | `~/.backup/config-hdd.yml` | `backup-hdd` |
| **backup-hdd-both** | Split backup across 2 drives | `~/.backup/config-hdd-both.yml` | `backup-hdd-both` |
| **restore-system** | System restoration (Live USB) | `restore-system/config.yml` | `restore.sh` |

---

## 🚀 Quick Start

### Installation

```bash
cd /code/bash/backup
sudo ./install.sh
```

**Interactive menu:**
1. Choose which HDD backup scripts to install (simple, split, or both)
2. Scripts are copied to `/usr/local/bin/`
3. Example configs are created in `~/.backup/`

### First Backup

```bash
# Edit your config
nano ~/.backup/config-system.yml

# Test run
sudo backup-system --dry-run

# Real backup
sudo backup-system
```

---

## 📂 Directory Structure

```
backup/
├── backup-system/          # System backup (/ /home /code → HDD)
│   ├── backup.sh
│   ├── config.yml
│   └── README.md
│
├── backup-hdd/
│   ├── hdd-to-hdd/        # Simple HDD mirror (HDD1 → Backup1)
│   │   ├── backup.sh
│   │   ├── config.yml
│   │   └── README.md
│   │
│   └── hdd-to-both-hdd/   # Split backup (HDD1 → Backup1 + Backup2)
│       ├── backup.sh
│       ├── config.yml
│       └── README.md
│
├── restore-system/         # System restoration (Live USB)
│   ├── restore.sh
│   ├── config.yml
│   └── README.md
│
└── install.sh             # Installation script
```

---

## 🎯 Use Cases

### 1. Complete System Backup

**Tools:** `backup-system` + `restore-system`

Backs up your entire Fedora system (root, home, code) to external HDD with optional snapshots.

```bash
sudo backup-system
```

**Features:**
- Incremental backups with rsync
- Optional BTRFS snapshots with rotation
- Optional Timeshift snapshot sync (configurable limit)
- Log rotation
- Configuration validation

📖 [Read more](backup-system/README.md)

---

### 2. Simple HDD Mirror

**Tool:** `backup-hdd`

Mirror one HDD to another (1:1 backup).

```bash
sudo backup-hdd
```

**Use for:**
- Backing up /mnt/hdd1 → /mnt/backup1
- Simple cold storage backup
- Entire drive mirroring

📖 [Read more](backup-hdd/hdd-to-hdd/README.md)

---

### 3. Split Backup Across Two Drives

**Tool:** `backup-hdd-both`

Backup different folders to different drives.

```bash
# Backup to both drives
sudo backup-hdd-both

# Backup to drive 1 only
sudo backup-hdd-both -d 1
```

**Use for:**
- Documents to Drive 1, Media to Drive 2
- Critical data vs archives
- Splitting large backups across multiple drives

📖 [Read more](backup-hdd/hdd-to-both-hdd/README.md)

---

### 4. System Restoration

**Tool:** `restore-system`

Restore your system from backup using a Live USB.

**Two modes:**
- **Full disk** (`--full-disk`): Erase and recreate all partitions
- **Partition mode** (`--partitions`): Dual-boot safe, preserves Windows

```bash
# From Live USB
sudo bash restore.sh --partitions
```

📖 [Read more](restore-system/README.md)

---

## ✨ Key Features

### All Scripts

- ✅ **YAML configuration** with validation
- ✅ **Log rotation** with size limits
- ✅ **Dry-run mode** for testing
- ✅ **Color output** for readability
- ✅ **Error handling** and validation

### Backup Scripts

- ✅ **Incremental backups** with rsync
- ✅ **Optional BTRFS snapshots** with retention
- ✅ **Compression statistics**
- ✅ **Integrity checks** (scrub)
- ✅ **Smart exclusions**

### Restore Script

- ✅ **Dual-boot safe** (partition mode)
- ✅ **LUKS encryption** setup
- ✅ **BTRFS subvolumes** recreation
- ✅ **GRUB with os-prober** (Windows detection)

---

## 🛠️ Requirements

### Software

```bash
sudo dnf install yq rsync
```

### Hardware

- **System backup:** External HDD (5TB+ recommended)
- **HDD mirror:** Source HDD + Backup HDD
- **Split backup:** Source HDD + 2 Backup HDDs

### Filesystem

- **BTRFS** (recommended for snapshots and compression)
- Works with ext4, but snapshots won't work

---

## 📋 Configuration Files

After installation, configs are in `~/.backup/`:

```
~/.backup/
├── config-system.yml      # System backup
├── config-hdd.yml         # Simple HDD mirror
└── config-hdd-both.yml    # Split HDD backup
```

**Restore config** is separate (for Live USB):
```
restore-system/config.yml
```

---

## 🔧 Typical Workflow

### Daily Backup

```bash
# System backup (automated with systemd timer)
sudo backup-system

# HDD backup (weekly)
sudo backup-hdd
```

### Disaster Recovery

1. Boot from Fedora Live USB
2. Copy `restore-system/` directory to USB
3. Edit `config.yml` with your settings
4. Run restoration:
   ```bash
   sudo bash restore.sh --partitions  # For dual-boot
   # or
   sudo bash restore.sh --full-disk   # For clean install
   ```

---

## 📖 Documentation

- [System Backup](backup-system/README.md)
- [Simple HDD Mirror](backup-hdd/hdd-to-hdd/README.md)
- [Split HDD Backup](backup-hdd/hdd-to-both-hdd/README.md)
- [System Restoration](restore-system/README.md)

---

## 🤝 Contributing

This is a personal backup solution but feel free to adapt it to your needs.

**Key principles:**
- YAML configuration (human-readable)
- Validation before execution
- Dry-run mode for safety
- Clear error messages

---

## ⚠️ Important Notes

1. **Test in dry-run mode** before running real backups
2. **Keep multiple backup copies** on different physical drives
3. **Test restoration** in a VM before you need it
4. **LUKS passwords**: Never lose them - no password = no data access
5. **Configuration validation**: All scripts validate config at startup
