# BTRFS System Backup & Restore

Complete backup and restoration solution for Linux systems using BTRFS subvolumes with LUKS encryption.

## 📋 Table of Contents

- [Features](#-features)
- [System Requirements](#-system-requirements)
- [Installation](#-installation)
- [Configuration](#%EF%B8%8F-configuration)
- [Usage](#-usage)
- [Restoration Process](#-restoration-process)
- [Troubleshooting](#-troubleshooting)

---

## ✨ Features

### Backup Script (`backup.sh`)
- **Incremental backups** with rsync to external HDD
- **BTRFS snapshots** (optional) with configurable retention
- **Source snapshots sync** (optional) - sync Timeshift/snapper snapshots with configurable limit
- **Atomic consistency** via read-only snapshots during backup
- **Smart exclusions** for caches, temporary files, and large datasets
- **Log rotation** with configurable size limit
- **Lock file** to prevent concurrent backups
- **Dry-run mode** to test before execution
- **Desktop notifications** on success/failure
- **Automatic BTRFS structure documentation**
- **Configuration validation** to prevent errors

---

## 🖥️ System Requirements

### Hardware
- **Main SSD**: System disk with BTRFS filesystem
- **External HDD**: For backups (5TB+ recommended)

### Software
- **Fedora Linux** (or compatible distribution)
- **BTRFS** filesystem with subvolumes
- **LUKS** encryption (optional but recommended)
- **yq** YAML parser: `sudo dnf install yq`

---

## 📦 Installation

### 1. Copy scripts

```bash
sudo mkdir -p /etc/backup-system
sudo cp backup.sh restore.sh /etc/backup-system/
sudo chmod +x /etc/backup-system/*.sh
```

### 2. Setup configuration

```bash
mkdir -p ~/.backup
cp config.yml ~/.backup/config-system.yml
nano ~/.backup/config-system.yml
```

### 3. Install dependencies

```bash
sudo dnf install yq rsync
```

---

## ⚙️ Configuration

### Default location

```
~/.backup/config-system.yml
```

### Configuration sections

```yaml
# Backup destination
backup:
  hdd_mount: /mnt/hdd1
  backup_root: /mnt/hdd1/backups

# Backup snapshots (versioning of backups)
snapshots:
  enabled: false
  directory: /mnt/hdd1/snapshots
  retention: 4

# Source snapshots sync (Timeshift/snapper)
source_snapshots:
  enabled: false           # Sync /.snapshots and /home/.snapshots
  max_per_subvolume: 10    # Limit per subvolume (prevents huge backups)

# Logging with rotation
logging:
  file: /var/log/backup-system.log
  max_size_mb: 50          # Rotate when exceeds this size
  retention: 5             # Keep 5 rotated files

# Exclusions per path
exclusions:
  system: [...]
  home: [...]
  code: [...]
```

### Source Snapshots Sync

By default, `/.snapshots` and `/home/.snapshots` (Timeshift/snapper snapshots) are **excluded** from backup to avoid backing up potentially 50+ snapshots per subvolume.

**To enable syncing**:

```yaml
source_snapshots:
  enabled: true
  max_per_subvolume: 10  # Only sync the 10 most recent
```

This will:
- Include snapshots in the backup
- Limit to the N most recent snapshots (newest first)
- Sync them to `$BACKUP_ROOT/root/.snapshots/` and `$BACKUP_ROOT/home/.snapshots/`

---

## 🚀 Usage

### Basic backup

```bash
sudo /etc/backup-system/backup.sh
```

### Options

```bash
# Custom config
sudo ./backup.sh -c /path/to/config.yml

# Dry run (test)
sudo ./backup.sh --dry-run

# With integrity check
sudo ./backup.sh --scrub

# With compression stats
sudo ./backup.sh --stats
```

### Automated backups (systemd)

```bash
# Create service
sudo nano /etc/systemd/system/backup-system.service
```

```ini
[Unit]
Description=System Backup
After=mnt-hdd1.mount

[Service]
Type=oneshot
ExecStart=/etc/backup-system/backup.sh
```

```bash
# Create timer
sudo nano /etc/systemd/system/backup-system.timer
```

```ini
[Unit]
Description=Daily Backup Timer

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now backup-system.timer
```

---

## 🔧 System Restoration

For system restoration from backup, see the **separate `restore-system/` directory**.

The restoration tools are kept separate because they:
- Run from a Live USB (before the system exists)
- Use their own configuration file
- Are meant to be copied to bootable media

**Quick start:**
1. Copy the entire `restore-system/` directory to your backup HDD or Live USB
2. Boot from Fedora Live USB
3. See `restore-system/README.md` for detailed instructions

---

## 🐛 Troubleshooting

### Configuration validation errors

Both scripts validate the configuration at startup. Common errors:

```
✗ snapshots.enabled must be 'true' or 'false' (got: 'yes')
✗ logging.max_size_mb must be a number (got: 'fifty')
✗ backup.hdd_mount must be an absolute path starting with /
```

**Fix**: Edit your config file and use correct types:
- Booleans: `true` or `false` (not "yes"/"no", not quoted)
- Numbers: `50` (not "50", not "fifty")
- Paths: `/mnt/hdd1` (absolute, starting with /)

### Log file too large

The script now includes **automatic log rotation**:
- Rotates when log exceeds `max_size_mb`
- Keeps `retention` number of old logs
- Configure in `logging` section

### "A backup is already running"

```bash
# Check if actually running
ps aux | grep backup.sh

# If not, remove stale lock
sudo rm /var/run/backup-system.lock
```

### Source snapshots too large

Reduce `max_per_subvolume` in config:

```yaml
source_snapshots:
  enabled: true
  max_per_subvolume: 5  # Only 5 most recent
```

Or disable entirely:

```yaml
source_snapshots:
  enabled: false
```

---

## 📁 Files

```
backup-system/
├── backup.sh          # Main backup script
├── config.yml         # Example backup configuration
└── README.md          # This file
```

**User configuration**: `~/.backup/config-system.yml`  
**Restoration tools**: See `../restore-system/` directory

---

**Version**: 3.2  
**Last Updated**: January 8, 2026
