#!/bin/bash
# ============================================================================
# BTRFS HDD Backup Script - Split Backup to Two Drives
# ============================================================================
# Version: 3.0.0
# Date: 2026-01-08
# 
# Performs backup from source HDD to two backup drives with different
# folder selections per drive.
#
# Features:
# - Split backup: different folders to different drives
# - Optional Btrfs snapshots with rotation
# - Compression statistics
# - Integrity check (scrub)
# - Dry run mode for testing
# - Log rotation with size limit
# - Configuration validation
# ============================================================================

set -o errexit
set -o pipefail
set -o nounset

# ============================================================================
# CONFIGURATION
# ============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"

# Get real user home directory (works with sudo)
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

readonly DEFAULT_CONFIG_FILE="$REAL_HOME/.backup/config-hdd-both.yml"

# Colors
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[0;31m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_MAGENTA='\033[0;35m'
readonly C_BOLD='\033[1m'
readonly C_NC='\033[0m'

# Global config variables
CONFIG_FILE=""
LOG_FILE=""
LOG_MAX_SIZE_MB=50
LOG_RETENTION=5

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
log_to_file() {
    if [ -n "$LOG_FILE" ]; then
        echo "$1" >> "$LOG_FILE"
    fi
}

log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"
    echo -e "${C_GREEN}✓${C_NC} $1"
    log_to_file "$msg"
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"
    echo -e "${C_YELLOW}⚠${C_NC} $1"
    log_to_file "$msg"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $1"
    echo -e "${C_RED}✗${C_NC} $1" >&2
    log_to_file "$msg"
}

log_section() {
    local msg="═══ $1 ═══"
    echo -e "\n${C_BLUE}═══ $1 ═══${C_NC}\n"
    log_to_file ""
    log_to_file "$msg"
    log_to_file ""
}

log_step() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] → $1"
    echo -e "${C_CYAN}→${C_NC} $1"
    log_to_file "$msg"
}

# ============================================================================
# LOG ROTATION
# ============================================================================
rotate_logs() {
    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        return 0
    fi
    
    # Get current log size in MB
    local log_size_kb
    log_size_kb=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1)
    local log_size_mb=$((log_size_kb / 1024))
    
    if [ "$log_size_mb" -ge "$LOG_MAX_SIZE_MB" ]; then
        log_info "Rotating log file (size: ${log_size_mb}MB, max: ${LOG_MAX_SIZE_MB}MB)"
        
        # Delete oldest if exceeds retention
        for ((i=LOG_RETENTION; i>=1; i--)); do
            if [ -f "${LOG_FILE}.${i}" ]; then
                if [ "$i" -eq "$LOG_RETENTION" ]; then
                    rm -f "${LOG_FILE}.${i}"
                else
                    mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
                fi
            fi
        done
        
        # Rotate current log
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        
        log_info "Log rotated. Kept last $LOG_RETENTION log files."
    fi
}

# ============================================================================
# USAGE
# ============================================================================
usage() {
    cat <<EOF
${C_BOLD}BTRFS HDD Split Backup Script v${VERSION}${C_NC}

Backup different folders from source to two separate backup drives.

${C_GREEN}Usage:${C_NC}
    $SCRIPT_NAME [options]

${C_GREEN}Options:${C_NC}
    -c, --config <file>    Config file (default: $DEFAULT_CONFIG_FILE)
    -d, --drive <num>      Backup to specific drive: 1, 2, or both (default: both)
    -n, --dry-run          Simulate without making changes
    -y, --yes              Skip confirmation prompts
    --snapshot             Create snapshot before backup (overrides config)
    --no-snapshot          Disable snapshots (overrides config)
    --scrub                Run integrity check after backup
    --stats                Show compression statistics
    -h, --help             Show this help

${C_GREEN}Examples:${C_NC}
    $SCRIPT_NAME                    # Backup to both drives
    $SCRIPT_NAME -d 1               # Backup to drive 1 only
    $SCRIPT_NAME -d 2               # Backup to drive 2 only
    $SCRIPT_NAME -n                 # Dry run (test)
    $SCRIPT_NAME -y --scrub         # No confirm + integrity check

EOF
    exit 0
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
check_dependencies() {
    local deps=("yq" "rsync")
    local missing=()
    
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        echo "Install with: sudo dnf install ${missing[*]}"
        exit 1
    fi
}

is_btrfs() {
    local path="$1"
    [[ "$(df -T "$path" 2>/dev/null | tail -1 | awk '{print $2}')" == "btrfs" ]]
}

is_mounted() {
    local path="$1"
    mountpoint -q "$path" 2>/dev/null
}

get_disk_usage() {
    local path="$1"
    df -h "$path" | tail -1 | awk '{print "Used: "$3" / "$2" ("$5")"}'
}

human_size() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"
}

