#!/bin/bash
set -euo pipefail

# piNAS Client Management Script
# Manages client configurations, SSH keys, and deployment automation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENTS_FILE="$REPO_ROOT/clients.json"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/deploy.yml"
DEPLOY_KEY_PATH="$HOME/.ssh/pinas_deploy"
DEPLOY_KEY_PUB="$HOME/.ssh/pinas_deploy.pub"

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
    setup-key <ip|hostname>  Set up SSH key on a specific client
    test <ip|hostname>       Test SSH connection to a client
    status                   Show overall deployment status
    sync-workflow           Update GitHub Actions workflow with current clients
    show-public-key         Display the public deployment key

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
    print(f\"Deployment key: {data.get('deployment_key_fingerprint', 'Not set')}\")
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
import sys
from datetime import datetime

try:
    with open('$CLIENTS_FILE', 'r') as f:
        data = json.load(f)
except:
    data = {'clients': [], 'last_updated': ''}

# Check if client already exists
for client in data['clients']:
    if client['ip'] == '$ip' or client['hostname'] == '$hostname':
        print(f'Client already exists: {client[\"hostname\"]} ({client[\"ip\"]})')
        sys.exit(1)

# Add new client
new_client = {
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

print(f'Added client: $hostname ($ip)')
"
    
    log SUCCESS "Client added: $hostname ($ip)"
    log INFO "Run '$0 setup-key $ip' to configure SSH access"
    log INFO "Run '$0 sync-workflow' to update deployment automation"
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
    
    log INFO "Setting up SSH key on $identifier..."
    log INFO "You may need to enter the pi user password"
    
    if ssh "pi@$identifier" "echo '$public_key' >> ~/.ssh/authorized_keys && echo 'SSH key added successfully'"; then
        log SUCCESS "SSH key setup complete for $identifier"
        
        # Update status in clients.json
        python3 -c "
import json
from datetime import datetime

try:
    with open('$CLIENTS_FILE', 'r') as f:
        data = json.load(f)
    
    for client in data['clients']:
        if client['ip'] == '$identifier' or client['hostname'] == '$identifier':
            client['status'] = 'active'
            break
    
    data['last_updated'] = datetime.now().isoformat() + 'Z'
    
    with open('$CLIENTS_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except:
    pass
"
        log INFO "Testing deployment key..."
        test_client "$identifier"
    else
        log ERROR "Failed to set up SSH key on $identifier"
        return 1
    fi
}

test_client() {
    local identifier="$1"
    
    ensure_deployment_key
    
    log INFO "Testing SSH connection to $identifier..."
    
    if ssh -i "$DEPLOY_KEY_PATH" -o ConnectTimeout=10 "pi@$identifier" "
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

sync_workflow() {
    if [ ! -f "$CLIENTS_FILE" ]; then
        log ERROR "No clients file found. Add clients first."
        return 1
    fi
    
    log INFO "Updating GitHub Actions workflow..."
    
    python3 - "$CLIENTS_FILE" "$WORKFLOW_FILE" <<'PY'
import json
import re
import sys

clients_file, workflow_file = sys.argv[1:]

with open(clients_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)

entries = []
for client in data.get("clients", []):
    if client.get("deployment_type") != "ssh":
        continue
    if client.get("status") != "active":
        continue
    target = client.get("hostname") if client.get("ip") == "auto" else client.get("ip")
    if target:
        entries.append(f'          - "{target}"')

block = ("\n".join(entries) + "\n") if entries else ""

with open(workflow_file, "r", encoding="utf-8") as fh:
    content = fh.read()

pattern = r'(        client:\n)(?:[\s\S]*?)(\n\s+# Add more LOCAL clients as needed:)'

def repl(match):
    return match.group(1) + block + match.group(2)

updated, count = re.subn(pattern, repl, content, count=1)
if count == 0:
    raise SystemExit("Unable to locate client matrix in workflow file")

with open(workflow_file, "w", encoding="utf-8") as fh:
    fh.write(updated)

print(f"Updated workflow file with {len(entries)} active SSH clients")
PY
    
    log SUCCESS "Updated GitHub Actions workflow with active SSH clients"
    log INFO "Commit and push changes to deploy to all clients:"
    log INFO "  git add . && git commit -m 'update: sync client deployment list' && git push origin main"
}

show_public_key() {
    ensure_deployment_key
    
    echo
    echo "🔑 piNAS Deployment Public Key:"
    echo "==============================="
    cat "$DEPLOY_KEY_PUB"
    echo
    echo "Add this key to GitHub repository secrets as PINAS_SSH_PRIVATE_KEY:"
    echo "https://github.com/Bruteforce-Group/piNAS/settings/secrets/actions"
    echo
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
    
    # Check workflow file
    if [ -f "$WORKFLOW_FILE" ]; then
        echo "✅ GitHub Actions workflow: Ready"
    else
        echo "❌ GitHub Actions workflow: Missing"
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
    "sync-workflow"|"sync")
        sync_workflow
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