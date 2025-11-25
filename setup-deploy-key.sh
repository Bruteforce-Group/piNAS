#!/bin/bash
set -euo pipefail

# Setup Deploy Key for piNAS Pull Updates
# This script configures the piNAS to use the GitHub deploy key for automatic updates

echo "🔑 piNAS Deploy Key Setup"
echo "========================="
echo

DEPLOY_KEY_PRIVATE="$HOME/.ssh/pinas_deploy"
PINAS_HOST="192.168.1.226"

if [ ! -f "$DEPLOY_KEY_PRIVATE" ]; then
    echo "❌ Deploy key not found at $DEPLOY_KEY_PRIVATE"
    echo "Please run ./scripts/manage-clients.sh first to generate the key"
    exit 1
fi

echo "This script will:"
echo "1. Copy the deploy key to your piNAS"  
echo "2. Configure SSH for GitHub access"
echo "3. Set up automatic pull-based updates"
echo

# Check if we can reach the piNAS
if ! ping -c 1 -W 3 "$PINAS_HOST" >/dev/null 2>&1; then
    echo "❌ Cannot reach piNAS at $PINAS_HOST"
    echo "Please check the IP address and network connection"
    exit 1
fi

echo "✅ piNAS reachable at $PINAS_HOST"
echo

# Method 1: Try existing SSH access
echo "Method 1: Using existing SSH access (if available)"
echo "=================================================="

if ssh -o ConnectTimeout=5 pi@$PINAS_HOST "echo 'SSH connection successful'" 2>/dev/null; then
    echo "✅ SSH access available! Setting up deploy key..."
    
    # Copy the deploy key
    scp "$DEPLOY_KEY_PRIVATE" pi@$PINAS_HOST:~/.ssh/pinas_deploy_key
    
    # Set up SSH config and permissions
    ssh pi@$PINAS_HOST << 'EOF'
        set -euo pipefail
        
        # Set proper permissions
        chmod 600 ~/.ssh/pinas_deploy_key
        
        # Create SSH config for GitHub
        cat >> ~/.ssh/config << 'SSHCONF'

# GitHub Deploy Key for piNAS
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/pinas_deploy_key
    IdentitiesOnly yes
SSHCONF
        
        # Test GitHub access
        if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
            echo "✅ GitHub SSH access configured successfully!"
        else
            echo "⚠️  GitHub access test failed, but key is installed"
        fi
        
        # Install the pull update script
        sudo mkdir -p /usr/local/sbin
        
        # Create a simple update trigger script
        cat > /tmp/pinas-auto-update.sh << 'UPDATESCRIPT'
#!/bin/bash
set -euo pipefail

# Simple wrapper to run the pull update
if [ -f /usr/local/sbin/pinas-pull-update.sh ]; then
    sudo /usr/local/sbin/pinas-pull-update.sh
else
    echo "Pull update script not found. Run manual installation first."
    exit 1
fi
UPDATESCRIPT
        
        chmod +x /tmp/pinas-auto-update.sh
        sudo mv /tmp/pinas-auto-update.sh /usr/local/bin/pinas-update
        
        echo "✅ Deploy key setup complete!"
        echo "Test with: pinas-update"
EOF
    
    echo "✅ Deploy key configuration successful!"
    echo
    
else
    echo "❌ No SSH access available. Using manual method..."
    echo
    echo "Method 2: Manual Setup Instructions"
    echo "==================================="
    echo
    echo "Please copy and run these commands on your piNAS:"
    echo
    echo "1. First, create the SSH directory and copy the key:"
    echo
    cat << EOF
# On your piNAS (192.168.1.226):
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Copy this private key content to ~/.ssh/pinas_deploy_key:
# (Use nano ~/.ssh/pinas_deploy_key and paste the content)
$(cat "$DEPLOY_KEY_PRIVATE")

# Set permissions:
chmod 600 ~/.ssh/pinas_deploy_key
EOF
    echo
    echo "2. Configure SSH for GitHub access:"
    echo
    cat << 'EOF'
# Add GitHub SSH config:
cat >> ~/.ssh/config << 'SSHCONF'

# GitHub Deploy Key for piNAS
Host github.com
    HostName github.com  
    User git
    IdentityFile ~/.ssh/pinas_deploy_key
    IdentitiesOnly yes
SSHCONF
EOF
    echo
    echo "3. Test GitHub access:"
    echo "ssh -T git@github.com"
    echo
    echo "4. Create update command:"
    echo
    cat << 'EOF'
# Create update wrapper
sudo tee /usr/local/bin/pinas-update << 'UPDATESCRIPT'
#!/bin/bash
set -euo pipefail

# Pull-based update using deploy key
REPO_URL="git@github.com:Bruteforce-Group/piNAS.git" 
CLONE_DIR="/tmp/pinas-update-$$"

git clone "$REPO_URL" "$CLONE_DIR"
cd "$CLONE_DIR"

# Copy new pull update script
sudo cp sbin/pinas-pull-update.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/pinas-pull-update.sh

# Run the full update
sudo /usr/local/sbin/pinas-pull-update.sh

rm -rf "$CLONE_DIR"
UPDATESCRIPT

sudo chmod +x /usr/local/bin/pinas-update
EOF
    echo
    echo "5. Test the update system:"
    echo "pinas-update"
    echo
fi

echo "🎉 Setup Guide Complete!"
echo "======================="
echo
echo "Your piNAS can now pull updates directly from GitHub!"
echo
echo "Usage:"
echo "• Manual update: pinas-update"
echo "• Check logs: tail -f /var/log/pinas-pull-update.log"
echo "• Automatic updates can be set up with cron or systemd timers"
echo
echo "This eliminates the need for SSH access from GitHub Actions!"
echo "The piNAS will pull updates instead of receiving pushes."