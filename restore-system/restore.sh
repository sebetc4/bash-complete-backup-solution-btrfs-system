#!/bin/bash
# ============================================================================
# COMPLETE SYSTEM RESTORATION SCRIPT
# ============================================================================
# Version: 3.1
# Date: 2026-01-08
#
# USAGE:
#   1. Boot from Fedora Live USB
#   2. Copy this script and config.yml
#   3. sudo bash restore.sh [MODE]
#
# MODES:
#   --full-disk     Erase entire disk and recreate all partitions (default)
#   --partitions    Restore only Linux partitions (preserves Windows/dual-boot)
#
# PREREQUISITES:
#   - Fedora Live USB
#   - External backup HDD connected and mounted
#   - config.yml file present
#
# ============================================================================

set -e
set -o pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="1.0.0"

# Restoration mode
RESTORE_MODE="full-disk"  # or "partitions"

# Partition mode variables
PART_EFI_EXISTING=""
PART_BOOT_TARGET=""
PART_LUKS_TARGET=""

# Search for config file in LOCAL locations only (for Live USB usage)
# Note: restore.sh is meant to be run from bootable USB, not from installed system
find_config_file() {
    local search_paths=(
        "$SCRIPT_DIR/config.yml"             # Same directory as script (recommended)
        "./config.yml"                       # Current directory
        "/mnt/hdd1/backups/restore-system/config.yml"  # On backup HDD
    )
    
    for cfg_path in "${search_paths[@]}"; do
        if [ -f "$cfg_path" ]; then
            echo "$cfg_path"
            return 0
        fi
    done
    
    return 1
}

CONFIG_FILE=""

# ============================================================================
# COLORS
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================================================
# FUNCTIONS
# ============================================================================
log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

section() {
    echo ""
    echo -e "${MAGENTA}=========================================================================${NC}"
    echo -e "${MAGENTA} $1${NC}"
    echo -e "${MAGENTA}=========================================================================${NC}"
}

confirm() {
    local prompt="$1"
    local response
    
    while true; do
        read -p "$(echo -e ${YELLOW}${prompt}${NC}) (yes/no): " response
        case "$response" in
            yes) return 0 ;;
            no) return 1 ;;
            *) warn "Answer 'yes' or 'no'" ;;
        esac
    done
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

