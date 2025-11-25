#!/bin/bash
set -euo pipefail

# piNAS Pull-Based Update Script
# This script runs ON the piNAS to pull updates from GitHub
# Can be triggered via webhook, cron, or manual execution

REPO_URL="git@github.com:Bruteforce-Group/piNAS.git"
CLONE_DIR="/tmp/pinas-update-$$"
INSTALL_DIR="/usr/local/pinas"
BACKUP_DIR="/usr/local/pinas-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/pinas-pull-update.log"

# Logging function
log() {
    local level=$1
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    if [ -d "$CLONE_DIR" ]; then
        rm -rf "$CLONE_DIR"
    fi
}

trap cleanup EXIT

log "INFO" "Starting piNAS pull update process..."

# Check if we have git access
if ! ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    error_exit "GitHub SSH access not configured. Please set up deploy key."
fi

# Clone the latest repository
log "INFO" "Cloning repository from $REPO_URL..."
if ! git clone "$REPO_URL" "$CLONE_DIR"; then
    error_exit "Failed to clone repository"
fi

cd "$CLONE_DIR"

# Get the current version
CURRENT_VERSION="unknown"
if [ -f "$INSTALL_DIR/VERSION" ]; then
    CURRENT_VERSION=$(cat "$INSTALL_DIR/VERSION")
fi

# Get the new version
NEW_VERSION=$(cat VERSION 2>/dev/null || echo "dev-$(git rev-parse --short HEAD)")

log "INFO" "Current version: $CURRENT_VERSION"
log "INFO" "New version: $NEW_VERSION"

# Check if update is needed
if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
    log "INFO" "Already up to date. No update needed."
    exit 0
fi

# Create backup of current installation
if [ -d "$INSTALL_DIR" ]; then
    log "INFO" "Creating backup at $BACKUP_DIR..."
    cp -r "$INSTALL_DIR" "$BACKUP_DIR"
fi

# Create installation directory
mkdir -p "$INSTALL_DIR"

# Copy new files
log "INFO" "Installing new version $NEW_VERSION..."
cp -r sbin/ "$INSTALL_DIR/"
cp -r boot/ "$INSTALL_DIR/" 2>/dev/null || true
cp -r scripts/ "$INSTALL_DIR/" 2>/dev/null || true
cp -r docs/ "$INSTALL_DIR/" 2>/dev/null || true
cp VERSION "$INSTALL_DIR/" 2>/dev/null || true
cp CHECKSUMS.sha256 "$INSTALL_DIR/" 2>/dev/null || true

# Update scripts in system locations
log "INFO" "Updating system scripts..."
cp "$INSTALL_DIR/sbin/pinas-install.sh" /usr/local/sbin/ 2>/dev/null || true
cp "$INSTALL_DIR/sbin/pinas-cache-deps.sh" /usr/local/sbin/ 2>/dev/null || true
cp "$INSTALL_DIR/sbin/pinas-update.sh" /usr/local/sbin/ 2>/dev/null || true
cp "$INSTALL_DIR/sbin/pinas-upgrade-usb.sh" /usr/local/sbin/ 2>/dev/null || true
cp "$INSTALL_DIR/sbin/pinas-pull-update.sh" /usr/local/sbin/ 2>/dev/null || true
chmod +x /usr/local/sbin/pinas-*.sh 2>/dev/null || true

# Verify installation
log "INFO" "Verifying installation..."
if ! bash -n /usr/local/sbin/pinas-install.sh; then
    error_exit "New installation failed syntax check"
fi

# Update services if needed
if systemctl is-active --quiet pinas-dashboard.service; then
    log "INFO" "Restarting dashboard service..."
    systemctl restart pinas-dashboard.service
fi

log "INFO" "Update completed successfully!"
log "INFO" "Updated from $CURRENT_VERSION to $NEW_VERSION"

# Clean up old backups (keep last 5)
if ls /usr/local/pinas-backup-* &>/dev/null; then
    log "INFO" "Cleaning up old backups..."
    ls -1t /usr/local/pinas-backup-* | tail -n +6 | xargs rm -rf 2>/dev/null || true
fi

log "INFO" "piNAS update process complete"