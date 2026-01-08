#!/bin/bash

################################################################################
# Test script for BTRFS backup with LUKS support
#
# This script tests the BTRFS backup functionality with automatic cleanup,
# verification, and reproducibility.
################################################################################

set -e

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR="$SCRIPT_DIR/tests"
readonly BACKUP_SCRIPT="$SCRIPT_DIR/backup-hdd-btrfs.sh"
readonly TEST_CONFIG="$TEST_DIR/test-config.yml"

# Colors
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo -e "${COLOR_GREEN}✓${COLOR_NC} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}⚠${COLOR_NC} $1"
}

log_error() {
    echo -e "${COLOR_RED}✗${COLOR_NC} $1" >&2
}

log_test() {
    echo -e "${COLOR_BLUE}▶${COLOR_NC} $1"
}

assert_file_exists() {
    local file="$1"
    local description="${2:-File should exist}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [ -f "$file" ]; then
        log_info "$description: $(basename "$file")"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$description: $(basename "$file") NOT FOUND"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    local description="${2:-File should not exist}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [ ! -f "$file" ]; then
        log_info "$description: $(basename "$file")"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$description: $(basename "$file") EXISTS (should not)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_files_identical() {
    local file1="$1"
    local file2="$2"
    local description="${3:-Files should be identical}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if diff -q "$file1" "$file2" &>/dev/null; then
        log_info "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$description: Files differ"
        echo "  Source: $file1"
        echo "  Backup: $file2"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local description="${2:-Directory should exist}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [ -d "$dir" ]; then
        log_info "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$description: $dir NOT FOUND"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

cleanup_backups() {
    log_warn "Cleaning up backup directories..."
    # Fix permissions before cleanup to avoid permission issues
    chmod -R u+w "$TEST_DIR/backup1" "$TEST_DIR/backup2" 2>/dev/null || true
    rm -rf "$TEST_DIR/backup1"/*
    rm -rf "$TEST_DIR/backup2"/*
}

setup_test_environment() {
    log_info "Setting up test environment..."

    mkdir -p "$TEST_DIR"/{source,backup1,backup2}

    # Create comprehensive test structure
    cd "$TEST_DIR/source"
    mkdir -p Documents/{Work,Personal} Photos/2024 Music Videos

    # Create test files with timestamps
    for i in {1..5}; do
        echo "Work Document $i - $(date +%s)" > "Documents/Work/file$i.txt"
    done

    for i in {1..3}; do
        echo "Personal note $i - $(date +%s)" > "Documents/Personal/note$i.txt"
    done

    for i in {1..4}; do
        echo "Photo $i metadata" > "Photos/2024/photo$i.jpg"
    done

    echo "Song 1 - Sample MP3" > "Music/song1.mp3"
    echo "Video 1 - Sample MP4" > "Videos/video1.mp4"

    # Add some larger test files
    dd if=/dev/urandom of="Documents/Work/largefile.bin" bs=1K count=100 2>/dev/null
    dd if=/dev/urandom of="Photos/2024/image.raw" bs=1K count=50 2>/dev/null
}

run_backup() {
    local drive="$1"
    local extra_args="${2:-}"

    # Answer: Y (confirm config), N (skip space check)
    "$BACKUP_SCRIPT" \
        --config "$TEST_CONFIG" \
        --no-progress \
        -d "$drive" \
        $extra_args \
        <<< $'Y\nN' 2>&1 | grep -v "^sending\|^sent\|^total size"
}

count_files() {
    local dir="$1"
    find "$dir" -type f 2>/dev/null | wc -l
}

################################################################################
# Test Functions
################################################################################

test_initial_backup_drive1() {
    log_test "TEST 1: Initial backup to Drive 1 (subfolder support)"

    cleanup_backups
    run_backup "1" >/dev/null

    # Drive 1 should have Documents/Work and Photos
    assert_dir_exists "$TEST_DIR/backup1/Documents/Work" "Drive 1: Documents/Work directory"
    assert_file_exists "$TEST_DIR/backup1/Documents/Work/file1.txt" "Drive 1: Work file1"
    assert_file_exists "$TEST_DIR/backup1/Documents/Work/file5.txt" "Drive 1: Work file5"
    assert_file_exists "$TEST_DIR/backup1/Documents/Work/largefile.bin" "Drive 1: Large file"

    # Should NOT have Personal subfolder
    assert_file_not_exists "$TEST_DIR/backup1/Documents/Personal/note1.txt" "Drive 1: Personal excluded"

    # Should have Photos
    assert_file_exists "$TEST_DIR/backup1/Photos/2024/photo1.jpg" "Drive 1: Photo 1"
    assert_file_exists "$TEST_DIR/backup1/Photos/2024/image.raw" "Drive 1: Raw image"

    # Verify file contents
    assert_files_identical \
        "$TEST_DIR/source/Documents/Work/file1.txt" \
        "$TEST_DIR/backup1/Documents/Work/file1.txt" \
        "Drive 1: File content matches"

    echo ""
}

test_initial_backup_drive2() {
    log_test "TEST 2: Initial backup to Drive 2 (full directory support)"

    run_backup "2" >/dev/null

    # Drive 2 should have full Documents, Music, and Videos
    assert_file_exists "$TEST_DIR/backup2/Documents/Work/file1.txt" "Drive 2: Work files"
    assert_file_exists "$TEST_DIR/backup2/Documents/Personal/note1.txt" "Drive 2: Personal files"
    assert_file_exists "$TEST_DIR/backup2/Music/song1.mp3" "Drive 2: Music"
    assert_file_exists "$TEST_DIR/backup2/Videos/video1.mp4" "Drive 2: Videos"

    # Verify file contents
    assert_files_identical \
        "$TEST_DIR/source/Documents/Personal/note1.txt" \
        "$TEST_DIR/backup2/Documents/Personal/note1.txt" \
        "Drive 2: File content matches"

    echo ""
}

test_incremental_backup() {
    log_test "TEST 3: Incremental backup (modify existing files)"

    # Modify files
    echo "Modified work file - $(date +%s)" > "$TEST_DIR/source/Documents/Work/file1.txt"
    echo "Modified photo - $(date +%s)" > "$TEST_DIR/source/Photos/2024/photo1.jpg"

    run_backup "1" >/dev/null

    # Verify updates
    assert_files_identical \
        "$TEST_DIR/source/Documents/Work/file1.txt" \
        "$TEST_DIR/backup1/Documents/Work/file1.txt" \
        "Modified file synced"

    assert_files_identical \
        "$TEST_DIR/source/Photos/2024/photo1.jpg" \
        "$TEST_DIR/backup1/Photos/2024/photo1.jpg" \
        "Modified photo synced"

    echo ""
}

test_new_files() {
    log_test "TEST 4: New file addition"

    # Add new files
    echo "New work file" > "$TEST_DIR/source/Documents/Work/newfile.txt"
    echo "New photo" > "$TEST_DIR/source/Photos/2024/newphoto.jpg"

    run_backup "1" >/dev/null

    # Verify new files
    assert_file_exists "$TEST_DIR/backup1/Documents/Work/newfile.txt" "New work file backed up"
    assert_file_exists "$TEST_DIR/backup1/Photos/2024/newphoto.jpg" "New photo backed up"

    assert_files_identical \
        "$TEST_DIR/source/Documents/Work/newfile.txt" \
        "$TEST_DIR/backup1/Documents/Work/newfile.txt" \
        "New file content matches"

    echo ""
}

test_file_deletion_with_delete() {
    log_test "TEST 5: File deletion with --delete flag"

    # Remove files from source
    rm -f "$TEST_DIR/source/Documents/Work/newfile.txt"
    rm -f "$TEST_DIR/source/Photos/2024/newphoto.jpg"

    run_backup "1" >/dev/null

    # Verify files removed from backup
    assert_file_not_exists "$TEST_DIR/backup1/Documents/Work/newfile.txt" "Deleted file removed"
    assert_file_not_exists "$TEST_DIR/backup1/Photos/2024/newphoto.jpg" "Deleted photo removed"

    echo ""
}

test_file_deletion_without_delete() {
    log_test "TEST 6: File deletion without --delete flag"

    # Create and backup a temp file
    echo "Temporary file" > "$TEST_DIR/source/Music/tempfile.mp3"
    run_backup "2" >/dev/null
    assert_file_exists "$TEST_DIR/backup2/Music/tempfile.mp3" "Temp file backed up"

    # Remove from source
    rm -f "$TEST_DIR/source/Music/tempfile.mp3"

    # Backup without delete
    run_backup "2" "--no-delete" >/dev/null

    # Verify file still in backup
    assert_file_exists "$TEST_DIR/backup2/Music/tempfile.mp3" "File kept (--no-delete)"

    # Cleanup
    rm -f "$TEST_DIR/backup2/Music/tempfile.mp3"

    echo ""
}

test_both_drives() {
    log_test "TEST 7: Backup to both drives simultaneously"

    cleanup_backups

    # Backup to both drives
    run_backup "both" >/dev/null

    # Verify both drives have their respective content
    assert_file_exists "$TEST_DIR/backup1/Documents/Work/file1.txt" "Both: Drive 1 has Work"
    assert_file_exists "$TEST_DIR/backup2/Documents/Personal/note1.txt" "Both: Drive 2 has Personal"
    assert_file_exists "$TEST_DIR/backup2/Music/song1.mp3" "Both: Drive 2 has Music"

    echo ""
}

test_file_count_verification() {
    log_test "TEST 8: File count verification"

    # Count files in source Work folder
    local source_work_count=$(find "$TEST_DIR/source/Documents/Work" -type f | wc -l)
    local backup1_work_count=$(find "$TEST_DIR/backup1/Documents/Work" -type f 2>/dev/null | wc -l)

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$source_work_count" -eq "$backup1_work_count" ]; then
        log_info "File count matches: $source_work_count files"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "File count mismatch: Source=$source_work_count, Backup=$backup1_work_count"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    echo ""
}

################################################################################
# Main Test Suite
################################################################################

main() {
    echo ""
    echo -e "${COLOR_BLUE}========================================${COLOR_NC}"
    echo -e "${COLOR_BLUE}  BTRFS Backup - Test Suite${COLOR_NC}"
    echo -e "${COLOR_BLUE}========================================${COLOR_NC}"
    echo ""

    # Check if backup script exists
    if [ ! -f "$BACKUP_SCRIPT" ]; then
        log_error "Backup script not found: $BACKUP_SCRIPT"
        exit 1
    fi

    # Setup
    setup_test_environment

    # Run tests
    test_initial_backup_drive1
    test_initial_backup_drive2
    test_incremental_backup
    test_new_files
    test_file_deletion_with_delete
    test_file_deletion_without_delete
    test_both_drives
    test_file_count_verification

    # Final cleanup
    cleanup_backups
    log_info "Test environment cleaned up and ready for next run"

    # Summary
    echo ""
    echo -e "${COLOR_BLUE}========================================${COLOR_NC}"
    echo -e "${COLOR_BLUE}  Test Results${COLOR_NC}"
    echo -e "${COLOR_BLUE}========================================${COLOR_NC}"
    echo ""
    echo "Total tests:  $TESTS_TOTAL"
    echo -e "Passed:       ${COLOR_GREEN}$TESTS_PASSED${COLOR_NC}"

    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "Failed:       ${COLOR_RED}$TESTS_FAILED${COLOR_NC}"
        echo ""
        exit 1
    else
        echo -e "Failed:       $TESTS_FAILED"
        echo ""
        log_info "All tests passed! ✨"
        exit 0
    fi
}

# Execute main
main "$@"
