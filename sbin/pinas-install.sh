#!/bin/bash
set -euo pipefail

# Detect boot mount used for FAT partition
BOOT_MNT=/boot/firmware
[ -d "$BOOT_MNT" ] || BOOT_MNT=/boot

LOG=/var/log/pinas-install.log
SD_LOG="$BOOT_MNT/pinas-install.log"

mkdir -p "$(dirname "$LOG")" || true

# Mirror all output to /var/log and boot partition so it is readable on another machine
exec > >(tee -a "$LOG" "$SD_LOG") 2>&1

echo "==== piNAS installer starting at $(date) ===="

APT_CACHE_DIR="$BOOT_MNT/pinas-apt"
PIP_CACHE_DIR="$BOOT_MNT/pinas-py"
PROGRESS_FILE="$BOOT_MNT/pinas-progress.json"
INSTALL_DIR="/usr/local/pinas"
AUTORUN_FLAG_DIR="/var/lib/pinas-installer"
AUTORUN_FLAG="$AUTORUN_FLAG_DIR/run-on-boot.flag"
AUTORUN_SERVICE="/etc/systemd/system/pinas-install-onboot.service"
CMDLINE_FILE="$BOOT_MNT/cmdline.txt"
[ -f "$CMDLINE_FILE" ] || CMDLINE_FILE="/boot/cmdline.txt"

ONLINE=0
if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
  ONLINE=1
fi

echo "Network online: $ONLINE (1=yes, 0=no)"
echo "APT cache dir: $APT_CACHE_DIR"
echo "Pip cache dir: $PIP_CACHE_DIR"
echo "Progress file: $PROGRESS_FILE"

# Guess main non-system user (first uid >= 1000, not nobody)
APP_USER="${APP_USER:-$(awk -F: '$3>=1000 && $1 != "nobody" {print $1; exit}' /etc/passwd || echo pi)}"
APP_GROUP="$APP_USER"
echo "Detected main user: $APP_USER"

declare -a STAGE_ORDER=()
declare -A STAGE_LABELS=()
declare -A STAGE_STATUS=()
declare -A STAGE_MESSAGE=()

add_stage() {
  local id="$1"
  local label="$2"
  STAGE_ORDER+=("$id")
  STAGE_LABELS["$id"]="$label"
}

add_stage init_display "Initialize TFT display"
add_stage packages "Install base packages"
add_stage usb_nas "Configure USB NAS"
add_stage dashboard "Deploy TFT dashboard"
add_stage usb_gadget "Configure USB gadget"
add_stage finalize "Finalize installation"

progress_write_file() {
  local tmp="${PROGRESS_FILE}.tmp"
  {
    for stage in "${STAGE_ORDER[@]}"; do
      printf '%s\t%s\t%s\t%s\n' \
        "$stage" \
        "${STAGE_LABELS[$stage]}" \
        "${STAGE_STATUS[$stage]}" \
        "${STAGE_MESSAGE[$stage]}"
    done
  } | python3 - "$PROGRESS_FILE" "$tmp" <<'PY'
import datetime
import json
import os
import shutil
import sys

path, tmp = sys.argv[1], sys.argv[2]
stages = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    stage_id, label, status, message = line.split("\t", 3)
    stages.append(
        {
            "id": stage_id,
            "label": label,
            "status": status,
            "message": message,
        }
    )

payload = {
    "updated": datetime.datetime.now().isoformat(),
    "stages": stages,
}

with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)

shutil.move(tmp, path)
PY
} || true

progress_render_console() {
  echo ""
  echo "piNAS installer progress:"
  for stage in "${STAGE_ORDER[@]}"; do
    local label="${STAGE_LABELS[$stage]}"
    local status="${STAGE_STATUS[$stage]}"
    local message="${STAGE_MESSAGE[$stage]}"
    local icon="[??]"
    case "$status" in
      pending) icon="[..]" ;;
      running) icon="[>>]" ;;
      done) icon="[OK]" ;;
      failed) icon="[!!]" ;;
    esac
    printf '  %s %-24s %s\n' "$icon" "$label" "$message"
  done
  echo ""
}

progress_flush() {
  progress_write_file
  progress_render_console
}

progress_update() {
  local stage="$1"
  local status="$2"
  shift 2 || true
  local message="${*:-}"
  STAGE_STATUS["$stage"]="$status"
  STAGE_MESSAGE["$stage"]="$message"
  progress_flush
}

progress_note() {
  local stage="$1"
  shift
  local message="$*"
  STAGE_MESSAGE["$stage"]="$message"
  progress_flush
}

progress_init() {
  for stage in "${STAGE_ORDER[@]}"; do
    STAGE_STATUS["$stage"]="pending"
    STAGE_MESSAGE["$stage"]="queued"
  done
  progress_flush
}

ensure_autorun_service() {
  mkdir -p "$AUTORUN_FLAG_DIR"
  cat >"$AUTORUN_SERVICE" <<'EOS'
[Unit]
Description=piNAS installer auto-run (scheduled)
ConditionPathExists=/var/lib/pinas-installer/run-on-boot.flag
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PINAS_AUTORUN=1
ExecStart=/usr/local/sbin/pinas-install.sh

[Install]
WantedBy=multi-user.target
EOS
  systemctl daemon-reload
  systemctl enable pinas-install-onboot.service >/dev/null 2>&1 || true
}

ensure_cmdline_modules() {
  if [ ! -f "$CMDLINE_FILE" ]; then
    return
  fi

  local contents
  contents="$(tr -d '\n' <"$CMDLINE_FILE")"

  if echo "$contents" | grep -q 'modules-load=.*dwc2'; then
    if echo "$contents" | grep -q 'modules-load=.*g_ether'; then
      return
    fi
  fi

  if echo "$contents" | grep -q 'modules-load='; then
    contents="$(echo "$contents" | sed 's/modules-load=[^ ]*/modules-load=dwc2,g_ether/')"
  else
    contents="$contents modules-load=dwc2,g_ether"
  fi

  printf "%s\n" "$contents" >"$CMDLINE_FILE"
}

