#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Usage: ./scripts/setup-sdcard.sh [/Volumes/bootfs] [--no-eject] [--client-ip IP]
# Options:
#   --no-eject     Skip automatic ejection of SD card
#   --client-ip    Configure for specific client IP (adds to deployment)
#   --client-name  Override hostname for client registration
#   --help         Show this help message

show_usage() {
    cat << EOF
Usage: $0 [VOLUME_PATH] [OPTIONS]

Prepares an SD card for piNAS installation by copying installer scripts,
configuring cloud-init, and setting up boot parameters. Can optionally
register the client for automatic deployment.

Arguments:
    VOLUME_PATH    Path to SD card boot volume (default: auto-detect)

Options:
    --no-eject           Skip automatic ejection of SD card after setup
    --client-ip IP       Configure for specific client IP (adds to deployment)
    --client-name NAME   Override hostname for client registration  
    --help               Show this help message

Examples:
    $0                                    # Auto-detect SD card and eject when done
    $0 /Volumes/bootfs                    # Use specific volume path
    $0 --no-eject                         # Setup but don't eject
    $0 --client-ip 192.168.1.100         # Setup for specific client IP
    $0 --client-ip 192.168.1.100 --client-name office-pinas
    $0 /Volumes/boot --no-eject --client-ip 10.0.0.50

Client Management:
    When --client-ip is specified, the client will be automatically added
    to the deployment system and configured for remote updates.

EOF
}

