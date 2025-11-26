#!/bin/bash
set -euo pipefail

# piNAS Client Management Script
# Manages client configurations, SSH keys, and deployment automation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENTS_FILE="$REPO_ROOT/clients.json"
DEPLOY_KEY_PATH="$HOME/.ssh/pinas_deploy"
DEPLOY_KEY_PUB="$HOME/.ssh/pinas_deploy.pub"
WORKER_URL="${WORKER_URL:-${PINAS_WORKER_URL:-}}"
WORKER_ADMIN_TOKEN="${WORKER_ADMIN_TOKEN:-${PINAS_WORKER_ADMIN_TOKEN:-}}"
CLIENT_CONFIG_PATH="${CLIENT_CONFIG_PATH:-/etc/pinas/update-endpoint.env}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    list                     List all configured piNAS clients
    add <ip> [hostname]      Add a new client to deployment list
    remove <ip|hostname>     Remove a client from deployment list  
    setup-key <ip|hostname>  Set up SSH key + Worker token on a client
    test <ip|hostname>       Test SSH connection to a client
    status                   Show overall deployment status
    show-public-key         Display the deployment SSH public key

Examples:
    $0 list
    $0 add 192.168.1.100 pinas-office
    $0 setup-key 192.168.1.226
    $0 test pinas.local
    $0 sync-workflow

EOF
}

log() {
    local level=$1
    shift
    case $level in
        ERROR) echo -e "${RED}[ERROR]${NC} $*" >&2 ;;
        SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} $*" ;;
        WARNING) echo -e "${YELLOW}[WARNING]${NC} $*" ;;
        INFO) echo -e "${BLUE}[INFO]${NC} $*" ;;
        *) echo "$*" ;;
    esac
}

ensure_deployment_key() {
    if [ ! -f "$DEPLOY_KEY_PATH" ]; then
        log WARNING "Deployment key not found. Generating new key..."
        ssh-keygen -t ed25519 -C "pinas-deployment@github.com" -f "$DEPLOY_KEY_PATH" -N ""
        log SUCCESS "Generated deployment key: $DEPLOY_KEY_PATH"
    fi
}

require_worker_settings() {
    if [ -z "$WORKER_URL" ] || [ -z "$WORKER_ADMIN_TOKEN" ]; then
        log ERROR "Set WORKER_URL and WORKER_ADMIN_TOKEN environment variables before provisioning clients."
        log INFO "Example: export WORKER_URL=https://pinas-deployer.example.workers.dev"
        log INFO "         export WORKER_ADMIN_TOKEN=<token>"
        exit 1
    fi
}

register_client_with_worker() {
    local client_id="$1"
    local display_name="$2"
    local token="$3"
    local notes="$4"

    require_worker_settings

    local payload
    payload=$(python3 - "$display_name" "$token" "$notes" <<'PY'
import json
import sys
display, token, notes = sys.argv[1:4]
data = {"displayName": display, "token": token}
if notes:
    data["notes"] = notes
print(json.dumps(data))
PY
)

    if ! curl -sfS -X PUT "$WORKER_URL/admin/clients/$client_id" \
        -H "Authorization: Bearer $WORKER_ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null; then
        return 1
    fi
}

push_client_config() {
    local identifier="$1"
    local client_id="$2"
    local token="$3"

    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "pi@$identifier" "sudo mkdir -p \"$(dirname "$CLIENT_CONFIG_PATH")\" && sudo tee $CLIENT_CONFIG_PATH >/dev/null <<EOF
WORKER_URL=\"$WORKER_URL\"
CLIENT_ID=\"$client_id\"
CLIENT_TOKEN=\"$token\"
EOF
sudo chmod 600 $CLIENT_CONFIG_PATH
" >/dev/null
}

get_client_by_ip_or_hostname() {
    local identifier="$1"
    python3 -c "
import json
import sys

try:
    with open('$CLIENTS_FILE', 'r') as f:
        data = json.load(f)
    
    for client in data['clients']:
        if client['ip'] == '$identifier' or client['hostname'] == '$identifier':
            print(json.dumps(client))
            sys.exit(0)
    
    sys.exit(1)
except:
    sys.exit(1)
"
}

