# BTRFS HDD Backup Script - Simple HDD Mirror

Simple and efficient backup script for mirroring HDD1 to Backup1 with optional Btrfs snapshots.

## Overview

```
HDD1 (5TB active)  ───rsync───▶  Backup1 (5TB cold storage)
     │
     └── .snapshots/ (optional)
         ├── backup-20260108-120000
         ├── backup-20260101-120000
         └── backup-20251225-120000
```

## Files

- `backup.sh` - Main backup script
- `config.yml` - Configuration file (example)
- `README.md` - This file

## Features

- ✅ Simple 1:1 mirror backup (rsync)
- ✅ Optional Btrfs snapshots with automatic rotation
- ✅ Dry run mode for testing
- ✅ Log rotation with size limit
- ✅ Compression statistics
- ✅ Integrity verification (scrub)
- ✅ Configurable via YAML

## Quick Start

### 1. Setup configuration

```bash
# Copy config to home
mkdir -p ~/.backup
cp config.yml ~/.backup/config-hdd.yml

# Edit paths
nano ~/.backup/config-hdd.yml
```

### 2. Run backup

```bash
# Standard backup
./backup.sh

# With snapshot
./backup.sh --snapshot

# Dry run (test)
./backup.sh -n

# Skip confirmation
./backup.sh -y

# Full options
./backup.sh --snapshot --scrub --stats
```

## Configuration

### Default location

```
~/.backup/config-hdd.yml
```

### Basic configuration

```yaml
source:
  path: /media/hdd1
  label: "HDD1 (5TB)"

backup:
  path: /media/backup1
  label: "Backup1 (5TB)"

# Backup entire drive
directories:
  - /

# Or specific folders:
# directories:
#   - Documents
#   - Photos
#   - Games
```

### Snapshots (optional)

```yaml
snapshots:
  enabled: true
  directory: ".snapshots"
  retention: 3
  prefix: "backup"
```

### Logging with rotation

```yaml
logging:
  file: /var/log/backup-hdd.log  # Empty = console only
  max_size_mb: 50                 # Rotate at this size
  retention: 5                    # Keep 5 old logs
```

### Rsync options

```yaml
rsync:
  delete: true       # Mirror mode (delete extra files)
  progress: true     # Show progress
  compress: false    # Not needed for local backup
```

## Options

| Option | Description |
|--------|-------------|
| `-c, --config` | Custom config file |
| `-n, --dry-run` | Simulate without changes |
| `-y, --yes` | Skip confirmation |
| `--snapshot` | Force snapshot creation |
| `--no-snapshot` | Disable snapshots |
| `--scrub` | Run integrity check |
| `--stats` | Show compression stats |
| `-h, --help` | Show help |

## Examples

```bash
# Regular weekly backup
./backup.sh -y

# Monthly backup with snapshot and verification
./backup.sh --snapshot --scrub

# Test what would happen
./backup.sh -n

# Custom config
./backup.sh -c /path/to/other-config.yml
```

## Workflow recommandé

### Hebdomadaire (standard)
```bash
./backup.sh -y
```

### Mensuel (avec vérification)
```bash
./backup.sh --scrub --stats
```

### Avant grosse modification
```bash
./backup.sh --snapshot
```

## Snapshots

Les snapshots sont **désactivés par défaut** car :
- Ton système Linux a déjà Timeshift
- Ton code est versionné avec Git
- Économise de l'espace disque

**Quand les activer ?**
- Avant de supprimer beaucoup de fichiers
- Avant une réorganisation majeure
- Si tu veux un historique des backups

## Requirements

```bash
# Fedora
sudo dnf install yq rsync

# Pour les stats de compression
sudo dnf install compsize
```

## Structure des disques

```
/media/
├── hdd1/           # Source (5TB actif)
│   ├── Documents/
│   ├── Photos/
│   ├── Videos/
│   ├── Games/
│   └── .snapshots/ (optionnel)
│
└── backup1/        # Destination (5TB cold)
    ├── Documents/
    ├── Photos/
    ├── Videos/
    └── Games/
```

## Notes

- Les deux disques doivent être montés avant de lancer le script
- Le backup est un **miroir** : les fichiers supprimés de la source seront supprimés du backup
- Utilise `--no-delete` si tu veux garder les fichiers supprimés sur le backup

---

**Version**: 1.0.0  
**Last Updated**: January 8, 2026