confirm() {
    local prompt="${1:-Continue?}"
    local response
    read -rp "$prompt [y/N] " response
    [[ "$response" =~ ^[yY]$ ]]
}

# ============================================================================
# YAML PARSING
# ============================================================================
parse_yaml() {
    local key="$1"
    local value
    value=$(yq e ".${key}" "$CONFIG_FILE" 2>/dev/null)
    if [ "$value" = "null" ] || [ -z "$value" ]; then
        echo ""
    else
        echo "$value"
    fi
}

parse_yaml_array() {
    local key="$1"
    yq e ".${key}[]" "$CONFIG_FILE" 2>/dev/null | grep -v '^null$'
}

# ============================================================================
# CONFIG FUNCTIONS
# ============================================================================
load_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi
    
    CONFIG_FILE="$config_file"
    
    # Load all config values
    SOURCE_PATH=$(parse_yaml "source.path")
    SOURCE_LABEL=$(parse_yaml "source.label")
    [ -z "$SOURCE_LABEL" ] && SOURCE_LABEL="Source"
    
    # Drive 1
    BACKUP1_PATH=$(parse_yaml "backup_drive_1.path")
    BACKUP1_LABEL=$(parse_yaml "backup_drive_1.label")
    [ -z "$BACKUP1_LABEL" ] && BACKUP1_LABEL="Backup1"
    
    # Drive 2
    BACKUP2_PATH=$(parse_yaml "backup_drive_2.path")
    BACKUP2_LABEL=$(parse_yaml "backup_drive_2.label")
    [ -z "$BACKUP2_LABEL" ] && BACKUP2_LABEL="Backup2"
    
    # Excludes (global)
    EXCLUDES=$(parse_yaml_array "exclude" 2>/dev/null || echo "")
    
    # Snapshots (per drive)
    SNAP1_ENABLED=$(parse_yaml "backup_drive_1.snapshots.enabled")
    [ -z "$SNAP1_ENABLED" ] && SNAP1_ENABLED="false"
    
    SNAP1_DIR=$(parse_yaml "backup_drive_1.snapshots.directory")
    [ -z "$SNAP1_DIR" ] && SNAP1_DIR=".snapshots"
    
    SNAP1_KEEP=$(parse_yaml "backup_drive_1.snapshots.retention")
    [ -z "$SNAP1_KEEP" ] && SNAP1_KEEP=3
    
    SNAP1_PREFIX=$(parse_yaml "backup_drive_1.snapshots.prefix")
    [ -z "$SNAP1_PREFIX" ] && SNAP1_PREFIX="backup"
    
    SNAP2_ENABLED=$(parse_yaml "backup_drive_2.snapshots.enabled")
    [ -z "$SNAP2_ENABLED" ] && SNAP2_ENABLED="false"
    
    SNAP2_DIR=$(parse_yaml "backup_drive_2.snapshots.directory")
    [ -z "$SNAP2_DIR" ] && SNAP2_DIR=".snapshots"
    
    SNAP2_KEEP=$(parse_yaml "backup_drive_2.snapshots.retention")
    [ -z "$SNAP2_KEEP" ] && SNAP2_KEEP=3
    
    SNAP2_PREFIX=$(parse_yaml "backup_drive_2.snapshots.prefix")
    [ -z "$SNAP2_PREFIX" ] && SNAP2_PREFIX="backup"
    
    # Rsync
    RSYNC_DELETE=$(parse_yaml "rsync.delete")
    [ -z "$RSYNC_DELETE" ] && RSYNC_DELETE="true"
    
    RSYNC_PROGRESS=$(parse_yaml "rsync.progress")
    [ -z "$RSYNC_PROGRESS" ] && RSYNC_PROGRESS="true"
    
    RSYNC_COMPRESS=$(parse_yaml "rsync.compress")
    [ -z "$RSYNC_COMPRESS" ] && RSYNC_COMPRESS="false"
    
    RSYNC_ARCHIVE=$(parse_yaml "rsync.archive")
    [ -z "$RSYNC_ARCHIVE" ] && RSYNC_ARCHIVE="true"
    
    # Btrfs
    BTRFS_SCRUB=$(parse_yaml "btrfs.scrub_after_backup")
    [ -z "$BTRFS_SCRUB" ] && BTRFS_SCRUB="false"
    
    BTRFS_STATS=$(parse_yaml "btrfs.show_compression_stats")
    [ -z "$BTRFS_STATS" ] && BTRFS_STATS="false"
    
    # Logging
    LOG_FILE=$(parse_yaml "logging.file")
    LOG_MAX_SIZE_MB=$(parse_yaml "logging.max_size_mb")
    [ -z "$LOG_MAX_SIZE_MB" ] && LOG_MAX_SIZE_MB=50
    
    LOG_RETENTION=$(parse_yaml "logging.retention")
    [ -z "$LOG_RETENTION" ] && LOG_RETENTION=5
    
    # Safety
    CONFIRM=$(parse_yaml "safety.confirm_before_start")
    [ -z "$CONFIRM" ] && CONFIRM="true"
    
    CHECK_SPACE=$(parse_yaml "safety.check_disk_space")
    [ -z "$CHECK_SPACE" ] && CHECK_SPACE="true"
    
    DRY_RUN=$(parse_yaml "safety.dry_run")
    [ -z "$DRY_RUN" ] && DRY_RUN="false"
    
    # Validate configuration
    validate_config
}

