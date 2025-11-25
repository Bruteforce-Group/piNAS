# piNAS Deployment Setup

This document explains how to set up automatic deployment of piNAS updates using GitHub Actions.

## GitHub Actions Workflow

The workflow (`.github/workflows/deploy.yml`) provides:

### Automated Build Pipeline
- **Script Validation**: Syntax checking for all shell scripts
- **Cloud-init Validation**: Validates the `boot/user-data` file
- **Package Creation**: Builds versioned release packages with checksums
- **Artifact Storage**: Uploads build artifacts for deployment

### Deployment Options

#### 1. Automatic Deployment (Main Branch)
- Triggers on pushes to `main` branch
- Deploys to pre-configured client list
- Creates backup before updating
- Verifies deployment success

#### 2. Tagged Releases
- Triggers on version tags (e.g., `v1.0.0`)
- Creates GitHub releases with packages
- Automatically generates release notes
- Deploys to production clients

#### 3. Manual Deployment
- Run via GitHub Actions web interface
- Specify target clients as comma-separated list
- Force deployment option available
- Useful for testing or emergency updates

## Setup Requirements

### 1. GitHub Repository Secrets

Add these secrets in your GitHub repository settings (`Settings > Secrets and variables > Actions`):

```
PINAS_SSH_PRIVATE_KEY
```

This should contain the private key for SSH access to your piNAS clients. Generate it with:

```bash
ssh-keygen -t ed25519 -C "pinas-deployment@github.com" -f ~/.ssh/pinas_deploy
```

Then add the public key to each piNAS client:

```bash
# On each piNAS client
cat pinas_deploy.pub >> ~/.ssh/authorized_keys
```

### 2. Client Configuration

#### Update Client List

Edit `.github/workflows/deploy.yml` and add your client IPs/hostnames to the matrix:

```yaml
strategy:
  matrix:
    # Add your piNAS client IPs/hostnames here
    client: 
      - "192.168.1.100"
      - "pinas-office.local" 
      - "pinas-home.bruteforce.group"
```

#### SSH Access

Ensure SSH access is enabled on all piNAS clients and the `pi` user has sudo privileges.

### 3. Client-Side Update System

The deployment system installs these components on each client:

#### Update Script (`pinas-update.sh`)
- Checks for latest releases on GitHub
- Downloads and verifies updates
- Creates backups before applying changes
- Restarts services as needed

#### Automatic Updates (Optional)
- `pinas-auto-update.service` - Systemd service for updates
- `pinas-auto-update.timer` - Runs daily at 3 AM with random delay
- Logs to `/var/log/pinas-update.log`

## Usage Examples

### Development Workflow

1. **Make Changes**: Edit scripts, configurations, or documentation
2. **Test Locally**: Run syntax validation:
   ```bash
   bash -n sbin/pinas-install.sh
   bash -n sbin/pinas-cache-deps.sh
   bash -n scripts/setup-sdcard.sh
   ```
3. **Commit and Push**: Changes trigger automatic validation and deployment
4. **Monitor Deployment**: Check GitHub Actions logs for deployment status

### Release Process

1. **Tag Release**: Create and push a version tag:
   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```
2. **Automatic Release**: GitHub Actions creates a release with built packages
3. **Client Updates**: Tagged releases trigger deployment to production clients

### Manual Deployment

1. **GitHub Interface**: Go to `Actions > Build and Deploy piNAS > Run workflow`
2. **Specify Targets**: Enter comma-separated client list:
   ```
   192.168.1.100, pinas-office.local, 10.0.0.50
   ```
3. **Force Option**: Enable to reinstall current version
4. **Run**: Click "Run workflow"

### Client-Side Operations

#### Manual Update Check
```bash
# Check for updates without installing
sudo /usr/local/sbin/pinas-update.sh --check-only

# Install latest update
sudo /usr/local/sbin/pinas-update.sh

# Install specific version
sudo /usr/local/sbin/pinas-update.sh --version v1.2.0

# Force reinstall current version
sudo /usr/local/sbin/pinas-update.sh --force
```

#### Monitor Auto-Updates
```bash
# Check timer status
systemctl status pinas-auto-update.timer

# View recent update logs
tail -f /var/log/pinas-update.log

# Manually trigger update service
sudo systemctl start pinas-auto-update.service
```

## Security Considerations

### SSH Key Management
- Use dedicated deployment keys (not personal keys)
- Restrict key access to deployment actions only
- Consider key rotation policy

### Network Security
- Ensure clients are accessible only from trusted networks
- Use VPN or SSH tunneling for remote clients
- Monitor deployment logs for unauthorized access

### Update Verification
- All packages include checksums for integrity verification
- Scripts undergo syntax validation before deployment
- Backups are created before applying updates
- Failed deployments trigger alerts

## Troubleshooting

### Common Issues

#### SSH Connection Failures
```bash
# Test SSH access manually
ssh pi@client-ip "echo 'Connection OK'"

# Check SSH key permissions
ls -la ~/.ssh/pinas_deploy*
```

#### Update Script Errors
```bash
# Check client logs
ssh pi@client-ip "tail -50 /var/log/pinas-update.log"

# Verify current version
ssh pi@client-ip "cat /usr/local/pinas/VERSION"
```

#### GitHub Actions Failures
- Check workflow logs in GitHub Actions tab
- Verify repository secrets are set correctly
- Ensure client connectivity from GitHub runners

### Recovery Procedures

#### Rollback Failed Update
```bash
# On affected client
sudo systemctl stop pinas-dashboard.service pinas-usb-gadget.service

# Find backup directory
ls -la /usr/local/pinas-backup-*

# Restore from backup
sudo cp -r /usr/local/pinas-backup-YYYYMMDD-HHMMSS/* /usr/local/pinas/

# Restart services
sudo systemctl start pinas-dashboard.service pinas-usb-gadget.service
```

#### Emergency Manual Deployment
```bash
# Download release package manually
curl -L -o pinas-v1.2.0.tar.gz \
  https://github.com/Bruteforce-Group/piNAS/releases/download/v1.2.0/pinas-v1.2.0.tar.gz

# Deploy manually (follow deployment script logic)
tar -xzf pinas-v1.2.0.tar.gz
# ... follow manual installation steps
```

## Monitoring and Alerting

### GitHub Actions Notifications
- Configure GitHub notifications for workflow failures
- Set up Slack/Discord webhooks for deployment status
- Monitor deployment frequency and success rates

### Client Health Monitoring
- Implement health checks for deployed services
- Monitor update success/failure rates
- Track client version distribution

### Log Aggregation
- Collect logs from all clients centrally
- Monitor for update-related errors
- Set up alerts for deployment failures

This deployment system provides a robust, automated way to keep all your piNAS clients updated while maintaining safety through backups, validation, and monitoring.