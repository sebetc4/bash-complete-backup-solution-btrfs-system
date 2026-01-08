#!/bin/bash

################################################################################
# BTRFS Backup Script with LUKS Support
# 
# This script performs automated backups from a source drive to encrypted
# backup drives with BTRFS compression, integrity checks, and automatic
# mounting/unmounting of LUKS-encrypted volumes.
#
# Features:
# - Automatic LUKS unlock/lock
# - BTRFS compression (zstd:9)
# - Integrity checks with scrub
# - Compression statistics
# - Selective drive backup (1, 2, or both)
# - Safe cleanup on interruption
################################################################################

set -o errexit   # Exit on error
set -o pipefail  # Exit on pipe failure
set -o nounset   # Exit on undefined variable

################################################################################
# CONFIGURATION
################################################################################

readonly DEFAULT_CONFIG_FILE="$HOME/.backup/backup-hdd.yml"
readonly SCRIPT_NAME="$(basename "$0")"

# LUKS mapper names
readonly LUKS_MAPPER1="backup1_crypt"
readonly LUKS_MAPPER2="backup2_crypt"

# Colors for output
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m' # No Color

# Global state
declare -a MOUNTED_DRIVES=()
BACKUP_IN_PROGRESS=false

################################################################################
# FUNCTIONS - Display & UI
################################################################################

usage() {
    cat <<EOF
${COLOR_BLUE}BTRFS Backup Script with LUKS Support${COLOR_NC}

This script performs a backup of specified directories from the source drive
to encrypted backup drives with automatic LUKS mounting/unmounting.

${COLOR_GREEN}Usage:${COLOR_NC}
    $SCRIPT_NAME [-c <config>] [-d <drive>] [options]

${COLOR_GREEN}Options:${COLOR_NC}
    -c, --config <file>      Configuration file (default: $DEFAULT_CONFIG_FILE)
    -d, --drive <drive>      Drive to backup: 1, 2, both (default: both)
    --no-delete              Don't delete files in destination not in source
    --no-progress            Don't show progress during file transfer
    --mount                  Enable automatic LUKS mounting/unmounting
    --scrub                  Run BTRFS scrub after backup (integrity check)
    --compression-stats      Show compression statistics for BTRFS filesystems
    -h, --help               Display this help message

${COLOR_GREEN}Examples:${COLOR_NC}
    $SCRIPT_NAME                          # Backup to both drives (manual mode)
    $SCRIPT_NAME -d 1                     # Backup to drive 1 only
    $SCRIPT_NAME --scrub --compression-stats
    $SCRIPT_NAME --mount                  # Enable automatic LUKS mounting

${COLOR_GREEN}Drive Requirements:${COLOR_NC}
    - When using -d both: ${COLOR_YELLOW}Both drives must be available${COLOR_NC}
    - When using -d 1 or -d 2: Only specified drive must be available

EOF
    exit 0
}

log_info() {
    echo -e "${COLOR_GREEN}✓${COLOR_NC} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}⚠${COLOR_NC} $1"
}

log_error() {
    echo -e "${COLOR_RED}✗${COLOR_NC} $1" >&2
}

log_section() {
    echo ""
    echo -e "${COLOR_BLUE}=== $1 ===${COLOR_NC}"
    echo ""
}

log_subsection() {
    echo ""
    echo -e "${COLOR_BLUE}--- $1 ---${COLOR_NC}"
}

################################################################################
# FUNCTIONS - Validation
################################################################################

check_dependencies() {
    local missing_deps=()

    if ! command -v yq &> /dev/null; then
        missing_deps+=("yq")
    fi

    if ! command -v cryptsetup &> /dev/null; then
        missing_deps+=("cryptsetup")
    fi

    if ! command -v rsync &> /dev/null; then
        missing_deps+=("rsync")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Install with: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

check_sudo_access() {
    if ! sudo -n true 2>/dev/null; then
        log_warn "This script requires sudo privileges"
        echo "Checking sudo access..."
        if ! sudo true; then
            log_error "Failed to obtain sudo privileges"
            exit 1
        fi
        log_info "Sudo access granted"
    fi
}

validate_config_file() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi
    
    if [ ! -r "$config_file" ]; then
        log_error "Configuration file not readable: $config_file"
        exit 1
    fi
}

