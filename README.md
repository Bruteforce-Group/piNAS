# piNAS - Raspberry Pi NAS Appliance

Transform a Raspberry Pi into a fully-featured NAS appliance with TFT display dashboard, USB mass storage gadget mode, and automated deployment via Cloudflare Workers.

## ✨ Features

- **📊 TFT Display Dashboard** - XC9022 2.8" display with live installation progress and NAS status
- **💾 USB Gadget Mode** - Pi appears as a USB mass storage device to host computers
- **🗂️ Samba File Sharing** - Network file sharing with auto-mounting USB drives
- **🔄 Automated Updates** - Pull-based updates via Cloudflare Worker (no inbound WAN access needed)
- **📦 Offline-First Installation** - Install from cached packages without internet
- **🎯 Touch Dashboard** - Touchscreen interface for USB device management
- **☁️ Cloudflare Infrastructure** - Modern deployment with R2 storage and Workers KV

## 🚀 Quick Start

### 1. Development Environment Setup

```bash
# Clone the repository
git clone <repo-url>
cd piNAS

# Run the setup script
./setup-dev-env.sh
```

This will:
- Create `.env` from template
- Create `boot/user-data` from template
- Install Cloudflare Worker dependencies
- Show you a checklist of remaining setup tasks

### 2. Configure Your Environment

Edit `.env` with your Cloudflare credentials:
```bash
WORKER_URL="https://pinas-deployer.YOUR_ACCOUNT.workers.dev"
WORKER_ADMIN_TOKEN="<from wrangler secret>"
PINAS_R2_BUCKET="pinas-artifacts"
```

Edit `boot/user-data` with your WiFi settings:
```yaml
network={
    ssid="YOUR_WIFI_SSID"
    psk="YOUR_WIFI_PASSWORD"
    key_mgmt=WPA-PSK
}
```

### 3. Deploy Cloudflare Infrastructure

```bash
cd infra/cloudflare

# Create KV namespace for client metadata
wrangler kv namespace create CLIENTS

# Create R2 bucket for artifacts
wrangler r2 bucket create pinas-artifacts

# Update wrangler.toml with the IDs from above commands

# Generate admin token
wrangler secret put ADMIN_TOKEN

# Deploy the Worker
npm run deploy
```

### 4. Prepare an SD Card

```bash
# Auto-detect SD card and prepare it
./scripts/setup-sdcard.sh

# Or specify the SD card path explicitly
./scripts/setup-sdcard.sh /Volumes/bootfs
```

### 5. Boot Your Raspberry Pi

1. Insert the prepared SD card into your Pi
2. Connect the XC9022 TFT display
3. Power on the Pi
4. Watch the installation progress on the TFT display
5. Installation completes in ~10-15 minutes

### 6. Register the Client for Updates

```bash
# Add the client to your registry
./scripts/manage-clients.sh add 192.168.1.100 pinas-living-room

# Setup SSH key and provision Worker credentials
./scripts/manage-clients.sh setup-key 192.168.1.100
```

## 📚 Documentation

- **[SETUP-CHECKLIST.md](SETUP-CHECKLIST.md)** - Step-by-step deployment guide
- **[docs/deployment-setup.md](docs/deployment-setup.md)** - Complete deployment runbook
- **[docs/client-config.md](docs/client-config.md)** - Client configuration guide
- **[DEPLOY-KEY-SOLUTION.md](DEPLOY-KEY-SOLUTION.md)** - Security and key rotation
- **[SSH-SETUP.md](SSH-SETUP.md)** - SSH configuration guide
- **[WARP.md](WARP.md)** - Project overview for WARP.dev

## 🏗️ Architecture

```
┌─────────────────────┐
│  Developer Machine  │
│                     │
│  publish-artifact   │──┐
│  manage-clients     │  │
└─────────────────────┘  │
                         │
                         ▼
              ┌──────────────────────┐
              │  Cloudflare Worker   │
              │                      │
              │  - Client API        │
              │  - Admin API         │
              │  - Auth & Tokens     │
              └──────────────────────┘
                   │            │
        ┌──────────┘            └──────────┐
        ▼                                  ▼
┌───────────────┐                 ┌────────────────┐
│  Workers KV   │                 │   R2 Bucket    │
│               │                 │                │
│  - Clients    │                 │  - Artifacts   │
│  - Metadata   │                 │  - Tarballs    │
└───────────────┘                 └────────────────┘
                                         │
                                         │
                                         ▼
                              ┌──────────────────────┐
                              │   piNAS Devices      │
                              │                      │
                              │  pinas-update.sh     │
                              │  (daily at 03:00)    │
                              └──────────────────────┘
```

## 🔄 Update Flow