# ============================================================================
# CONFIG VALIDATION
# ============================================================================
validate_config() {
    local errors=()
    local warnings=()
    
    # Required fields
    if [ -z "$SOURCE_PATH" ]; then
        errors+=("source.path is required")
    fi
    
    if [ -z "$BACKUP1_PATH" ]; then
        errors+=("backup_drive_1.path is required")
    fi
    
    if [ -z "$BACKUP2_PATH" ]; then
        errors+=("backup_drive_2.path is required")
    fi
    
    # Boolean validation helper
    validate_boolean() {
        local key="$1"
        local value="$2"
        if [ -n "$value" ] && [ "$value" != "true" ] && [ "$value" != "false" ]; then
            errors+=("$key must be 'true' or 'false' (got: '$value')")
        fi
    }
    
    # Integer validation helper
    validate_integer() {
        local key="$1"
        local value="$2"
        if [ -n "$value" ] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
            errors+=("$key must be a number (got: '$value')")
        fi
    }
    
    # Path validation helper
    validate_path_format() {
        local key="$1"
        local value="$2"
        if [ -n "$value" ] && [[ ! "$value" =~ ^/ ]]; then
            errors+=("$key must be an absolute path starting with / (got: '$value')")
        fi
    }
    
    # Validate booleans
    validate_boolean "backup_drive_1.snapshots.enabled" "$SNAP1_ENABLED"
    validate_boolean "backup_drive_2.snapshots.enabled" "$SNAP2_ENABLED"
    validate_boolean "rsync.delete" "$RSYNC_DELETE"
    validate_boolean "rsync.progress" "$RSYNC_PROGRESS"
    validate_boolean "rsync.compress" "$RSYNC_COMPRESS"
    validate_boolean "rsync.archive" "$RSYNC_ARCHIVE"
    validate_boolean "btrfs.scrub_after_backup" "$BTRFS_SCRUB"
    validate_boolean "btrfs.show_compression_stats" "$BTRFS_STATS"
    validate_boolean "safety.confirm_before_start" "$CONFIRM"
    validate_boolean "safety.check_disk_space" "$CHECK_SPACE"
    validate_boolean "safety.dry_run" "$DRY_RUN"
    
    # Validate integers
    validate_integer "backup_drive_1.snapshots.retention" "$SNAP1_KEEP"
    validate_integer "backup_drive_2.snapshots.retention" "$SNAP2_KEEP"
    validate_integer "logging.max_size_mb" "$LOG_MAX_SIZE_MB"
    validate_integer "logging.retention" "$LOG_RETENTION"
    
    # Validate paths format
    validate_path_format "source.path" "$SOURCE_PATH"
    validate_path_format "backup_drive_1.path" "$BACKUP1_PATH"
    validate_path_format "backup_drive_2.path" "$BACKUP2_PATH"
    
    if [ -n "$LOG_FILE" ]; then
        validate_path_format "logging.file" "$LOG_FILE"
    fi
    
    # Logical validations
    if [ "$SOURCE_PATH" = "$BACKUP1_PATH" ] || [ "$SOURCE_PATH" = "$BACKUP2_PATH" ]; then
        errors+=("source.path cannot be the same as backup paths")
    fi
    
    if [ "$BACKUP1_PATH" = "$BACKUP2_PATH" ]; then
        errors+=("backup_drive_1.path and backup_drive_2.path cannot be the same")
    fi
    
    # Show results
    if [ ${#errors[@]} -gt 0 ]; then
        echo ""
        echo -e "${C_RED}╔═══════════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_RED}║               CONFIGURATION ERRORS                            ║${C_NC}"
        echo -e "${C_RED}╚═══════════════════════════════════════════════════════════════╝${C_NC}"
        for err in "${errors[@]}"; do
            echo -e "${C_RED}  ✗ $err${C_NC}"
        done
        echo ""
        echo -e "${C_YELLOW}Config file: $CONFIG_FILE${C_NC}"
        echo ""
        exit 1
    fi
    
    if [ ${#warnings[@]} -gt 0 ]; then
        for w in "${warnings[@]}"; do
            log_warn "$w"
        done
    fi
}

validate_paths() {
    # Check source
    if [[ ! -d "$SOURCE_PATH" ]]; then
        log_error "Source not found: $SOURCE_PATH"
        echo "Is the source drive mounted?"
        exit 1
    fi
    
    # Check backups (based on which drive(s) selected)
    if [ "$TARGET_DRIVE" = "1" ] || [ "$TARGET_DRIVE" = "both" ]; then
        if [[ ! -d "$BACKUP1_PATH" ]]; then
            log_error "Backup drive 1 not found: $BACKUP1_PATH"
            echo "Is $BACKUP1_LABEL mounted? Use: sudo mount $BACKUP1_PATH"
            exit 1
        fi
    fi
    
    if [ "$TARGET_DRIVE" = "2" ] || [ "$TARGET_DRIVE" = "both" ]; then
        if [[ ! -d "$BACKUP2_PATH" ]]; then
            log_error "Backup drive 2 not found: $BACKUP2_PATH"
            echo "Is $BACKUP2_LABEL mounted? Use: sudo mount $BACKUP2_PATH"
            exit 1
        fi
    fi
}

# ============================================================================
# SNAPSHOT FUNCTIONS
# ============================================================================
create_snapshot() {
    local source="$1"
    local snap_dir="$2"
    local snap_prefix="$3"
    local snap_keep="$4"
    
    if ! is_btrfs "$source"; then
        log_warn "Not a BTRFS filesystem, skipping snapshot: $source"
        return 0
    fi
    
    local snap_path="$source/$snap_dir"
    mkdir -p "$snap_path"
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local snap_name="${snap_prefix}_${timestamp}"
    
    log_step "Creating snapshot: $snap_name"
    btrfs subvolume snapshot -r "$source" "$snap_path/$snap_name"
    
    # Cleanup old snapshots
    local snap_count=$(find "$snap_path" -maxdepth 1 -type d -name "${snap_prefix}_*" | wc -l)
    if [[ $snap_count -gt $snap_keep ]]; then
        log_step "Cleaning up old snapshots (keeping $snap_keep most recent)"
        find "$snap_path" -maxdepth 1 -type d -name "${snap_prefix}_*" -printf '%T@ %p\n' | \
            sort -n | head -n -$snap_keep | cut -d' ' -f2- | \
            while read -r old_snap; do
                log_step "Deleting: $(basename "$old_snap")"
                btrfs subvolume delete "$old_snap"
            done
    fi
}

# ============================================================================
# BACKUP FUNCTIONS
# ============================================================================
build_rsync_options() {
    local opts=()
    
    [[ "$RSYNC_ARCHIVE" == "true" ]] && opts+=("-a")
    [[ "$RSYNC_DELETE" == "true" ]] && opts+=("--delete")
    [[ "$RSYNC_PROGRESS" == "true" ]] && opts+=("--info=progress2")
    [[ "$RSYNC_COMPRESS" == "true" ]] && opts+=("-z")
    [[ "$DRY_RUN" == "true" ]] && opts+=("--dry-run")
    
    opts+=("-h" "--stats")
    
    echo "${opts[@]}"
}

build_exclude_args() {
    local exclude_args=()
    
    if [ -n "$EXCLUDES" ]; then
        while IFS= read -r pattern; do
            if [ -n "$pattern" ]; then
                exclude_args+=("--exclude=$pattern")
            fi
        done <<< "$EXCLUDES"
    fi
    
    echo "${exclude_args[@]}"
}

get_drive_folders() {
    local drive_num="$1"
    local folders_key="backup_drive_${drive_num}.folders"
    
    # Get folder count
    local count
    count=$(yq e "${folders_key} | length" "$CONFIG_FILE" 2>/dev/null)
    
    if [ "$count" = "null" ] || [ -z "$count" ] || [ "$count" -eq 0 ]; then
        echo ""
        return
    fi
    
    # Parse each folder
    for ((i=0; i<count; i++)); do
        local path
        path=$(yq e "${folders_key}[$i].path" "$CONFIG_FILE" 2>/dev/null)
        
        if [ "$path" != "null" ] && [ -n "$path" ]; then
            # Check if there are subfolders
            local subfolder_count
            subfolder_count=$(yq e "${folders_key}[$i].subfolders | length" "$CONFIG_FILE" 2>/dev/null)
            
            if [ "$subfolder_count" != "null" ] && [ -n "$subfolder_count" ] && [ "$subfolder_count" -gt 0 ]; then
                # Has subfolders
                for ((j=0; j<subfolder_count; j++)); do
                    local subfolder
                    subfolder=$(yq e "${folders_key}[$i].subfolders[$j]" "$CONFIG_FILE" 2>/dev/null)
                    if [ "$subfolder" != "null" ] && [ -n "$subfolder" ]; then
                        echo "${path}/${subfolder}"
                    fi
                done
            else
                # Entire folder
                echo "$path"
            fi
        fi
    done
}

backup_to_drive() {
    local drive_num="$1"
    local backup_path
    local backup_label
    local snap_enabled
    local snap_dir
    local snap_prefix
    local snap_keep
    
    if [ "$drive_num" = "1" ]; then
        backup_path="$BACKUP1_PATH"
        backup_label="$BACKUP1_LABEL"
        snap_enabled="$SNAP1_ENABLED"
        snap_dir="$SNAP1_DIR"
        snap_prefix="$SNAP1_PREFIX"
        snap_keep="$SNAP1_KEEP"
    else
        backup_path="$BACKUP2_PATH"
        backup_label="$BACKUP2_LABEL"
        snap_enabled="$SNAP2_ENABLED"
        snap_dir="$SNAP2_DIR"
        snap_prefix="$SNAP2_PREFIX"
        snap_keep="$SNAP2_KEEP"
    fi
    
    log_section "BACKUP TO DRIVE $drive_num: $backup_label"
    
    # Create snapshot if enabled
    if [[ "$snap_enabled" == "true" ]]; then
        create_snapshot "$backup_path" "$snap_dir" "$snap_prefix" "$snap_keep"
    fi
    
    # Get folders to backup for this drive
    local folders
    folders=$(get_drive_folders "$drive_num")
    
    if [ -z "$folders" ]; then
        log_warn "No folders configured for drive $drive_num, skipping"
        return
    fi
    
    # Build rsync options
    local rsync_opts
    rsync_opts=$(build_rsync_options)
    local exclude_args
    exclude_args=$(build_exclude_args)
    
    # Backup each folder
    while IFS= read -r folder; do
        local src="${SOURCE_PATH}/${folder}/"
        local dst="${backup_path}/${folder}/"
        
        if [[ ! -d "$src" ]]; then
            log_warn "Source folder not found, skipping: $src"
            continue
        fi
        
        log_step "Syncing: $folder"
        
        # Create destination directory if needed
        mkdir -p "$dst"
        
        # Execute rsync
        eval rsync $rsync_opts $exclude_args "$src" "$dst"
        
    done <<< "$folders"
    
    log_info "Drive $drive_num backup complete"
}

# ============================================================================
# STATISTICS FUNCTIONS
# ============================================================================
show_compression_stats() {
    local path="$1"
    local label="$2"
    
    if ! is_btrfs "$path"; then
        return
    fi
    
    log_section "COMPRESSION STATS: $label"
    
    sudo compsize "$path" 2>/dev/null || {
        log_warn "compsize not installed. Install with: sudo dnf install compsize"
    }
}

run_scrub() {
    local path="$1"
    local label="$2"
    
    if ! is_btrfs "$path"; then
        log_warn "Not BTRFS, skipping scrub: $label"
        return
    fi
    
    log_section "INTEGRITY CHECK (SCRUB): $label"
    
    log_step "Starting scrub (this may take a while)..."
    sudo btrfs scrub start -B "$path"
    
    log_step "Scrub status:"
    sudo btrfs scrub status "$path"
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

# Default values
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
TARGET_DRIVE="both"
OVERRIDE_SNAPSHOT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -d|--drive)
            TARGET_DRIVE="$2"
            if [[ ! "$TARGET_DRIVE" =~ ^(1|2|both)$ ]]; then
                log_error "Invalid drive: $TARGET_DRIVE (must be 1, 2, or both)"
                exit 1
            fi
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -y|--yes)
            CONFIRM="false"
            shift
            ;;
        --snapshot)
            OVERRIDE_SNAPSHOT="true"
            shift
            ;;
        --no-snapshot)
            OVERRIDE_SNAPSHOT="false"
            shift
            ;;
        --scrub)
            BTRFS_SCRUB="true"
            shift
            ;;
        --stats)
            BTRFS_STATS="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Check dependencies