validate_drive_option() {
    local drive="$1"
    
    if [[ ! "$drive" =~ ^(1|2|both)$ ]]; then
        log_error "Invalid drive option: $drive"
        echo "Valid options: 1, 2, both"
        exit 1
    fi
}

validate_path() {
    local path="$1"
    local name="$2"
    local required="${3:-true}"

    if [ -z "$path" ]; then
        log_error "$name path is not defined in configuration"
        exit 1
    fi

    if [ "$required" = "true" ] && [ ! -d "$path" ]; then
        log_error "$name path does not exist: $path"
        exit 1
    fi
}

validate_luks_device() {
    local device="$1"
    local name="$2"
    local auto_mount="$3"

    # Skip validation if we're not mounting (test mode)
    if [ "$auto_mount" = "false" ]; then
        return 0
    fi

    if [ -z "$device" ] || [ "$device" = "null" ]; then
        log_error "$name LUKS device is not defined in configuration"
        echo "Please add 'luks_device' field in the configuration file"
        exit 1
    fi
}

check_disk_space() {
    local source_dir="$1"
    local dest_dir="$2"
    local drive_name="$3"
    local drive_number="$4"
    local config_file="$5"
    local no_delete="$6"

    if [ ! -d "$dest_dir" ]; then
        return 0
    fi

    # Calculate the size of folders that will be backed up to this specific drive
    local source_size=0
    local folder_count
    folder_count=$(yq eval ".backup_drive_${drive_number}.folders | length" "$config_file")

    for ((i = 0; i < folder_count; i++)); do
        local folder_path
        folder_path=$(yq eval ".backup_drive_${drive_number}.folders[$i].path" "$config_file")

        local subfolder_count
        subfolder_count=$(yq eval ".backup_drive_${drive_number}.folders[$i].subfolders | length" "$config_file")

        if [ "$subfolder_count" = "0" ] || [ "$subfolder_count" = "null" ]; then
            # Backup entire folder
            local folder_size
            folder_size=$(du -sk "$source_dir/$folder_path" 2>/dev/null | awk '{print $1}')
            source_size=$((source_size + folder_size))
        else
            # Backup only specific subfolders
            for ((j = 0; j < subfolder_count; j++)); do
                local subfolder
                subfolder=$(yq eval ".backup_drive_${drive_number}.folders[$i].subfolders[$j]" "$config_file")

                local subfolder_size
                subfolder_size=$(du -sk "$source_dir/$folder_path/$subfolder" 2>/dev/null | awk '{print $1}')
                source_size=$((source_size + subfolder_size))
            done
        fi
    done

    # Get available space on destination in KB
    local dest_available
    dest_available=$(df -k "$dest_dir" | tail -1 | awk '{print $4}')

    # Calculate required space based on delete mode
    local required_space
    if [ "$no_delete" = "true" ]; then
        # Without --delete: we need space for source + existing unique files
        # We can't predict exactly, so we calculate the delta (new/modified files)
        # For safety, we check if we have at least space for the source size
        # This is conservative but prevents running out of space during sync
        required_space=$((source_size + source_size / 10))
    else
        # With --delete (default): destination will mirror source
        # Maximum space needed is source size + 10% margin
        # Old files will be deleted, so we only need space for the final state
        required_space=$((source_size + source_size / 10))

        # Additional check: ensure the destination can hold the source
        # This is the actual maximum space we'll use after sync completes
        local dest_total
        dest_total=$(df -k "$dest_dir" | tail -1 | awk '{print $2}')

        if [ "$dest_total" -lt "$required_space" ]; then
            log_error "$drive_name: Destination filesystem too small"
            echo "  Source size: ~$(numfmt --to=iec-i --suffix=B $((source_size * 1024)) 2>/dev/null || echo "${source_size}KB")"
            echo "  Destination total: $(numfmt --to=iec-i --suffix=B $((dest_total * 1024)) 2>/dev/null || echo "${dest_total}KB")"
            return 1
        fi

        # In delete mode, we only need to check if destination filesystem is large enough
        # Available space is less relevant since files will be deleted during sync
        log_info "$drive_name: Sufficient disk space available"
        echo "  Source size: ~$(numfmt --to=iec-i --suffix=B $((source_size * 1024)) 2>/dev/null || echo "${source_size}KB")"
        echo "  Destination total: $(numfmt --to=iec-i --suffix=B $((dest_total * 1024)) 2>/dev/null || echo "${dest_total}KB")"
        echo "  Destination available: $(numfmt --to=iec-i --suffix=B $((dest_available * 1024)) 2>/dev/null || echo "${dest_available}KB")"
        return 0
    fi

    # For --no-delete mode: check available space
    if [ "$dest_available" -lt "$required_space" ]; then
        log_error "$drive_name: Insufficient disk space"
        echo "  Required: ~$(numfmt --to=iec-i --suffix=B $((required_space * 1024)) 2>/dev/null || echo "${required_space}KB")"
        echo "  Available: $(numfmt --to=iec-i --suffix=B $((dest_available * 1024)) 2>/dev/null || echo "${dest_available}KB")"
        return 1
    else
        log_info "$drive_name: Sufficient disk space available"
        echo "  Required: ~$(numfmt --to=iec-i --suffix=B $((required_space * 1024)) 2>/dev/null || echo "${required_space}KB")"
        echo "  Available: $(numfmt --to=iec-i --suffix=B $((dest_available * 1024)) 2>/dev/null || echo "${dest_available}KB")"
        return 0
    fi
}

