# Test Environment

Test directory for the HDD mirror backup script.

## Structure

```
tests/
├── source/           # Test source files (auto-created)
│   ├── Documents/
│   │   ├── Work/
│   │   └── Personal/
│   ├── Photos/2024/
│   ├── Music/
│   └── Videos/
├── backup/           # Test backup destination
├── test-config.yml   # Test configuration (auto-generated)
└── README.md
```

## Running Tests

### Quick test

```bash
# From btrfs-backup directory
./test-backup.sh
```

### Full test suite

```bash
./test-btrfs-backup.sh
```

### Test with options

```bash
./test-backup.sh -n          # Dry run
./test-backup.sh --snapshot  # With snapshot
./test-backup.sh --stats     # Show stats
```

## Verify Results

```bash
# Compare
diff -r tests/source tests/backup

# Tree view
tree tests/
```

## Reset

```bash
rm -rf tests/source tests/backup
```