1. **Publish**: `./scripts/publish-artifact.sh --version v2025.11.26.01`
   - Builds tarball from repo
   - Uploads to R2 bucket
   - Notifies Worker of new version

2. **Poll**: piNAS devices check daily at 03:00 (via systemd timer)
   - Sends current version to Worker
   - Worker responds with update if available

3. **Download**: Device pulls artifact from Worker
   - Streams from R2 bucket
   - Verifies SHA-256 checksum

4. **Install**: Automatic installation with rollback
   - Backs up current version
   - Installs new version
   - Restarts services
   - Rolls back on failure

## 🛠️ Common Commands

```bash
# Client Management
./scripts/manage-clients.sh add <ip> [hostname]      # Register new client
./scripts/manage-clients.sh setup-key <ip>           # Provision credentials
./scripts/manage-clients.sh test <ip>                # Test connectivity
./scripts/manage-clients.sh list                     # List all clients
./scripts/manage-clients.sh status                   # Show client status

# Artifact Publishing
./scripts/publish-artifact.sh                        # Publish with auto version
./scripts/publish-artifact.sh --version v2025.11.26  # Explicit version
./scripts/publish-artifact.sh --dry-run              # Test without uploading

# SD Card Preparation
./scripts/setup-sdcard.sh                            # Auto-detect SD card
./scripts/setup-sdcard.sh /Volumes/bootfs            # Explicit path
./scripts/setup-sdcard.sh --client-ip 192.168.1.100  # Auto-register client

# Worker Management
cd infra/cloudflare
npm run deploy                                       # Deploy Worker
npm run dev                                          # Local development
wrangler secret put ADMIN_TOKEN                      # Update admin token
wrangler tail                                        # View live logs
```

## 📦 Installation System

The installer runs in 6 stages with progress tracking on the TFT display:

1. **init_display** - Initialize TFT display and show progress
2. **packages** - Install APT packages (offline-first from cache)
3. **usb_nas** - Configure Samba and USB auto-mounting
4. **dashboard** - Deploy permanent NAS status dashboard
5. **usb_gadget** - Configure USB mass storage gadget mode
6. **finalize** - Enable services and complete installation

Progress is tracked in `/boot/pinas-progress.json` and displayed on the TFT with visual stage indicators: `[..]` pending, `[>>]` running, `[OK]` complete, `[!!]` failed.

## 🔧 Hardware Requirements

- **Raspberry Pi** - Tested on Pi 5 (should work on Pi 4, Pi Zero 2 W)
- **SD Card** - 16GB+ recommended
- **XC9022 TFT Display** - 2.8" ILI9341 SPI display with STMPE610/XPT2046 touch controller
- **USB Drives** - For NAS storage (NTFS, exFAT, FAT32 supported)
- **WiFi** - For network access and updates

## 📋 Prerequisites

- **Cloudflare Account** - Free tier is sufficient
- **Wrangler CLI** - `npm install -g wrangler`
- **Node.js** - v18+ for Worker development
- **Bash** - For helper scripts
- **SSH** - For client management

## 🔐 Security

- WiFi credentials are **never committed** to git (`.gitignore` protection)
- Admin tokens stored securely in Wrangler secrets
- Client tokens are SHA-256 hashed in Workers KV
- SSH keys managed via `manage-clients.sh`
- Pull-based updates (no inbound WAN access needed)

See [DEPLOY-KEY-SOLUTION.md](DEPLOY-KEY-SOLUTION.md) for security best practices.

## 🐛 Troubleshooting

### Worker not deploying
```bash
cd infra/cloudflare
wrangler whoami                    # Check authentication
wrangler kv namespace list         # Verify KV namespace
wrangler r2 bucket list            # Verify R2 bucket
```

### Client not connecting
```bash
./scripts/manage-clients.sh test <ip>        # Test SSH
ssh pi@<ip> cat /etc/pinas/update-endpoint.env  # Check config
ssh pi@<ip> sudo journalctl -u pinas-auto-update -n 50  # Check logs
```

### Installation failing
- Check `/var/log/pinas-auto-boot.log` on the Pi
- View progress in `/boot/pinas-progress.json`
- Check TFT display for stage status

### Update not working
```bash
# On the Pi
sudo /usr/local/sbin/pinas-update.sh --check-only  # Test without installing
sudo /usr/local/sbin/pinas-update.sh --force       # Force update
tail -f /var/log/pinas-update.log                  # View logs
```

## 📄 License

[Add your license here]

## 🤝 Contributing

Contributions welcome! Please read the documentation before submitting PRs.

## 📞 Support

- **Issues**: [GitHub Issues](link-to-issues)
- **Documentation**: [docs/](docs/)
- **Deployment Guide**: [SETUP-CHECKLIST.md](SETUP-CHECKLIST.md)