check_dependencies

# Load configuration
load_config "$CONFIG_FILE"

# Apply snapshot override if specified
if [ -n "$OVERRIDE_SNAPSHOT" ]; then
    SNAP1_ENABLED="$OVERRIDE_SNAPSHOT"
    SNAP2_ENABLED="$OVERRIDE_SNAPSHOT"
fi

# Rotate logs before starting
rotate_logs

# Display banner
echo -e "${C_BOLD}${C_BLUE}"
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║        BTRFS HDD SPLIT BACKUP - TWO DRIVE SYSTEM            ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${C_NC}"

log_info "Version: $VERSION"
log_info "Config: $CONFIG_FILE"
log_info "Target: Drive $TARGET_DRIVE"
if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
fi
echo ""

# Validate paths
validate_paths

# Display info
log_section "CONFIGURATION"
log_info "Source: $SOURCE_PATH ($SOURCE_LABEL)"
if [ "$TARGET_DRIVE" = "1" ] || [ "$TARGET_DRIVE" = "both" ]; then
    log_info "Backup Drive 1: $BACKUP1_PATH ($BACKUP1_LABEL)"
fi
if [ "$TARGET_DRIVE" = "2" ] || [ "$TARGET_DRIVE" = "both" ]; then
    log_info "Backup Drive 2: $BACKUP2_PATH ($BACKUP2_LABEL)"