schedule_autorun_next_boot() {
  mkdir -p "$AUTORUN_FLAG_DIR"
  touch "$AUTORUN_FLAG"
}

clear_autorun_flag() {
  rm -f "$AUTORUN_FLAG"
}

run_stage() {
  local stage="$1"
  shift
  local label="${STAGE_LABELS[$stage]}"
  local start_msg="Starting $label"
  progress_update "$stage" "running" "$start_msg"
  if "$@"; then
    local message="${STAGE_MESSAGE[$stage]}"
    if [ -z "$message" ] || [ "$message" = "$start_msg" ]; then
      message="$label complete"
    fi
    progress_update "$stage" "done" "$message"
  else
    progress_update "$stage" "failed" "$label failed"
    echo "Stage '$label' failed. See logs for details." >&2
    exit 1
  fi
}

progress_init
ensure_autorun_service
ensure_cmdline_modules

install_apt_pkgs() {
  local pkgs=("$@")

  if [ -d "$APT_CACHE_DIR" ] && ls "$APT_CACHE_DIR"/*.deb >/dev/null 2>&1; then
    echo "--- Installing APT packages from offline cache at $APT_CACHE_DIR ---"
    dpkg -i "$APT_CACHE_DIR"/*.deb || true
    if [ "$ONLINE" -eq 1 ]; then
      apt-get -f install -y
    else
      apt-get -f install -y || true
    fi
    return 0
  fi

  if [ "$ONLINE" -eq 1 ]; then
    echo "--- No cached .deb found; installing APT packages from network ---"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${pkgs[@]}"
    return 0
  fi

  echo "ERROR: offline and no cached APT packages in $APT_CACHE_DIR" >&2
  return 1
}

pip_install_offline_first() {
  local venv_bin="$1"; shift
  local pkgs=("$@")

  if [ -d "$PIP_CACHE_DIR" ] && ls "$PIP_CACHE_DIR"/*.whl >/dev/null 2>&1; then
    echo "--- Pip: installing from offline cache at $PIP_CACHE_DIR ---"
    "$venv_bin/pip" install --no-index --find-links="$PIP_CACHE_DIR" "${pkgs[@]}"
    return 0
  fi

  if [ "$ONLINE" -eq 1 ]; then
    echo "--- Pip: no cache found; installing from network ---"
    "$venv_bin/pip" install "${pkgs[@]}"
    return 0
  fi

  echo "ERROR: offline and no pip cache in $PIP_CACHE_DIR" >&2
  return 1
}

setup_install_display() {
  echo "--- Setting up venv + install-time TFT log viewer (XC9022) ---"
  progress_note init_display "Preparing dashboard virtualenv"

  mkdir -p /opt/pinas-dashboard

  # Always ensure build dependencies are present for Blinka/sysv_ipc
  progress_note init_display "Installing python3-dev/build deps"
  install_apt_pkgs python3-venv python3-pip python3-dev libjpeg-dev zlib1g-dev python3-setuptools python3-wheel gcc

  if ! python3 -m venv /opt/pinas-dashboard/.venv 2>/dev/null; then
    python3 -m venv /opt/pinas-dashboard/.venv
  fi

  /opt/pinas-dashboard/.venv/bin/pip install --upgrade pip setuptools wheel || true
  progress_note init_display "Installing display libraries"
  pip_install_offline_first "/opt/pinas-dashboard/.venv/bin" \
    adafruit-blinka adafruit-circuitpython-rgb-display pillow

  cat >/usr/local/sbin/pinas-install-display.py <<'EOPY'
#!/usr/bin/env python3
import json
import sys
import time
from typing import List

import board
import digitalio
from PIL import Image, ImageDraw, ImageFont
from adafruit_rgb_display import ili9341

LOG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/var/log/pinas-install.log"
PROGRESS_PATH = sys.argv[2] if len(sys.argv) > 2 else "/boot/pinas-progress.json"

TFT_CS = board.CE0
TFT_DC = board.D25
TFT_RST = None
BAUDRATE = 24_000_000

STATUS_COLORS = {
    "pending": (80, 80, 80),
    "running": (0, 180, 255),
    "done": (0, 200, 0),
    "failed": (255, 60, 60),
}


def init_display():
    spi = board.SPI()
    cs_pin = digitalio.DigitalInOut(TFT_CS)
    dc_pin = digitalio.DigitalInOut(TFT_DC)
    display = ili9341.ILI9341(
        spi,
        cs=cs_pin,
        dc=dc_pin,
        rst=TFT_RST,
        baudrate=BAUDRATE,
        rotation=270,
    )
    return display


def tail_lines(path: str, max_lines: int = 9, max_chars: int = 40) -> List[str]:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return ["waiting for log file..."]

    if not lines:
        return ["(log empty)"]

    out = []
    for line in lines[-max_lines:]:
        line = line.rstrip("\n\r")
        if len(line) > max_chars:
            line = line[-max_chars:]
        out.append(line)
    return out


def load_progress() -> List[str]:
    try:
        with open(PROGRESS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []

    lines: List[str] = []
    for stage in data.get("stages", []):
        label = stage.get("label", "")
        status = stage.get("status", "pending")
        message = stage.get("message", "")
        lines.append((label, status, message))
    return lines


def main():
    display = init_display()
    width = display.width
    height = display.height

    font = ImageFont.load_default()
    header = "piNAS install progress"

    while True:
        image = Image.new("RGB", (width, height))
        draw = ImageDraw.Draw(image)

        draw.rectangle((0, 0, width, height), fill=(0, 0, 0))

        draw.text((2, 0), header, font=font, fill=(0, 255, 0))

        y = 14
        for label, status, message in load_progress()[:6]:
            color = STATUS_COLORS.get(status, (200, 200, 200))
            text = f"{label}: {message}"
            draw.text((2, y), text[:35], font=font, fill=color)
            y += 12

        y += 4
        draw.text((2, y), "Installer log tail", font=font, fill=(0, 200, 200))
        y += 12

        lines = tail_lines(LOG_PATH, max_lines=10, max_chars=40)
        for line in lines:
            draw.text((2, y), line, font=font, fill=(200, 200, 200))
            y += 12
            if y > height - 10:
                break

        display.image(image)
        time.sleep(0.5)


if __name__ == "__main__":
    main()
EOPY

  chmod 755 /usr/local/sbin/pinas-install-display.py
  progress_note init_display "Launching install progress viewer"
  /opt/pinas-dashboard/.venv/bin/python /usr/local/sbin/pinas-install-display.py "$LOG" "$PROGRESS_FILE" >/dev/null 2>&1 &
  echo "Started install log viewer on XC9022 TFT"
}

setup_usb_nas() {
  echo "--- Setting up USB auto-mount + Samba NAS ---"
  progress_note usb_nas "Configuring Samba + auto-mount rules"
  local MOUNT_ROOT="/srv/usb-shares"
  mkdir -p "$MOUNT_ROOT"
  chown "$APP_USER":"$APP_GROUP" "$MOUNT_ROOT"

  if [ -f /etc/samba/smb.conf ] && [ ! -f /etc/samba/smb.conf.pinas.bak ]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.pinas.bak
  fi

  cat >/etc/samba/smb.conf <<'EOSMB'
[global]
   workgroup = WORKGROUP
   server string = piNAS
   
   # Guest access configuration
   security = user
   map to guest = Bad User
   guest account = nobody
   usershare allow guests = yes
   restrict anonymous = 0
   
   # Logging
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   log level = 2

   # Server configuration
   server role = standalone server
   local master = yes
   preferred master = yes
   os level = 20
   
   # Disable unnecessary features
   load printers = no
   disable spoolss = yes
   printing = bsd
   printcap name = /dev/null
   show add printer wizard = no
   
   # Performance and compatibility
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=65536 SO_SNDBUF=65536
   use sendfile = yes
   aio read size = 16384
   aio write size = 16384
   
   # macOS compatibility
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   
   # Windows compatibility
   acl compatibility = auto
   ea support = yes
   store dos attributes = no
   map hidden = no
   map system = no
   map archive = no
   map readonly = no
   
   # Character encoding
   unix charset = UTF-8
   display charset = UTF-8

   include = /etc/samba/usb-shares.conf
EOSMB

  touch /etc/samba/usb-shares.conf
  chown root:root /etc/samba/usb-shares.conf
  chmod 644 /etc/samba/usb-shares.conf

  cat >/usr/local/sbin/usb-autoshare <<'EOUSB'
#!/bin/bash
set -euo pipefail

ACTION="${1:-}"
DEVNAME="${2:-}"

if [ -z "$ACTION" ] || [ -z "$DEVNAME" ]; then
  exit 0
fi

DEVPATH="/dev/$DEVNAME"
MOUNT_ROOT="/srv/usb-shares"
USB_CONF="/etc/samba/usb-shares.conf"

SHARE_USER="__APP_USER__"
SHARE_GROUP="$SHARE_USER"
SHARE_UID="$(id -u "$SHARE_USER" 2>/dev/null || echo 1000)"
SHARE_GID="$(id -g "$SHARE_GROUP" 2>/dev/null || echo 1000)"

log() {
  echo "$(date -Iseconds) usb-autoshare $*" >> /var/log/usb-autoshare.log
}

mkdir -p "$MOUNT_ROOT"

case "$ACTION" in
  add)
    case "$DEVNAME" in
      *[0-9]) ;;
      *)
        log "ignoring non-partition $DEVNAME"
        exit 0
        ;;
    esac

    # Get filesystem info
    FS_TYPE="$(blkid -o value -s TYPE "$DEVPATH" 2>/dev/null || true)"
    LABEL="$(blkid -o value -s LABEL "$DEVPATH" 2>/dev/null || true)"
    
    # Skip EFI system partitions and other system filesystems
    case "$FS_TYPE" in
      "")
        log "unknown filesystem type for $DEVPATH, skipping"
        exit 0
        ;;
      swap)
        log "ignoring swap partition $DEVPATH"
        exit 0
        ;;
    esac
    
    # Skip EFI partitions based on label or filesystem
    if [ "$LABEL" = "EFI" ] || [ "$FS_TYPE" = "vfat" ]; then
      # For FAT filesystems, check if it's really an EFI partition
      if [ "$LABEL" = "EFI" ] || [ "$(echo "$DEVNAME" | grep -E 'p1$|s1$')" ]; then
        # Check if it contains EFI directory structure
        TEMP_MOUNT="$(mktemp -d)"
        if mount "$DEVPATH" "$TEMP_MOUNT" 2>/dev/null; then
          if [ -d "$TEMP_MOUNT/EFI" ] && [ -z "$(find "$TEMP_MOUNT" -maxdepth 1 -type f -name '*.txt' -o -name '*.doc*' -o -name '*.pdf' 2>/dev/null)" ]; then
            umount "$TEMP_MOUNT"
            rmdir "$TEMP_MOUNT"
            log "ignoring EFI system partition $DEVPATH"
            exit 0
          fi
          umount "$TEMP_MOUNT"
        fi
        rmdir "$TEMP_MOUNT"
      fi
    fi
    
    # Determine user-friendly share name
    if [ -n "$LABEL" ] && [ "$LABEL" != "EFI" ]; then
      SHARE_LABEL="$LABEL"
    else
      # Try to determine a friendly name based on device and filesystem
      case "$FS_TYPE" in
        ext*|btrfs|xfs)
          SHARE_LABEL="Linux-Drive-${DEVNAME#sd}"
          ;;
        ntfs|exfat)
          SHARE_LABEL="Windows-Drive-${DEVNAME#sd}"
          ;;
        vfat)
          SHARE_LABEL="USB-Drive-${DEVNAME#sd}"
          ;;
        *)
          SHARE_LABEL="Drive-${DEVNAME#sd}"
          ;;
      esac
    fi
    
    # Create safe directory name (preserve more characters, handle duplicates)
    SAFE_LABEL="$(echo "$SHARE_LABEL" | sed 's/[^A-Za-z0-9._-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')"
    
    # Handle empty labels
    if [ -z "$SAFE_LABEL" ]; then
      SAFE_LABEL="USB-${DEVNAME#sd}"
    fi
    
    # Handle duplicate mount points
    ORIGINAL_LABEL="$SAFE_LABEL"
    COUNTER=1
    MOUNT_POINT="$MOUNT_ROOT/$SAFE_LABEL"
    while [ -d "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT"; do
      SAFE_LABEL="${ORIGINAL_LABEL}-${COUNTER}"
      MOUNT_POINT="$MOUNT_ROOT/$SAFE_LABEL"
      COUNTER=$((COUNTER + 1))
    done
    
    mkdir -p "$MOUNT_POINT"
    log "mounting $DEVPATH ($FS_TYPE, label: '$LABEL') as '$SAFE_LABEL'"

    if ! mountpoint -q "$MOUNT_POINT"; then
      # Mount with appropriate options based on filesystem type
      MOUNT_OPTS="uid=$SHARE_UID,gid=$SHARE_GID,umask=000"
      
      case "$FS_TYPE" in
        vfat|msdos)
          MOUNT_OPTS="$MOUNT_OPTS,iocharset=utf8,shortname=mixed"
          ;;
        ntfs)
          MOUNT_OPTS="$MOUNT_OPTS,windows_names,locale=en_US.UTF-8"
          ;;
        exfat)
          MOUNT_OPTS="$MOUNT_OPTS,iocharset=utf8"
          ;;
        ext*|btrfs|xfs)
          # For Linux filesystems, use different approach
          if ! mount "$DEVPATH" "$MOUNT_POINT" 2>>/var/log/usb-autoshare.log; then
            log "failed to mount $DEVPATH on $MOUNT_POINT"
            rmdir "$MOUNT_POINT" || true
            exit 1
          fi
          # Set ownership after mounting
          chown -R "$SHARE_UID:$SHARE_GID" "$MOUNT_POINT" 2>/dev/null || true
          chmod -R 755 "$MOUNT_POINT" 2>/dev/null || true
          log "mounted $DEVPATH on $MOUNT_POINT (Linux filesystem)"
          exit 0
          ;;
      esac
      
      if ! mount -o "$MOUNT_OPTS" "$DEVPATH" "$MOUNT_POINT" 2>>/var/log/usb-autoshare.log; then
        log "failed to mount $DEVPATH on $MOUNT_POINT with options: $MOUNT_OPTS"
        rmdir "$MOUNT_POINT" || true
        exit 1
      fi
      log "mounted $DEVPATH on $MOUNT_POINT with options: $MOUNT_OPTS"
    fi
    ;;
  remove)
    umount "$DEVPATH" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac

TMP="$(mktemp)"
echo "# auto-generated by usb-autoshare, do not edit by hand" > "$TMP"

# Generate share configuration for each mounted USB device
grep " $MOUNT_ROOT/" /proc/mounts | while read -r dev mp rest; do
  NAME="$(basename "$mp")"
  SHARE_NAME="$(echo "$NAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9._-')"
  
  # Get filesystem type for the device
  DEV_FS_TYPE="$(findmnt -n -o FSTYPE "$mp" 2>/dev/null || echo unknown)"
  
  {
    echo
    echo "[$SHARE_NAME]"
    echo "  comment = USB drive: $NAME ($DEV_FS_TYPE)"
    echo "  path = $mp"
    echo "  browseable = yes"
    echo "  read only = no"
    echo "  guest ok = yes"
    echo "  guest only = yes"
    echo "  public = yes"
    echo "  writeable = yes"
    echo "  create mask = 0666"
    echo "  directory mask = 0777"
    echo "  force create mode = 0666"
    echo "  force directory mode = 0777"
    echo "  force user = $SHARE_USER"
    echo "  force group = $SHARE_GROUP"
    echo "  inherit permissions = no"
    echo "  inherit acls = no"
    echo "  map archive = no"
    echo "  map hidden = no"
    echo "  map readonly = no"
    echo "  map system = no"
    echo "  store dos attributes = no"
    
    # Add filesystem-specific options
    case "$DEV_FS_TYPE" in
      vfat|msdos|ntfs|exfat)
        echo "  delete readonly = yes"
        echo "  dos filemode = yes"
        ;;
      ext*|btrfs|xfs)
        echo "  unix extensions = no"
        ;;
    esac
  } >>"$TMP"
done

mv "$TMP" "$USB_CONF"
chown root:root "$USB_CONF"
chmod 644 "$USB_CONF"

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet smbd; then
    systemctl reload smbd || systemctl restart smbd || true
  fi
fi
EOUSB

  sed -i "s/__APP_USER__/$APP_USER/g" /usr/local/sbin/usb-autoshare
  chmod 755 /usr/local/sbin/usb-autoshare

  cat >/etc/udev/rules.d/99-usb-autoshare.rules <<'EOUDEV'
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd*[0-9]", ENV{ID_BUS}=="usb", RUN+="/usr/bin/systemd-run -r /usr/local/sbin/usb-autoshare add %k"
ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd*[0-9]", ENV{ID_BUS}=="usb", RUN+="/usr/bin/systemd-run -r /usr/local/sbin/usb-autoshare remove %k"
EOUDEV

  udevadm control --reload || true
  udevadm trigger --subsystem-match=block || true

  systemctl enable --now smbd nmbd || true
  progress_note usb_nas "USB auto-share ready"
}

setup_dashboard() {
  echo "--- Setting up XC9022 TFT NAS dashboard ---"
  progress_note dashboard "Installing dashboard dependencies"

  pip_install_offline_first "/opt/pinas-dashboard/.venv/bin" \
    adafruit-circuitpython-stmpe610 psutil

  cat >/opt/pinas-dashboard/nas_dashboard.py <<'EOPY2'
#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import time
import urllib.request
from collections import deque
from datetime import datetime
from typing import Dict, List, Optional, Tuple

import psutil
from PIL import Image, ImageDraw, ImageFont

import board
import digitalio
from adafruit_rgb_display import ili9341, color565
try:
    import adafruit_stmpe610
except ImportError:
    adafruit_stmpe610 = None
try:
    import adafruit_xpt2046
except ImportError:
    adafruit_xpt2046 = None

MOUNT_ROOT = "/srv/usb-shares"

TFT_CS = board.CE0
TFT_DC = board.D25
TFT_RST = None

TOUCH_CS = board.CE1
TOUCH_IRQ = board.D24

BAUDRATE = 24_000_000
UPDATE_INTERVAL = 1.0

HOSTNAME = socket.gethostname()


def init_touch_controller(spi):
    """Attempt to initialize STMPE610 first, then fall back to XPT2046."""
    touch = None
    driver = None

    if adafruit_stmpe610 is not None:
        try:
            touch_cs = digitalio.DigitalInOut(TOUCH_CS)
            touch_cs.switch_to_output(value=True)
            touch = adafruit_stmpe610.Adafruit_STMPE610_SPI(
                spi, cs=touch_cs, baudrate=1_000_000
            )
            driver = "stmpe610"
        except Exception:
            touch = None

    if touch is None and adafruit_xpt2046 is not None:
        try:
            touch_cs = digitalio.DigitalInOut(TOUCH_CS)
            touch = adafruit_xpt2046.XPT2046(spi, cs=touch_cs, baudrate=2_000_000)
            driver = "xpt2046"
        except Exception:
            touch = None

    return touch, driver


def init_display_and_touch():
    spi = board.SPI()

    dc_pin = digitalio.DigitalInOut(TFT_DC)
    cs_pin = digitalio.DigitalInOut(TFT_CS)

    display = ili9341.ILI9341(
        spi,
        cs=cs_pin,
        dc=dc_pin,
        rst=TFT_RST,
        baudrate=BAUDRATE,
        rotation=270,
    )

    ts, driver = init_touch_controller(spi)

    return display, ts, driver


def linear_map(value: int, in_min: int, in_max: int, out_min: int, out_max: int) -> int:
    if in_max == in_min:
        return out_min
    ratio = (value - in_min) / (in_max - in_min)
    return int(out_min + ratio * (out_max - out_min))


def map_touch(ts, rotation=270, driver=None):
    """Read raw touch, apply calibration, and map to screen coordinates."""
    if ts is None:
        return None

    try:
        if hasattr(ts, "touched"):
            if not ts.touched:
                return None
        elif hasattr(ts, "tirq_touched"):
            if not ts.tirq_touched():
                return None

        p = ts.touch_point
        if p is None:
            return None

        x_raw, y_raw, *_ = p
        WIDTH, HEIGHT = 320, 240

        if driver == "xpt2046" and rotation == 270:
            screen_x = linear_map(y_raw, 143, 3715, 0, WIDTH - 1)
            screen_y = linear_map(x_raw, 3786, 216, 0, HEIGHT - 1)
            screen_x = max(0, min(WIDTH - 1, screen_x))
            screen_y = max(0, min(HEIGHT - 1, screen_y))
            return (screen_x, screen_y)

        MIN_X, MAX_X = 200, 3800
        MIN_Y, MAX_Y = 200, 3800

        x_raw = max(MIN_X, min(x_raw, MAX_X))
        y_raw = max(MIN_Y, min(y_raw, MAX_Y))

        x_norm = (x_raw - MIN_X) / (MAX_X - MIN_X)
        y_norm = (y_raw - MIN_Y) / (MAX_Y - MIN_Y)

        if rotation == 270:
            screen_x = int(y_norm * WIDTH)
            screen_y = int((1.0 - x_norm) * HEIGHT)
            return (screen_x, screen_y)
        elif rotation == 90:
            screen_x = int((1.0 - y_norm) * WIDTH)
            screen_y = int(x_norm * HEIGHT)
            return (screen_x, screen_y)
        elif rotation == 0:
            screen_x = int(x_norm * 240)
            screen_y = int(y_norm * 320)
            return (screen_x, screen_y)

        return (0, 0)

    except Exception:
        return None


def load_fonts():
    try:
        font_big = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 24
        )
        font_medium = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18
        )
        font_small = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 14
        )
    except OSError:
        font_big = ImageFont.load_default()
        font_medium = ImageFont.load_default()
        font_small = ImageFont.load_default()
    return font_big, font_medium, font_small


def get_cpu_temp_c() -> Optional[float]:
    try:
        temps = psutil.sensors_temperatures()
        if temps:
            for entries in temps.values():
                if entries:
                    return entries[0].current
    except Exception:
        pass

    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r", encoding="utf-8") as f:
            milli = int(f.read().strip())
        return milli / 1000.0
    except Exception:
        return None


def get_primary_iface() -> Optional[str]:
    stats = psutil.net_if_stats()
    for name in ("eth0", "enp0s31f6", "wlan0"):
        if name in stats and stats[name].isup:
            return name
    for name, st in stats.items():
        if st.isup:
            return name
    return None


def get_usb_mounts() -> List[str]:
    mounts: List[str] = []
    if not os.path.isdir(MOUNT_ROOT):
        return mounts
    try:
        with open("/proc/mounts", "r", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 2:
                    continue
                mp = parts[1]
                if mp.startswith(MOUNT_ROOT + "/"):
                    mounts.append(mp)
    except Exception:
        pass
    return sorted(mounts)


def format_bytes(num_bytes: float) -> str:
    units = ["B", "KB", "MB", "GB"]
    value = float(num_bytes)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            if value >= 100:
                return f"{value:4.0f}{unit}"
            return f"{value:4.1f}{unit}"
        value /= 1024.0
    return f"{value:.1f}TB"


def sample_net_rates(
    iface: Optional[str], prev: Optional[Tuple[int, int, float]]
) -> Tuple[Optional[Tuple[int, int, float]], float, float]:
    if iface is None:
        return prev, 0.0, 0.0

    counters = psutil.net_io_counters(pernic=True).get(iface)
    now = time.monotonic()
    if counters is None:
        return prev, 0.0, 0.0

    rx = counters.bytes_recv
    tx = counters.bytes_sent

    if prev is None:
        return (rx, tx, now), 0.0, 0.0

    prev_rx, prev_tx, prev_t = prev
    dt = max(now - prev_t, 1e-3)
    rx_rate = (rx - prev_rx) / dt
    tx_rate = (tx - prev_tx) / dt

    return (rx, tx, now), rx_rate, tx_rate


def draw_dashboard(
    draw,
    width,
    height,
    font_big,
    font_medium,
    font_small,
    show_details: bool,
    iface: Optional[str],
    rx_bps: float,
    tx_bps: float,
):
    draw.rectangle((0, 0, width, height), fill=(0, 0, 0))

    y = 0

    now = datetime.now().strftime("%H:%M:%S")
    header = f"{HOSTNAME}  {now}"
    draw.text((4, y), header, font=font_small, fill=(0, 255, 255))
    y += 20

    cpu_percent = psutil.cpu_percent(interval=None)
    temp_c = get_cpu_temp_c()
    if temp_c is not None:
        cpu_line = f"CPU {cpu_percent:4.1f}%  {temp_c:4.1f}C"
    else:
        cpu_line = f"CPU {cpu_percent:4.1f}%"
    draw.text((4, y), cpu_line, font=font_medium, fill=(255, 255, 0))
    y += 22

    mem = psutil.virtual_memory()
    mem_line = f"RAM {mem.used // (1024**2):4d}/{mem.total // (1024**2):4d}MB {mem.percent:4.0f}%"
    draw.text((4, y), mem_line, font=font_medium, fill=(0, 255, 0))
    y += 22

    if iface:
        rx_txt = format_bytes(rx_bps) + "/s"
        tx_txt = format_bytes(tx_bps) + "/s"
        net_line1 = f"NET {iface}"
        net_line2 = f"RX {rx_txt}  TX {tx_txt}"
        draw.text((4, y), net_line1, font=font_medium, fill=(0, 128, 255))
        y += 20
        draw.text((4, y), net_line2, font=font_medium, fill=(0, 128, 255))
        y += 22
    else:
        draw.text((4, y), "NET down", font=font_medium, fill=(255, 0, 0))
        y += 22

    mounts = get_usb_mounts()
    if not mounts:
        draw.text(
            (4, y),
            "USB: NO DEVICES",
            font=font_medium,
            fill=(255, 0, 0),
        )
        y += 20
    else:
        draw.text(
            (4, y),
            f"USB shares: {len(mounts)}",
            font=font_medium,
            fill=(255, 255, 255),
        )
        y += 20

        for mp in mounts[:3]:
            try:
                du = psutil.disk_usage(mp)
            except Exception:
                continue
            name = os.path.basename(mp) or mp.rsplit("/", 1)[-1]
            used_pct = du.percent
            free_gb = du.free / (1024**3)
            line1 = f"{name[:14]:14s} {used_pct:5.1f}%"
            line2 = f"free {free_gb:4.1f}GB"
            draw.text((4, y), line1, font=font_small, fill=(200, 200, 200))
            y += 16
            draw.text((12, y), line2, font=font_small, fill=(160, 160, 160))
            y += 16

    if show_details:
        footer = "Touch: toggle compact view"
    else:
        footer = "Touch: toggle detail view"
    draw.text(
        (4, height - 18),
        footer,
        font=font_small,
        fill=(128, 128, 255),
    )


def main():
    display, ts, touch_driver = init_display_and_touch()
    font_big, font_medium, font_small = load_fonts()

    hw_width = display.width
    hw_height = display.height
    rotate_output = hw_width < hw_height
    logical_width = 320
    logical_height = 240

    display_model = "XPT2046" if touch_driver == "xpt2046" else "XC9022"
    if touch_driver is None:
        print("Touch controller not detected; dashboard touch input disabled")
    else:
        print(f"Touch controller detected: {touch_driver}")
    print(
        f"Dashboard configured for {display_model}, framebuffer {hw_width}x{hw_height}, rotate_output={rotate_output}"
    )

    width = logical_width
    height = logical_height
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)

    iface = get_primary_iface()
    prev_net = None

    show_details = False
    last_touch = 0.0

    display.fill(color565(0, 0, 0))

    while True:
        try:
            touch = map_touch(ts, rotation=270, driver=touch_driver)
            if touch:
                now = time.monotonic()
                if now - last_touch > 0.5:
                    show_details = not show_details
                    last_touch = now
        except Exception:
            pass

        prev_net, rx_bps, tx_bps = sample_net_rates(iface, prev_net)

        draw_dashboard(
            draw,
            width,
            height,
            font_big,
            font_medium,
            font_small,
            show_details,
            iface,
            rx_bps,
            tx_bps,
        )

        output_image = image.transpose(Image.ROTATE_90) if rotate_output else image
        display.image(output_image)

        time.sleep(UPDATE_INTERVAL)


if __name__ == "__main__":
    main()
EOPY2

  chmod 755 /opt/pinas-dashboard/nas_dashboard.py

  usermod -aG gpio,spi,i2c "$APP_USER" || true
  chown -R "$APP_USER":"$APP_GROUP" /opt/pinas-dashboard || true

  cat >/etc/systemd/system/pinas-dashboard.service <<'EOSVC'
[Unit]
Description=piNAS XC9022 TFT Dashboard
After=multi-user.target

[Service]
Type=simple
User=__APP_USER__
Group=__APP_USER__
WorkingDirectory=/opt/pinas-dashboard
ExecStart=/opt/pinas-dashboard/.venv/bin/python /opt/pinas-dashboard/nas_dashboard.py
Restart=always

[Install]
WantedBy=multi-user.target
EOSVC

  sed -i "s/__APP_USER__/$APP_USER/g" /etc/systemd/system/pinas-dashboard.service
  systemctl daemon-reload
  systemctl enable pinas-dashboard.service || true
  progress_note dashboard "Dashboard service enabled"
}

setup_usb_gadget() {
  echo "--- Setting up USB mass-storage gadget ---"
  progress_note usb_gadget "Updating config.txt and gadget services"

  local CONFIG_TXT="$BOOT_MNT/config.txt"
  if [ ! -f "$CONFIG_TXT" ]; then
    CONFIG_TXT="/boot/config.txt"
  fi

  if [ -f "$CONFIG_TXT" ]; then
    if grep -q '^dtoverlay=dwc2' "$CONFIG_TXT"; then
      sed -i 's/^dtoverlay=dwc2.*/dtoverlay=dwc2,dr_mode=peripheral/' "$CONFIG_TXT"
    else
      echo 'dtoverlay=dwc2,dr_mode=peripheral' >>"$CONFIG_TXT"
    fi

    if grep -q '^#dtparam=spi=on' "$CONFIG_TXT"; then
      sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' "$CONFIG_TXT"
    elif ! grep -q '^dtparam=spi=on' "$CONFIG_TXT"; then
      echo 'dtparam=spi=on' >>"$CONFIG_TXT"
    fi

    if grep -q '^#dtparam=i2c_arm=on' "$CONFIG_TXT"; then
      sed -i 's/^#dtparam=i2c_arm=on/dtparam=i2c_arm=on/' "$CONFIG_TXT"
    elif ! grep -q '^dtparam=i2c_arm=on' "$CONFIG_TXT"; then
      echo 'dtparam=i2c_arm=on' >>"$CONFIG_TXT"
    fi
  fi

  echo "libcomposite" >/etc/modules-load.d/usb-gadget.conf

  mkdir -p /srv/usb-gadget

  cat >/usr/local/sbin/create-pinas-backfile.sh <<'EOBF'
#!/bin/bash
set -euo pipefail

BACKING_DIR=/srv/usb-gadget
BACKING_FILE="$BACKING_DIR/pinas-gadget.img"
RESERVE_BYTES=$((2 * 1024 * 1024 * 1024))

if [ -f "$BACKING_FILE" ]; then
  echo "backing file already exists at $BACKING_FILE"
  exit 0
fi

mkdir -p "$BACKING_DIR"

FREE_BYTES=$(df -B1 / | awk 'NR==2 {print $4}')

if [ "$FREE_BYTES" -le "$RESERVE_BYTES" ]; then
  echo "not enough free space on / to create backing file" >&2
  exit 1
fi

SIZE_BYTES=$((FREE_BYTES - RESERVE_BYTES))
SIZE_MIB=$((SIZE_BYTES / (1024 * 1024)))

if [ "$SIZE_MIB" -lt 512 ]; then
  echo "backing file would be smaller than 512MiB; aborting" >&2
  exit 1
fi

echo "creating sparse backing file of ${SIZE_MIB}MiB at $BACKING_FILE"
dd if=/dev/zero of="$BACKING_FILE" bs=1M count=0 seek="$SIZE_MIB"

echo "backing file created; format it from the host when first connected"
EOBF

  chmod 755 /usr/local/sbin/create-pinas-backfile.sh

  cat >/usr/local/sbin/pinas-usb-gadget-start.sh <<'EOGS'
#!/bin/bash
set -euo pipefail

BACKING_FILE=/srv/usb-gadget/pinas-gadget.img
GADGET_NAME=pinas

CONFIGFS_ROOT=$(findmnt -o TARGET -n configfs || true)
if [ -z "$CONFIGFS_ROOT" ] && [ -d /sys/kernel/config ]; then
  CONFIGFS_ROOT="/sys/kernel/config"
fi
if [ -z "$CONFIGFS_ROOT" ]; then
  mount -t configfs configfs /sys/kernel/config
  CONFIGFS_ROOT="/sys/kernel/config"
fi

if [ ! -f "$BACKING_FILE" ]; then
  echo "backing file $BACKING_FILE not found" >&2
  exit 1
fi

GADGET_DIR="$CONFIGFS_ROOT/usb_gadget/$GADGET_NAME"

if [ -d "$GADGET_DIR" ]; then
  echo "USB gadget already configured"
  exit 0
fi

modprobe libcomposite || true

mkdir -p "$GADGET_DIR"
cd "$GADGET_DIR"

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
SERIAL="$(sha256sum < /etc/machine-id | awk '{print $1}')"
echo "piNAS-$SERIAL" > strings/0x409/serialnumber
echo "piNAS" > strings/0x409/manufacturer
echo "piNAS Composite Gadget" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "Mass Storage" > configs/c.1/strings/0x409/configuration

MAX_POWER=250
if grep -q "Raspberry Pi 5" /sys/firmware/devicetree/base/model 2>/dev/null; then
  MAX_POWER=600
elif grep -q "Raspberry Pi 4" /sys/firmware/devicetree/base/model 2>/dev/null; then
  MAX_POWER=500
fi
echo $MAX_POWER > configs/c.1/MaxPower

mkdir -p functions/mass_storage.usb0
echo 0 > functions/mass_storage.usb0/stall
echo 0 > functions/mass_storage.usb0/lun.0/removable
echo 0 > functions/mass_storage.usb0/lun.0/ro
echo "$BACKING_FILE" > functions/mass_storage.usb0/lun.0/file

ln -sf functions/mass_storage.usb0 configs/c.1/

UDC_NAME=$(ls /sys/class/udc 2>/dev/null | head -n1 || true)
if [ -z "$UDC_NAME" ]; then
  echo "no UDC found in /sys/class/udc; ensure dwc2/g_ether modules load at boot and hardware supports device mode" >&2
  exit 1
fi

echo "$UDC_NAME" > UDC
echo "USB mass storage gadget started on UDC $UDC_NAME"
EOGS

  chmod 755 /usr/local/sbin/pinas-usb-gadget-start.sh

  cat >/usr/local/sbin/pinas-usb-gadget-stop.sh <<'EOGX'
#!/bin/bash
set -euo pipefail

CONFIGFS_ROOT=$(findmnt -o TARGET -n configfs || true)
GADGET_NAME=pinas
GADGET_DIR=

if [ -n "$CONFIGFS_ROOT" ] && [ -d "$CONFIGFS_ROOT/usb_gadget/$GADGET_NAME" ]; then
  GADGET_DIR="$CONFIGFS_ROOT/usb_gadget/$GADGET_NAME"
fi

if [ -z "$GADGET_DIR" ]; then
  echo "gadget $GADGET_NAME not present"
  exit 0
fi

cd "$GADGET_DIR"

if [ -f UDC ]; then
  echo "" > UDC || true
fi

if [ -L configs/c.1/mass_storage.usb0 ]; then
  rm configs/c.1/mass_storage.usb0
fi

if [ -d functions/mass_storage.usb0 ]; then
  rmdir functions/mass_storage.usb0
fi

find configs -type d -mindepth 1 -maxdepth 2 -empty -delete || true
find strings -type d -mindepth 1 -maxdepth 2 -empty -delete || true

cd "$CONFIGFS_ROOT/usb_gadget"
rmdir "$GADGET_NAME" || true

echo "USB mass storage gadget stopped"
EOGX

  chmod 755 /usr/local/sbin/pinas-usb-gadget-stop.sh

  cat >/etc/systemd/system/pinas-usb-gadget.service <<'EOSG'
[Unit]
Description=piNAS USB Mass Storage Gadget
After=local-fs.target
Requires=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/create-pinas-backfile.sh
ExecStart=/usr/local/sbin/pinas-usb-gadget-start.sh
ExecStop=/usr/local/sbin/pinas-usb-gadget-stop.sh

[Install]
WantedBy=multi-user.target
EOSG

  systemctl daemon-reload
  systemctl enable --now pinas-usb-gadget.service || true
  progress_note usb_gadget "USB gadget service enabled"
}

