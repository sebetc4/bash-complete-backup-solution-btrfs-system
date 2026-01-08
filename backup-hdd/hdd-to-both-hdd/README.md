# HDD Split Backup - Two Drive System

Backup different folders from a source drive to two separate backup drives.

---

## 📋 Overview

This script allows you to **split your backup across two drives** by selecting which folders go to which drive. This is useful for:

- **Separating critical data from media files** (Documents to Drive 1, Videos to Drive 2)
- **Splitting large backups** across multiple drives when one drive isn't large enough
- **Different backup frequencies** (critical data backed up more often to Drive 1)
- **Redundancy strategies** (important files to both drives, archives to Drive 2 only)

---

## ✨ Features

- **Selective folder backup** - Choose which folders go to which drive
- **Subfolder selection** - Backup only specific subfolders from large directories
- **Independent snapshots** - Optional BTRFS snapshots per drive with separate retention
- **Log rotation** - Automatic log file management
- **Dry-run mode** - Test before executing
- **Configuration validation** - Prevents errors from invalid configs
- **Drive selection** - Backup to drive 1, drive 2, or both at once

---

## 🚀 Quick Start

### Installation

```bash
cd /code/bash/backup
sudo ./install.sh
# Choose option 2 or 3 to install backup-hdd-both
```

### Configuration

Edit your config file:

```bash
nano ~/.backup/config-hdd-both.yml
```

**Basic example:**

```yaml
source:
  path: /mnt/hdd1
  label: HDD1

backup_drive_1:
  path: /mnt/backup1
  folders:
    - path: Documents
    - path: Photos

backup_drive_2:
  path: /mnt/backup2
  folders:
    - path: Music
    - path: Videos
```

### Usage

```bash
# Backup to both drives
sudo backup-hdd-both

# Backup to drive 1 only
sudo backup-hdd-both -d 1

# Backup to drive 2 only
sudo backup-hdd-both -d 2

# Dry run (test without changes)
sudo backup-hdd-both --dry-run
```

---

## ⚙️ Configuration

### Folder Selection

**Full folder backup:**

```yaml
folders:
  - path: Documents     # Backs up entire Documents folder
  - path: Photos        # Backs up entire Photos folder
```

**Selective subfolder backup:**

```yaml
folders:
  - path: Documents
    subfolders:
      - Work          # Only backs up Documents/Work
      - Projects      # Only backs up Documents/Projects
  
  - path: Photos
    subfolders:
      - 2024          # Only backs up Photos/2024
      - 2025          # Only backs up Photos/2025
```

### Complete Example

```yaml
source:
  path: /mnt/hdd1
  label: HDD1

# Drive 1: Critical data
backup_drive_1:
  path: /mnt/backup1
  label: Backup1 - Critical
  
  folders:
    # Selective subfolder backup
    - path: Documents
      subfolders:
        - Work
        - Projects
        - Finance
    
    # Recent photos only
    - path: Photos
      subfolders:
        - 2024
        - 2025
  
  snapshots:
    enabled: true
    directory: .snapshots
    retention: 5        # Keep 5 versions
    prefix: backup

# Drive 2: Media and archives
backup_drive_2:
  path: /mnt/backup2
  label: Backup2 - Media
  
  folders:
    # Full folders
    - path: Music
    - path: Videos
    - path: Downloads
    - path: Archives
  
  snapshots:
    enabled: false

# Global exclusions
exclude:
  - "*.tmp"
  - "*.cache"
  - ".Trash-*"

# Rsync options
rsync:
  delete: true
  progress: true
  archive: true

# Logging
logging:
  file: /var/log/backup-hdd-both.log
  max_size_mb: 50
  retention: 5

# Safety
safety:
  confirm_before_start: true
  dry_run: false
```

---

## 📊 Options

### Drive Selection

```bash
# Both drives (default)
sudo backup-hdd-both
sudo backup-hdd-both -d both

# Drive 1 only
sudo backup-hdd-both -d 1

# Drive 2 only
sudo backup-hdd-both -d 2
```

### Snapshot Control

