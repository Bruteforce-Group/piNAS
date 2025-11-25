#!/bin/bash
set -euo pipefail

BOOT_MNT=/boot/firmware
[ -d "$BOOT_MNT" ] || BOOT_MNT=/boot

APT_CACHE_DIR="$BOOT_MNT/pinas-apt"
PIP_CACHE_DIR="$BOOT_MNT/pinas-py"

NAS_APT_PKGS=(
  samba ntfs-3g exfat-fuse exfatprogs
  python3-venv python3-pip python3-dev libjpeg-dev zlib1g-dev
  i2c-tools libgpiod-dev python3-libgpiod
)

PY_PKGS_BASE=(
  adafruit-blinka
  adafruit-circuitpython-rgb-display
  pillow
)
PY_PKGS_EXTRA=(
  adafruit-circuitpython-stmpe610
  psutil
)

echo "Boot mount: $BOOT_MNT"
echo "APT cache dir: $APT_CACHE_DIR"
echo "Pip cache dir: $PIP_CACHE_DIR"

mkdir -p "$APT_CACHE_DIR" "$PIP_CACHE_DIR"

export DEBIAN_FRONTEND=noninteractive

echo "--- APT: updating and installing required packages ---"
apt-get update
apt-get install -y "${NAS_APT_PKGS[@]}"

echo "--- APT: copying .deb files into $APT_CACHE_DIR ---"
cp -u /var/cache/apt/archives/*.deb "$APT_CACHE_DIR"/ || true

echo "--- Pip: creating temp venv for downloading wheels ---"
TMP_VENV=/tmp/pinas-cache-venv
python3 -m venv "$TMP_VENV"
"$TMP_VENV/bin/pip" install --upgrade pip

echo "--- Pip: downloading wheels into $PIP_CACHE_DIR ---"
"$TMP_VENV/bin/pip" download -d "$PIP_CACHE_DIR" "${PY_PKGS_BASE[@]}" "${PY_PKGS_EXTRA[@]}"

echo "--- Cleanup temp venv ---"
rm -rf "$TMP_VENV"

echo "Done. Offline caches under:"
echo "  $APT_CACHE_DIR"
echo "  $PIP_CACHE_DIR"
