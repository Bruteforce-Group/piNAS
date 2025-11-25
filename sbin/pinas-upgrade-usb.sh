#!/bin/bash
set -euo pipefail

# piNAS USB Auto-Share Upgrade Script
# Upgrades existing piNAS installations with improved USB sharing
# Fixes EFI partition detection and guest write permissions

echo "==== piNAS USB Auto-Share Upgrade Starting at $(date) ===="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

# Detect the main user
APP_USER="${APP_USER:-$(awk -F: '$3>=1000 && $1 != "nobody" {print $1; exit}' /etc/passwd || echo pi)}"
APP_GROUP="$APP_USER"
echo "Detected main user: $APP_USER"

# Backup existing configuration
echo "Creating backup of existing configuration..."
BACKUP_DIR="/var/backups/pinas-usb-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ -f /etc/samba/smb.conf ]; then
    cp /etc/samba/smb.conf "$BACKUP_DIR/smb.conf.bak"
fi
if [ -f /usr/local/sbin/usb-autoshare ]; then
    cp /usr/local/sbin/usb-autoshare "$BACKUP_DIR/usb-autoshare.bak"
fi
if [ -f /etc/udev/rules.d/99-usb-autoshare.rules ]; then
    cp /etc/udev/rules.d/99-usb-autoshare.rules "$BACKUP_DIR/99-usb-autoshare.rules.bak"
fi
echo "Backup created in: $BACKUP_DIR"

# Stop Samba services
echo "Stopping Samba services..."
systemctl stop smbd nmbd 2>/dev/null || true

# Update Samba global configuration
echo "Updating Samba configuration..."
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

# Create improved USB auto-share script
echo "Installing improved USB auto-share script..."
cat >/usr/local/sbin/usb-autoshare <<EOUSB
#!/bin/bash
set -euo pipefail

ACTION="\${1:-}"
DEVNAME="\${2:-}"

if [ -z "\$ACTION" ] || [ -z "\$DEVNAME" ]; then
  exit 0
fi

DEVPATH="/dev/\$DEVNAME"
MOUNT_ROOT="/srv/usb-shares"
USB_CONF="/etc/samba/usb-shares.conf"

SHARE_USER="$APP_USER"
SHARE_GROUP="\$SHARE_USER"
SHARE_UID="\$(id -u "\$SHARE_USER" 2>/dev/null || echo 1000)"
SHARE_GID="\$(id -g "\$SHARE_GROUP" 2>/dev/null || echo 1000)"

log() {
  echo "\$(date -Iseconds) usb-autoshare \$*" >> /var/log/usb-autoshare.log
}

mkdir -p "\$MOUNT_ROOT"

case "\$ACTION" in
  add)
    case "\$DEVNAME" in
      *[0-9]) ;;
      *)
        log "ignoring non-partition \$DEVNAME"
        exit 0
        ;;
    esac

    # Get filesystem info
    FS_TYPE="\$(blkid -o value -s TYPE "\$DEVPATH" 2>/dev/null || true)"
    LABEL="\$(blkid -o value -s LABEL "\$DEVPATH" 2>/dev/null || true)"
    
    # Skip EFI system partitions and other system filesystems
    case "\$FS_TYPE" in
      "")
        log "unknown filesystem type for \$DEVPATH, skipping"
        exit 0
        ;;
      swap)
        log "ignoring swap partition \$DEVPATH"
        exit 0
        ;;
    esac
    
    # Skip EFI partitions based on label or filesystem
    if [ "\$LABEL" = "EFI" ] || [ "\$FS_TYPE" = "vfat" ]; then
      # For FAT filesystems, check if it's really an EFI partition
      if [ "\$LABEL" = "EFI" ] || [ "\$(echo "\$DEVNAME" | grep -E 'p1\$|s1\$')" ]; then
        # Check if it contains EFI directory structure
        TEMP_MOUNT="\$(mktemp -d)"
        if mount "\$DEVPATH" "\$TEMP_MOUNT" 2>/dev/null; then
          if [ -d "\$TEMP_MOUNT/EFI" ] && [ -z "\$(find "\$TEMP_MOUNT" -maxdepth 1 -type f -name '*.txt' -o -name '*.doc*' -o -name '*.pdf' 2>/dev/null)" ]; then
            umount "\$TEMP_MOUNT"
            rmdir "\$TEMP_MOUNT"
            log "ignoring EFI system partition \$DEVPATH"
            exit 0
          fi
          umount "\$TEMP_MOUNT"
        fi
        rmdir "\$TEMP_MOUNT"
      fi
    fi
    
    # Determine user-friendly share name
    if [ -n "\$LABEL" ] && [ "\$LABEL" != "EFI" ]; then
      SHARE_LABEL="\$LABEL"
    else
      # Try to determine a friendly name based on device and filesystem
      case "\$FS_TYPE" in
        ext*|btrfs|xfs)
          SHARE_LABEL="Linux-Drive-\${DEVNAME#sd}"
          ;;
        ntfs|exfat)
          SHARE_LABEL="Windows-Drive-\${DEVNAME#sd}"
          ;;
        vfat)
          SHARE_LABEL="USB-Drive-\${DEVNAME#sd}"
          ;;
        *)
          SHARE_LABEL="Drive-\${DEVNAME#sd}"
          ;;
      esac
    fi
    
    # Create safe directory name (preserve more characters, handle duplicates)
    SAFE_LABEL="\$(echo "\$SHARE_LABEL" | sed 's/[^A-Za-z0-9._-]/-/g' | sed 's/--*/-/g' | sed 's/^-\\|-\$//g')"
    
    # Handle empty labels
    if [ -z "\$SAFE_LABEL" ]; then
      SAFE_LABEL="USB-\${DEVNAME#sd}"
    fi
    
    # Handle duplicate mount points
    ORIGINAL_LABEL="\$SAFE_LABEL"
    COUNTER=1
    MOUNT_POINT="\$MOUNT_ROOT/\$SAFE_LABEL"
    while [ -d "\$MOUNT_POINT" ] && mountpoint -q "\$MOUNT_POINT"; do
      SAFE_LABEL="\${ORIGINAL_LABEL}-\${COUNTER}"
      MOUNT_POINT="\$MOUNT_ROOT/\$SAFE_LABEL"
      COUNTER=\$((COUNTER + 1))
    done
    
    mkdir -p "\$MOUNT_POINT"
    log "mounting \$DEVPATH (\$FS_TYPE, label: '\$LABEL') as '\$SAFE_LABEL'"

    if ! mountpoint -q "\$MOUNT_POINT"; then
      # Mount with appropriate options based on filesystem type
      MOUNT_OPTS="uid=\$SHARE_UID,gid=\$SHARE_GID,umask=000"
      
      case "\$FS_TYPE" in
        vfat|msdos)
          MOUNT_OPTS="\$MOUNT_OPTS,iocharset=utf8,shortname=mixed"
          ;;
        ntfs)
          MOUNT_OPTS="\$MOUNT_OPTS,windows_names,locale=en_US.UTF-8"
          ;;
        exfat)
          MOUNT_OPTS="\$MOUNT_OPTS,iocharset=utf8"
          ;;
        ext*|btrfs|xfs)
          # For Linux filesystems, use different approach
          if ! mount "\$DEVPATH" "\$MOUNT_POINT" 2>>/var/log/usb-autoshare.log; then
            log "failed to mount \$DEVPATH on \$MOUNT_POINT"
            rmdir "\$MOUNT_POINT" || true
            exit 1
          fi
          # Set ownership after mounting
          chown -R "\$SHARE_UID:\$SHARE_GID" "\$MOUNT_POINT" 2>/dev/null || true
          chmod -R 755 "\$MOUNT_POINT" 2>/dev/null || true
          log "mounted \$DEVPATH on \$MOUNT_POINT (Linux filesystem)"
          exit 0
          ;;
      esac
      
      if ! mount -o "\$MOUNT_OPTS" "\$DEVPATH" "\$MOUNT_POINT" 2>>/var/log/usb-autoshare.log; then
        log "failed to mount \$DEVPATH on \$MOUNT_POINT with options: \$MOUNT_OPTS"
        rmdir "\$MOUNT_POINT" || true
        exit 1
      fi
      log "mounted \$DEVPATH on \$MOUNT_POINT with options: \$MOUNT_OPTS"
    fi
    ;;
  remove)
    umount "\$DEVPATH" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac

