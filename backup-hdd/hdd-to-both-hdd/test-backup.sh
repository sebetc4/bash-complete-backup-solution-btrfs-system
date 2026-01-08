#!/bin/bash

################################################################################
# Test wrapper for backup-hdd-btrfs.sh
#
# This script simulates the backup process without requiring actual LUKS
# encrypted drives. It uses the --no-mount option to skip LUKS operations.
################################################################################

set -e

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_CONFIG="$SCRIPT_DIR/tests/test-config.yml"
readonly BACKUP_SCRIPT="$SCRIPT_DIR/backup-hdd-btrfs.sh"

# Colors
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_NC='\033[0m'

echo -e "${COLOR_BLUE}========================================${COLOR_NC}"
echo -e "${COLOR_BLUE}  Backup Script Test Environment${COLOR_NC}"
echo -e "${COLOR_BLUE}========================================${COLOR_NC}"
echo ""

# Check if test environment exists
if [ ! -d "$SCRIPT_DIR/tests/source" ]; then
    echo -e "${COLOR_YELLOW}Test environment not found. Creating it...${COLOR_NC}"
    mkdir -p "$SCRIPT_DIR/tests"/{source,backup1,backup2}

    # Create test structure
    cd "$SCRIPT_DIR/tests/source"
    mkdir -p Documents/{Work,Personal} Photos/2024 Music Videos

    # Create sample files
    for i in {1..5}; do
        echo "Document $i - $(date)" > "Documents/Work/file$i.txt"
    done

    for i in {1..3}; do
        echo "Personal note $i" > "Documents/Personal/note$i.txt"
    done

    for i in {1..4}; do
        echo "Photo $i" > "Photos/2024/photo$i.jpg"
    done

    echo "Song 1" > "Music/song1.mp3"
    echo "Video 1" > "Videos/video1.mp4"

    echo -e "${COLOR_GREEN}✓ Test environment created${COLOR_NC}"
    echo ""
fi

# Display test structure
echo -e "${COLOR_GREEN}Test Structure:${COLOR_NC}"
echo "Source: $SCRIPT_DIR/tests/source"
tree -L 2 "$SCRIPT_DIR/tests/source" 2>/dev/null || ls -lR "$SCRIPT_DIR/tests/source"
echo ""

echo -e "${COLOR_GREEN}Configuration:${COLOR_NC}"
cat "$TEST_CONFIG"
echo ""

echo -e "${COLOR_YELLOW}Note: This test runs with --no-mount (skips LUKS operations)${COLOR_NC}"
echo ""

# Run the backup script with test config
exec "$BACKUP_SCRIPT" \
    --config "$TEST_CONFIG" \
    --no-mount \
    "$@"