```bash
# Force snapshot creation (overrides config)
sudo backup-hdd-both --snapshot

# Disable snapshots (overrides config)
sudo backup-hdd-both --no-snapshot
```

### Other Options

```bash
# Dry run (test mode)
sudo backup-hdd-both -n
sudo backup-hdd-both --dry-run

# Skip confirmation
sudo backup-hdd-both -y

# Run integrity check after backup
sudo backup-hdd-both --scrub

# Show compression statistics
sudo backup-hdd-both --stats

# Custom config file
sudo backup-hdd-both -c /path/to/config.yml
```

---

## 💡 Use Cases

### Case 1: Critical Data vs Media

**Scenario:** You want important documents on one drive and media on another.

```yaml
backup_drive_1:
  folders:
    - path: Documents
    - path: Projects
    - path: Finance

backup_drive_2:
  folders:
    - path: Music
    - path: Videos
    - path: Photos
```

### Case 2: Recent vs Archives

**Scenario:** Recent files to fast SSD, archives to slower HDD.

```yaml
backup_drive_1:  # Fast SSD
  folders:
    - path: Documents
      subfolders:
        - Current
    - path: Photos
      subfolders:
        - 2025

backup_drive_2:  # Large HDD
  folders:
    - path: Documents
      subfolders:
        - Archives
    - path: Photos
      subfolders:
        - 2020
        - 2021
        - 2022
```

### Case 3: Partial Redundancy

**Scenario:** Critical files to both drives, less important files to one drive only.

```yaml
backup_drive_1:
  folders:
    - path: Documents    # Critical - on both drives
    - path: Photos       # Also important

backup_drive_2:
  folders:
    - path: Documents    # Critical - on both drives
    - path: Music        # Less critical - only on drive 2
    - path: Downloads    # Less critical - only on drive 2
```

---

## 🔧 Maintenance

### Log Management

Logs are automatically rotated when they exceed `max_size_mb`:

```bash
# View current log
tail -f /var/log/backup-hdd-both.log

# View rotated logs
ls -lh /var/log/backup-hdd-both.log*
```

### Snapshot Management

Snapshots are automatically cleaned up based on `retention` setting:

```bash
# View snapshots (if BTRFS)
ls /mnt/backup1/.snapshots/
ls /mnt/backup2/.snapshots/

# Manual snapshot cleanup (if needed)
sudo btrfs subvolume delete /mnt/backup1/.snapshots/backup_20250101_120000
```

---

## 🐛 Troubleshooting

### Configuration Errors

```
✗ backup_drive_1.path is required
✗ rsync.delete must be 'true' or 'false' (got: 'yes')
```

**Solution:** Check your config file for correct types:
- Booleans: `true` or `false` (not quoted)
- Paths: `/mnt/backup1` (absolute, starting with /)

### Drive Not Found

```
✗ Backup drive 1 not found: /mnt/backup1
```

**Solution:**
```bash
# Check if drive is connected
lsblk

# Mount the drive
sudo mount /dev/sdX /mnt/backup1

# Verify
mountpoint /mnt/backup1
```

### No Folders Configured

```
⚠ No folders configured for drive 1, skipping
```

**Solution:** Check your `folders:` section in the config - make sure it's not empty.

---

## 📖 Advanced

### Combining with systemd

Create a timer for automatic backups:

```bash
sudo nano /etc/systemd/system/backup-hdd-both.timer
```

```ini
[Unit]
Description=HDD Split Backup Timer

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo nano /etc/systemd/system/backup-hdd-both.service
```

```ini
[Unit]
Description=HDD Split Backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-hdd-both -y
```

```bash
sudo systemctl enable --now backup-hdd-both.timer
```

---

## 📁 Files

```
hdd-to-both-hdd/
├── backup.sh          # Main backup script
├── config.yml         # Example configuration
└── README.md          # This file
```

**User configuration**: `~/.backup/config-hdd-both.yml`

---

**Version**: 1.0  
**Last Updated**: January 8, 2026

**Related:**
- Simple HDD mirror: `../hdd-to-hdd/README.md`
- System backup: `../../backup-system/README.md`