fi
echo ""

# Disk usage
log_section "DISK USAGE"
log_info "Source: $(get_disk_usage "$SOURCE_PATH")"
if [ "$TARGET_DRIVE" = "1" ] || [ "$TARGET_DRIVE" = "both" ]; then
    log_info "Drive 1: $(get_disk_usage "$BACKUP1_PATH")"
fi
if [ "$TARGET_DRIVE" = "2" ] || [ "$TARGET_DRIVE" = "both" ]; then
    log_info "Drive 2: $(get_disk_usage "$BACKUP2_PATH")"
fi
echo ""

# Confirmation
if [[ "$CONFIRM" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
    if ! confirm "Start backup to drive(s) $TARGET_DRIVE?"; then
        log_warn "Backup cancelled by user"
        exit 0
    fi
fi

# Execute backups
START_TIME=$(date +%s)

if [ "$TARGET_DRIVE" = "1" ] || [ "$TARGET_DRIVE" = "both" ]; then
    backup_to_drive 1
fi

if [ "$TARGET_DRIVE" = "2" ] || [ "$TARGET_DRIVE" = "both" ]; then
    backup_to_drive 2
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Statistics
if [[ "$BTRFS_STATS" == "true" ]]; then
    if [ "$TARGET_DRIVE" = "1" ] || [ "$TARGET_DRIVE" = "both" ]; then
        show_compression_stats "$BACKUP1_PATH" "$BACKUP1_LABEL"
    fi
    if [ "$TARGET_DRIVE" = "2" ] || [ "$TARGET_DRIVE" = "both" ]; then
        show_compression_stats "$BACKUP2_PATH" "$BACKUP2_LABEL"
    fi
fi

# Scrub
if [[ "$BTRFS_SCRUB" == "true" ]]; then
    if [ "$TARGET_DRIVE" = "1" ] || [ "$TARGET_DRIVE" = "both" ]; then
        run_scrub "$BACKUP1_PATH" "$BACKUP1_LABEL"
    fi
    if [ "$TARGET_DRIVE" = "2" ] || [ "$TARGET_DRIVE" = "both" ]; then
        run_scrub "$BACKUP2_PATH" "$BACKUP2_LABEL"
    fi
fi

# Final report
log_section "BACKUP COMPLETE"
log_info "Duration: ${DURATION}s ($(date -u -d @${DURATION} +"%H:%M:%S" 2>/dev/null || echo "${DURATION}s"))"
log_info "Target: Drive $TARGET_DRIVE"

echo ""
echo -e "${C_GREEN}${C_BOLD}"
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║                   ✓  BACKUP SUCCESSFUL  ✓                   ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${C_NC}"

exit 0