# Parse command line arguments
VOL_NAME=""
AUTO_EJECT=true
CLIENT_IP=""
CLIENT_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-eject)
            AUTO_EJECT=false
            shift
            ;;
        --client-ip)
            if [ $# -lt 2 ]; then
                echo "Error: --client-ip requires an IP address"
                exit 1
            fi
            CLIENT_IP="$2"
            shift 2
            ;;
        --client-name)
            if [ $# -lt 2 ]; then
                echo "Error: --client-name requires a hostname"
                exit 1
            fi
            CLIENT_NAME="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [ -z "$VOL_NAME" ]; then
                VOL_NAME="$1"
            else
                echo "Multiple volume paths specified. Use only one."
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Default volume name if not specified
if [ -z "$VOL_NAME" ]; then
    VOL_NAME="/Volumes/bootfs"
fi

# Auto-detect common SD card mount points on macOS
if [ ! -d "$VOL_NAME" ]; then
    echo "Specified volume not found: $VOL_NAME"
    echo "Searching for SD card..."
    
    # Common mount points for Raspberry Pi SD cards
    CANDIDATES=(
        "/Volumes/bootfs"
        "/Volumes/boot" 
        "/Volumes/BOOT"
        "/Volumes/RPI-BOOT"
    )
    
    for candidate in "${CANDIDATES[@]}"; do
        if [ -d "$candidate" ]; then
            echo "Found potential SD card at: $candidate"
            VOL_NAME="$candidate"
            break
        fi
    done
fi

if [ ! -d "$VOL_NAME" ]; then
    echo "Error: Could not find SD card boot volume."
    echo "Please ensure SD card is inserted and mounted."
    echo ""
    echo "Available volumes:"
    ls -1 /Volumes/ 2>/dev/null | grep -E "(boot|BOOT)" | sed 's/^/  \/Volumes\//' || echo "  (none found)"
    echo ""
    echo "You can specify a specific volume path:"
    echo "  $0 /Volumes/your-sd-card"
    exit 1
fi

echo "Found boot volume at: $VOL_NAME"

# Client management setup
if [ -n "$CLIENT_IP" ]; then
    echo "Setting up client management for IP: $CLIENT_IP"
    
    # Default client name if not specified
    if [ -z "$CLIENT_NAME" ]; then
        CLIENT_NAME="pinas-$(echo "$CLIENT_IP" | tr '.' '-')"
    fi
    
    # Add client to deployment system
    MANAGE_CLIENT_SCRIPT="$REPO_ROOT/scripts/manage-clients.sh"
    if [ -x "$MANAGE_CLIENT_SCRIPT" ]; then
        echo "Adding client to deployment system..."
        if "$MANAGE_CLIENT_SCRIPT" add "$CLIENT_IP" "$CLIENT_NAME" "piNAS at $CLIENT_IP" 2>/dev/null; then
            echo "✅ Client added to deployment system: $CLIENT_NAME ($CLIENT_IP)"
        else
            echo "⚠️  Client may already exist in deployment system"
        fi
    else
        echo "⚠️  Client management script not found, skipping registration"
    fi
fi

# Store the volume name for later ejection
VOLUME_PATH="$VOL_NAME"
VOLUME_NAME="$(basename "$VOL_NAME")"

# 1. Create pinas directory
echo "Creating $VOL_NAME/pinas..."
mkdir -p "$VOL_NAME/pinas"

# 2. Copy scripts
echo "Copying installer scripts..."
cp "$REPO_ROOT/sbin/pinas-install.sh" "$VOL_NAME/pinas/"
cp "$REPO_ROOT/sbin/pinas-cache-deps.sh" "$VOL_NAME/pinas/"
if [ -f "$REPO_ROOT/sbin/pinas-pull-update.sh" ]; then
    cp "$REPO_ROOT/sbin/pinas-pull-update.sh" "$VOL_NAME/pinas/"
fi

# 3. Cloud-Init Auto-Install
if [ -f "$REPO_ROOT/boot/user-data" ]; then
  echo "Copying user-data for cloud-init auto-install..."
  cp "$REPO_ROOT/boot/user-data" "$VOL_NAME/user-data"
  # meta-data is required for cloud-init to run user-data
  touch "$VOL_NAME/meta-data"
fi

# 4. Enable SSH (Backup access)
echo "Enabling SSH..."
touch "$VOL_NAME/ssh"

# 5. Copy reference config/cmdline templates (optional but handy)
CONFIG_TEMPLATE="$REPO_ROOT/boot/templates/config.txt"
CMDLINE_TEMPLATE="$REPO_ROOT/boot/templates/cmdline.txt"

if [ -f "$CONFIG_TEMPLATE" ]; then
  echo "Copying reference config.txt template..."
  cp "$CONFIG_TEMPLATE" "$VOL_NAME/config.txt.template"
fi
if [ -f "$CMDLINE_TEMPLATE" ]; then
  echo "Copying reference cmdline.txt template..."
  cp "$CMDLINE_TEMPLATE" "$VOL_NAME/cmdline.txt.template"
fi

# 6. Force enable SPI & UART (Fixes TFT stability when HDMI is connected)
echo "Configuring config.txt for SPI display stability..."
CONFIG_TXT="$VOL_NAME/config.txt"
if [ -f "$CONFIG_TXT" ]; then
  # Enable SPI if not already enabled
  if ! grep -q "^dtparam=spi=on" "$CONFIG_TXT"; then
    echo "dtparam=spi=on" >> "$CONFIG_TXT"
  fi
  # Enable I2C (for touch)
  if ! grep -q "^dtparam=i2c_arm=on" "$CONFIG_TXT"; then
    echo "dtparam=i2c_arm=on" >> "$CONFIG_TXT"
  fi
  # Pin core frequency (via UART enable) to prevent SPI clock drift when HDMI is plugged in
  if ! grep -q "^enable_uart=1" "$CONFIG_TXT"; then
    echo "enable_uart=1" >> "$CONFIG_TXT"
  fi
else
  echo "Warning: config.txt not found on SD card!"
fi

# Sync filesystem to ensure all writes are complete
echo "Syncing filesystem..."
sync

echo ""
echo "✅ SD card setup completed successfully!"
echo ""
echo "Setup summary:"
echo "  📁 Installer scripts copied to $VOL_NAME/pinas/"
echo "  ☁️  Cloud-init configured for automatic installation"
echo "  🔧 Boot configuration updated for TFT display"
echo "  🔑 SSH enabled for backup access"
if [ -n "$CLIENT_IP" ]; then
    echo "  📡 Deployment automation helper scripts prepared for $CLIENT_IP"
fi
echo ""

# Automatic ejection (if enabled)
if [ "$AUTO_EJECT" = true ]; then
    echo "🏃 Ejecting SD card..."
    
    # Detect operating system and use appropriate eject command
    case "$(uname -s)" in
        Darwin)  # macOS
            if diskutil unmount "$VOLUME_PATH" >/dev/null 2>&1; then
                echo "✅ SD card ejected successfully ($VOLUME_NAME)"
                echo "💾 You can now safely remove the SD card"
            else
                echo "⚠️  Failed to eject SD card automatically"
                echo "💾 Please manually eject: $VOLUME_NAME"
            fi
            ;;
        Linux)
            # On Linux, try to unmount
            if umount "$VOLUME_PATH" >/dev/null 2>&1; then
                echo "✅ SD card unmounted successfully"
                echo "💾 You can now safely remove the SD card"
            else
                echo "⚠️  Failed to unmount SD card automatically"
                echo "💾 Please manually unmount: $VOLUME_PATH"
            fi
            ;;
        *)
            echo "ℹ️  Automatic ejection not supported on this platform"
            echo "💾 Please manually eject the SD card"
            ;;
    esac
else
    echo "💾 SD card ready - remember to eject before removing!"
    echo "   On macOS: diskutil unmount $VOLUME_PATH"
fi

echo ""
echo "🚀 Next steps:"
echo "   1. Insert SD card into Raspberry Pi"
echo "   2. Connect power to start installation"
echo "   3. Monitor progress on TFT display"
echo "   4. Installation completes automatically (takes ~10-20 minutes)"
echo ""
echo "📡 The Pi will be accessible via:"
echo "   • Hostname: pinas.local"
echo "   • SSH: ssh pi@pinas.local (if WiFi connects)"
echo "   • USB: Will appear as storage device when connected via USB-C"

# Client-specific next steps
if [ -n "$CLIENT_IP" ]; then
    echo ""
    echo "🔐 Deployment Setup Reminder:"
    echo "   Use the helper to register this Pi for GitHub Actions deployments:"
    echo "   $REPO_ROOT/scripts/manage-clients.sh setup-key $CLIENT_IP"
    echo ""
    echo "   After the device is online, run:"
    echo "   $REPO_ROOT/scripts/manage-clients.sh test $CLIENT_IP"
    echo "   $REPO_ROOT/scripts/manage-clients.sh sync-workflow"
    echo ""
    echo "   Detailed instructions: DEPLOY-KEY-SOLUTION.md"
fi

echo ""

