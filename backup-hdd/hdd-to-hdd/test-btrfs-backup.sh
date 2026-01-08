#!/bin/bash

################################################################################
# Automated Test Suite for HDD Mirror Backup Script
#
# Tests: initial backup, incremental, deletions, snapshots (mock), file counts
################################################################################

set -e

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR="$SCRIPT_DIR/tests"
readonly BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
readonly TEST_CONFIG="$TEST_DIR/test-config.yml"

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

################################################################################
# Helpers
################################################################################

log_info()  { echo -e "${GREEN}✓${NC} $1"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }
log_test()  { echo -e "${BLUE}▶${NC} $1"; }

assert_file_exists() {
    local file="$1" desc="${2:-File should exist}"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ -f "$file" ]; then
        log_info "$desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "$desc: NOT FOUND"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_file_not_exists() {
    local file="$1" desc="${2:-File should not exist}"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ ! -f "$file" ]; then
        log_info "$desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "$desc: EXISTS (should not)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_files_identical() {
    local file1="$1" file2="$2" desc="${3:-Files should match}"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if diff -q "$file1" "$file2" &>/dev/null; then
        log_info "$desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "$desc: FILES DIFFER"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_dir_exists() {
    local dir="$1" desc="${2:-Directory should exist}"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ -d "$dir" ]; then
        log_info "$desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "$desc: NOT FOUND"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

cleanup() {
    log_warn "Cleaning test environment..."
    rm -rf "$TEST_DIR/backup"/* 2>/dev/null || true
}

setup_test_env() {
    log_info "Setting up test environment..."

    mkdir -p "$TEST_DIR"/{source,backup}

    cd "$TEST_DIR/source"
    mkdir -p Documents/{Work,Personal} Photos/2024 Music Videos

    for i in {1..5}; do
        echo "Work Document $i - $(date +%s)" > "Documents/Work/file$i.txt"
    done

    for i in {1..3}; do
        echo "Personal note $i" > "Documents/Personal/note$i.txt"
    done

    for i in {1..4}; do
        dd if=/dev/urandom bs=1K count=10 2>/dev/null > "Photos/2024/photo$i.jpg"
    done

    echo "Sample audio" > "Music/song1.mp3"
    echo "Sample video" > "Videos/video1.mp4"

    # Create config
    cat > "$TEST_CONFIG" << EOF
source:
  path: $TEST_DIR/source
  label: "Test Source"

backup:
  path: $TEST_DIR/backup
  label: "Test Backup"

directories:
  - /

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
}

run_backup() {
    local extra_args="${1:-}"
    "$BACKUP_SCRIPT" --config "$TEST_CONFIG" -y $extra_args 2>&1 | \
        grep -v "^sending\|^sent\|^total size\|^\s*$" || true
}

################################################################################
# Tests
################################################################################

test_initial_backup() {
    log_test "TEST 1: Initial full backup"

    cleanup
    run_backup >/dev/null

    assert_dir_exists "$TEST_DIR/backup/Documents" "Documents backed up"
    assert_dir_exists "$TEST_DIR/backup/Photos" "Photos backed up"
    assert_dir_exists "$TEST_DIR/backup/Music" "Music backed up"
    assert_dir_exists "$TEST_DIR/backup/Videos" "Videos backed up"

    assert_file_exists "$TEST_DIR/backup/Documents/Work/file1.txt" "Work file1 exists"
    assert_file_exists "$TEST_DIR/backup/Documents/Personal/note1.txt" "Personal note1 exists"
    assert_file_exists "$TEST_DIR/backup/Music/song1.mp3" "Song exists"

    assert_files_identical \
        "$TEST_DIR/source/Documents/Work/file1.txt" \
        "$TEST_DIR/backup/Documents/Work/file1.txt" \
        "File content matches"

    echo ""
}

test_incremental_backup() {
    log_test "TEST 2: Incremental backup (modify files)"

    echo "Modified - $(date +%s)" > "$TEST_DIR/source/Documents/Work/file1.txt"
    echo "New photo content" > "$TEST_DIR/source/Photos/2024/photo1.jpg"

    run_backup >/dev/null

    assert_files_identical \
        "$TEST_DIR/source/Documents/Work/file1.txt" \
        "$TEST_DIR/backup/Documents/Work/file1.txt" \
        "Modified work file synced"

    assert_files_identical \
        "$TEST_DIR/source/Photos/2024/photo1.jpg" \
        "$TEST_DIR/backup/Photos/2024/photo1.jpg" \
        "Modified photo synced"

    echo ""
}

test_new_files() {
    log_test "TEST 3: New file addition"

    echo "New document" > "$TEST_DIR/source/Documents/newfile.txt"
    mkdir -p "$TEST_DIR/source/NewFolder"
    echo "New folder content" > "$TEST_DIR/source/NewFolder/content.txt"

    run_backup >/dev/null

    assert_file_exists "$TEST_DIR/backup/Documents/newfile.txt" "New file backed up"
    assert_dir_exists "$TEST_DIR/backup/NewFolder" "New folder backed up"
    assert_file_exists "$TEST_DIR/backup/NewFolder/content.txt" "New folder content backed up"

    echo ""
}

test_deletion_with_delete() {
    log_test "TEST 4: File deletion (mirror mode)"

    rm -f "$TEST_DIR/source/Documents/newfile.txt"
    rm -rf "$TEST_DIR/source/NewFolder"

    run_backup >/dev/null

    assert_file_not_exists "$TEST_DIR/backup/Documents/newfile.txt" "Deleted file removed from backup"
    assert_file_not_exists "$TEST_DIR/backup/NewFolder/content.txt" "Deleted folder removed from backup"

    echo ""
}

test_dry_run() {
    log_test "TEST 5: Dry run mode"

    echo "Should not be backed up" > "$TEST_DIR/source/Documents/drytest.txt"

    run_backup "-n" >/dev/null

    assert_file_not_exists "$TEST_DIR/backup/Documents/drytest.txt" "Dry run: file not created"

    # Cleanup
    rm -f "$TEST_DIR/source/Documents/drytest.txt"

    echo ""
}

test_file_counts() {
    log_test "TEST 6: File count verification"

    run_backup >/dev/null

    local source_count=$(find "$TEST_DIR/source" -type f | wc -l)
    local backup_count=$(find "$TEST_DIR/backup" -type f | wc -l)

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$source_count" -eq "$backup_count" ]; then
        log_info "File counts match: $source_count files"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "File count mismatch: Source=$source_count, Backup=$backup_count"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    echo ""
}

################################################################################
# Main
################################################################################

main() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  HDD Mirror Backup - Test Suite${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    if [ ! -f "$BACKUP_SCRIPT" ]; then
        log_error "Backup script not found: $BACKUP_SCRIPT"
        exit 1
    fi

    setup_test_env

    test_initial_backup
    test_incremental_backup
    test_new_files
    test_deletion_with_delete
    test_dry_run
    test_file_counts

    cleanup
    log_info "Test environment cleaned"

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Results${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Total:  $TESTS_TOTAL"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"

    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
        exit 1
    else
        echo "Failed: 0"
        echo ""
        log_info "All tests passed! ✨"
        exit 0
    fi
}

main "$@"