################################################################################
# FUNCTIONS - BTRFS Operations
################################################################################

is_btrfs() {
    local path="$1"
    df -T "$path" 2>/dev/null | tail -1 | awk '{print $2}' | grep -q "btrfs"
}

get_filesystem_type() {
    local path="$1"
    df -T "$path" 2>/dev/null | tail -1 | awk '{print $2}'
}

verify_btrfs_compression() {
    local path="$1"
    local name="$2"
    local expected_level="$3"

    if ! is_btrfs "$path"; then
        return 0
    fi

    # Get mount options to check compression
    local mount_opts
    mount_opts=$(mount | grep " $path " | sed 's/.*(\(.*\))/\1/')

    if echo "$mount_opts" | grep -q "compress=zstd:${expected_level}"; then
        log_info "$name: Mounted with correct compression (zstd:${expected_level})"
        return 0
    elif echo "$mount_opts" | grep -q "compress="; then
        local current_compress
        current_compress=$(echo "$mount_opts" | grep -o 'compress=[^,]*' || echo "unknown")
        log_warn "$name: Mounted with different compression: $current_compress (expected: zstd:${expected_level})"
        return 1
    else
        log_warn "$name: No compression detected (expected: zstd:${expected_level})"
        return 1
    fi
}

run_btrfs_scrub() {
    local path="$1"
    local name="$2"

    if ! is_btrfs "$path"; then
        log_warn "$name is not on BTRFS filesystem. Skipping scrub."
        return 0
    fi

    echo "Running BTRFS scrub on $name (this may take a while)..."
    if sudo btrfs scrub start -B "$path"; then
        log_info "Scrub completed successfully on $name"
        sudo btrfs scrub status "$path"
        return 0
    else
        log_error "Scrub failed or found errors on $name"
        sudo btrfs scrub status "$path"
        return 1
    fi
}

show_compression_stats() {
    local path="$1"
    local name="$2"
    
    if ! is_btrfs "$path"; then
        return 0
    fi
    
    echo ""
    echo "=== Compression statistics for $name ==="
    echo ""
    
    if command -v compsize &> /dev/null; then
        sudo compsize "$path"
    else
        log_warn "Install 'compsize' for detailed statistics: sudo dnf install compsize"
        echo ""
        echo "Basic filesystem usage:"
        sudo btrfs filesystem usage "$path"
    fi
    echo ""
}

################################################################################
# FUNCTIONS - LUKS Operations
################################################################################