install_packages() {
  echo "--- Installing piNAS APT packages (offline-first) ---"
  progress_note packages "Installing cached APT packages if available"
  NAS_APT_PKGS=(
    samba ntfs-3g exfat-fuse exfatprogs
    python3-venv python3-pip python3-dev libjpeg-dev zlib1g-dev
    i2c-tools libgpiod-dev python3-libgpiod
  )
  install_apt_pkgs "${NAS_APT_PKGS[@]}"
}

finalize_install() {
  echo "--- Finalizing piNAS installation ---"
  progress_note finalize "Installing update system"
  
  # Install update script if available
  if [ -f "$INSTALL_DIR/sbin/pinas-update.sh" ]; then
    echo "Installing update system..."
    cp "$INSTALL_DIR/sbin/pinas-update.sh" /usr/local/sbin/
    chmod +x /usr/local/sbin/pinas-update.sh
    
    # Install auto-update service and timer if available
    if [ -f "$INSTALL_DIR/docs/pinas-auto-update.service" ] && [ -f "$INSTALL_DIR/docs/pinas-auto-update.timer" ]; then
      cp "$INSTALL_DIR/docs/pinas-auto-update.service" /etc/systemd/system/
      cp "$INSTALL_DIR/docs/pinas-auto-update.timer" /etc/systemd/system/
      
      systemctl daemon-reload
      systemctl enable pinas-auto-update.timer || true
      systemctl start pinas-auto-update.timer || true
      echo "Auto-update service enabled (daily at 3 AM)"
    fi
    
    # Create version file if it doesn't exist
    if [ ! -f "$INSTALL_DIR/VERSION" ]; then
      # Generate date-based version for local installs
      DATE_VERSION="v$(date -u +%Y.%m.%d)"
      BUILD_TIME="$(date -u +%H%M)"
      echo "${DATE_VERSION}.${BUILD_TIME}" > "$INSTALL_DIR/VERSION"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$INSTALL_DIR/BUILD_DATE"
      echo "local-install" > "$INSTALL_DIR/BUILD_SOURCE"
    fi
  fi
  
  progress_note finalize "Switching to permanent dashboard"

  # Kill temporary viewer to release SPI bus
  pkill -f pinas-install-display.py 2>/dev/null || true

  # Start permanent dashboard
  systemctl start pinas-dashboard.service || true

  local tries=0
  while [ $tries -lt 30 ]; do
    if systemctl is-active --quiet pinas-dashboard.service; then
      echo "Dashboard service active"
      break
    fi
    sleep 1
    tries=$((tries + 1))
  done
}

# Main execution sequence
run_stage init_display setup_install_display
run_stage packages install_packages
run_stage usb_nas setup_usb_nas
run_stage dashboard setup_dashboard
run_stage usb_gadget setup_usb_gadget
run_stage finalize finalize_install

echo "==== piNAS installer finished at $(date) ===="

if [ "${PINAS_AUTORUN:-0}" = "1" ]; then
  clear_autorun_flag
  echo "Automatic post-reboot installer run complete; system will reboot once more to finalize device mode."
  systemctl reboot
  exit 0
fi

schedule_autorun_next_boot
echo "Installer will automatically run again on the next boot to apply kernel/device changes, then reboot once more when finished."
echo "Please reboot now to allow the scheduled run to proceed."
exit 0
