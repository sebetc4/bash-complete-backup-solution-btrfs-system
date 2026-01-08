# BTRFS Backup Script with LUKS Support

Advanced backup script with LUKS encryption support, BTRFS compression and integrity verification.

## Files

- `backup-hdd-btrfs.sh` - Main BTRFS/LUKS backup script
- `backup-hdd-btrfs.yml` - Example configuration file
- `test-backup.sh` - Test wrapper script
- `test-btrfs-backup.sh` - Automated test suite
- `tests/` - Complete test environment
  - `source/` - Test source directory
  - `backup1/` - Backup drive 1 destination
  - `backup2/` - Backup drive 2 destination
  - `test-config.yml` - Test configuration
  - `README.md` - Test documentation

## Features

- ✅ Optional automatic mounting/unmounting of LUKS encrypted volumes
- ✅ Manual mode by default (safer)
- ✅ BTRFS compression (zstd:9)
- ✅ Integrity verification with BTRFS scrub
- ✅ Compression statistics
- ✅ Disk space validation before backup
- ✅ Selective drive backup
- ✅ Subfolder support
- ✅ Safe cleanup on interruption

## Usage

### Production Mode (with LUKS)

```bash
./backup-hdd-btrfs.sh [-c <config>] [-d <drive>] [options]
```

### Test Mode (without LUKS)

```bash
./test-backup.sh [-d <drive>] [options]
```

### Options

- `-c, --config <file>` - Configuration file (default: `~/.backup/backup-hdd.yml`)
- `-d, --drive <drive>` - Drive to backup: 1, 2, both (default: both)
- `--no-delete` - Don't delete files in destination not in source
- `--no-progress` - Don't show progress during file transfer
- `--mount` - Enable automatic LUKS mounting/unmounting (requires sudo)
- `--scrub` - Run BTRFS scrub after backup (integrity check)
- `--compression-stats` - Show compression statistics for BTRFS filesystems
- `-h, --help` - Display help message

### Examples

**Production:**
```bash
# Manual mode (default - volumes already mounted)
./backup-hdd-btrfs.sh

# Automatic LUKS mode with integrity check
sudo ./backup-hdd-btrfs.sh --mount --scrub --compression-stats

# Backup to drive 1 only with automatic mounting
sudo ./backup-hdd-btrfs.sh --mount -d 1
```

**Testing:**
```bash
# Full test
./test-backup.sh

# Test drive 1 only
./test-backup.sh -d 1

# Test without deleting files
./test-backup.sh --no-delete
```

## Configuration

The YAML configuration file defines:
- Source directory
- LUKS devices (only required when using `--mount` option)
- Destination directories
- Folders and subfolders to backup

**Note:** In manual mode (default), LUKS devices are not used. The script assumes volumes are already mounted.

### Setup

1. Copy the example configuration:
```bash
mkdir -p ~/.backup
cp backup-hdd-btrfs.yml ~/.backup/backup-hdd.yml
```

2. Edit the configuration:
```bash
nano ~/.backup/backup-hdd.yml
```

### Example Configuration
```yaml
source:
  dir: /mnt/source

backup_drive_1:
  dir: /mnt/backup1
  luks_device: /dev/sda1
  compression_level: 9  # BTRFS zstd compression level (1-15, recommended: 9)
  folders:
    - path: Documents
      subfolders:
        - Work
    - path: Photos

backup_drive_2:
  dir: /mnt/backup2
  luks_device: /dev/sdb1
  compression_level: 9  # BTRFS zstd compression level (1-15, recommended: 9)
  folders:
    - path: Documents
    - path: Music
    - path: Videos
```

**Configuration options:**
- `luks_device`: LUKS encrypted partition (only required with `--mount` option)
- `compression_level`: BTRFS zstd compression level (1-15, default: 9)
  - Lower values (1-3): Faster, less compression
  - Higher values (9-15): Slower, better compression
  - Recommended: 9 (good balance)
- `folders`: Directories to backup (with optional subfolders)

## Requirements

```bash
sudo dnf install yq cryptsetup rsync
```

Optional for compression statistics:
```bash
sudo dnf install compsize
```

## Testing

See [tests/README.md](tests/README.md) for complete test documentation.

### Quick test setup

```bash
# Full test (all drives)
./test-backup.sh

# Incremental test (modify files then re-test)
echo "Modified" >> tests/source/Documents/Work/file1.txt
./test-backup.sh -d 1

# Verify results
tree tests/backup1
diff -r tests/source/Documents/Work tests/backup1/Documents/Work
```

## Project Structure

```
btrfs-backup/
├── backup-hdd-btrfs.sh    # Main script
├── test-backup.sh         # Test wrapper
├── tests/              # Test environment
│   ├── source/            # Test source files
│   ├── backup1/           # Test drive 1 destination
│   ├── backup2/           # Test drive 2 destination
│   ├── test-config.yml    # Test config
│   └── README.md          # Test documentation
└── README.md              # This file
```

## Security

- The script requests sudo permissions only in production mode (with LUKS mounting)
- LUKS passwords are requested securely via `cryptsetup`
- Volumes are automatically unmounted and locked after use
- Cleanup is performed even on interruption (Ctrl+C)

## Improvements over simple backup script

1. **Sudo validation** - Checks permissions at startup
2. **LUKS validation** - Verifies that devices are defined in config
3. **Disk space check** - Validates available space before starting
4. **Quoting fixes** - Uses arrays for rsync options
5. **Test mode** - Full support without sudo or LUKS
6. **Color display** - Fixed ANSI color code rendering