mount_luks_drive() {
    local device="$1"
    local mapper_name="$2"
    local mount_point="$3"
    local label="$4"
    local compression_level="${5:-9}"  # Default to level 9 if not specified

    # Check if device exists
    if [ ! -b "$device" ]; then
        log_warn "$label: Device $device not found (drive not plugged in)"
        return 1
    fi

    # Unlock LUKS if not already unlocked
    if [ ! -b "/dev/mapper/$mapper_name" ]; then
        echo "🔓 Unlocking $label ($device)..."
        if ! sudo cryptsetup luksOpen "$device" "$mapper_name"; then
            log_error "Failed to unlock $label"
            return 1
        fi
    else
        log_info "$label already unlocked"
    fi

    # Create mount point if needed
    sudo mkdir -p "$mount_point"

    # Mount if not already mounted
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        echo "📁 Mounting $label with BTRFS compression (zstd:${compression_level})..."
        if sudo mount -o compress=zstd:${compression_level},noatime "/dev/mapper/$mapper_name" "$mount_point"; then
            log_info "$label mounted at $mount_point"
            MOUNTED_DRIVES+=("$mapper_name:$mount_point:$label")
            return 0
        else
            log_error "Failed to mount $label"
            sudo cryptsetup luksClose "$mapper_name" 2>/dev/null || true
            return 1
        fi
    else
        log_info "$label already mounted at $mount_point"
        # Verify compression level if already mounted
        if is_btrfs "$mount_point"; then
            local current_compress
            current_compress=$(sudo btrfs property get "$mount_point" compression 2>/dev/null || echo "")
            if [ -n "$current_compress" ] && [ "$current_compress" != "compress=zstd:${compression_level}" ]; then
                log_warn "$label: Mounted with different compression: $current_compress (expected: zstd:${compression_level})"
            fi
        fi
        return 0
    fi
}

unmount_luks_drive() {
    local mapper_name="$1"
    local mount_point="$2"
    local label="$3"
    
    local unmount_success=true
    
    # Unmount if mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        echo "📁 Unmounting $label..."
        if sudo umount "$mount_point"; then
            log_info "$label unmounted"
        else
            log_error "Failed to unmount $label"
            unmount_success=false
        fi
    fi
    
    # Lock LUKS if unlocked
    if [ -b "/dev/mapper/$mapper_name" ]; then
        echo "🔒 Locking $label..."
        if sudo cryptsetup luksClose "$mapper_name"; then
            log_info "$label locked"
        else
            log_error "Failed to lock $label"
            unmount_success=false
        fi
    fi
    
    [ "$unmount_success" = true ] && return 0 || return 1
}

################################################################################
# FUNCTIONS - Backup Operations
################################################################################

perform_backup() {
    local source_dir="$1"
    local backup_dir="$2"
    local drive_num="$3"
    local config_file="$4"
    local use_sudo="$5"
    shift 5
    local rsync_options=("$@")

    local SUDO_CMD=""
    if [ "$use_sudo" = "true" ]; then
        SUDO_CMD="sudo"
    fi
    
    local folder_count
    folder_count=$(yq e ".backup_drive_${drive_num}.folders | length" "$config_file")
    
    for ((i=0; i<folder_count; i++)); do
        local folder_path
        folder_path=$(yq e ".backup_drive_${drive_num}.folders[$i].path" "$config_file")
        
        if [ ! -d "$source_dir/$folder_path" ]; then
            log_warn "Source directory not found: $source_dir/$folder_path (skipping)"
            continue
        fi
        
        # Check if subfolders are specified
        if yq e ".backup_drive_${drive_num}.folders[$i].subfolders" "$config_file" &> /dev/null && \
           [ "$(yq e ".backup_drive_${drive_num}.folders[$i].subfolders | length" "$config_file")" -gt 0 ]; then
            
            # Backup specific subfolders
            local subfolder_count
            subfolder_count=$(yq e ".backup_drive_${drive_num}.folders[$i].subfolders | length" "$config_file")
            
            for ((j=0; j<subfolder_count; j++)); do
                local subfolder
                subfolder=$(yq e ".backup_drive_${drive_num}.folders[$i].subfolders[$j]" "$config_file")
                
                if [ ! -d "$source_dir/$folder_path/$subfolder" ]; then
                    log_warn "Source subfolder not found: $source_dir/$folder_path/$subfolder (skipping)"
                    continue
                fi
                
                $SUDO_CMD mkdir -p "$backup_dir/$folder_path"

                echo "→ Syncing: $folder_path/$subfolder"
                $SUDO_CMD rsync "${rsync_options[@]}" \
                    "$source_dir/$folder_path/$subfolder/" \
                    "$backup_dir/$folder_path/$subfolder/"
            done
        else
            # Backup entire folder
            echo "→ Syncing: $folder_path"
            $SUDO_CMD rsync "${rsync_options[@]}" \
                "$source_dir/$folder_path/" \
                "$backup_dir/$folder_path/"
        fi
    done
}

################################################################################
# FUNCTIONS - Display
################################################################################

