# Test Environment for backup-hdd-btrfs.sh

This directory contains a complete test environment for the backup script.

## Structure

```
tests/
├── source/           # Source directory with test files
│   ├── Documents/
│   │   ├── Work/     # Contains 5 test files
│   │   └── Personal/ # Contains 3 test files
│   ├── Photos/
│   │   └── 2024/     # Contains 4 test photos
│   ├── Music/        # Contains 1 test file
│   └── Videos/       # Contains 1 test file
├── backup1/          # Destination for backup drive 1
├── backup2/          # Destination for backup drive 2
└── test-config.yml   # Test configuration file
```

## Configuration

The test configuration (`test-config.yml`) defines:

- **Backup Drive 1**: Backs up Documents/Work subfolder and Photos
- **Backup Drive 2**: Backs up all Documents, Music, and Videos

## How to Test

### 1. Run the test script (recommended)

```bash
cd /mnt/code/Bash/backup-hdd
./test-backup.sh
```

This wrapper script:
- Uses `--no-mount` to skip LUKS operations
- Automatically uses the test configuration
- Shows the test structure before running

### 2. Test specific drives

```bash
./test-backup.sh -d 1              # Test backup to drive 1 only
./test-backup.sh -d 2              # Test backup to drive 2 only
./test-backup.sh -d both           # Test backup to both drives
```

### 3. Test other options

```bash
./test-backup.sh --no-delete       # Don't delete files in destination
./test-backup.sh --no-progress     # Hide rsync progress
./test-backup.sh --scrub           # Run BTRFS scrub (if on BTRFS)
./test-backup.sh --compression-stats  # Show compression stats (if on BTRFS)
```

### 4. Run directly with the main script

```bash
./backup-hdd-btrfs.sh \
    --config tests/test-config.yml \
    --no-mount
```

## Verify Results

After running a backup, check the results:

```bash
# Compare source and backup
tree tests/source
tree tests/backup1
tree tests/backup2

# Or use diff
diff -r tests/source/Documents/Work tests/backup1/Documents/Work
diff -r tests/source tests/backup2
```

## Clean Up Test Environment

To reset the test environment:

```bash
# Remove backups only
rm -rf tests/backup1/* tests/backup2/*

# Remove everything and start fresh
rm -rf tests
```

## Testing Scenarios

### Scenario 1: Initial Backup
Run the test script to create the first backup.

### Scenario 2: Incremental Backup
1. Modify some files in `tests/source`
2. Run the test script again
3. Only changed files should be copied

### Scenario 3: File Deletion
1. Delete a file from source
2. Run with default settings (with --delete)
3. File should be removed from backup
4. Run with `--no-delete`
5. File should remain in backup

### Scenario 4: New Files
1. Add new files to source
2. Run the test script
3. New files should appear in backups

## Notes

- The test uses `/dev/null` as a dummy LUKS device
- `--no-mount` is required since we don't have actual LUKS drives
- The test environment uses regular directories, not encrypted volumes
- For real LUKS testing, you would need actual encrypted block devices
