#!/bin/bash
# ============================================================================
# FULL SYSTEM BACKUP TO EXTERNAL HDD
# ============================================================================
# Version: 3.0
# Date: 2026-01-08
# 
# Features:
#   - Complete backup of /, /home, /code
#   - BTRFS structure backup (subvolumes)
#   - Additional disk documentation (/data)
#   - Versioned BTRFS snapshots
#   - YAML-based configuration
#   - Log rotation with size limit
#
# Usage:
#   sudo ./backup.sh [OPTIONS]
#
# Options:
#   --dry-run   Simulate backup without modifying files
#   --scrub     Run BTRFS scrub after backup
#   --stats     Display compression statistics
#   --help      Display this help
#
# ============================================================================

set -e  # Exit on error
set -o pipefail  # Propagate errors in pipes

# ============================================================================
# CONFIGURATION
# ============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

# Get real user home directory (works with sudo)
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

# Default configuration file path (can be overridden with -c option)
readonly DEFAULT_CONFIG_FILE="$REAL_HOME/.backup/config-system.yml"

# Lock file to prevent concurrent executions
readonly LOCK_FILE="/var/run/backup-system.lock"

# ============================================================================
# COLORS
# ============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    send_notification "❌ Backup failed" "$1" "critical"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

section() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}=========================================================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA} $1${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}=========================================================================${NC}" | tee -a "$LOG_FILE"
}

# ============================================================================
# DEPENDENCY CHECKS
# ============================================================================
check_dependencies() {
    local missing_deps=()
    
    if ! command -v yq &> /dev/null; then
        missing_deps+=("yq")
    fi
    
    if ! command -v rsync &> /dev/null; then
        missing_deps+=("rsync")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}[ERROR]${NC} Missing required dependencies: ${missing_deps[*]}"
        echo "Installation: sudo dnf install ${missing_deps[*]}"
        exit 1
    fi
}