print_drive_info() {
    local drive_name="$1"
    local drive_path="$2"
    local luks_device="$3"
    local config_file="$4"
    local drive_num="$5"
    
    echo "$drive_name:"
    echo "    Path: $drive_path"
    echo "    Device: $luks_device"
    
    local fs_type
    if [ -d "$drive_path" ]; then
        fs_type=$(get_filesystem_type "$drive_path")
        if is_btrfs "$drive_path"; then
            echo "    Filesystem: BTRFS ✓ (encrypted)"
        else
            echo "    Filesystem: $fs_type (encrypted)"
        fi
    else
        echo "    Filesystem: Not mounted"
    fi
    
    echo "    Directories to backup:"
    
    local folder_count
    folder_count=$(yq e ".backup_drive_${drive_num}.folders | length" "$config_file")
    
    for ((i=0; i<folder_count; i++)); do
        local folder_path
        folder_path=$(yq e ".backup_drive_${drive_num}.folders[$i].path" "$config_file")
        echo "        - $folder_path"
        
        if yq e ".backup_drive_${drive_num}.folders[$i].subfolders" "$config_file" &> /dev/null; then
            local subfolder_count
            subfolder_count=$(yq e ".backup_drive_${drive_num}.folders[$i].subfolders | length" "$config_file")
            for ((j=0; j<subfolder_count; j++)); do
                local subfolder
                subfolder=$(yq e ".backup_drive_${drive_num}.folders[$i].subfolders[$j]" "$config_file")
                echo "            - $subfolder"
            done
        fi
    done
    echo ""
}

print_configuration_summary() {
    local source_dir="$1"
    local backup_dir1="$2"
    local backup_dir2="$3"
    local luks_device1="$4"
    local luks_device2="$5"
    local drive="$6"
    local config_file="$7"
    local no_delete="$8"
    local run_scrub="$9"

    echo ""
    echo -e "${COLOR_BLUE}╔════════════════════════════════════════════════════════════════╗${COLOR_NC}"
    echo -e "${COLOR_BLUE}║           BACKUP CONFIGURATION SUMMARY                         ║${COLOR_NC}"
    echo -e "${COLOR_BLUE}╚════════════════════════════════════════════════════════════════╝${COLOR_NC}"
    echo ""
    echo -e "${COLOR_GREEN}Source Drive:${COLOR_NC}"
    echo "    Path: $source_dir"
    
    local fs_type
    fs_type=$(get_filesystem_type "$source_dir")
    if is_btrfs "$source_dir"; then
        echo "    Filesystem: BTRFS ✓"
    else
        echo "    Filesystem: $fs_type"
    fi
    echo ""
    
    if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
        echo -e "${COLOR_GREEN}Backup Drive 1:${COLOR_NC}"
        print_drive_info "Backup Drive 1" "$backup_dir1" "$luks_device1" "$config_file" "1"
    fi

    if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
        echo -e "${COLOR_GREEN}Backup Drive 2:${COLOR_NC}"
        print_drive_info "Backup Drive 2" "$backup_dir2" "$luks_device2" "$config_file" "2"
    fi
    
    if [ "$run_scrub" = true ]; then
        echo -e "${COLOR_YELLOW}BTRFS scrub will run after backup (integrity verification)${COLOR_NC}"
        echo ""
    fi
    
    if [ "$no_delete" = false ]; then
        echo -e "${COLOR_RED}⚠ WARNING:${COLOR_NC} Files in destination that don't exist in source will be ${COLOR_RED}DELETED${COLOR_NC}"
        echo ""
    fi
}

confirm_execution() {
    local prompt="${1:-Do you want to proceed?}"
    local response
    
    read -p "$prompt (Y/N) " response
    if [[ ! "$response" =~ ^[yY]$ ]]; then
        return 1
    fi
    return 0
}

################################################################################
# FUNCTIONS - Cleanup
################################################################################

