#!/bin/bash

################################################################################
# Test wrapper for backup.sh
#
# Simulates backup with local test directories instead of mounted drives.
################################################################################

set -e

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR="$SCRIPT_DIR/tests"
readonly TEST_CONFIG="$TEST_DIR/test-config.yml"
readonly BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  HDD Mirror Backup - Test Mode${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Create test environment if needed
setup_test_env() {
    if [ -d "$TEST_DIR/source" ]; then
        echo -e "${GREEN}✓ Test environment exists${NC}"
        return
    fi

    echo -e "${YELLOW}Creating test environment...${NC}"
    mkdir -p "$TEST_DIR"/{source,backup}

    cd "$TEST_DIR/source"
    mkdir -p Documents/{Work,Personal} Photos/2024 Music Videos

    # Create test files
    for i in {1..5}; do
        echo "Work Document $i - $(date)" > "Documents/Work/file$i.txt"
    done

    for i in {1..3}; do
        echo "Personal note $i" > "Documents/Personal/note$i.txt"
    done

    for i in {1..4}; do
        dd if=/dev/urandom bs=1K count=10 2>/dev/null > "Photos/2024/photo$i.jpg"
    done

    echo "Sample audio" > "Music/song1.mp3"
    echo "Sample video" > "Videos/video1.mp4"

    echo -e "${GREEN}✓ Test environment created${NC}"
}

# Create test config
create_test_config() {
    cat > "$TEST_CONFIG" << EOF
# Test configuration - mirrors test/source to test/backup
source:
  path: $TEST_DIR/source
  label: "Test Source"

backup:
  path: $TEST_DIR/backup
  label: "Test Backup"

# Backup everything
directories:
  - /

# Test with snapshots disabled
snapshots:
  enabled: false
  directory: ".snapshots"
  keep: 2
  prefix: "test"

rsync:
  delete: true
  progress: false
  compress: false
EOF
    echo -e "${GREEN}✓ Test config created${NC}"
}

# Main
setup_test_env
create_test_config

echo ""
echo -e "${GREEN}Test Structure:${NC}"
tree -L 2 "$TEST_DIR/source" 2>/dev/null || find "$TEST_DIR/source" -type f | head -20
echo ""

echo -e "${GREEN}Running backup with test config...${NC}"
echo ""

# Run backup with test config, skip confirmation
exec "$BACKUP_SCRIPT" \
    --config "$TEST_CONFIG" \
    -y \
    "$@"