# Generate share configuration for each mounted USB device
TMP="\$(mktemp)"
echo "# auto-generated by usb-autoshare, do not edit by hand" > "\$TMP"

grep " \$MOUNT_ROOT/" /proc/mounts | while read -r dev mp rest; do
  NAME="\$(basename "\$mp")"
  SHARE_NAME="\$(echo "\$NAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9._-')"
  
  # Get filesystem type for the device
  DEV_FS_TYPE="\$(findmnt -n -o FSTYPE "\$mp" 2>/dev/null || echo unknown)"
  
  {
    echo
    echo "[\$SHARE_NAME]"
    echo "  comment = USB drive: \$NAME (\$DEV_FS_TYPE)"
    echo "  path = \$mp"
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
    echo "  force user = \$SHARE_USER"
    echo "  force group = \$SHARE_GROUP"
    echo "  inherit permissions = no"
    echo "  inherit acls = no"
    echo "  map archive = no"
    echo "  map hidden = no"
    echo "  map readonly = no"
    echo "  map system = no"
    echo "  store dos attributes = no"
    
    # Add filesystem-specific options
    case "\$DEV_FS_TYPE" in
      vfat|msdos|ntfs|exfat)
        echo "  delete readonly = yes"
        echo "  dos filemode = yes"
        ;;
      ext*|btrfs|xfs)
        echo "  unix extensions = no"
        ;;
    esac
  } >>"\$TMP"
done

mv "\$TMP" "\$USB_CONF"
chown root:root "\$USB_CONF"
chmod 644 "\$USB_CONF"

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet smbd; then
    systemctl reload smbd || systemctl restart smbd || true
  fi
fi
EOUSB

chmod 755 /usr/local/sbin/usb-autoshare

# Ensure usb-shares directory exists and has correct ownership
echo "Setting up USB shares directory..."
mkdir -p /srv/usb-shares
chown "$APP_USER":"$APP_GROUP" /srv/usb-shares

# Create empty USB shares config
touch /etc/samba/usb-shares.conf
chown root:root /etc/samba/usb-shares.conf
chmod 644 /etc/samba/usb-shares.conf

# Regenerate current USB shares configuration
echo "Regenerating USB shares configuration..."
/usr/local/sbin/usb-autoshare add dummy 2>/dev/null || true

# Start Samba services
echo "Starting Samba services..."
systemctl enable --now smbd nmbd

echo "==== USB Auto-Share Upgrade Completed at $(date) ===="
echo ""
echo "✅ Upgrade completed successfully!"
echo ""
echo "Improvements made:"
echo "  • EFI partitions are now properly detected and ignored"
echo "  • USB drive labels are used for share names when available"
echo "  • Improved guest write permissions for all filesystem types"
echo "  • Better macOS compatibility with Fruit VFS module"
echo "  • Enhanced error handling and logging"
echo ""
echo "Please unplug and re-plug any USB drives to apply the new configuration."
echo "Check /var/log/usb-autoshare.log for detailed mounting logs."
echo ""
echo "Backup of old configuration saved to: $BACKUP_DIR"