# ============================================================================
# CONFIG PARSING (YAML)
# ============================================================================
parse_yaml() {
    local key="$1"
    local value
    value=$(yq e ".${key}" "$CONFIG_FILE" 2>/dev/null)
    # Handle null/empty values
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

load_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}[ERROR]${NC} Configuration file not found: $config_file"
        exit 1
    fi
    
    CONFIG_FILE="$config_file"
    
    # Load configuration
    BACKUP_MOUNT=$(parse_yaml "backup.hdd_mount")
    BACKUP_ROOT=$(parse_yaml "backup.backup_root")
    
    # Snapshots (destination)
    ENABLE_SNAPSHOTS=$(parse_yaml "snapshots.enabled")
    SNAPSHOT_DIR=$(parse_yaml "snapshots.directory")
    SNAPSHOT_RETENTION=$(parse_yaml "snapshots.retention")
    
    # Logging
    LOG_FILE=$(parse_yaml "logging.file")
    LOG_MAX_SIZE_MB=$(parse_yaml "logging.max_size_mb")
    LOG_RETENTION=$(parse_yaml "logging.retention")
    
    # Advanced options
    RSYNC_OPTIONS=$(parse_yaml "advanced.rsync_options")
    
    # Set defaults if empty
    [ -z "$ENABLE_SNAPSHOTS" ] && ENABLE_SNAPSHOTS="false"
    [ -z "$SNAPSHOT_RETENTION" ] && SNAPSHOT_RETENTION=4
    [ -z "$LOG_MAX_SIZE_MB" ] && LOG_MAX_SIZE_MB=50
    [ -z "$LOG_RETENTION" ] && LOG_RETENTION=5
    [ -z "$LOG_FILE" ] && LOG_FILE="/var/log/backup-system.log"
    
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
    if [ -z "$BACKUP_MOUNT" ]; then
        errors+=("backup.hdd_mount is required")
    fi
    
    if [ -z "$BACKUP_ROOT" ]; then
        errors+=("backup.backup_root is required")
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
    validate_boolean "snapshots.enabled" "$ENABLE_SNAPSHOTS"
    
    # Validate integers
    validate_integer "snapshots.retention" "$SNAPSHOT_RETENTION"
    validate_integer "logging.max_size_mb" "$LOG_MAX_SIZE_MB"
    validate_integer "logging.retention" "$LOG_RETENTION"
    
    # Validate paths format
    validate_path_format "backup.hdd_mount" "$BACKUP_MOUNT"
    validate_path_format "backup.backup_root" "$BACKUP_ROOT"
    validate_path_format "logging.file" "$LOG_FILE"
    
    if [ -n "$SNAPSHOT_DIR" ]; then
        validate_path_format "snapshots.directory" "$SNAPSHOT_DIR"
    fi
    
    # Logical validations
    if [ "$ENABLE_SNAPSHOTS" = "true" ] && [ -z "$SNAPSHOT_DIR" ]; then
        errors+=("snapshots.directory is required when snapshots.enabled is true")
    fi
    
    if [ "$SNAPSHOT_RETENTION" -lt 1 ] 2>/dev/null; then
        warnings+=("snapshots.retention should be at least 1")
    fi
    
    # Show results
    if [ ${#errors[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║               CONFIGURATION ERRORS                            ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
        for err in "${errors[@]}"; do
            echo -e "${RED}  ✗ $err${NC}"
        done
        echo ""
        echo -e "${YELLOW}Config file: $CONFIG_FILE${NC}"
        echo ""
        exit 1
    fi
    
    if [ ${#warnings[@]} -gt 0 ]; then
        for w in "${warnings[@]}"; do
            echo -e "${YELLOW}[WARNING]${NC} $w"
        done
    fi
}

# ============================================================================
# LOG ROTATION
# ============================================================================
rotate_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi
    
    # Get current log size in MB
    local log_size_kb
    log_size_kb=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1)
    local log_size_mb=$((log_size_kb / 1024))
    
    if [ "$log_size_mb" -ge "$LOG_MAX_SIZE_MB" ]; then
        info "Rotating log file (size: ${log_size_mb}MB, max: ${LOG_MAX_SIZE_MB}MB)"
        
        # Rotate existing logs
        local log_dir
        log_dir=$(dirname "$LOG_FILE")
        local log_name
        log_name=$(basename "$LOG_FILE")
        
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
        
        info "Log rotated. Kept last $LOG_RETENTION log files."
    fi
}

# ============================================================================
# RSYNC WRAPPER
# ============================================================================
# Rsync wrapper that handles exit code 24 (vanished files) as non-fatal
# Code 24 = some files vanished before transfer (normal for temp/cache files)
rsync_safe() {
    local exit_code=0
    rsync "$@" || exit_code=$?
    
    case $exit_code in
        0)
            # Success
            return 0
            ;;
        24)
            # Some files vanished - this is normal and expected
            warn "Some files vanished during transfer (rsync code 24) - this is normal for temp files"
            return 0
            ;;
        23)
            # Partial transfer due to error - often permission issues
            warn "Some files could not be transferred (rsync code 23) - check logs for details"
            return 0
            ;;
        *)
            # Real error
            error "rsync failed with exit code $exit_code"
            ;;
    esac
}

# ============================================================================
# NOTIFICATIONS
# ============================================================================
send_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"
    
    local notif_enabled
    notif_enabled=$(parse_yaml "notifications.enabled")
    
    if [ "$notif_enabled" != "true" ]; then
        return
    fi
    
    if command -v notify-send &> /dev/null; then
        for user in $(who | awk '{print $1}' | sort -u); do
            user_id=$(id -u "$user" 2>/dev/null) || continue
            DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_id}/bus" \
            sudo -u "$user" notify-send -u "$urgency" -i drive-harddisk "$title" "$message" 2>/dev/null || true
        done
    fi
}

