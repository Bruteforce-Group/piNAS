# Next Steps for piNAS Deployment

This document outlines the remaining tasks to get your piNAS system fully operational.

## ✅ Completed

- [x] Security fixes for hardcoded WiFi credentials
- [x] Fixed critical bugs in installation scripts
- [x] Fixed security issues in update scripts
- [x] Fixed SSH security issues in client management
- [x] Created comprehensive documentation
- [x] Set up development environment scripts
- [x] Archived legacy GitHub Actions workflow
- [x] Created validation and testing scripts
- [x] Committed all changes to git

## 🚀 Immediate Next Steps (Do First)

### 1. Deploy Cloudflare Infrastructure

The Worker deployment system is coded but not yet deployed. Here's what you need to do:

```bash
# Step 1: Install Wrangler globally if not already installed
npm install -g wrangler

# Step 2: Authenticate with Cloudflare
wrangler login

# Step 3: Create KV namespace for client metadata
cd infra/cloudflare
wrangler kv namespace create CLIENTS --preview=false

# You'll get output like:
# { binding = "CLIENTS", id = "abc123..." }

# Step 4: Create R2 bucket for artifacts
wrangler r2 bucket create pinas-artifacts

# Step 5: Update wrangler.toml with the real IDs
# Replace the placeholder IDs with the ones from step 3 & 4

# Step 6: Generate admin token
wrangler secret put ADMIN_TOKEN
# Enter a strong random token when prompted (e.g., output from: openssl rand -hex 32)

# Step 7: Deploy the Worker
npm run deploy

# Step 8: Note the Worker URL from deployment output
# It will be something like: https://pinas-deployer.your-account.workers.dev
```

### 2. Configure Local Environment

```bash
# Step 1: Copy environment template
cp .env.example .env

# Step 2: Edit .env with your Cloudflare details
# WORKER_URL="https://pinas-deployer.your-account.workers.dev"
# WORKER_ADMIN_TOKEN="<the token you created in step 6 above>"
# PINAS_R2_BUCKET="pinas-artifacts"

# Step 3: Copy WiFi template
cp boot/user-data.example boot/user-data

# Step 4: Edit boot/user-data with your WiFi credentials
# Uncomment the network section and add your SSID/password
```

### 3. Validate Your Setup

```bash
# Run the validation script
./scripts/validate-setup.sh

# This will check:
# - Environment variables configured
# - WiFi credentials set
# - Worker deployed
# - SSH keys present
# - All scripts executable
# - Required commands available
```

## 📋 Production Deployment Workflow

Once infrastructure is ready, follow this workflow:

### 4. Generate SSH Deployment Key

```bash
# Generate a dedicated SSH key for deployments
ssh-keygen -t ed25519 -f ~/.ssh/pinas-deploy-key -C "pinas-deployment"

# Update .env with the key path
echo 'PINAS_SSH_KEY="$HOME/.ssh/pinas-deploy-key"' >> .env
```

### 5. Prepare Your First SD Card

```bash
# Option A: Auto-detect SD card
./scripts/setup-sdcard.sh

# Option B: Specify path explicitly
./scripts/setup-sdcard.sh /Volumes/bootfs

# Option C: Include client registration
./scripts/setup-sdcard.sh --client-ip 192.168.1.100
```

### 6. Boot Raspberry Pi and Monitor Installation

1. Insert SD card into Raspberry Pi
2. Connect XC9022 TFT display
3. Power on the Pi
4. Watch installation progress on TFT display
5. Installation takes ~10-15 minutes

Monitor from your computer:
```bash
# After Pi gets an IP address (check your router)
ssh pi@192.168.1.100 tail -f /var/log/pinas-auto-boot.log
```

### 7. Register Client for Updates

```bash
# Step 1: Add client to registry
./scripts/manage-clients.sh add 192.168.1.100 pinas-living-room "Living room NAS"

# Step 2: Set up SSH key and provision Worker credentials
./scripts/manage-clients.sh setup-key 192.168.1.100

# Step 3: Test connection
./scripts/manage-clients.sh test 192.168.1.100

# Step 4: Check client status
./scripts/manage-clients.sh list
```

### 8. Publish Your First Artifact

```bash
# Option A: Auto-generate version from date + git commits
./scripts/publish-artifact.sh

# Option B: Specify explicit version
./scripts/publish-artifact.sh --version v2025.11.26.01

# Option C: Dry run (test without uploading)
./scripts/publish-artifact.sh --dry-run

# The script will:
# 1. Build a tarball with all necessary files
# 2. Compute SHA-256 checksum
# 3. Upload to R2 bucket
# 4. Notify Worker of new version
```

### 9. Test Update Flow

```bash
# On your development machine
# Trigger an update check on the client
ssh -i ~/.ssh/pinas-deploy-key pi@192.168.1.100 \
  sudo /usr/local/sbin/pinas-update.sh --check-only

# Force an immediate update (bypass timer)
ssh -i ~/.ssh/pinas-deploy-key pi@192.168.1.100 \
  sudo /usr/local/sbin/pinas-update.sh --force

# View update logs
ssh -i ~/.ssh/pinas-deploy-key pi@192.168.1.100 \
  sudo tail -f /var/log/pinas-update.log
```

## 🔍 Verification & Testing