# ============================================================================
# CONFIG VALIDATION
# ============================================================================
validate_config() {
    local errors=()
    local warnings=()
    
    info "Validating configuration..."
    
    # Required fields
    local backup_mount
    backup_mount=$(parse_yaml "backup.hdd_mount")
    if [ -z "$backup_mount" ]; then
        errors+=("backup.hdd_mount is required")
    fi
    
    local backup_root
    backup_root=$(parse_yaml "backup.backup_root")
    if [ -z "$backup_root" ]; then
        errors+=("backup.backup_root is required")
    fi
    
    local target_disk
    target_disk=$(parse_yaml "restore.target_disk")
    if [ -z "$target_disk" ] && [ "$RESTORE_MODE" = "full-disk" ]; then
        errors+=("restore.target_disk is required for full-disk mode")
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
    
    # Validate paths format
    validate_path_format "backup.hdd_mount" "$backup_mount"
    validate_path_format "backup.backup_root" "$backup_root"
    
    if [ "$RESTORE_MODE" = "full-disk" ] && [ -n "$target_disk" ]; then
        validate_path_format "restore.target_disk" "$target_disk"
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
        error "Configuration validation failed. Please fix the errors above."
    fi
    
    if [ ${#warnings[@]} -gt 0 ]; then
        for w in "${warnings[@]}"; do
            warn "$w"
        done
    fi
    
    success "Configuration validated"
}

# ============================================================================
# DEPENDENCIES CHECK
# ============================================================================
check_dependencies() {
    if ! command -v yq &> /dev/null; then
        echo -e "${RED}[ERROR]${NC} yq is required to parse YAML configuration"
        echo "Installation on Live USB: sudo dnf install yq"
        exit 1
    fi
}

# ============================================================================
# PARTITION NAMING
# ============================================================================
# Determine partition suffix (p1 for NVMe, 1 for SATA/HDD)
get_partition_suffix() {
    local disk="$1"
    local num="$2"
    # NVMe uses p1, p2, etc. SATA uses 1, 2, etc.
    if [[ "$disk" =~ nvme|loop ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# ============================================================================
# HELP
# ============================================================================
show_help() {
    cat << EOF
${CYAN}SYSTEM RESTORATION FROM BACKUP v${VERSION}${NC}

Usage: sudo bash restore.sh [MODE] [OPTIONS]

This script restores the system from a backup.

${GREEN}Modes:${NC}
    --full-disk      Erase ENTIRE disk and recreate all partitions
                     Use for: new SSD, no dual-boot
                     ${RED}⚠️  DESTROYS ALL DATA ON DISK${NC}

    --partitions     Restore only Linux partitions (interactive)
                     Use for: dual-boot, preserve Windows
                     Requires specifying: EFI, /boot, LUKS partitions
                     ${YELLOW}Preserves other partitions${NC}

${GREEN}Options:${NC}
    -c, --config <file>  Configuration file
    -h, --help           Display this help

${GREEN}Examples:${NC}
    # Full disk restoration (new SSD)
    sudo bash restore.sh --full-disk

    # Dual-boot restoration (preserve Windows)
    sudo bash restore.sh --partitions

${GREEN}Dual-boot partition mode:${NC}
    The script will ask for:
    1. Existing EFI partition (e.g., /dev/nvme0n1p1)
    2. Target /boot partition (e.g., /dev/nvme0n1p4)  
    3. Target LUKS partition (e.g., /dev/nvme0n1p5)

    Only partitions 2 and 3 will be formatted.
    EFI is preserved, GRUB is reinstalled alongside Windows.

${GREEN}Configuration search paths (local only):${NC}
    - ./config.yml              (same directory as restore.sh)
    - /mnt/hdd1/backups/restore-system/config.yml

${YELLOW}Note:${NC} This script is designed to run from a Live USB.
       Place config.yml in the restore-system/ directory.

EOF
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --full-disk)
            RESTORE_MODE="full-disk"
            shift
            ;;
        --partitions)
            RESTORE_MODE="partitions"
            shift
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Check root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (sudo)"
fi

# Check dependencies
check_dependencies

# Find config file if not specified
if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE=$(find_config_file) || error "Configuration file not found

Searched in:
  - $SCRIPT_DIR/config.yml
  - ./config.yml
  - /mnt/hdd1/backups/restore-system/config.yml

Tip: Copy the entire restore-system/ directory to your Live USB"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    error "Configuration file not found: $CONFIG_FILE"
fi

# Validate config
validate_config

# Load config
BACKUP_MOUNT=$(parse_yaml "backup.hdd_mount")
BACKUP_ROOT=$(parse_yaml "backup.backup_root")
TARGET_DISK=$(parse_yaml "restore.target_disk")
BTRFS_CONFIG="$BACKUP_ROOT/btrfs-structure"

# Points de montage temporaires
BTRFS_ROOT_MOUNT="/mnt/btrfs-root"
NEW_ROOT_MOUNT="/mnt/newroot"

# Partitions (will be calculated)
PART_EFI=""
PART_BOOT=""
PART_LUKS=""

# ============================================================================
# PARTITION MODE: INTERACTIVE PARTITION SELECTION
# ============================================================================
select_partitions_interactive() {
    echo ""
    info "You have selected PARTITION mode (dual-boot safe)"
    info "The script will ask you to identify your existing partitions."
    echo ""
    
    # List available partitions
    info "Available partitions:"
    echo ""
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,UUID | grep -E "^[a-z]|^└|^├"
    echo ""
    
    # Select EFI partition (will NOT be formatted)
    while true; do
        read -rp "$(echo -e "${YELLOW}Enter EXISTING EFI partition (e.g., /dev/nvme0n1p1): ${NC}")" PART_EFI_EXISTING
        if [ -b "$PART_EFI_EXISTING" ]; then
            EFI_FSTYPE=$(blkid -s TYPE -o value "$PART_EFI_EXISTING" 2>/dev/null)
            if [ "$EFI_FSTYPE" = "vfat" ]; then
                success "EFI partition: $PART_EFI_EXISTING (will be PRESERVED)"
                break
            else
                warn "This doesn't appear to be a FAT32 EFI partition (found: $EFI_FSTYPE)"
                if confirm "Use it anyway?"; then
                    break
                fi
            fi
        else
            warn "Partition not found: $PART_EFI_EXISTING"
        fi
    done
    
    # Select /boot partition (will be formatted)
    while true; do
        read -rp "$(echo -e "${YELLOW}Enter /boot partition to FORMAT (e.g., /dev/nvme0n1p4): ${NC}")" PART_BOOT_TARGET
        if [ -b "$PART_BOOT_TARGET" ]; then
            if [ "$PART_BOOT_TARGET" = "$PART_EFI_EXISTING" ]; then
                warn "Cannot be the same as EFI partition"
            else
                warn "/boot ($PART_BOOT_TARGET) will be FORMATTED as ext4"
                if confirm "Confirm?"; then
                    break
                fi
            fi
        else
            warn "Partition not found: $PART_BOOT_TARGET"
        fi
    done
    
    # Select LUKS partition (will be formatted)
    while true; do
        read -rp "$(echo -e "${YELLOW}Enter LUKS partition to FORMAT (e.g., /dev/nvme0n1p5): ${NC}")" PART_LUKS_TARGET
        if [ -b "$PART_LUKS_TARGET" ]; then
            if [ "$PART_LUKS_TARGET" = "$PART_EFI_EXISTING" ] || [ "$PART_LUKS_TARGET" = "$PART_BOOT_TARGET" ]; then
                warn "Cannot be the same as EFI or /boot partition"
            else
                warn "LUKS ($PART_LUKS_TARGET) will be FORMATTED with LUKS+BTRFS"
                if confirm "Confirm?"; then
                    break
                fi
            fi
        else
            warn "Partition not found: $PART_LUKS_TARGET"
        fi
    done
    
    # Set variables for the rest of the script
    PART_EFI="$PART_EFI_EXISTING"
    PART_BOOT="$PART_BOOT_TARGET"
    PART_LUKS="$PART_LUKS_TARGET"
    
    echo ""
    success "Partition selection complete"
    info "  EFI (preserve):  $PART_EFI"
    info "  /boot (format):  $PART_BOOT"
    info "  LUKS (format):   $PART_LUKS"
}

# ============================================================================
# BANNER
# ============================================================================
clear
echo -e "${CYAN}"
if [ "$RESTORE_MODE" = "full-disk" ]; then
cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║            COMPLETE SYSTEM RESTORATION FROM BACKUP                        ║
║                         FULL DISK MODE                                    ║
║                  ⚠️  WARNING - DESTRUCTIVE OPERATION  ⚠️                 ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
else
cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║            COMPLETE SYSTEM RESTORATION FROM BACKUP                        ║
║                       PARTITION MODE (DUAL-BOOT)                          ║
║               ⚠️  Linux partitions will be formatted  ⚠️                ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
fi
echo -e "${NC}"

info "Configuration: $CONFIG_FILE"
if [ "$RESTORE_MODE" = "full-disk" ]; then
    info "Target disk: $TARGET_DISK"
else
    info "Mode: Partition-only (Windows/dual-boot preserved)"
fi
info "Backup source: $BACKUP_ROOT"
echo ""

if [ "$RESTORE_MODE" = "full-disk" ]; then
    warn "This script will:"
    warn "  1. COMPLETELY ERASE: $TARGET_DISK"
    warn "  2. Recreate partitions"
    warn "  3. Configure LUKS (encryption)"
else
    warn "This script will:"
    warn "  1. PRESERVE your EFI partition (Windows Boot Manager intact)"
    warn "  2. FORMAT only /boot and LUKS partitions"
    warn "  3. Configure LUKS (encryption)"
fi
warn "  4. Recreate BTRFS structure"
warn "  5. Restore all data"
echo ""

if [ "$RESTORE_MODE" = "full-disk" ]; then
    warn "ALL DATA ON $TARGET_DISK WILL BE LOST!"
else
    warn "ONLY Linux partitions will be formatted!"
    warn "Windows and other partitions will be PRESERVED."
fi
echo ""

if ! confirm "Do you want to continue?"; then
    log "Operation cancelled"
    exit 0
fi

# Partition mode: interactive selection
if [ "$RESTORE_MODE" = "partitions" ]; then
    select_partitions_interactive
fi

# Double confirmation
warn ""
warn "FINAL CONFIRMATION!"
if [ "$RESTORE_MODE" = "full-disk" ]; then
    warn "Target disk: $TARGET_DISK"
else
    warn "Partitions to FORMAT: $PART_BOOT, $PART_LUKS"
    warn "Partition PRESERVED: $PART_EFI"
fi
if ! confirm "Are you ABSOLUTELY SURE?"; then
    log "Operation cancelled"
    exit 0
fi

# ============================================================================
# STEP 1: CHECKS
# ============================================================================
section "STEP 1/10: PRELIMINARY CHECKS"

if [ "$RESTORE_MODE" = "full-disk" ]; then
    # Target disk (only in full-disk mode)
    if [ ! -b "$TARGET_DISK" ]; then
        error "Target disk not found: $TARGET_DISK

Check with: lsblk"
    fi

    log "Target disk: $TARGET_DISK"
    lsblk "$TARGET_DISK"

    # Calculate partition names
    PART_EFI=$(get_partition_suffix "$TARGET_DISK" 1)
    PART_BOOT=$(get_partition_suffix "$TARGET_DISK" 2)
    PART_LUKS=$(get_partition_suffix "$TARGET_DISK" 3)
    info "Partitions: EFI=$PART_EFI, Boot=$PART_BOOT, LUKS=$PART_LUKS"
else
    # Partitions mode - already selected interactively
    log "Target partitions:"
    info "  EFI (preserve): $PART_EFI"
    info "  /boot (format): $PART_BOOT"
    info "  LUKS (format): $PART_LUKS"
fi

# Backup HDD
if ! mountpoint -q "$BACKUP_MOUNT"; then
    error "Backup HDD not mounted on $BACKUP_MOUNT

Actions:
1. Plug in the HDD
2. If LUKS, decrypt: sudo cryptsetup luksOpen /dev/sdX hdd1
3. Mount: sudo mount /dev/mapper/hdd1 $BACKUP_MOUNT
4. Rerun this script"
fi

success "Backup HDD mounted"

# Backups
if [ ! -d "$BACKUP_ROOT/root" ] || [ ! -d "$BACKUP_ROOT/home" ]; then
    error "Incomplete backups in $BACKUP_ROOT

Expected structure:
$BACKUP_ROOT/
├── root/
├── home/
├── code/
└── btrfs-structure/"
fi

success "Backups found and valid"

info ""
info "Backup size:"
du -sh "$BACKUP_ROOT"/{root,home,code} 2>/dev/null

sleep 2

# ============================================================================
# STEP 2: PARTITIONING (full-disk mode only)
# ============================================================================
if [ "$RESTORE_MODE" = "full-disk" ]; then
    section "STEP 2/10: PARTITIONING"

    warn "Erasing and repartitioning $TARGET_DISK"
    lsblk "$TARGET_DISK"

    sleep 3

    log "Erasing partition table..."
    wipefs -af "$TARGET_DISK" 2>/dev/null || true

    log "Creating GPT table..."
    parted -s "$TARGET_DISK" mklabel gpt

    log "Creating partitions..."
    log "  - EFI (210 MB)"
    parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 211MiB
    parted -s "$TARGET_DISK" set 1 esp on

    log "  - /boot (2.15 GB)"
    parted -s "$TARGET_DISK" mkpart primary ext4 211MiB 2347MiB

    log "  - LUKS+BTRFS (rest)"
    parted -s "$TARGET_DISK" mkpart primary 2347MiB 100%

    sleep 2
    partprobe "$TARGET_DISK"
    sleep 2

    # Check that partitions exist
    if [ ! -b "$PART_EFI" ] || [ ! -b "$PART_BOOT" ] || [ ! -b "$PART_LUKS" ]; then
        error "Partitions not created correctly. Check with lsblk $TARGET_DISK"
    fi

    success "Partitioning complete"
    lsblk "$TARGET_DISK"
else
    section "STEP 2/10: PARTITION CHECK (skipping partitioning)"
    
    info "Partition mode: preserving existing partition layout"
    info "Checking selected partitions..."
    
    if [ ! -b "$PART_EFI" ] || [ ! -b "$PART_BOOT" ] || [ ! -b "$PART_LUKS" ]; then
        error "One or more selected partitions not found.
        
EFI: $PART_EFI (exists: $([ -b "$PART_EFI" ] && echo yes || echo NO))
Boot: $PART_BOOT (exists: $([ -b "$PART_BOOT" ] && echo yes || echo NO))
LUKS: $PART_LUKS (exists: $([ -b "$PART_LUKS" ] && echo yes || echo NO))"
    fi
    
    success "All selected partitions exist"
fi

# ============================================================================
# STEP 3: LUKS
# ============================================================================
section "STEP 3/10: LUKS ENCRYPTION"

warn "Encryption configuration"
warn "You will enter a password (required at every boot)"
info ""
info "Tips:"
info "  - STRONG password (12+ characters)"
info "  - Write it down in a SAFE place"
info "  - NEVER lose it"

log "Configuring LUKS..."
cryptsetup luksFormat "$PART_LUKS" || error "LUKS failed"

success "LUKS configured"

# Get LUKS UUID for consistent naming
NEW_LUKS_UUID=$(blkid -s UUID -o value "$PART_LUKS")
LUKS_MAPPER_NAME="luks-$NEW_LUKS_UUID"

log "Opening encrypted partition (mapper: $LUKS_MAPPER_NAME)..."
cryptsetup luksOpen "$PART_LUKS" "$LUKS_MAPPER_NAME" || error "LUKS open failed"

success "LUKS partition opened"

# ============================================================================
# STEP 4: BTRFS
# ============================================================================
section "STEP 4/10: BTRFS FILESYSTEM"

log "Formatting as BTRFS..."
mkfs.btrfs -f -L "fedora-root" "/dev/mapper/$LUKS_MAPPER_NAME"

success "BTRFS filesystem created"

# ============================================================================
# STEP 5: SUBVOLUMES
# ============================================================================
section "STEP 5/10: BTRFS SUBVOLUMES"

log "Mounting BTRFS root..."
mkdir -p "$BTRFS_ROOT_MOUNT"
mount -o subvolid=5 "/dev/mapper/$LUKS_MAPPER_NAME" "$BTRFS_ROOT_MOUNT"

log "Creating subvolumes..."
btrfs subvolume create "$BTRFS_ROOT_MOUNT/root"
btrfs subvolume create "$BTRFS_ROOT_MOUNT/home"
btrfs subvolume create "$BTRFS_ROOT_MOUNT/code"
btrfs subvolume create "$BTRFS_ROOT_MOUNT/vm"
btrfs subvolume create "$BTRFS_ROOT_MOUNT/ai"

log "Applying nodatacow on /vm..."
chattr +C "$BTRFS_ROOT_MOUNT/vm"

# Recover UID/GID of first user from backup
MAIN_USER=$(ls -d "$BACKUP_ROOT/home"/* 2>/dev/null | head -1 | xargs basename)

if [ -n "$MAIN_USER" ]; then
    # Search for UID in backup
    MAIN_UID=$(stat -c '%u' "$BACKUP_ROOT/home/$MAIN_USER" 2>/dev/null || echo "1000")
    MAIN_GID=$(stat -c '%g' "$BACKUP_ROOT/home/$MAIN_USER" 2>/dev/null || echo "1000")
    
    info "Main user detected: $MAIN_USER (UID:$MAIN_UID GID:$MAIN_GID)"
    
    # Apply permissions on user subvolumes
    chown "$MAIN_UID:$MAIN_GID" "$BTRFS_ROOT_MOUNT/code"
    chown "$MAIN_UID:$MAIN_GID" "$BTRFS_ROOT_MOUNT/ai"
    
    chmod 755 "$BTRFS_ROOT_MOUNT/code"
    chmod 755 "$BTRFS_ROOT_MOUNT/ai"
    
    success "User permissions configured"
else
    warn "Cannot detect main user, default root permissions"
fi

success "Subvolumes created"

log "Verification:"
btrfs subvolume list "$BTRFS_ROOT_MOUNT"

umount "$BTRFS_ROOT_MOUNT"

# ============================================================================
# STEP 6: MOUNTING
# ============================================================================
section "STEP 6/10: MOUNTING SUBVOLUMES"

mkdir -p "$NEW_ROOT_MOUNT"

log "Mounting / ..."
mount -o subvol=root,compress=zstd:1,noatime,ssd,space_cache=v2,discard=async \
    "/dev/mapper/$LUKS_MAPPER_NAME" "$NEW_ROOT_MOUNT"

mkdir -p "$NEW_ROOT_MOUNT"/{home,code,vm,ai,boot,boot/efi,data}

log "Mounting /home ..."
mount -o subvol=home,compress=zstd:1,noatime,ssd,space_cache=v2,discard=async \
    "/dev/mapper/$LUKS_MAPPER_NAME" "$NEW_ROOT_MOUNT/home"

log "Mounting /code ..."
mount -o subvol=code,compress=zstd:1,noatime,ssd,space_cache=v2,discard=async \
    "/dev/mapper/$LUKS_MAPPER_NAME" "$NEW_ROOT_MOUNT/code"

log "Mounting /vm ..."
mount -o subvol=vm,noatime,ssd,space_cache=v2,discard=async,nodatacow \
    "/dev/mapper/$LUKS_MAPPER_NAME" "$NEW_ROOT_MOUNT/vm"

log "Mounting /ai ..."
mount -o subvol=ai,compress=zstd:1,noatime,ssd,space_cache=v2,discard=async \
    "/dev/mapper/$LUKS_MAPPER_NAME" "$NEW_ROOT_MOUNT/ai"

success "Subvolumes mounted"

log "Formatting /boot..."
mkfs.ext4 -F -L "boot" "$PART_BOOT"
mount "$PART_BOOT" "$NEW_ROOT_MOUNT/boot"

if [ "$RESTORE_MODE" = "full-disk" ]; then
    log "Formatting /boot/efi..."
    mkfs.vfat -F32 -n "EFI" "$PART_EFI"
else
    log "Mounting existing EFI partition (preserving Windows Boot Manager)..."
fi
mount "$PART_EFI" "$NEW_ROOT_MOUNT/boot/efi"

# In partition mode, create EFI/fedora directory if needed
if [ "$RESTORE_MODE" = "partitions" ]; then
    mkdir -p "$NEW_ROOT_MOUNT/boot/efi/EFI/fedora"
fi

success "Boot partitions mounted"

# ============================================================================
# STEP 7: DATA RESTORATION
# ============================================================================
section "STEP 7/10: DATA RESTORATION"

warn "This step may take 30-60 minutes"

log "Restoring / ..."
rsync -aAXHv --info=progress2 "$BACKUP_ROOT/root/" "$NEW_ROOT_MOUNT/"

success "/ restored"

log "Restoring /home ..."
rsync -aAXHv --info=progress2 "$BACKUP_ROOT/home/" "$NEW_ROOT_MOUNT/home/"

success "/home restored"

if [ -d "$BACKUP_ROOT/code" ] && [ "$(ls -A $BACKUP_ROOT/code 2>/dev/null)" ]; then
    log "Restoring /code ..."
    rsync -aAXHv --info=progress2 "$BACKUP_ROOT/code/" "$NEW_ROOT_MOUNT/code/"
    success "/code restored"
fi

success "All data restored"

# ============================================================================
# STEP 8: CONFIGURATION
# ============================================================================
section "STEP 8/10: SYSTEM CONFIGURATION"

log "Recovering UUIDs..."
NEW_BTRFS_UUID=$(blkid -s UUID -o value "/dev/mapper/$LUKS_MAPPER_NAME")
NEW_BOOT_UUID=$(blkid -s UUID -o value "$PART_BOOT")
NEW_EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")
# NEW_LUKS_UUID already defined during LUKS open

info "New UUIDs:"
info "  BTRFS: $NEW_BTRFS_UUID"
info "  Boot: $NEW_BOOT_UUID"
info "  EFI: $NEW_EFI_UUID"
info "  LUKS: $NEW_LUKS_UUID"

log "Creating fstab..."
cat > "$NEW_ROOT_MOUNT/etc/fstab" << EOF
#
# /etc/fstab
# Generated during restoration on $(date)
#

# Boot
UUID=$NEW_BOOT_UUID  /boot      ext4   defaults                                                    1 2
UUID=$NEW_EFI_UUID   /boot/efi  vfat   umask=0077,shortname=winnt                                  0 2

# Système (BTRFS + LUKS)
UUID=$NEW_BTRFS_UUID  /      btrfs  subvol=root,compress=zstd:1,noatime,ssd,space_cache=v2,discard=async,x-systemd.device-timeout=0  0 0
UUID=$NEW_BTRFS_UUID  /home  btrfs  subvol=home,compress=zstd:1,noatime,ssd,space_cache=v2,discard=async,x-systemd.device-timeout=0  0 0

# Data
UUID=$NEW_BTRFS_UUID  /code  btrfs  subvol=code,compress=zstd:1,noatime,ssd,space_cache=v2,discard=async  0 0
UUID=$NEW_BTRFS_UUID  /vm    btrfs  subvol=vm,noatime,ssd,space_cache=v2,discard=async,nodatacow          0 0
UUID=$NEW_BTRFS_UUID  /ai    btrfs  subvol=ai,compress=zstd:1,noatime,ssd,space_cache=v2,discard=async   0 0
EOF

# /data management
if [ -f "$BTRFS_CONFIG/additional-disks-info.txt" ]; then
    DATA_UUID_BACKUP=$(grep "UUID" "$BTRFS_CONFIG/additional-disks-info.txt" | grep -v "LUKS" | head -1 | awk '{print $3}')
    
    if [ -n "$DATA_UUID_BACKUP" ]; then
        info "/data disk detected (UUID: $DATA_UUID_BACKUP)"
        
        if blkid | grep -q "$DATA_UUID_BACKUP"; then
            success "Original /data connected, adding to fstab"
            echo "" >> "$NEW_ROOT_MOUNT/etc/fstab"
            echo "# Additional disk /data" >> "$NEW_ROOT_MOUNT/etc/fstab"
            echo "UUID=$DATA_UUID_BACKUP  /data  btrfs  compress=zstd:1,noatime,ssd,space_cache=v2,discard=async,nofail  0 0" >> "$NEW_ROOT_MOUNT/etc/fstab"
        else
            warn "Original /data not connected"
            cat >> "$NEW_ROOT_MOUNT/etc/fstab" << EOF

# /data disk (UUID: $DATA_UUID_BACKUP)
# Not connected during restoration
# Uncomment after connection:
# UUID=$DATA_UUID_BACKUP  /data  btrfs  compress=zstd:1,noatime,ssd,space_cache=v2,discard=async,nofail  0 0
EOF
        fi
    fi
fi

success "fstab created"

log "Configuring crypttab..."
cat > "$NEW_ROOT_MOUNT/etc/crypttab" << EOF
$LUKS_MAPPER_NAME  UUID=$NEW_LUKS_UUID  none  discard
EOF

success "crypttab created"

# ============================================================================
# STEP 9: GRUB
# ============================================================================
section "STEP 9/10: GRUB INSTALLATION"

log "Preparing chroot..."
mount --bind /dev "$NEW_ROOT_MOUNT/dev"
mount --bind /proc "$NEW_ROOT_MOUNT/proc"
mount --bind /sys "$NEW_ROOT_MOUNT/sys"
mount --bind /run "$NEW_ROOT_MOUNT/run"

# Mount efivars if available (needed for EFI operations)
if [ -d /sys/firmware/efi/efivars ]; then
    mount --bind /sys/firmware/efi/efivars "$NEW_ROOT_MOUNT/sys/firmware/efi/efivars" 2>/dev/null || true
fi

log "Installing GRUB and generating initramfs..."

# Different GRUB install depending on mode
if [ "$RESTORE_MODE" = "partitions" ]; then
    info "Partition mode: GRUB will be installed alongside Windows Boot Manager"
    
    chroot "$NEW_ROOT_MOUNT" /bin/bash << 'CHROOT_SCRIPT'
set -e

echo "Installing GRUB (preserving Windows Boot Manager)..."
grub2-install --target=x86_64-efi \
              --efi-directory=/boot/efi \
              --bootloader-id=fedora \
              --recheck

# Enable os-prober for Windows detection
echo "Enabling os-prober for dual-boot..."
if [ -f /etc/default/grub ]; then
    # Ensure GRUB_DISABLE_OS_PROBER is not set to true
    sed -i 's/^GRUB_DISABLE_OS_PROBER=true/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    if ! grep -q "GRUB_DISABLE_OS_PROBER" /etc/default/grub; then
        echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
    fi
fi

echo "Running os-prober to detect Windows..."
os-prober || true

echo "Generating GRUB config..."
grub2-mkconfig -o /boot/grub2/grub.cfg

echo "Regenerating initramfs..."
dracut --force --regenerate-all

echo "Configuration complete"
CHROOT_SCRIPT

    success "GRUB installed (dual-boot mode)"
else
    chroot "$NEW_ROOT_MOUNT" /bin/bash << 'CHROOT_SCRIPT'
set -e

echo "Installing GRUB..."
grub2-install --target=x86_64-efi \
              --efi-directory=/boot/efi \
              --bootloader-id=fedora \
              --recheck

echo "Generating GRUB config..."
grub2-mkconfig -o /boot/grub2/grub.cfg

echo "Regenerating initramfs..."
dracut --force --regenerate-all

echo "Configuration complete"
CHROOT_SCRIPT

    success "GRUB installed"
fi

# ============================================================================
# STEP 10: CLEANUP
# ============================================================================
section "STEP 10/10: FINALIZATION"

log "Unmounting filesystems..."
umount "$NEW_ROOT_MOUNT/run" 2>/dev/null || true
umount "$NEW_ROOT_MOUNT/sys" 2>/dev/null || true
umount "$NEW_ROOT_MOUNT/proc" 2>/dev/null || true
umount "$NEW_ROOT_MOUNT/dev" 2>/dev/null || true
umount "$NEW_ROOT_MOUNT/boot/efi"
umount "$NEW_ROOT_MOUNT/boot"
umount "$NEW_ROOT_MOUNT/ai"
umount "$NEW_ROOT_MOUNT/vm"
umount "$NEW_ROOT_MOUNT/code"
umount "$NEW_ROOT_MOUNT/home"
umount "$NEW_ROOT_MOUNT"

log "Closing LUKS..."
cryptsetup luksClose "$LUKS_MAPPER_NAME"

success "Cleanup complete"

# ============================================================================
# FINAL REPORT
# ============================================================================
section "✅ RESTORATION COMPLETED SUCCESSFULLY!"

echo ""
success "The system has been completely restored"
echo ""
info "Summary:"
if [ "$RESTORE_MODE" = "full-disk" ]; then
    info "  - Mode: Full disk"
    info "  - Disk: $TARGET_DISK"
else
    info "  - Mode: Partition (dual-boot)"
    info "  - EFI (preserved): $PART_EFI"
    info "  - /boot: $PART_BOOT"
    info "  - LUKS: $PART_LUKS"
fi
info "  - BTRFS structure recreated"
info "  - Data restored"
info "  - GRUB configured"
info ""
warn "NEXT STEPS:"
warn "  1. Remove Live USB"
warn "  2. Reboot: reboot"
warn "  3. Enter LUKS password at boot"
warn "  4. Verify the system"

if [ "$RESTORE_MODE" = "partitions" ]; then
    warn ""
    info "DUAL-BOOT INFO:"
    info "  - GRUB should show both Fedora and Windows"
    info "  - If Windows is missing, run: sudo grub2-mkconfig -o /boot/grub2/grub.cfg"
    info "  - Windows Boot Manager was preserved in EFI"
fi

warn ""
info "Post-boot checks:"
info "  - df -h"
info "  - mount | grep btrfs"
info "  - btrfs subvolume list /"
warn ""

if [ -n "$DATA_UUID_BACKUP" ] && ! blkid | grep -q "$DATA_UUID_BACKUP"; then
    warn "DON'T FORGET:"
    warn "  - Connect /data disk"
    warn "  - Modify /etc/fstab if necessary"
    warn "  - Mount: sudo mount /data"
fi

echo ""
echo -e "${CYAN}"
if [ "$RESTORE_MODE" = "full-disk" ]; then
cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║                    ✅  RESTORATION COMPLETE  ✅                          ║
║                                                                           ║
║                      You can reboot now                                  ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
else
cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║              ✅  RESTORATION COMPLETE (DUAL-BOOT)  ✅                    ║
║                                                                           ║
║            Windows and Fedora should both be available                   ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
fi
echo -e "${NC}"

exit 0
