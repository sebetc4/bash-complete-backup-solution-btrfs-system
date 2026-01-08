#!/bin/bash

# ============================================================================
# BACKUP SCRIPTS INSTALLATION
# ============================================================================
# Installs backup scripts to /usr/local/bin and config to ~/.backup
# Version: 1.0

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.backup"

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                                                               ║${NC}"
echo -e "${BLUE}║            BACKUP SCRIPTS INSTALLATION                        ║${NC}"
echo -e "${BLUE}║                                                               ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Ask which HDD backup script to install
echo -e "${YELLOW}Which HDD backup script(s) do you want to install?${NC}"
echo ""
echo "  1) backup-hdd         - Simple HDD to HDD mirror (default)"
echo "  2) backup-hdd-both    - Split backup across two drives"
echo "  3) both               - Install both scripts"
echo ""
read -rp "Choice [1]: " HDD_CHOICE
HDD_CHOICE=${HDD_CHOICE:-1}

case "$HDD_CHOICE" in
    1)
        INSTALL_HDD_SIMPLE=true
        INSTALL_HDD_BOTH=false
        ;;
    2)
        INSTALL_HDD_SIMPLE=false
        INSTALL_HDD_BOTH=true
        ;;
    3)
        INSTALL_HDD_SIMPLE=true
        INSTALL_HDD_BOTH=true
        ;;
    *)
        echo -e "${RED}Invalid choice, defaulting to option 1${NC}"
        INSTALL_HDD_SIMPLE=true
        INSTALL_HDD_BOTH=false
        ;;
esac

echo ""

# Check if running as root for /usr/local/bin
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (sudo)${NC}"
    echo "Reason: Installing to $BIN_DIR requires root privileges"
    exit 1
fi

# Check dependencies
echo -e "${YELLOW}Checking dependencies...${NC}"
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: yq is not installed${NC}"
    echo "Install with: sudo dnf install yq"
    exit 1
fi
echo -e "${GREEN}✓ Dependencies OK${NC}"
echo ""

# ============================================================================
# SYSTEM BACKUP SCRIPTS
# ============================================================================
echo -e "${YELLOW}Installing system backup scripts...${NC}"

if [ ! -f "$SCRIPT_DIR/backup-system/backup.sh" ]; then
    echo -e "${RED}Error: backup.sh not found in $SCRIPT_DIR/backup-system/${NC}"
    exit 1
fi

# Copy scripts
cp "$SCRIPT_DIR/backup-system/backup.sh" "$BIN_DIR/backup-system"

# Make executable
chmod +x "$BIN_DIR/backup-system"

echo -e "${GREEN}✓ Installed: backup-system${NC}"

# ============================================================================
# HDD BACKUP SCRIPTS
# ============================================================================
if [ "$INSTALL_HDD_SIMPLE" = true ]; then
    echo -e "${YELLOW}Installing HDD simple backup script...${NC}"

    if [ ! -f "$SCRIPT_DIR/backup-hdd/hdd-to-hdd/backup.sh" ]; then
        echo -e "${RED}Error: HDD simple backup.sh not found${NC}"
        exit 1
    fi

    cp "$SCRIPT_DIR/backup-hdd/hdd-to-hdd/backup.sh" "$BIN_DIR/backup-hdd"
    chmod +x "$BIN_DIR/backup-hdd"

    echo -e "${GREEN}✓ Installed: backup-hdd${NC}"
fi

if [ "$INSTALL_HDD_BOTH" = true ]; then
    echo -e "${YELLOW}Installing HDD split backup script...${NC}"

    if [ ! -f "$SCRIPT_DIR/backup-hdd/hdd-to-both-hdd/backup.sh" ]; then
        echo -e "${RED}Error: HDD both backup.sh not found${NC}"
        exit 1
    fi

    cp "$SCRIPT_DIR/backup-hdd/hdd-to-both-hdd/backup.sh" "$BIN_DIR/backup-hdd-both"
    chmod +x "$BIN_DIR/backup-hdd-both"

    echo -e "${GREEN}✓ Installed: backup-hdd-both${NC}"
fi
echo ""

# ============================================================================
# CONFIGURATION FILES
# ============================================================================
echo -e "${YELLOW}Setting up configuration...${NC}"

# Get real user (not root when using sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo ~$REAL_USER)
REAL_CONFIG_DIR="$REAL_HOME/.backup"

# Create config directory
mkdir -p "$REAL_CONFIG_DIR"