# ============================================================================
# HELP
# ============================================================================
show_help() {
    cat << EOF
${CYAN}BTRFS System Backup v${VERSION}${NC}

Complete system backup to external HDD with BTRFS snapshots.

${GREEN}Usage:${NC}
    sudo $SCRIPT_NAME [OPTIONS]

${GREEN}Options:${NC}
    -c, --config <file>  Configuration file (default: $DEFAULT_CONFIG_FILE)
    -n, --dry-run        Simulate backup (test exclusions and paths)
    --scrub              Run BTRFS scrub after backup (check integrity)
    --stats              Display BTRFS compression statistics
    -h, --help           Display this help

${GREEN}Configuration:${NC}
    Default: $DEFAULT_CONFIG_FILE
    
    Modify this file to change:
    - Backup HDD path
    - Paths to backup
    - Exclusions
    - Snapshot retention
    - Log rotation settings

${GREEN}Examples:${NC}
    # Normal backup
    sudo $SCRIPT_NAME
    
    # Backup with integrity check
    sudo $SCRIPT_NAME --scrub
    
    # Backup with statistics
    sudo $SCRIPT_NAME --stats
    
    # Dry run to test
    sudo $SCRIPT_NAME --dry-run

EOF
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
ENABLE_SCRUB=false
ENABLE_STATS=false
DRY_RUN=false

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --scrub)
                ENABLE_SCRUB=true
                shift
                ;;
            --stats)
                ENABLE_STATS=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1
                
Use --help to see available options"
                ;;
        esac
    done
}