cleanup() {
    local exit_code=$?
    
    echo ""
    
    if [ "$BACKUP_IN_PROGRESS" = true ]; then
        log_warn "Backup process interrupted"
        pkill -TERM rsync 2>/dev/null || true
    fi
    
    # Unmount drives that we mounted
    if [ ${#MOUNTED_DRIVES[@]} -gt 0 ]; then
        log_section "Cleaning up mounted drives"
        
        for drive_info in "${MOUNTED_DRIVES[@]}"; do
            IFS=':' read -r mapper mount_point label <<< "$drive_info"
            unmount_luks_drive "$mapper" "$mount_point" "$label" || true
        done
    fi
    
    exit $exit_code
}

################################################################################
# MAIN SCRIPT
################################################################################

main() {
    # Default values
    local config_file="$DEFAULT_CONFIG_FILE"
    local drive="both"
    local no_delete=false
    local no_progress=false
    local auto_mount=false
    local run_scrub=false
    local show_compression=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -d|--drive)
                drive="$2"
                shift 2
                ;;
            --no-delete)
                no_delete=true
                shift
                ;;
            --no-progress)
                no_progress=true
                shift
                ;;
            --mount)
                auto_mount=true
                shift
                ;;
            --scrub)
                run_scrub=true
                shift
                ;;
            --compression-stats)
                show_compression=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Set up signal handlers
    trap cleanup SIGINT SIGTERM EXIT

    # Validate inputs
    check_dependencies
    validate_config_file "$config_file"
    validate_drive_option "$drive"

    # Only check sudo if we're going to use it (when auto_mount is true)
    if [ "$auto_mount" = true ]; then
        check_sudo_access
    fi
    
    # Read configuration
    local source_dir backup_dir1 backup_dir2 luks_device1 luks_device2
    local compression_level1 compression_level2

    source_dir=$(yq e '.source.dir' "$config_file")
    backup_dir1=$(yq e '.backup_drive_1.dir' "$config_file")
    backup_dir2=$(yq e '.backup_drive_2.dir' "$config_file")
    luks_device1=$(yq e '.backup_drive_1.luks_device' "$config_file")
    luks_device2=$(yq e '.backup_drive_2.luks_device' "$config_file")

    # Read compression levels (default to 9 if not specified)
    compression_level1=$(yq e '.backup_drive_1.compression_level' "$config_file")
    compression_level2=$(yq e '.backup_drive_2.compression_level' "$config_file")
    [ "$compression_level1" = "null" ] && compression_level1=9
    [ "$compression_level2" = "null" ] && compression_level2=9
    
    # Validate source path
    validate_path "$source_dir" "Source drive"
    validate_path "$backup_dir1" "Backup drive 1" false
    validate_path "$backup_dir2" "Backup drive 2" false

    # Validate LUKS devices are defined in config (only if auto_mount is true)
    if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
        validate_luks_device "$luks_device1" "Backup drive 1" "$auto_mount"
    fi

    if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
        validate_luks_device "$luks_device2" "Backup drive 2" "$auto_mount"
    fi
    
    # Prevent backup to same location as source
    if [ "$source_dir" = "$backup_dir1" ] || [ "$source_dir" = "$backup_dir2" ]; then
        log_error "Backup directories cannot be the same as source directory"
        exit 1
    fi
    
    # Mount drives if auto_mount is enabled
    if [ "$auto_mount" = true ]; then
        log_section "Mounting Encrypted Backup Drives"
        
        local mount_failed=false
        
        if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
            if ! mount_luks_drive "$luks_device1" "$LUKS_MAPPER1" "$backup_dir1" "Backup Drive 1" "$compression_level1"; then
                mount_failed=true
                if [ "$drive" = "both" ]; then
                    log_error "Failed to mount Backup Drive 1 (required for 'both' mode)"
                else
                    log_error "Failed to mount Backup Drive 1"
                fi
            fi
        fi

        if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
            if ! mount_luks_drive "$luks_device2" "$LUKS_MAPPER2" "$backup_dir2" "Backup Drive 2" "$compression_level2"; then
                mount_failed=true
                if [ "$drive" = "both" ]; then
                    log_error "Failed to mount Backup Drive 2 (required for 'both' mode)"
                else
                    log_error "Failed to mount Backup Drive 2"
                fi
            fi
        fi
        
        # Strict check for 'both' mode
        if [ "$mount_failed" = true ]; then
            if [ "$drive" = "both" ]; then
                log_error "Cannot proceed: 'both' mode requires all drives to be available"
                exit 1
            elif [ "$drive" = "1" ] || [ "$drive" = "2" ]; then
                log_error "Cannot proceed: specified drive is not available"
                exit 1
            fi
        fi
    fi
    
    # Validate that backup directories exist (after mounting)
    if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
        if [ ! -d "$backup_dir1" ]; then
            log_error "Backup drive 1 is not mounted or directory doesn't exist: $backup_dir1"
            exit 1
        fi
    fi

    if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
        if [ ! -d "$backup_dir2" ]; then
            log_error "Backup drive 2 is not mounted or directory doesn't exist: $backup_dir2"
            exit 1
        fi
    fi

    # Verify BTRFS compression settings
    log_section "Verifying BTRFS Compression"

    if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
        verify_btrfs_compression "$backup_dir1" "Backup Drive 1" "$compression_level1"
    fi

    if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
        verify_btrfs_compression "$backup_dir2" "Backup Drive 2" "$compression_level2"
    fi

    echo ""

    # Display configuration
    print_configuration_summary "$source_dir" "$backup_dir1" "$backup_dir2" \
        "$luks_device1" "$luks_device2" "$drive" "$config_file" \
        "$no_delete" "$run_scrub"

    # Confirm configuration first
    echo ""
    if ! confirm_execution "Do you confirm the above configuration?"; then
        log_warn "Backup cancelled by user"
        exit 0
    fi

    # Ask if user wants to check disk space
    echo ""
    if confirm_execution "Do you want to check available disk space before backup?"; then
        log_section "Checking Disk Space"

        local space_check_failed=false

        if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
            if ! check_disk_space "$source_dir" "$backup_dir1" "Backup Drive 1" "1" "$config_file" "$no_delete"; then
                space_check_failed=true
            fi
        fi

        if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
            if ! check_disk_space "$source_dir" "$backup_dir2" "Backup Drive 2" "2" "$config_file" "$no_delete"; then
                space_check_failed=true
            fi
        fi

        if [ "$space_check_failed" = true ]; then
            log_error "Insufficient disk space on one or more backup drives"
            if ! confirm_execution "Do you want to proceed anyway?"; then
                log_warn "Backup cancelled due to insufficient disk space"
                exit 1
            fi
        fi
    else
        log_info "Skipping disk space check"
    fi
    
    # Prepare rsync options as array
    local rsync_options=("-a" "-v" "-z")
    [ "$no_delete" = false ] && rsync_options+=("--delete")
    [ "$no_progress" = false ] && rsync_options+=("--progress")

    # Determine if we need sudo (only when auto_mount is true, meaning we're working with LUKS)
    local use_sudo="$auto_mount"

    # Perform backup
    BACKUP_IN_PROGRESS=true
    log_section "Starting Backup"

    if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
        log_subsection "Backup to Drive 1"
        perform_backup "$source_dir" "$backup_dir1" "1" "$config_file" "$use_sudo" "${rsync_options[@]}"
    fi

    if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
        log_subsection "Backup to Drive 2"
        perform_backup "$source_dir" "$backup_dir2" "2" "$config_file" "$use_sudo" "${rsync_options[@]}"
    fi
    
    BACKUP_IN_PROGRESS=false
    echo ""
    log_info "Backup completed successfully"
    
    # Run BTRFS scrub if requested
    if [ "$run_scrub" = true ]; then
        log_section "Running BTRFS Integrity Check"
        
        run_btrfs_scrub "$source_dir" "Source drive"
        
        if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
            run_btrfs_scrub "$backup_dir1" "Backup drive 1"
        fi
        
        if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
            run_btrfs_scrub "$backup_dir2" "Backup drive 2"
        fi
    fi
    
    # Show compression statistics if requested
    if [ "$show_compression" = true ]; then
        log_section "Compression Statistics"
        
        show_compression_stats "$source_dir" "Source drive"
        
        if [ "$drive" = "1" ] || [ "$drive" = "both" ]; then
            show_compression_stats "$backup_dir1" "Backup drive 1"
        fi
        
        if [ "$drive" = "2" ] || [ "$drive" = "both" ]; then
            show_compression_stats "$backup_dir2" "Backup drive 2"
        fi
    fi
    
    # Unmount drives if auto_mount is enabled
    if [ "$auto_mount" = true ] && [ ${#MOUNTED_DRIVES[@]} -gt 0 ]; then
        log_section "Unmounting Encrypted Backup Drives"
        
        for drive_info in "${MOUNTED_DRIVES[@]}"; do
            IFS=':' read -r mapper mount_point label <<< "$drive_info"
            unmount_luks_drive "$mapper" "$mount_point" "$label"
        done
        
        echo ""
        log_info "All backup drives unmounted and locked"
        echo -e "${COLOR_GREEN}You can now safely unplug the drives.${COLOR_NC}"
    fi
}

# Execute main function
main "$@"