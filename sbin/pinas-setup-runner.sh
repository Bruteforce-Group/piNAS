#!/bin/bash
set -euo pipefail

# piNAS GitHub Actions Self-Hosted Runner Setup
# Allows remote piNAS clients to receive updates via GitHub Actions runners

RUNNER_VERSION="2.311.0"
RUNNER_USER="${RUNNER_USER:-pi}"
RUNNER_DIR="/opt/pinas-runner"
SERVICE_NAME="pinas-github-runner"

echo "==== Setting up piNAS GitHub Actions Runner ===="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

# Function to get GitHub repository info
get_repo_info() {
    if [ -n "${GITHUB_REPOSITORY:-}" ]; then
        echo "$GITHUB_REPOSITORY"
    else
        echo "Bruteforce-Group/piNAS"
    fi
}

REPO=$(get_repo_info)
echo "Setting up runner for repository: $REPO"

# Check if GitHub CLI is available for token generation
if ! command -v gh >/dev/null 2>&1; then
    echo "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update && apt-get install -y gh
fi

# Create runner user and directory
if ! id "$RUNNER_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$RUNNER_USER"
fi

mkdir -p "$RUNNER_DIR"
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

# Download and install GitHub Actions runner
cd "$RUNNER_DIR"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) RUNNER_ARCH="x64" ;;
    aarch64) RUNNER_ARCH="arm64" ;;
    armv7l) RUNNER_ARCH="arm" ;;
    *) 
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

echo "Downloading GitHub Actions runner for $RUNNER_ARCH..."
if [ ! -f "actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" ]; then
    wget -q "$RUNNER_URL"
fi

echo "Extracting runner..."
tar xzf "actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

# Install dependencies
./bin/installdependencies.sh

# Generate runner token (requires GitHub CLI authentication)
echo ""
echo "🔐 Runner Token Setup Required"
echo ""
echo "You need to authenticate with GitHub and generate a runner token."
echo "Run these commands manually:"
echo ""
echo "1. Authenticate with GitHub CLI:"
echo "   sudo -u $RUNNER_USER gh auth login"
echo ""
echo "2. Generate runner token:"
echo "   sudo -u $RUNNER_USER gh api repos/$REPO/actions/runners/registration-token --jq .token"
echo ""
echo "3. Configure the runner:"
echo "   sudo -u $RUNNER_USER ./config.sh --url https://github.com/$REPO --token YOUR_TOKEN --name pinas-\$(hostname) --labels pinas,remote"
echo ""
echo "4. Install as service:"
echo "   sudo ./svc.sh install $RUNNER_USER"
echo "   sudo ./svc.sh start"
echo ""

# Create helper script for easier setup
cat > /usr/local/sbin/pinas-runner-setup.sh << 'EOH'
#!/bin/bash
set -euo pipefail

RUNNER_DIR="/opt/pinas-runner"
RUNNER_USER="pi"
REPO="Bruteforce-Group/piNAS"

cd "$RUNNER_DIR"

echo "Setting up piNAS GitHub Actions Runner..."

# Check if already configured
if [ -f ".runner" ]; then
    echo "Runner already configured. Current status:"
    sudo systemctl status actions.runner.${REPO//\//.}.pinas-$(hostname).service || true
    exit 0
fi

echo "Please authenticate with GitHub first:"
sudo -u "$RUNNER_USER" gh auth login

echo "Generating registration token..."
TOKEN=$(sudo -u "$RUNNER_USER" gh api "repos/$REPO/actions/runners/registration-token" --jq .token)

echo "Configuring runner..."
sudo -u "$RUNNER_USER" ./config.sh \
    --url "https://github.com/$REPO" \
    --token "$TOKEN" \
    --name "pinas-$(hostname)" \
    --labels "pinas,remote,$(hostname)" \
    --work "_work" \
    --replace

echo "Installing as system service..."
sudo ./svc.sh install "$RUNNER_USER"
sudo ./svc.sh start

echo "✅ Runner setup complete!"
echo "Service status:"
sudo systemctl status "actions.runner.${REPO//\//.}.pinas-$(hostname).service"

echo ""
echo "The runner is now active and will receive deployment jobs for this piNAS client."
EOH

chmod +x /usr/local/sbin/pinas-runner-setup.sh

echo ""
echo "✅ Runner installation complete!"
echo ""
echo "Next steps:"
echo "1. Run: /usr/local/sbin/pinas-runner-setup.sh"
echo "2. Follow the authentication prompts"
echo "3. The runner will automatically receive updates from GitHub Actions"
echo ""
echo "The runner will appear in your repository at:"
echo "https://github.com/$REPO/settings/actions/runners"