# Copy example configs if they don't exist
if [ ! -f "$REAL_CONFIG_DIR/config-system.yml" ]; then
    if [ -f "$SCRIPT_DIR/backup-system/config.yml" ]; then
        cp "$SCRIPT_DIR/backup-system/config.yml" "$REAL_CONFIG_DIR/config-system.yml"
        chown "$REAL_USER:$REAL_USER" "$REAL_CONFIG_DIR/config-system.yml"
        echo -e "${GREEN}✓ Created: $REAL_CONFIG_DIR/config-system.yml${NC}"
        echo -e "${YELLOW}  ⚠️  Edit this file with your settings!${NC}"
    fi
else
    echo -e "${BLUE}ℹ Config already exists: $REAL_CONFIG_DIR/config-system.yml${NC}"
fi

if [ "$INSTALL_HDD_SIMPLE" = true ]; then
    if [ ! -f "$REAL_CONFIG_DIR/config-hdd.yml" ]; then
        if [ -f "$SCRIPT_DIR/backup-hdd/hdd-to-hdd/config.yml" ]; then
            cp "$SCRIPT_DIR/backup-hdd/hdd-to-hdd/config.yml" "$REAL_CONFIG_DIR/config-hdd.yml"
            chown "$REAL_USER:$REAL_USER" "$REAL_CONFIG_DIR/config-hdd.yml"
            echo -e "${GREEN}✓ Created: $REAL_CONFIG_DIR/config-hdd.yml${NC}"
            echo -e "${YELLOW}  ⚠️  Edit this file with your settings!${NC}"
        fi
    else
        echo -e "${BLUE}ℹ Config already exists: $REAL_CONFIG_DIR/config-hdd.yml${NC}"
    fi
fi

if [ "$INSTALL_HDD_BOTH" = true ]; then
    if [ ! -f "$REAL_CONFIG_DIR/config-hdd-both.yml" ]; then
        if [ -f "$SCRIPT_DIR/backup-hdd/hdd-to-both-hdd/config.yml" ]; then
            cp "$SCRIPT_DIR/backup-hdd/hdd-to-both-hdd/config.yml" "$REAL_CONFIG_DIR/config-hdd-both.yml"
            chown "$REAL_USER:$REAL_USER" "$REAL_CONFIG_DIR/config-hdd-both.yml"
            echo -e "${GREEN}✓ Created: $REAL_CONFIG_DIR/config-hdd-both.yml${NC}"
            echo -e "${YELLOW}  ⚠️  Edit this file with your settings!${NC}"
        fi
    else
        echo -e "${BLUE}ℹ Config already exists: $REAL_CONFIG_DIR/config-hdd-both.yml${NC}"
    fi
fi

# Set ownership
chown "$REAL_USER:$REAL_USER" "$REAL_CONFIG_DIR"

echo ""

# ============================================================================
# SUMMARY
# ============================================================================
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║             ✅  INSTALLATION COMPLETE  ✅                     ║${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Installed commands:${NC}"
echo "  • backup-system     - System backup"
if [ "$INSTALL_HDD_SIMPLE" = true ]; then
    echo "  • backup-hdd        - HDD to HDD mirror backup"
fi
if [ "$INSTALL_HDD_BOTH" = true ]; then
    echo "  • backup-hdd-both   - Split backup across two drives"
fi
echo ""
echo -e "${BLUE}Configuration files:${NC}"
echo "  • $REAL_CONFIG_DIR/config-system.yml"
if [ "$INSTALL_HDD_SIMPLE" = true ]; then
    echo "  • $REAL_CONFIG_DIR/config-hdd.yml"
fi
if [ "$INSTALL_HDD_BOTH" = true ]; then
    echo "  • $REAL_CONFIG_DIR/config-hdd-both.yml"
fi
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Edit configs: nano $REAL_CONFIG_DIR/config-system.yml"
echo "  2. Test backup:  sudo backup-system --dry-run"
echo "  3. Run backup:   sudo backup-system"
if [ "$INSTALL_HDD_SIMPLE" = true ]; then
    echo "  4. HDD backup:   sudo backup-hdd"
fi
if [ "$INSTALL_HDD_BOTH" = true ]; then
    echo "  4. Split backup: sudo backup-hdd-both -d both"
fi
echo ""
echo -e "${BLUE}Version info:${NC}"
echo -e "$(backup-system --help | head -1)"
echo ""
