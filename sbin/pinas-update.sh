#!/bin/bash
set -euo pipefail

# piNAS Client Update Script
# Checks for and applies updates from GitHub releases

GITHUB_REPO="Bruteforce-Group/piNAS"
GITHUB_API="https://api.github.com/repos/$GITHUB_REPO"
INSTALL_DIR="/usr/local/pinas"
BACKUP_DIR="/usr/local/pinas-backup"
TEMP_DIR="/tmp/pinas-update"
LOG_FILE="/var/log/pinas-update.log"

# Ensure logging directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Mirror all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==== piNAS Update Check Starting at $(date) ===="

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --check-only        Only check for updates, don't install
    --force            Force update even if versions match
    --version VERSION  Install specific version (tag name)
    --help             Show this help message

Examples:
    $0                 # Check for and install latest update
    $0 --check-only    # Only check if updates are available
    $0 --version v1.2.3 # Install specific version
    $0 --force         # Force reinstall current version
EOF
}

# Parse command line arguments
CHECK_ONLY=false
FORCE_UPDATE=false
SPECIFIC_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --force)
            FORCE_UPDATE=true
            shift
            ;;
        --version)
            SPECIFIC_VERSION="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Function to get current installed version
get_current_version() {
    if [ -f "$INSTALL_DIR/VERSION" ]; then
        cat "$INSTALL_DIR/VERSION"
    else
        echo "unknown"
    fi
}

# Function to get latest release from GitHub
get_latest_release() {
    curl -s "$GITHUB_API/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

# Function to get specific release info
get_release_info() {
    local version="$1"
    curl -s "$GITHUB_API/releases/tags/$version"
}

# Function to download and verify update package
download_update() {
    local version="$1"
    local download_url="https://github.com/$GITHUB_REPO/releases/download/$version/pinas-$version.tar.gz"
    
    echo "Downloading piNAS $version..."
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"
    
    if ! curl -L -o "pinas-$version.tar.gz" "$download_url"; then
        echo "ERROR: Failed to download update package"
        return 1
    fi
    
    echo "Extracting package..."
    if ! tar -xzf "pinas-$version.tar.gz"; then
        echo "ERROR: Failed to extract update package"
        return 1
    fi
    
    # Verify package integrity
    if [ ! -f "pinas-$version/VERSION" ]; then
        echo "ERROR: Invalid update package - missing VERSION file"
        return 1
    fi
    
    local package_version
    package_version=$(cat "pinas-$version/VERSION")
    if [ "$package_version" != "$version" ]; then
        echo "ERROR: Version mismatch - expected $version, got $package_version"
        return 1
    fi
    
    echo "Package verification successful"
    return 0
}

# Function to create backup
create_backup() {
    if [ -d "$INSTALL_DIR" ]; then
        local backup_path="$BACKUP_DIR-$(date +%Y%m%d-%H%M%S)"
        echo "Creating backup at $backup_path..."
        sudo cp -r "$INSTALL_DIR" "$backup_path"
        echo "Backup created successfully"
    fi
}

# Function to apply update
apply_update() {
    local version="$1"
    local package_dir="$TEMP_DIR/pinas-$version"
    
    echo "Applying update to piNAS $version..."
    
    # Create backup first
    create_backup
    
    # Stop services gracefully
    echo "Stopping piNAS services..."
    sudo systemctl stop pinas-dashboard.service 2>/dev/null || true
    sudo systemctl stop pinas-usb-gadget.service 2>/dev/null || true
    
    # Install new version
    sudo mkdir -p "$INSTALL_DIR"
    sudo cp -r "$package_dir"/* "$INSTALL_DIR"/
    
    # Update system scripts
    echo "Updating system scripts..."
    sudo cp "$INSTALL_DIR/sbin/pinas-install.sh" /usr/local/sbin/
    sudo cp "$INSTALL_DIR/sbin/pinas-cache-deps.sh" /usr/local/sbin/
    sudo cp "$INSTALL_DIR/sbin/pinas-update.sh" /usr/local/sbin/
    sudo chmod +x /usr/local/sbin/pinas-*.sh
    
    # Verify installation
    echo "Verifying installation..."
    if ! bash -n /usr/local/sbin/pinas-install.sh; then
        echo "ERROR: New installer script has syntax errors"
        return 1
    fi
    
    if ! bash -n /usr/local/sbin/pinas-cache-deps.sh; then
        echo "ERROR: New cache script has syntax errors"
        return 1
    fi
    
    # Restart services
    echo "Restarting piNAS services..."
    sudo systemctl start pinas-dashboard.service 2>/dev/null || true
    sudo systemctl start pinas-usb-gadget.service 2>/dev/null || true
    
    echo "Update applied successfully!"
    echo "New version: $(cat "$INSTALL_DIR/VERSION")"
    echo "Build date: $(cat "$INSTALL_DIR/BUILD_DATE")"
    
    return 0
}

# Function to cleanup temp files
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Main update logic
main() {
    local current_version
    local target_version
    
    current_version=$(get_current_version)
    echo "Current piNAS version: $current_version"
    
    if [ -n "$SPECIFIC_VERSION" ]; then
        target_version="$SPECIFIC_VERSION"
        echo "Target version (specified): $target_version"
    else
        echo "Checking for latest release..."
        target_version=$(get_latest_release)
        if [ -z "$target_version" ]; then
            echo "ERROR: Could not determine latest release version"
            exit 1
        fi
        echo "Latest available version: $target_version"
    fi
    
    # Check if update is needed
    if [ "$current_version" = "$target_version" ] && [ "$FORCE_UPDATE" = "false" ]; then
        echo "piNAS is already up to date (version $current_version)"
        exit 0
    fi
    
    if [ "$CHECK_ONLY" = "true" ]; then
        if [ "$current_version" != "$target_version" ]; then
            echo "Update available: $current_version → $target_version"
            exit 1  # Exit code 1 indicates update available
        else
            echo "No updates available"
            exit 0
        fi
    fi
    
    # Verify we can reach the release
    echo "Verifying release availability..."
    if [ -n "$SPECIFIC_VERSION" ]; then
        if ! get_release_info "$target_version" >/dev/null; then
            echo "ERROR: Release $target_version not found"
            exit 1
        fi
    fi
    
    # Check available disk space
    available_space=$(df / | tail -1 | awk '{print $4}')
    if [ "$available_space" -lt 500000 ]; then  # 500MB in KB
        echo "WARNING: Low disk space. Available: ${available_space}KB"
        echo "Update may fail. Consider freeing up space first."
    fi
    
    # Download and apply update
    if download_update "$target_version"; then
        if apply_update "$target_version"; then
            echo "piNAS successfully updated to version $target_version"
            echo "Update completed at $(date)"
        else
            echo "ERROR: Failed to apply update"
            exit 1
        fi
    else
        echo "ERROR: Failed to download update"
        exit 1
    fi
}

# Check if running as root (some operations require sudo)
if [ "$(id -u)" -eq 0 ]; then
    echo "WARNING: Running as root. This script should typically be run as pi user with sudo access."
fi

# Check internet connectivity
if ! ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
    echo "ERROR: No internet connectivity. Cannot check for updates."
    exit 1
fi

# Run main function
main "$@"

echo "==== piNAS Update Check Completed at $(date) ====="