# ============================================================================
# MAIN BACKUP LOGIC
# ============================================================================
main() {
    # Parse command line arguments first (for --help without root)
    parse_arguments "$@"
    
    # Check dependencies
    check_dependencies
    
    # Load configuration
    load_config "$CONFIG_FILE"
    
    # Rotate logs if needed BEFORE starting
    rotate_logs
    
    # Dynamic variables
    local DATE
    DATE=$(date +%Y-%m-%d_%H-%M-%S)
    local START_TIME
    START_TIME=$(date +%s)
    local BTRFS_CONFIG="$BACKUP_ROOT/btrfs-structure"
    
    # Check that script is run as root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root (sudo)"
    fi
    
    # Acquire lock (prevents concurrent executions)
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        error "A backup is already running (lock: $LOCK_FILE)"
    fi
    trap 'flock -u 200; rm -f "$LOCK_FILE"' EXIT
    
    # ========================================================================
    # BACKUP START
    # ========================================================================
    if [ "$DRY_RUN" = true ]; then
        section "DRY-RUN MODE - BACKUP SIMULATION"
        warn "No files will be modified"
        RSYNC_OPTIONS="$RSYNC_OPTIONS --dry-run"
    else
        section "SYSTEM BACKUP START"
    fi
    
    info "Date: $(date '+%A %d %B %Y, %H:%M:%S')"
    info "Configuration: $CONFIG_FILE"
    info "Destination: $BACKUP_MOUNT"
    info ""
    
    # Check if HDD is mounted
    if ! mountpoint -q "$BACKUP_MOUNT"; then
        error "External HDD not mounted on $BACKUP_MOUNT

The HDD should be mounted automatically.

Checks:
1. Is the HDD plugged in?
2. Did LUKS decryption succeed?
3. Check: lsblk
4. Check mounts: mount | grep hdd1

If necessary, mount manually:
    sudo mount /mnt/hdd1"
    fi
    
    success "External HDD detected and mounted"
    
    # Check available space
    local AVAILABLE_SPACE
    AVAILABLE_SPACE=$(df -BG "$BACKUP_MOUNT" | tail -1 | awk '{print $4}' | tr -d 'G')
    info "Available space: ${AVAILABLE_SPACE}G"
    
    if [ "$AVAILABLE_SPACE" -lt 50 ]; then
        warn "⚠️  Low available space: ${AVAILABLE_SPACE}G"
        warn "Consider cleaning up or increasing retention"
    fi
    
    # Create backup structure
    mkdir -p "$BACKUP_ROOT"/{root,home,code}
    mkdir -p "$BTRFS_CONFIG"
    
    # ========================================================================
    # SAVE BTRFS STRUCTURE
    # ========================================================================
    section "SAVE BTRFS STRUCTURE"
    
    log "Saving subvolume list..."
    btrfs subvolume list / > "$BTRFS_CONFIG/subvolumes-list.txt" 2>&1 || warn "Cannot list subvolumes"
    
    log "Saving fstab..."
    cp /etc/fstab "$BTRFS_CONFIG/fstab.backup"
    
    log "Saving BTRFS attributes..."
    for path in / /home /code /vm /ai /data; do
        if [ -d "$path" ]; then
            attr_file="$BTRFS_CONFIG/$(echo $path | tr '/' '-' | sed 's/^-//')-attributes.txt"
            lsattr -d "$path" > "$attr_file" 2>/dev/null || true
        fi
    done
    
    log "Saving system UUIDs..."
    blkid > "$BTRFS_CONFIG/blkid.txt"
    
    log "Saving current mount options..."
    mount | grep btrfs > "$BTRFS_CONFIG/current-mounts.txt"
    
    # ========================================================================
    # ADDITIONAL DISKS DOCUMENTATION (/data)
    # ========================================================================
    log "Documenting additional disks..."
    
    cat > "$BTRFS_CONFIG/additional-disks-info.txt" << 'DISK_INFO_START'
========================================
ADDITIONAL DISKS (not on main system)
========================================
DISK_INFO_START
    
    echo "Generated on: $(date)" >> "$BTRFS_CONFIG/additional-disks-info.txt"
    echo "" >> "$BTRFS_CONFIG/additional-disks-info.txt"
    
    cat >> "$BTRFS_CONFIG/additional-disks-info.txt" << 'DISK_INFO_DATA'
These disks are NOT backed up by this script.
They require separate management.

========================================
/data DISK
========================================
DISK_INFO_DATA
    
    if mountpoint -q /data 2>/dev/null; then
        local DATA_DEV DATA_UUID DATA_SIZE DATA_USED
        DATA_DEV=$(findmnt -n -o SOURCE /data)
        DATA_UUID=$(findmnt -n -o UUID /data)
        DATA_SIZE=$(df -h /data | tail -1 | awk '{print $2}')
        DATA_USED=$(df -h /data | tail -1 | awk '{print $3}')
        
        cat >> "$BTRFS_CONFIG/additional-disks-info.txt" << DISK_MOUNTED
Status  : ✅ Mounted
Device  : $DATA_DEV
UUID    : $DATA_UUID
Size    : $DATA_SIZE
Used    : $DATA_USED

Fstab entry:
$(grep '/data' /etc/fstab 2>/dev/null || echo "None")

Mount options:
$(mount | grep '/data')

Content (top 10):
$(du -sh /data/* 2>/dev/null | sort -hr | head -10 || echo "Empty")

⚠️ RESTORATION:
1. Connect the same /data disk (UUID: $DATA_UUID)
2. The restored fstab will mount it automatically
3. Verify: sudo mount -a && df -h | grep data

If /data disk lost/changed:
1. New disk, format: sudo mkfs.btrfs -L data /dev/sdX
2. Get UUID: sudo blkid | grep btrfs
3. Update /etc/fstab with new UUID
4. Mount: sudo mount /data
5. Restore data if backup available

Manual backup of /data:
    sudo rsync -aAXHv --info=progress2 /data/ /mnt/hdd1/backups-data/

DISK_MOUNTED
    else
        cat >> "$BTRFS_CONFIG/additional-disks-info.txt" << 'DISK_NOT_MOUNTED'
Status : ❌ Not mounted or doesn't exist

If /data existed:
- Check connection: lsblk
- Check UUID: sudo blkid | grep btrfs
- Mount: sudo mount /data
DISK_NOT_MOUNTED
    fi
    
    echo "" >> "$BTRFS_CONFIG/additional-disks-info.txt"
    echo "========================================" >> "$BTRFS_CONFIG/additional-disks-info.txt"
    echo "ALL BTRFS DISKS" >> "$BTRFS_CONFIG/additional-disks-info.txt"
    echo "=========================================" >> "$BTRFS_CONFIG/additional-disks-info.txt"
    blkid | grep btrfs >> "$BTRFS_CONFIG/additional-disks-info.txt" 2>/dev/null || echo "No BTRFS disk detected" >> "$BTRFS_CONFIG/additional-disks-info.txt"
    
    # Create subvolume recreation script
    cat > "$BTRFS_CONFIG/recreate-subvolumes.sh" << 'RECREATE_SCRIPT'
#!/bin/bash
# BTRFS subvolume recreation script
# Automatically generated during backup

set -e

BTRFS_ROOT="/mnt/btrfs-root"

echo "========================================="
echo "BTRFS Subvolume Recreation"
echo "========================================="

if [ ! -d "$BTRFS_ROOT" ] || ! mountpoint -q "$BTRFS_ROOT"; then
    echo "ERROR: Mount the BTRFS root first:"
    echo "  sudo mount /dev/mapper/luks-XXXX -o subvolid=5 /mnt/btrfs-root"
    exit 1
fi

echo "Creating subvolumes..."
btrfs subvolume create "$BTRFS_ROOT/root"
btrfs subvolume create "$BTRFS_ROOT/home"
btrfs subvolume create "$BTRFS_ROOT/code"
btrfs subvolume create "$BTRFS_ROOT/vm"
btrfs subvolume create "$BTRFS_ROOT/ai"

echo "Applying nodatacow to /vm..."
chattr +C "$BTRFS_ROOT/vm"

echo ""
echo "✅ Subvolumes recreated!"
btrfs subvolume list "$BTRFS_ROOT"
RECREATE_SCRIPT
    
    chmod +x "$BTRFS_CONFIG/recreate-subvolumes.sh"
    
    # System info
    cat > "$BTRFS_CONFIG/system-info.txt" << SYSINFO
========================================
SYSTEM INFORMATION
========================================
Date     : $(date)
Hostname : $(hostname)
Kernel   : $(uname -r)
OS       : $(cat /etc/fedora-release 2>/dev/null || echo "Unknown")

DISKS:
$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE)

MEMORY:
$(free -h)

BTRFS SUBVOLUMES:
$(btrfs subvolume list / 2>/dev/null || echo "Error")
SYSINFO
    
    success "BTRFS structure saved"
    
    # ========================================================================
    # BUILD EXCLUSIONS
    # ========================================================================
    # Build exclusions from config
    EXCLUSIONS_HOME=()
    while IFS= read -r excl; do
        [ -z "$excl" ] && continue
        EXCLUSIONS_HOME+=("--exclude=$excl")
    done < <(parse_yaml_array "exclusions.home")
    
    EXCLUSIONS_SYSTEM=()
    while IFS= read -r excl; do
        [ -z "$excl" ] && continue
        EXCLUSIONS_SYSTEM+=("--exclude=$excl")
    done < <(parse_yaml_array "exclusions.system")
    
    EXCLUSIONS_CODE=()
    while IFS= read -r excl; do
        [ -z "$excl" ] && continue
        EXCLUSIONS_CODE+=("--exclude=$excl")
    done < <(parse_yaml_array "exclusions.code")
    
    # Always exclude .snapshots - syncing them via rsync would copy full data
    # (rsync doesn't understand BTRFS CoW, each snapshot = full copy)
    EXCLUSIONS_HOME+=("--exclude=.snapshots")
    EXCLUSIONS_SYSTEM+=("--exclude=.snapshots")
    
    # ========================================================================
    # BACKUP /home
    # ========================================================================
    section "BACKUP /home (USER DATA)"
    
    info "Source      : /home/"
    info "Destination : $BACKUP_ROOT/home/"
    info "Exclusions /home: ${#EXCLUSIONS_HOME[@]} rules"
    
    if [ "$DRY_RUN" = true ]; then
        info "Rules: ${EXCLUSIONS_HOME[*]}"
    fi
    
    rsync_safe $RSYNC_OPTIONS --delete "${EXCLUSIONS_HOME[@]}" /home/ "$BACKUP_ROOT/home/" 2>&1 | tee -a "$LOG_FILE"
    
    success "Backup /home completed"
    
    # ========================================================================
    # BACKUP / (SYSTEM)
    # ========================================================================
    section "BACKUP / (SYSTEM)"
    
    info "Source      : /"
    info "Destination : $BACKUP_ROOT/root/"
    info "Exclusions /: ${#EXCLUSIONS_SYSTEM[@]} rules"
    
    if [ "$DRY_RUN" = true ]; then
        info "Rules: ${EXCLUSIONS_SYSTEM[*]}"
    fi
    
    # Create read-only snapshot to guarantee consistency
    local SNAPSHOT_SOURCE="/"
    local TEMP_SNAPSHOT=""
    
    if [ "$DRY_RUN" = false ]; then
        TEMP_SNAPSHOT="/.backup-snapshot-$$"
        if btrfs subvolume snapshot -r / "$TEMP_SNAPSHOT" 2>/dev/null; then
            log "Temporary snapshot created for consistency: $TEMP_SNAPSHOT"
            SNAPSHOT_SOURCE="$TEMP_SNAPSHOT"
            trap 'btrfs subvolume delete "$TEMP_SNAPSHOT" 2>/dev/null || true; flock -u 200; rm -f "$LOCK_FILE"' EXIT
        else
            warn "Cannot create temporary snapshot, backup without consistency guarantee"
        fi
    fi
    
    rsync_safe $RSYNC_OPTIONS --delete "${EXCLUSIONS_SYSTEM[@]}" "$SNAPSHOT_SOURCE/" "$BACKUP_ROOT/root/" 2>&1 | tee -a "$LOG_FILE"
    
    # Delete temporary snapshot after successful backup
    if [ -n "$TEMP_SNAPSHOT" ] && [ -d "$TEMP_SNAPSHOT" ]; then
        log "Deleting temporary snapshot..."
        btrfs subvolume delete "$TEMP_SNAPSHOT" 2>/dev/null || warn "Failed to delete temporary snapshot"
        TEMP_SNAPSHOT=""
        # Reset trap without snapshot
        trap 'flock -u 200; rm -f "$LOCK_FILE"' EXIT
    fi
    
    success "Backup / completed"
    
    # ========================================================================
    # BACKUP /code
    # ========================================================================
    section "BACKUP /code (PROJECTS)"
    
    if [ -d "/code" ] && [ "$(ls -A /code 2>/dev/null)" ]; then
        info "Source      : /code/"
        info "Destination : $BACKUP_ROOT/code/"
        info "Exclusions /code: ${#EXCLUSIONS_CODE[@]} rules"
        
        if [ "$DRY_RUN" = true ]; then
            info "Rules: ${EXCLUSIONS_CODE[*]}"
        fi
        
        rsync_safe $RSYNC_OPTIONS --delete "${EXCLUSIONS_CODE[@]}" /code/ "$BACKUP_ROOT/code/" 2>&1 | tee -a "$LOG_FILE"
        
        success "Backup /code completed"
    else
        info "/code empty or doesn't exist, skipping"
    fi
    
    # ========================================================================
    # NOTE ABOUT /vm AND /ai
    # ========================================================================
    info ""
    info "NOTE: /vm and /ai are NOT backed up (too large)"
    info "Manual backup if necessary:"
    info "  sudo rsync -aAXHv /vm/ $BACKUP_ROOT/vm/"
    info "  sudo rsync -aAXHv /ai/ $BACKUP_ROOT/ai/"
    
    # ========================================================================
    # BTRFS BACKUP SNAPSHOT (Versioning)
    # ========================================================================
    section "BTRFS SNAPSHOT (VERSIONING)"
    
    if [ "$ENABLE_SNAPSHOTS" != "true" ]; then
        info "Backup snapshots disabled in configuration (snapshots.enabled = false)"
        info "To enable: set 'snapshots.enabled: true' in config"
        info "See README.md for setup instructions"
    else
        # Check if backup root is a BTRFS subvolume (required for snapshots)
        if btrfs subvolume show "$BACKUP_ROOT" &>/dev/null; then
            mkdir -p "$SNAPSHOT_DIR"
            
            log "Creating readonly snapshot: backup-$DATE"
            if btrfs subvolume snapshot -r "$BACKUP_ROOT" "$SNAPSHOT_DIR/backup-$DATE" 2>&1 | tee -a "$LOG_FILE"; then
                success "Snapshot created: backup-$DATE"
                
                # Clean old snapshots
                log "Cleaning snapshots (retention: $SNAPSHOT_RETENTION)"
                cd "$SNAPSHOT_DIR"
                local SNAPSHOT_COUNT
                SNAPSHOT_COUNT=$(ls -1d backup-* 2>/dev/null | wc -l)
                info "Current snapshots: $SNAPSHOT_COUNT"
                
                if [ "$SNAPSHOT_COUNT" -gt "$SNAPSHOT_RETENTION" ]; then
                    local TO_DELETE=$((SNAPSHOT_COUNT - SNAPSHOT_RETENTION))
                    log "Deleting $TO_DELETE old snapshot(s)..."
                    
                    ls -1td backup-* | tail -n "+$((SNAPSHOT_RETENTION + 1))" | while read -r old_snapshot; do
                        log "Deleting: $old_snapshot"
                        btrfs subvolume delete "$old_snapshot" 2>&1 | tee -a "$LOG_FILE"
                    done
                    
                    success "Cleanup completed"
                else
                    info "Retention OK, no cleanup necessary"
                fi
            else
                warn "Failed to create snapshot"
            fi
        else
            warn "$BACKUP_ROOT is not a BTRFS subvolume - cannot create snapshots"
            info ""
            info "To enable snapshots:"
            info "  1. Backup existing data: sudo mv $BACKUP_ROOT ${BACKUP_ROOT}-old"
            info "  2. Create subvolume: sudo btrfs subvolume create $BACKUP_ROOT"
            info "  3. Restore data: sudo rsync -aAXHv ${BACKUP_ROOT}-old/ $BACKUP_ROOT/"
            info "  4. Enable in config: set 'snapshots.enabled: true'"
            info "  See README.md for detailed instructions"
        fi
    fi
    
    # ========================================================================
    # OPTIONAL CHECKS
    # ========================================================================
    if [ "$ENABLE_SCRUB" = true ]; then
        section "BTRFS SCRUB (INTEGRITY CHECK)"
        
        warn "Scrub started, estimated duration: 10-30 minutes..."
        btrfs scrub start -B "$BACKUP_MOUNT" 2>&1 | tee -a "$LOG_FILE"
        btrfs scrub status "$BACKUP_MOUNT" | tee -a "$LOG_FILE"
        
        success "Scrub completed"
    fi
    
    if [ "$ENABLE_STATS" = true ] && command -v compsize &> /dev/null; then
        section "COMPRESSION STATISTICS"
        
        compsize "$BACKUP_ROOT" | tee -a "$LOG_FILE"
    fi
    
    # ========================================================================
    # FINAL REPORT
    # ========================================================================
    local END_TIME
    END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    local DURATION_MIN=$((DURATION / 60))
    local DURATION_SEC=$((DURATION % 60))
    
    section "BACKUP COMPLETED SUCCESSFULLY"
    
    # Disk space
    info "External HDD space:"
    df -h "$BACKUP_MOUNT" | tee -a "$LOG_FILE"
    
    # Backup sizes
    echo "" | tee -a "$LOG_FILE"
    info "Backup sizes:"
    du -sh "$BACKUP_ROOT"/{root,home,code} 2>/dev/null | tee -a "$LOG_FILE"
    
    # Snapshots
    echo "" | tee -a "$LOG_FILE"
    if [ "$ENABLE_SNAPSHOTS" = "true" ] && [ -d "$SNAPSHOT_DIR" ]; then
        local FINAL_SNAPSHOT_COUNT
        FINAL_SNAPSHOT_COUNT=$(ls -1d "$SNAPSHOT_DIR"/backup-* 2>/dev/null | wc -l)
        info "Available backup snapshots: $FINAL_SNAPSHOT_COUNT"
        ls -lh "$SNAPSHOT_DIR" 2>/dev/null | tail -n +2 | tee -a "$LOG_FILE"
    else
        info "Backup snapshots: disabled"
    fi
    
    # Duration
    echo "" | tee -a "$LOG_FILE"
    success "Total duration: ${DURATION_MIN}m ${DURATION_SEC}s"
    success "Full log: $LOG_FILE"
    
    # Notification
    local SNAPSHOT_MSG
    if [ "$ENABLE_SNAPSHOTS" = "true" ] && [ -d "$SNAPSHOT_DIR" ]; then
        local NOTIF_SNAPSHOT_COUNT
        NOTIF_SNAPSHOT_COUNT=$(ls -1d "$SNAPSHOT_DIR"/backup-* 2>/dev/null | wc -l)
        SNAPSHOT_MSG="Snapshots: $NOTIF_SNAPSHOT_COUNT"
    else
        SNAPSHOT_MSG="Snapshots: disabled"
    fi
    
    send_notification \
        "✅ Backup completed" \
        "System backup completed successfully

Duration: ${DURATION_MIN}m ${DURATION_SEC}s
$SNAPSHOT_MSG
Destination: $BACKUP_MOUNT" \
        "normal"
    
    log "========================================================================="
    
    exit 0
}

# Execute main function
main "$@"
