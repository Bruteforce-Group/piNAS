# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

piNAS is a Raspberry Pi-based NAS appliance that converts a Pi into a USB storage device and NAS server with an advanced TFT display dashboard. The project includes automated installation scripts, offline dependency caching, comprehensive hardware integration, and automatic deployment capabilities for both local and remote clients.

### Version System
piNAS uses date-based versioning: `v2025.11.25.01` (Year.Month.Day.Build)

## Architecture

### Core Components

**Installation System (`sbin/`)**
- `pinas-install.sh` - Main installer with staged progress tracking and offline-first package management
- `pinas-cache-deps.sh` - Dependency cacher for offline installations
- Progress tracking via JSON files and structured stage management

**Hardware Integration**
- XC9022 2.8" TFT display with live installation progress and advanced dashboard
- Full-screen dashboard with real-time charts (CPU/RAM/Disk/Network)
- Touch controls for USB drive management (share/unshare, format)
- Version tracking and update status indicators
- USB mass storage gadget mode (Pi appears as USB drive to host)
- Auto-mounting USB drives as Samba shares with improved EFI detection

**Boot Configuration (`boot/`)**
- `user-data` - Cloud-init configuration for automated first boot
- `templates/` - Minimal reference config files for Pi boot
- Automatic WiFi setup and installer execution

**Support Scripts (`scripts/`)**
- `setup-sdcard.sh` - Workstation script to prepare SD cards for installation

**Remote Client Support**
- Cloudflare Worker coordination for remote + local clients
- Pull-based updater with per-device Worker tokens
- No inbound SSH exposure required on WAN links

### Installation Flow

1. **init_display** - Bring up TFT with live installer log
2. **packages** - Install APT packages (offline-first from cache)
3. **usb_nas** - Configure Samba and USB auto-mounting
4. **dashboard** - Deploy permanent NAS status dashboard to TFT
5. **usb_gadget** - Configure USB mass storage gadget mode
6. **finalize** - Complete installation and enable services

## Common Development Commands

### Testing Installation Scripts

```bash
# Validate main installer syntax
bash -n sbin/pinas-install.sh

# Check dependency cacher
bash -n sbin/pinas-cache-deps.sh

# Test SD card setup script
bash -n scripts/setup-sdcard.sh

# Test client update script
bash -n sbin/pinas-update.sh

# Test USB upgrade script
bash -n sbin/pinas-upgrade-usb.sh
```

### SD Card Preparation

```bash
# Auto-detect SD card and eject when done
./scripts/setup-sdcard.sh

# Specify mount point explicitly
./scripts/setup-sdcard.sh /Volumes/bootfs

# Setup without ejecting (for multiple operations)
./scripts/setup-sdcard.sh --no-eject

# Show help and options
./scripts/setup-sdcard.sh --help
```

### Deployment and Updates

```bash
# Publish a release to Cloudflare R2 and notify the Worker metadata
./scripts/publish-artifact.sh --version v2025.11.26.01

# Register a client + provision Worker token
./scripts/manage-clients.sh add 192.168.1.226 pinas-226
./scripts/manage-clients.sh setup-key 192.168.1.226

# Manual client update / verification
ssh pi@pinas.local sudo /usr/local/sbin/pinas-update.sh --check-only
ssh pi@pinas.local sudo /usr/local/sbin/pinas-update.sh --force

# Upgrade existing USB sharing (fixes EFI detection and permissions)
sudo /usr/local/sbin/pinas-upgrade-usb.sh
```

### Development Workflow

**Modifying Installation Scripts:**
- Edit scripts in `sbin/` directory
- Test syntax with `bash -n` before deployment
- Scripts are copied to Pi via `setup-sdcard.sh` (auto-ejects when complete)
- Installation logs available at `/var/log/pinas-install.log` and on SD card

**Boot Configuration Changes:**
- Modify `boot/user-data` for cloud-init changes
- Update `boot/templates/` for Pi configuration templates
- WiFi credentials in `user-data` (currently set to "Zoomies" network)

**Architecture Changes:**
- Hardware pin configurations in installer (TFT_CS=CE0, TFT_DC=D25, TOUCH_CS=CE1, etc.)
- Samba configuration auto-generated in `/etc/samba/usb-shares.conf`
- USB gadget uses configfs and libcomposite kernel modules

### Key Implementation Details

**Offline-First Package Management:**
- APT cache: `$BOOT_MNT/pinas-apt/` (`.deb` files)
- Python wheels: `$BOOT_MNT/pinas-py/` (`.whl` files)
- Falls back to network if cache unavailable

**Progress Tracking:**
- Machine-readable: `$BOOT_MNT/pinas-progress.json`
- Human-readable: Console dashboard with stage icons `[..]` `[>>]` `[OK]` `[!!]`

**Service Management:**
- `pinas-dashboard.service` - TFT dashboard (systemd)
- `pinas-usb-gadget.service` - USB mass storage gadget
- `pinas-install-onboot.service` - Automatic reinstall scheduling

**Hardware Integration:**
- Display: ILI9341 SPI TFT at 270° rotation, 24MHz baudrate
- Touch: Auto-detects STMPE610 or XPT2046 controllers
- USB gadget: Uses deterministic serial from `/etc/machine-id`

## Project Structure

```
piNAS/
├── .github/workflows/    # Legacy GitHub Actions CI/CD (kept for reference)
├── infra/cloudflare/     # Cloudflare Worker project (Wrangler, KV, R2)
├── sbin/                 # Main installation scripts
│   ├── pinas-install.sh  # Main installer
│   ├── pinas-cache-deps.sh # Dependency cacher
│   ├── pinas-update.sh   # Worker/R2 client update script
│   └── pinas-upgrade-usb.sh # USB sharing upgrade script
├── boot/                 # Boot configuration and cloud-init
│   ├── templates/        # Reference Pi config files
│   └── user-data         # Cloud-init automation
├── scripts/              # Development and setup utilities
├── docs/                 # Documentation
│   ├── deployment-setup.md # Cloudflare Worker deployment guide
│   ├── client-config.md  # Client deployment configuration
│   ├── pinas-auto-update.service # Systemd service
│   └── pinas-auto-update.timer   # Systemd timer
└── archive/              # Reference files from live Pi (not for build)
```

## Notes

- Uses cloud-init for automated first boot installation
- TFT displays live installation progress and post-install NAS status
- Supports offline installations with dependency caching
- Auto-restarts after installation to ensure kernel modules load
- All scripts use `set -euo pipefail` for strict error handling
- Progress tracking allows monitoring via SSH or TFT display
- USB shares auto-configured with guest Samba access
- Touch interaction toggles dashboard detail/compact views
- **Automatic deployment**: Clients poll the Worker (timer or manual) and self-update
- Cloudflare Worker + R2 manage artifact distribution without GitHub Actions
- Client update system with automatic daily checks (3 AM)
- Update rollback capability with automatic backups

<citations>
<document>
<document_type>RULE</document_type>
<document_id>qPsKvBmu9Dwf9IJaby5nez</document_id>
</document>
</citations>