list_clients() {
    if [ ! -f "$CLIENTS_FILE" ]; then
        log WARNING "No clients file found. No clients configured."
        return
    fi
    
    echo
    echo "📋 piNAS Client List:"
    echo "==================="
    
    python3 -c "
import json
import sys

try:
    with open('$CLIENTS_FILE', 'r') as f:
        data = json.load(f)
    
    for i, client in enumerate(data['clients'], 1):
        status_icon = '✅' if client['status'] == 'active' else '⏳' if client['status'] == 'pending_setup' else '❌'
        print(f\"{i}. {status_icon} {client['hostname']} ({client['ip']})\")
        print(f\"   Description: {client['description']}\")
        print(f\"   Type: {client['deployment_type']} | Status: {client['status']}\")
        print()
        
    print(f\"Last updated: {data.get('last_updated', 'Unknown')}\")
    fingerprint = data.get('deployment_key_fingerprint')
    if fingerprint:
        print(f\"Deployment key fingerprint: {fingerprint}\")
except Exception as e:
    print(f'Error reading clients file: {e}')
    sys.exit(1)
"
}

add_client() {
    local ip="$1"
    local hostname="${2:-pinas-$(echo "$ip" | tr '.' '-')}"
    local description="${3:-piNAS at $ip}"
    
    # Validate IP format
    if ! [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log ERROR "Invalid IP address format: $ip"
        return 1
    fi
    
    # Test if IP is reachable
    if ! ping -c 1 -W 3 "$ip" >/dev/null 2>&1; then
        log WARNING "IP $ip is not reachable. Adding anyway..."
    fi
    
    # Add to clients.json
    python3 -c "
import json
import re
import sys
from datetime import datetime

def slugify(value, existing_ids):
    base = re.sub(r'[^a-z0-9]+', '-', value.lower()).strip('-') or 'client'
    slug = base
    idx = 1
    while slug in existing_ids:
        slug = f'{base}-{idx}'
        idx += 1
    return slug

try:
    with open('$CLIENTS_FILE', 'r') as f:
        data = json.load(f)
except:
    data = {'clients': [], 'last_updated': ''}

existing_ids = {c.get('client_id') for c in data['clients'] if c.get('client_id')}

# Check if client already exists
for client in data['clients']:
    if client['ip'] == '$ip' or client['hostname'] == '$hostname':
        print(f'Client already exists: {client[\"hostname\"]} ({client[\"ip\"]})')
        sys.exit(1)

client_id = slugify('$hostname', existing_ids)

# Add new client
new_client = {
    'client_id': client_id,
    'hostname': '$hostname',
    'ip': '$ip',
    'description': '$description',
    'deployment_type': 'ssh',
    'added_date': datetime.now().strftime('%Y-%m-%d'),
    'status': 'pending_setup'
}

data['clients'].append(new_client)
data['last_updated'] = datetime.now().isoformat() + 'Z'

with open('$CLIENTS_FILE', 'w') as f:
    json.dump(data, f, indent=2)

print(f'Added client: $hostname ($ip) [client_id={client_id}]')
"    
    
    log SUCCESS "Client added: $hostname ($ip)"
    log INFO "Run '$0 setup-key $ip' to configure SSH access"
}

setup_key_on_client() {
    local identifier="$1"

    ensure_deployment_key

    if [ ! -f "$DEPLOY_KEY_PUB" ]; then
        log ERROR "Public key not found: $DEPLOY_KEY_PUB"
        return 1
    fi

    local public_key
    public_key=$(cat "$DEPLOY_KEY_PUB")

    local client_json client_id client_name client_notes
    client_json="$(get_client_by_ip_or_hostname "$identifier" || true)"
    if [ -n "$client_json" ]; then
        readarray -t client_meta < <(python3 <<'PY' <<<"$client_json"
import json
import sys
data = json.load(sys.stdin)
print(data.get("client_id", ""))
print(data.get("hostname") or data.get("ip") or "")
print(data.get("description") or "")
PY
)
        client_id="${client_meta[0]}"
        client_name="${client_meta[1]}"
        client_notes="${client_meta[2]}"
    fi

    if [ -z "$client_id" ]; then
        client_id=$(echo "${client_name:-$identifier}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')
        client_id="${client_id:-client-$(date +%s)}"
    fi

    log INFO "Setting up SSH key on $identifier..."
    log INFO "You may need to enter the pi user password"

    # Use StrictHostKeyChecking=accept-new to auto-accept new host keys
    # Stream the public key via stdin to avoid shell escaping issues
    if ! ssh -o StrictHostKeyChecking=accept-new "pi@$identifier" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'SSH key added successfully'" < "$DEPLOY_KEY_PUB"; then
        log ERROR "Failed to set up SSH key on $identifier"
        return 1
    fi

    log SUCCESS "SSH key setup complete for $identifier"

    local worker_token=""
    if [ -n "$WORKER_URL" ] && [ -n "$WORKER_ADMIN_TOKEN" ]; then
        if ! command -v openssl >/dev/null 2>&1; then
            log ERROR "openssl is required to generate client tokens"
            return 1
        fi

        worker_token="$(openssl rand -hex 32)"
        log INFO "Registering client $client_id with Cloudflare Worker..."
        if register_client_with_worker "$client_id" "${client_name:-$identifier}" "$worker_token" "$client_notes"; then
            log SUCCESS "Worker updated for client $client_id"
            log INFO "Pushing worker config to $CLIENT_CONFIG_PATH"
            push_client_config "$identifier" "$client_id" "$worker_token"
        else
            log ERROR "Failed to register client with Worker API"
            return 1
        fi
    else
        log WARNING "WORKER_URL / WORKER_ADMIN_TOKEN not set. Skipping worker provisioning."
    fi

    python3 -c "
import json
from datetime import datetime

try:
    with open('$CLIENTS_FILE', 'r') as f:
        data = json.load(f)

    for client in data['clients']:
        if client['ip'] == '$identifier' or client['hostname'] == '$identifier':
            client['status'] = 'active'
            client['client_id'] = client.get('client_id') or '$client_id'
            break

    data['last_updated'] = datetime.now().isoformat() + 'Z'

    with open('$CLIENTS_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except:
    pass
"

    log INFO "Testing deployment key..."
    test_client "$identifier"
}
}

test_client() {
    local identifier="$1"
    
    ensure_deployment_key
    
    log INFO "Testing SSH connection to $identifier..."
    
    if ssh -i "$DEPLOY_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "pi@$identifier" "
        echo '=== piNAS Connection Test ==='
        echo 'Hostname:' \$(hostname)
        echo 'Version:' \$(cat /usr/local/pinas/VERSION 2>/dev/null || echo 'Not installed')
        echo 'Dashboard:' \$(systemctl is-active pinas-dashboard.service 2>/dev/null || echo 'Not running')
        echo 'USB Gadget:' \$(systemctl is-active pinas-usb-gadget.service 2>/dev/null || echo 'Not running')
        echo 'Disk Usage:' \$(df -h / | tail -1 | awk '{print \$4\" free of \"\$2}')
        echo '=== Test Complete ==='
    "; then
        log SUCCESS "SSH connection successful to $identifier"
    else
        log ERROR "SSH connection failed to $identifier"
        log INFO "Run '$0 setup-key $identifier' to configure SSH access"
        return 1
    fi
}

show_public_key() {
    ensure_deployment_key
    
    echo
    echo "🔑 piNAS Deployment Public Key:"
    echo "==============================="
    cat "$DEPLOY_KEY_PUB"
    echo
    echo "Share this key only with trusted operator machines."
    echo "scripts/manage-clients.sh uses it to configure piNAS devices via SSH."
    echo "Private key location: $DEPLOY_KEY_PATH"
    echo "Public key location: $DEPLOY_KEY_PUB"
}

show_status() {
    echo
    echo "🚀 piNAS Deployment Status:"
    echo "=========================="
    
    # Check deployment key
    if [ -f "$DEPLOY_KEY_PATH" ]; then
        echo "✅ Deployment SSH key: Ready"
        echo "   Key: $(ssh-keygen -lf "$DEPLOY_KEY_PUB" 2>/dev/null || echo 'Invalid')"
    else
        echo "❌ Deployment SSH key: Missing"
        echo "   Run: $0 show-public-key"
    fi
    
    # Check clients file
    if [ -f "$CLIENTS_FILE" ]; then
        local active_count
        active_count=$(python3 -c "
import json
try:
    with open('$CLIENTS_FILE', 'r') as f:
        data = json.load(f)
    print(len([c for c in data['clients'] if c['status'] == 'active']))
except:
    print('0')
")
        echo "✅ Client configuration: $active_count active clients"
    else
        echo "❌ Client configuration: No clients configured"
    fi
    
    echo
    list_clients
}

# Main command handling
case "${1:-}" in
    "list"|"ls")
        list_clients
        ;;
    "add")
        if [ $# -lt 2 ]; then
            echo "Usage: $0 add <ip> [hostname] [description]"
            exit 1
        fi
        add_client "$2" "${3:-}" "${4:-}"
        ;;
    "remove"|"rm")
        log ERROR "Remove functionality not implemented yet"
        ;;
    "setup-key"|"setup")
        if [ $# -lt 2 ]; then
            echo "Usage: $0 setup-key <ip|hostname>"
            exit 1
        fi
        setup_key_on_client "$2"
        ;;
    "test")
        if [ $# -lt 2 ]; then
            echo "Usage: $0 test <ip|hostname>"
            exit 1
        fi
        test_client "$2"
        ;;
    "show-public-key"|"key")
        show_public_key
        ;;
    "status")
        show_status
        ;;
    "help"|"--help"|"-h"|"")
        show_usage
        ;;
    *)
        log ERROR "Unknown command: $1"
        show_usage
        exit 1
        ;;
esac