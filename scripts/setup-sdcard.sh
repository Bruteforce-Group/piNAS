#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Usage: ./scripts/setup-sdcard.sh /Volumes/bootfs
# (Or just run it, and it tries to find the volume)

VOL_NAME="${1:-/Volumes/bootfs}"

if [ ! -d "$VOL_NAME" ]; then
  # Try /Volumes/boot if bootfs doesn't exist
  VOL_NAME="/Volumes/boot"
fi

if [ ! -d "$VOL_NAME" ]; then
  echo "Error: Could not find SD card boot volume at $VOL_NAME"
  echo "Please ensure SD card is inserted and mounted."
  exit 1
fi

echo "Found boot volume at: $VOL_NAME"

# 1. Create pinas directory
echo "Creating $VOL_NAME/pinas..."
mkdir -p "$VOL_NAME/pinas"

# 2. Copy scripts
echo "Copying installer scripts..."
cp "$REPO_ROOT/sbin/pinas-install.sh" "$VOL_NAME/pinas/"
cp "$REPO_ROOT/sbin/pinas-cache-deps.sh" "$VOL_NAME/pinas/"

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

echo "Done! You can now eject the SD card."
echo "The Pi will automatically install piNAS on first boot."
echo "Monitor progress on the TFT screen."

