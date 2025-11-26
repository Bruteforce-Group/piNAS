#!/bin/bash
set -euo pipefail

# Quick Deploy Key Setup for Running piNAS
# This sets up the deploy key and update system on an already-running piNAS

PINAS_HOST="192.168.1.226"
DEPLOY_KEY_PRIVATE="$HOME/.ssh/pinas_deploy"

echo "🔧 Quick Deploy Key Setup for piNAS"
echo "===================================="
echo

if [ ! -f "$DEPLOY_KEY_PRIVATE" ]; then
    echo "❌ Deploy key not found at $DEPLOY_KEY_PRIVATE"
    echo "Please run ./scripts/manage-clients.sh first to generate the key"
    exit 1
fi

echo "Setting up deploy key on piNAS at $PINAS_HOST..."
echo

# Create a comprehensive setup script to run on the piNAS
cat > /tmp/pinas-deploy-setup.sh << 'EOF'
#!/bin/bash
set -euo pipefail

echo "🚀 Setting up piNAS automatic deployment..."

# Create SSH directory
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Configure SSH for GitHub (using the key we'll copy)
cat >> ~/.ssh/config << 'SSHCONFIG'

# GitHub Deploy Key for piNAS
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/pinas_deploy_key
    IdentitiesOnly yes
SSHCONFIG
chmod 600 ~/.ssh/config

# Test GitHub access
echo "Testing GitHub access..."
if ssh -o StrictHostKeyChecking=no -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo "✅ GitHub SSH access working!"
else
    echo "⚠️  GitHub access test failed, but continuing with setup..."
fi

# Create the update command
sudo tee /usr/local/bin/pinas-update << 'UPDATESCRIPT'
#!/bin/bash
set -euo pipefail

REPO_URL="git@github.com:Bruteforce-Group/piNAS.git"
CLONE_DIR="/tmp/pinas-update-$$"
LOG_FILE="/var/log/pinas-pull-update.log"

echo "$(date): Starting piNAS pull update..." | tee -a "$LOG_FILE"

# Clone repository
if git clone "$REPO_URL" "$CLONE_DIR" 2>&1 | tee -a "$LOG_FILE"; then
    cd "$CLONE_DIR"
    
    echo "$(date): Repository cloned successfully" | tee -a "$LOG_FILE"
    
    # Get version info
    NEW_VERSION=$(cat VERSION 2>/dev/null || echo "dev-$(git rev-parse --short HEAD)")
    echo "$(date): Updating to version $NEW_VERSION" | tee -a "$LOG_FILE"
    
    # Update scripts
    sudo cp -r sbin/* /usr/local/sbin/ 2>/dev/null || true
    sudo chmod +x /usr/local/sbin/pinas-*.sh 2>/dev/null || true
    
    # Copy new pull update script if available
    if [ -f "sbin/pinas-pull-update.sh" ]; then
        sudo cp sbin/pinas-pull-update.sh /usr/local/sbin/
        sudo chmod +x /usr/local/sbin/pinas-pull-update.sh
        echo "$(date): Updated to comprehensive pull update script" | tee -a "$LOG_FILE"
    fi
    
    # Update installation directory
    sudo mkdir -p /usr/local/pinas
    sudo cp -r * /usr/local/pinas/ 2>/dev/null || true
    
    # Restart services if they exist
    for service in pinas-dashboard pinas-usb-gadget; do
        if systemctl is-active --quiet ${service}.service 2>/dev/null; then
            echo "$(date): Restarting ${service}" | tee -a "$LOG_FILE"
            sudo systemctl restart ${service}.service || true
        fi
    done
    
    cd /
    rm -rf "$CLONE_DIR"
    echo "$(date): Update completed successfully!" | tee -a "$LOG_FILE"
    echo "✅ piNAS updated to version $NEW_VERSION"
else
    echo "$(date): Failed to clone repository" | tee -a "$LOG_FILE"
    echo "❌ Update failed - check network and GitHub access"
    exit 1
fi
UPDATESCRIPT

sudo chmod +x /usr/local/bin/pinas-update

# Set up automatic daily updates
sudo tee /etc/systemd/system/pinas-auto-update.service << 'SERVICECONFIG'
[Unit]
Description=piNAS Automatic Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/pinas-update
StandardOutput=append:/var/log/pinas-auto-update.log
StandardError=append:/var/log/pinas-auto-update.log
SERVICECONFIG

sudo tee /etc/systemd/system/pinas-auto-update.timer << 'TIMERCONFIG'
[Unit]
Description=piNAS Automatic Update Timer
Requires=pinas-auto-update.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TIMERCONFIG

sudo systemctl daemon-reload
sudo systemctl enable pinas-auto-update.timer
sudo systemctl start pinas-auto-update.timer

echo "✅ Deploy key setup complete!"
echo "✅ Automatic daily updates enabled!"
echo
echo "Usage:"
echo "• Manual update: pinas-update"
echo "• Check logs: tail -f /var/log/pinas-pull-update.log"
echo "• Update status: systemctl status pinas-auto-update.timer"
echo
echo "Your piNAS will now automatically pull updates daily!"
EOF

# Copy the deploy key and setup script to the piNAS
echo "Copying deploy key to piNAS..."
scp "$DEPLOY_KEY_PRIVATE" "pi@$PINAS_HOST:~/.ssh/pinas_deploy_key" || {
    echo "❌ Failed to copy deploy key. SSH access might not be configured."
    echo "You may need to:"
    echo "1. Connect a keyboard/monitor to your piNAS"
    echo "2. Enable password authentication temporarily"
    echo "3. Or set up SSH keys manually"
    exit 1
}

echo "Setting permissions on deploy key..."
ssh "pi@$PINAS_HOST" "chmod 600 ~/.ssh/pinas_deploy_key"

echo "Copying and running setup script..."
scp /tmp/pinas-deploy-setup.sh "pi@$PINAS_HOST:~/setup.sh"
ssh "pi@$PINAS_HOST" "chmod +x ~/setup.sh && ./setup.sh && rm ~/setup.sh"

echo
echo "🎉 Deploy key setup complete!"
echo "Testing the update system..."

# Test the update system
ssh "pi@$PINAS_HOST" "pinas-update"

echo
echo "✅ Automatic deployment is now working!"
echo "• Your piNAS will pull updates daily automatically"
echo "• Manual updates: ssh pi@$PINAS_HOST 'pinas-update'"
echo "• Check logs: ssh pi@$PINAS_HOST 'tail -f /var/log/pinas-pull-update.log'"

# Clean up
rm -f /tmp/pinas-deploy-setup.sh