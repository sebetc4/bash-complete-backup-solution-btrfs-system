#!/bin/bash
# ============================================================================
# BTRFS HDD Backup Script - Simple HDD Mirror
# ============================================================================
# Version: 3.0.0
# Date: 2026-01-08
# 
# Performs backup from HDD1 (active) to Backup1 (cold storage)
# with optional Btrfs snapshots for versioning.
#
# Features:
# - Simple 1:1 mirror backup (rsync)
# - Optional Btrfs snapshots with rotation
# - Compression statistics
# - Integrity check (scrub)
# - Dry run mode for testing
# - Log rotation with size limit
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

readonly DEFAULT_CONFIG_FILE="$REAL_HOME/.backup/config-hdd.yml"

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
${C_BOLD}BTRFS HDD Backup Script v${VERSION}${C_NC}

Simple HDD mirror backup with optional Btrfs snapshots.

${C_GREEN}Usage:${C_NC}
    $SCRIPT_NAME [options]

${C_GREEN}Options:${C_NC}
    -c, --config <file>    Config file (default: $DEFAULT_CONFIG_FILE)
    -n, --dry-run          Simulate without making changes
    -y, --yes              Skip confirmation prompts
    --snapshot             Create snapshot before backup (overrides config)
    --no-snapshot          Disable snapshots (overrides config)
    --scrub                Run integrity check after backup
    --stats                Show compression statistics
    -h, --help             Show this help

${C_GREEN}Examples:${C_NC}
    $SCRIPT_NAME                    # Standard backup
    $SCRIPT_NAME --snapshot         # Backup with snapshot
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
    
    BACKUP_PATH=$(parse_yaml "backup.path")
    BACKUP_LABEL=$(parse_yaml "backup.label")
    [ -z "$BACKUP_LABEL" ] && BACKUP_LABEL="Backup"
    
    # Directories
    DIRECTORIES=$(parse_yaml_array "directories" 2>/dev/null || echo "/")
    
    # Excludes
    EXCLUDES=$(parse_yaml_array "exclude" 2>/dev/null || echo "")
    
    # Snapshots
    SNAP_ENABLED=$(parse_yaml "snapshots.enabled")
    [ -z "$SNAP_ENABLED" ] && SNAP_ENABLED="false"
    
    SNAP_DIR=$(parse_yaml "snapshots.directory")
    [ -z "$SNAP_DIR" ] && SNAP_DIR=".snapshots"
    
    SNAP_KEEP=$(parse_yaml "snapshots.retention")
    [ -z "$SNAP_KEEP" ] && SNAP_KEEP=3
    
    SNAP_PREFIX=$(parse_yaml "snapshots.prefix")
    [ -z "$SNAP_PREFIX" ] && SNAP_PREFIX="backup"
    
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
    
    if [ -z "$BACKUP_PATH" ]; then
        errors+=("backup.path is required")
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
    validate_boolean "snapshots.enabled" "$SNAP_ENABLED"
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
    validate_integer "snapshots.retention" "$SNAP_KEEP"
    validate_integer "logging.max_size_mb" "$LOG_MAX_SIZE_MB"
    validate_integer "logging.retention" "$LOG_RETENTION"
    
    # Validate paths format
    validate_path_format "source.path" "$SOURCE_PATH"
    validate_path_format "backup.path" "$BACKUP_PATH"
    
    if [ -n "$LOG_FILE" ]; then
        validate_path_format "logging.file" "$LOG_FILE"
    fi
    
    # Logical validations
    if [ "$SNAP_ENABLED" = "true" ] && [ "$SNAP_KEEP" -lt 1 ] 2>/dev/null; then
        warnings+=("snapshots.retention should be at least 1 when snapshots are enabled")
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
        echo "Is HDD1 mounted?"
        exit 1
    fi
    
    # Check backup
    if [[ ! -d "$BACKUP_PATH" ]]; then
        log_error "Backup drive not found: $BACKUP_PATH"
        echo "Is Backup1 mounted? Use: sudo mount $BACKUP_PATH"
        exit 1
    fi
    
    # Prevent same path
    if [[ "$SOURCE_PATH" == "$BACKUP_PATH" ]]; then
        log_error "Source and backup cannot be the same path!"
        exit 1
    fi
}

