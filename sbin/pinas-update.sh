#!/bin/bash
set -euo pipefail

# piNAS Client Update Script (Cloudflare Worker + R2 backed)
# Polls the deployment Worker for the latest artifact and installs it locally.

INSTALL_DIR="/usr/local/pinas"
BACKUP_DIR="/usr/local/pinas-backup"
TEMP_DIR="/tmp/pinas-update"
LOG_FILE="/var/log/pinas-update.log"
CONFIG_FILE="/etc/pinas/update-endpoint.env"
STATE_FILE="$TEMP_DIR/state.json"

# Ensure logging directory exists and mirror all output to the log file.
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==== piNAS Update Check Starting at $(date) ===="

usage() {
    cat <<'USAGE'
Usage: pinas-update [OPTIONS]

Options:
  --check-only        Query the Worker but do not install anything.
  --force             Install even if the reported version matches.
  --version VERSION   Request a specific version (must exist in R2).
  --help              Show this help text.
USAGE
}

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
        --help|-h)
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

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Missing required command '$1'" >&2
        exit 1
    fi
}

safe_sha256() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        sha256sum "$file" | awk '{print $1}'
    fi
}

load_worker_config() {
    if [ ! -r "$CONFIG_FILE" ]; then
        echo "ERROR: Missing worker config at $CONFIG_FILE" >&2
        echo "Create it via scripts/manage-clients.sh setup-key <client>."
        exit 1
    fi

    # Validate config file permissions for security
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config file not found: $CONFIG_FILE" >&2
        exit 1
    fi

    # Check file permissions (should be 600 or 640)
    if command -v stat >/dev/null 2>&1; then
        config_perms=$(stat -f%Lp "$CONFIG_FILE" 2>/dev/null || stat -c%a "$CONFIG_FILE" 2>/dev/null || echo "unknown")
        if [ "$config_perms" != "600" ] && [ "$config_perms" != "640" ] && [ "$config_perms" != "unknown" ]; then
            echo "WARNING: $CONFIG_FILE has permissions $config_perms (should be 600)" >&2
            echo "  Run: sudo chmod 600 $CONFIG_FILE" >&2
        fi
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    WORKER_URL="${WORKER_URL:-${PINAS_WORKER_URL:-}}"
    CLIENT_ID="${CLIENT_ID:-${PINAS_CLIENT_ID:-}}"
    CLIENT_TOKEN="${CLIENT_TOKEN:-${PINAS_CLIENT_TOKEN:-}}"

    if [ -z "$WORKER_URL" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_TOKEN" ]; then
        echo "ERROR: WORKER_URL, CLIENT_ID, and CLIENT_TOKEN must be set in $CONFIG_FILE" >&2
        exit 1
    fi

    # Normalise URL (drop trailing slash)
    WORKER_URL="${WORKER_URL%/}"
}

build_state_payload() {
    python3 - "$1" "$2" <<'PY'
import json
import sys
payload = {"currentVersion": sys.argv[1]}
if len(sys.argv) > 2 and sys.argv[2]:
    payload["desiredVersion"] = sys.argv[2]
print(json.dumps(payload))
PY
}

request_worker_state() {
    local payload
    payload="$(build_state_payload "$1" "$2")"

    # Use curl config file to avoid exposing credentials in process list
    curl -sfS -X POST "$WORKER_URL/client/state" \
        -K <(cat <<EOF
-H "Content-Type: application/json"
-H "X-Client-Id: $CLIENT_ID"
-H "X-Client-Token: $CLIENT_TOKEN"
EOF
        ) \
        -d "$payload" > "$STATE_FILE"
}

parse_state_field() {
    python3 - "$STATE_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)
latest = data.get('latest') or {}
print('true' if data.get('updateAvailable') else 'false')
print(latest.get('version', ''))
print(data.get('downloadPath') or '')
print(latest.get('sha256') or '')
print(str(latest.get('size') or ''))
print(str(data.get('pollIntervalSeconds') or ''))
PY
}

download_update() {
    local version="$1"
    local download_url="$2"
    local expected_sha="$3"

    if [ -z "$download_url" ]; then
        echo "ERROR: Worker did not return a download URL" >&2
        exit 1
    fi

    mkdir -p "$TEMP_DIR"
    local archive="$TEMP_DIR/pinas-$version.tar.gz"

    echo "Downloading piNAS $version from worker..."
    curl -fSL "$download_url" \
        -H "X-Client-Id: $CLIENT_ID" \
        -H "X-Client-Token: $CLIENT_TOKEN" \
        -o "$archive"

    if [ -n "$expected_sha" ]; then
        local actual_sha
        actual_sha="$(safe_sha256 "$archive")"
        if [ "$actual_sha" != "$expected_sha" ]; then
            echo "ERROR: SHA mismatch (expected $expected_sha, got $actual_sha)" >&2
            exit 1
        fi
    fi

    echo "Extracting package..."
    tar -xzf "$archive" -C "$TEMP_DIR"

    if [ ! -f "$TEMP_DIR/pinas-$version/VERSION" ]; then
        echo "ERROR: Extracted package missing VERSION file" >&2
        exit 1
    fi
}

create_backup() {
    if [ -d "$INSTALL_DIR" ]; then
        local dest="$BACKUP_DIR-$(date +%Y%m%d-%H%M%S)"
        echo "Creating backup at $dest..."
        sudo cp -r "$INSTALL_DIR" "$dest"
    fi
}

apply_update() {
    local version="$1"
    local package_dir="$TEMP_DIR/pinas-$version"

    echo "Applying update to piNAS $version..."
    create_backup

    echo "Stopping piNAS services..."
    sudo systemctl stop pinas-dashboard.service 2>/dev/null || true
    sudo systemctl stop pinas-usb-gadget.service 2>/dev/null || true

    sudo mkdir -p "$INSTALL_DIR"
    sudo cp -r "$package_dir"/* "$INSTALL_DIR"/

    echo "Updating system scripts..."
    sudo cp "$INSTALL_DIR/sbin/pinas-install.sh" /usr/local/sbin/
    sudo cp "$INSTALL_DIR/sbin/pinas-cache-deps.sh" /usr/local/sbin/
    sudo cp "$INSTALL_DIR/sbin/pinas-update.sh" /usr/local/sbin/
    sudo chmod +x /usr/local/sbin/pinas-*.sh

    echo "Verifying installation..."
    bash -n /usr/local/sbin/pinas-install.sh
    bash -n /usr/local/sbin/pinas-cache-deps.sh

    echo "Restarting piNAS services..."
    sudo systemctl start pinas-dashboard.service 2>/dev/null || true
    sudo systemctl start pinas-usb-gadget.service 2>/dev/null || true

    echo "Update applied successfully!"
    echo "New version: $(cat "$INSTALL_DIR/VERSION")"
    echo "Build date: $(cat "$INSTALL_DIR/BUILD_DATE")"
}

cleanup() {
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

main() {
    require_command curl
    require_command python3
    require_command tar
    load_worker_config

    local current_version target_version download_path sha size poll_interval download_url state_values

    current_version="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")"
    echo "Current piNAS version: $current_version"

    mkdir -p "$TEMP_DIR"
    request_worker_state "$current_version" "$SPECIFIC_VERSION"

    mapfile -t state_values < <(parse_state_field)
    local update_available="${state_values[0]}"
    target_version="${state_values[1]}"
    download_path="${state_values[2]}"
    sha="${state_values[3]}"
    size="${state_values[4]}"
    poll_interval="${state_values[5]}"

    if [ -z "$target_version" ] && [ -n "$SPECIFIC_VERSION" ]; then
        target_version="$SPECIFIC_VERSION"
        download_path="/artifact?objectKey=${target_version}/pinas-${target_version}.tar.gz"
    fi

    if [ -z "$target_version" ]; then
        echo "ERROR: Worker did not return a target version" >&2
        exit 1
    fi

    if [[ "$download_path" =~ ^https?:// ]]; then
        download_url="$download_path"
    else
        download_url="$WORKER_URL$download_path"
    fi

    echo "Worker reports latest version: $target_version"
    if [ -n "$size" ]; then
        echo "Package size: $size bytes"
    fi
    if [ -n "$poll_interval" ]; then
        echo "Recommended poll interval: $poll_interval seconds"
    fi

    if [ "$update_available" != "true" ] && [ "$FORCE_UPDATE" = "false" ]; then
        echo "piNAS is already up to date."
        exit 0
    fi

    if [ "$CHECK_ONLY" = "true" ]; then
        if [ "$update_available" = "true" ]; then
            echo "Update available: $current_version → $target_version"
            exit 1
        fi
        echo "No updates available"
        exit 0
    fi

    download_update "$target_version" "$download_url" "$sha"
    apply_update "$target_version"

    echo "piNAS successfully updated to version $target_version"
    echo "==== piNAS Update Check Completed at $(date) ====="
}

if ! ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
    echo "WARNING: Could not reach 1.1.1.1. Continuing with Worker request." >&2
fi

main "$@"