### 10. Verify All Services

```bash
# Test SSH connectivity
./scripts/manage-clients.sh test 192.168.1.100

# On the Pi, check all services:
ssh pi@192.168.1.100

# Check systemd services
systemctl status pinas-dashboard.service
systemctl status pinas-usb-gadget.service
systemctl status pinas-auto-update.service
systemctl status pinas-auto-update.timer

# Check Samba shares
sudo smbstatus

# Check USB mounts
df -h | grep /srv/usb-shares

# Check update configuration
cat /etc/pinas/update-endpoint.env
```

### 11. Test TFT Display

Connect to the Pi and verify:
- Dashboard shows system stats (CPU, memory, disk)
- USB device list appears when drives are connected
- Touch interface responds to input

### 12. Test USB Gadget Mode

1. Connect Pi USB-C port to your computer
2. Wait ~10 seconds for detection
3. Your computer should see the Pi as a USB mass storage device
4. You should be able to browse shared USB drives

### 13. Test Samba File Sharing

From another computer on your network:
```bash
# macOS
open smb://pinas.local

# Linux
smbclient -L //pinas.local -N

# Windows
\\pinas.local
```

## 📊 Monitoring & Maintenance

### View Worker Logs

```bash
cd infra/cloudflare
wrangler tail --env production
```

### Check R2 Storage

```bash
cd infra/cloudflare
wrangler r2 bucket list pinas-artifacts
wrangler r2 object list pinas-artifacts
```

### View Client Activity

```bash
# SSH to client
ssh -i ~/.ssh/pinas-deploy-key pi@192.168.1.100

# View update logs
sudo tail -100 /var/log/pinas-update.log

# View installation logs (from initial setup)
sudo cat /var/log/pinas-auto-boot.log

# Check systemd timer
systemctl status pinas-auto-update.timer
systemctl list-timers | grep pinas
```

## 🐛 Troubleshooting

### Worker Not Responding

```bash
cd infra/cloudflare
wrangler whoami              # Check authentication
wrangler dev                 # Test locally
wrangler tail                # View live logs
```

### Client Can't Connect to Worker

```bash
# On the client
ssh pi@192.168.1.100

# Check config
cat /etc/pinas/update-endpoint.env

# Test connectivity
curl -v "$WORKER_URL/health"

# Check DNS
ping -c3 $(echo $WORKER_URL | sed 's|https://||;s|/.*||')

# Test update manually
sudo /usr/local/sbin/pinas-update.sh --check-only
```

### SSH Connection Issues

```bash
# Check key is added to ssh-agent
ssh-add ~/.ssh/pinas-deploy-key

# Test connection with verbose output
ssh -v -i ~/.ssh/pinas-deploy-key pi@192.168.1.100

# Verify key is on client
ssh pi@192.168.1.100 cat ~/.ssh/authorized_keys
```

### Installation Failed on Pi

```bash
# Check installation log
ssh pi@192.168.1.100 cat /var/log/pinas-auto-boot.log

# Check progress file
ssh pi@192.168.1.100 cat /boot/pinas-progress.json

# Re-run installer manually
ssh pi@192.168.1.100
sudo /boot/firmware/pinas/pinas-install.sh
```

## 📚 Additional Resources

- [README.md](README.md) - Project overview and quick start
- [SETUP-CHECKLIST.md](SETUP-CHECKLIST.md) - Detailed setup checklist
- [docs/deployment-setup.md](docs/deployment-setup.md) - Complete deployment runbook
- [docs/client-config.md](docs/client-config.md) - Client configuration guide
- [DEPLOY-KEY-SOLUTION.md](DEPLOY-KEY-SOLUTION.md) - Security best practices
- [BUGFIXES.md](BUGFIXES.md) - Known issues and fixes

## ⚙️ Advanced Configuration

### Custom Update Schedule

The default update check runs daily at 03:00. To customize:

```bash
# On the client
sudo systemctl edit pinas-auto-update.timer

# Add your custom schedule (e.g., every 6 hours):
[Timer]
OnCalendar=
OnCalendar=*-*-* 00,06,12,18:00:00
```

### Multiple Environments

You can deploy separate dev/staging/production Workers:

```bash
cd infra/cloudflare

# Deploy to dev
wrangler deploy --env development

# Deploy to production
wrangler deploy --env production
```

Update wrangler.toml to define environments with separate KV namespaces and R2 buckets.

## 🎯 Success Criteria

You'll know everything is working when:

- ✅ `./scripts/validate-setup.sh` passes with no errors
- ✅ Pi boots and completes installation automatically
- ✅ TFT display shows dashboard with system stats
- ✅ USB gadget mode works (Pi appears as USB drive)
- ✅ Samba shares are accessible from network
- ✅ Client checks for updates daily and installs automatically
- ✅ You can publish new artifacts and clients update

## 🎉 You're Done!

Once all steps above are complete, your piNAS deployment system is fully operational!

To add more Pis:
1. Run `./scripts/setup-sdcard.sh --client-ip <new-ip>`
2. Boot the new Pi
3. Run `./scripts/manage-clients.sh setup-key <new-ip>`
4. Done! It will auto-update going forward.

---

**Questions or Issues?**

Check [BUGFIXES.md](BUGFIXES.md) for known issues or create an issue in the repository.