# ============================================================================
# SNAPSHOT FUNCTIONS
# ============================================================================
create_snapshot() {
    local source="$1"
    local snap_dir="$source/$SNAP_DIR"
    local snap_name="${SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    local snap_path="$snap_dir/$snap_name"
    
    if ! is_btrfs "$source"; then
        log_warn "Source is not Btrfs, skipping snapshot"
        return 0
    fi
    
    log_step "Creating snapshot: $snap_name"
    
    # Create snapshot directory if needed
    mkdir -p "$snap_dir"
    
    # Create read-only snapshot
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would create snapshot: $snap_path"
    else
        if sudo btrfs subvolume snapshot -r "$source" "$snap_path"; then
            log_info "Snapshot created: $snap_name"
        else
            log_error "Failed to create snapshot"
            return 1
        fi
    fi
}

rotate_snapshots() {
    local source="$1"
    local snap_dir="$source/$SNAP_DIR"
    local keep="$SNAP_KEEP"
    
    if [[ ! -d "$snap_dir" ]]; then
        return 0
    fi
    
    # List snapshots sorted by date (oldest first)
    local snapshots=()
    while IFS= read -r snap; do
        [[ -n "$snap" ]] && snapshots+=("$snap")
    done < <(ls -1d "$snap_dir"/${SNAP_PREFIX}-* 2>/dev/null | sort)
    
    local count=${#snapshots[@]}
    local to_delete=$((count - keep))
    
    if [[ $to_delete -gt 0 ]]; then
        log_step "Rotating snapshots (keeping $keep, deleting $to_delete)"
        
        for ((i=0; i<to_delete; i++)); do
            local old_snap="${snapshots[$i]}"
            local snap_name=$(basename "$old_snap")
            
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "[DRY RUN] Would delete: $snap_name"
            else
                if sudo btrfs subvolume delete "$old_snap" &>/dev/null; then
                    log_info "Deleted old snapshot: $snap_name"
                else
                    log_warn "Failed to delete: $snap_name"
                fi
            fi
        done
    fi
}

list_snapshots() {
    local source="$1"
    local snap_dir="$source/$SNAP_DIR"
    
    if [[ ! -d "$snap_dir" ]]; then
        echo "No snapshots found"
        return
    fi
    
    echo "Snapshots in $snap_dir:"
    ls -1d "$snap_dir"/${SNAP_PREFIX}-* 2>/dev/null | while read -r snap; do
        local name=$(basename "$snap")
        local size=$(sudo btrfs subvolume show "$snap" 2>/dev/null | grep "Total" || echo "")
        echo "  - $name $size"
    done
}

# ============================================================================
# BACKUP FUNCTIONS
# ============================================================================
build_rsync_options() {
    local opts=()
    
    [[ "$RSYNC_ARCHIVE" == "true" ]] && opts+=("-a")
    [[ "$RSYNC_DELETE" == "true" ]] && opts+=("--delete")
    [[ "$RSYNC_PROGRESS" == "true" ]] && opts+=("--progress" "--info=progress2")
    [[ "$RSYNC_COMPRESS" == "true" ]] && opts+=("-z")
    [[ "$DRY_RUN" == "true" ]] && opts+=("--dry-run")
    
    # Add verbose
    opts+=("-v")
    
    # Add excludes
    for exclude in $EXCLUDES; do
        opts+=("--exclude=$exclude")
    done
    
    # Human readable
    opts+=("-h")
    
    echo "${opts[@]}"
}

check_disk_space() {
    local source="$1"
    local dest="$2"
    
    log_step "Checking disk space..."
    
    local source_used=$(df -k "$source" | tail -1 | awk '{print $3}')
    local dest_avail=$(df -k "$dest" | tail -1 | awk '{print $4}')
    local dest_total=$(df -k "$dest" | tail -1 | awk '{print $2}')
    
    echo "  Source used:      $(human_size $((source_used * 1024)))"
    echo "  Destination free: $(human_size $((dest_avail * 1024)))"
    echo "  Destination total:$(human_size $((dest_total * 1024)))"
    
    # Warning if less than 10% free after backup
    local after_backup=$((dest_total - source_used))
    if [[ $after_backup -lt $((dest_total / 10)) ]]; then
        log_warn "Destination will be more than 90% full after backup"
    else
        log_info "Sufficient space available"
    fi
}

perform_backup() {
    local source="$1"
    local dest="$2"
    
    log_section "Starting Backup"
    
    echo "Source:      $source ($SOURCE_LABEL)"
    echo "Destination: $dest ($BACKUP_LABEL)"
    echo ""
    
    local rsync_opts
    read -ra rsync_opts <<< "$(build_rsync_options)"
    
    # Handle directories
    if [[ "$DIRECTORIES" == "/" ]] || [[ -z "$DIRECTORIES" ]]; then
        # Backup entire drive
        log_step "Syncing entire drive..."
        rsync "${rsync_opts[@]}" "$source/" "$dest/"
    else
        # Backup specific directories
        for dir in $DIRECTORIES; do
            # Remove leading slash if present
            dir="${dir#/}"
            
            if [[ ! -d "$source/$dir" ]]; then
                log_warn "Directory not found: $source/$dir (skipping)"
                continue
            fi
            
            log_step "Syncing: $dir"
            mkdir -p "$dest/$dir"
            rsync "${rsync_opts[@]}" "$source/$dir/" "$dest/$dir/"
        done
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run completed (no changes made)"
    else
        log_info "Backup completed successfully"
    fi
}

# ============================================================================
# BTRFS FUNCTIONS
# ============================================================================
run_scrub() {
    local path="$1"
    local label="$2"
    
    if ! is_btrfs "$path"; then
        log_warn "$label is not Btrfs, skipping scrub"
        return 0
    fi
    
    log_step "Running integrity check on $label..."
    echo "This may take a while..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would run: btrfs scrub start -B $path"
    else
        if sudo btrfs scrub start -B "$path"; then
            log_info "Scrub completed on $label"
            sudo btrfs scrub status "$path"
        else
            log_error "Scrub failed on $label"
            return 1
        fi
    fi
}

show_compression_stats() {
    local path="$1"
    local label="$2"
    
    if ! is_btrfs "$path"; then
        return 0
    fi
    
    echo ""
    echo "Compression stats for $label:"
    echo "─────────────────────────────"
    
    if command -v compsize &>/dev/null; then
        sudo compsize "$path" 2>/dev/null || echo "Unable to get stats"
    else
        log_warn "Install 'compsize' for detailed stats: sudo dnf install compsize"
        sudo btrfs filesystem df "$path"
    fi
}

# ============================================================================
# DISPLAY FUNCTIONS
# ============================================================================
print_summary() {
    echo ""
    echo -e "${C_BOLD}╔════════════════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_BOLD}║              BACKUP CONFIGURATION                          ║${C_NC}"
    echo -e "${C_BOLD}╚════════════════════════════════════════════════════════════╝${C_NC}"
    echo ""
    echo -e "${C_CYAN}Source:${C_NC}      $SOURCE_PATH"
    echo -e "             $SOURCE_LABEL"
    is_mounted "$SOURCE_PATH" && echo -e "             $(get_disk_usage "$SOURCE_PATH")"
    echo ""
    echo -e "${C_CYAN}Destination:${C_NC} $BACKUP_PATH"
    echo -e "             $BACKUP_LABEL"
    is_mounted "$BACKUP_PATH" && echo -e "             $(get_disk_usage "$BACKUP_PATH")"
    echo ""
    echo -e "${C_CYAN}Directories:${C_NC} ${DIRECTORIES:-"/ (entire drive)"}"
    echo ""
    echo -e "${C_CYAN}Options:${C_NC}"
    echo "  Snapshots:    $([[ "$SNAP_ENABLED" == "true" ]] && echo "✓ Enabled (keep $SNAP_KEEP)" || echo "✗ Disabled")"
    echo "  Delete mode:  $([[ "$RSYNC_DELETE" == "true" ]] && echo "✓ Mirror (delete extra files)" || echo "✗ Additive only")"
    echo "  Dry run:      $([[ "$DRY_RUN" == "true" ]] && echo "✓ Yes (no changes)" || echo "✗ No")"
    echo "  Scrub:        $([[ "$BTRFS_SCRUB" == "true" ]] && echo "✓ After backup" || echo "✗ Skip")"
    echo "  Log file:     ${LOG_FILE:-"(console only)"}"
    echo ""
    
    if [[ "$RSYNC_DELETE" == "true" ]]; then
        echo -e "${C_YELLOW}⚠ WARNING: Files on backup not in source will be DELETED${C_NC}"
        echo ""
    fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    local config_file="$DEFAULT_CONFIG_FILE"
    local force_snapshot=""
    local force_scrub=false
    local force_stats=false
    local skip_confirm=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            --snapshot)
                force_snapshot="true"
                shift
                ;;
            --no-snapshot)
                force_snapshot="false"
                shift
                ;;
            --scrub)
                force_scrub=true
                shift
                ;;
            --stats)
                force_stats=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Check dependencies
    check_dependencies
    
    # Load config
    load_config "$config_file"
    
    # Apply overrides
    [[ -n "$force_snapshot" ]] && SNAP_ENABLED="$force_snapshot"
    [[ "$force_scrub" == "true" ]] && BTRFS_SCRUB="true"
    [[ "$force_stats" == "true" ]] && BTRFS_STATS="true"
    
    # Rotate logs if needed
    rotate_logs
    
    # Validate
    validate_paths
    
    # Print summary
    print_summary
    
    # Check disk space
    if [[ "$CHECK_SPACE" == "true" ]]; then
        check_disk_space "$SOURCE_PATH" "$BACKUP_PATH"
        echo ""
    fi
    
    # Confirm
    if [[ "$CONFIRM" == "true" ]] && [[ "$skip_confirm" != "true" ]]; then
        if ! confirm "Proceed with backup?"; then
            log_warn "Backup cancelled"
            exit 0
        fi
    fi
    
    # Create snapshot if enabled
    if [[ "$SNAP_ENABLED" == "true" ]]; then
        log_section "Creating Snapshot"
        create_snapshot "$SOURCE_PATH"
        rotate_snapshots "$SOURCE_PATH"
    fi
    
    # Perform backup
    perform_backup "$SOURCE_PATH" "$BACKUP_PATH"
    
    # Run scrub if enabled
    if [[ "$BTRFS_SCRUB" == "true" ]]; then
        log_section "Integrity Check"
        run_scrub "$BACKUP_PATH" "$BACKUP_LABEL"
    fi
    
    # Show stats if enabled
    if [[ "$BTRFS_STATS" == "true" ]]; then
        log_section "Compression Statistics"
        show_compression_stats "$SOURCE_PATH" "$SOURCE_LABEL"
        show_compression_stats "$BACKUP_PATH" "$BACKUP_LABEL"
    fi
    
    # Final summary
    log_section "Backup Complete"
    echo "Source:      $(get_disk_usage "$SOURCE_PATH")"
    echo "Destination: $(get_disk_usage "$BACKUP_PATH")"
    
    if [[ "$SNAP_ENABLED" == "true" ]]; then
        echo ""
        list_snapshots "$SOURCE_PATH"
    fi
    
    echo ""
    log_info "All done!"
}

main "$@"
