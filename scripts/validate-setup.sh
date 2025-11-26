#!/usr/bin/env bash
set -euo pipefail

# piNAS Setup Validation Script
# Validates that all components are properly configured

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0
WARN=0

# Helper functions
check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARN++))
}

echo -e "${BLUE}=== piNAS Setup Validation ===${NC}\n"

# Check 1: .env file exists and is configured
echo -e "${BLUE}Checking environment configuration...${NC}"
if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source .env
    check_pass ".env file exists"

    if [[ -n "${WORKER_URL:-}" ]] && [[ "$WORKER_URL" != *"YOUR_ACCOUNT"* ]]; then
        check_pass "WORKER_URL is configured"
    else
        check_fail "WORKER_URL is not configured in .env"
    fi

    if [[ -n "${WORKER_ADMIN_TOKEN:-}" ]] && [[ "$WORKER_ADMIN_TOKEN" != "generate-with"* ]]; then
        check_pass "WORKER_ADMIN_TOKEN is configured"
    else
        check_fail "WORKER_ADMIN_TOKEN is not configured in .env"
    fi

    if [[ -n "${PINAS_R2_BUCKET:-}" ]]; then
        check_pass "PINAS_R2_BUCKET is configured"
    else
        check_fail "PINAS_R2_BUCKET is not configured in .env"
    fi
else
    check_fail ".env file not found - run ./setup-dev-env.sh"
fi

echo ""

# Check 2: boot/user-data configuration
echo -e "${BLUE}Checking boot configuration...${NC}"
if [[ -f boot/user-data ]]; then
    check_pass "boot/user-data exists"

    if grep -q "YOUR_WIFI_SSID" boot/user-data; then
        check_fail "WiFi not configured in boot/user-data"
    else
        # Check if WiFi network section is uncommented
        if grep -q "^\s*ssid=" boot/user-data 2>/dev/null; then
            check_pass "WiFi appears to be configured"
        else
            check_warn "WiFi section may be commented out"
        fi
    fi
else
    check_fail "boot/user-data not found - run ./setup-dev-env.sh"
fi

if [[ -f boot/user-data.example ]]; then
    check_pass "boot/user-data.example template exists"
else
    check_warn "boot/user-data.example template missing"
fi

echo ""

# Check 3: Cloudflare Worker infrastructure
echo -e "${BLUE}Checking Cloudflare Worker...${NC}"
if [[ -d infra/cloudflare ]]; then
    check_pass "Cloudflare Worker directory exists"

    if [[ -d infra/cloudflare/node_modules ]]; then
        check_pass "Worker dependencies installed"
    else
        check_fail "Worker dependencies not installed - run: cd infra/cloudflare && npm install"
    fi

    if [[ -f infra/cloudflare/wrangler.toml ]]; then
        check_pass "wrangler.toml exists"

        if grep -q "00000000-0000-0000-0000-000000000000" infra/cloudflare/wrangler.toml; then
            check_fail "wrangler.toml contains placeholder IDs - need to create KV namespace and R2 bucket"
        else
            check_pass "wrangler.toml appears configured"
        fi
    else
        check_fail "wrangler.toml not found"
    fi
else
    check_fail "infra/cloudflare directory not found"
fi

echo ""

# Check 4: Scripts are executable
echo -e "${BLUE}Checking scripts...${NC}"
for script in scripts/manage-clients.sh scripts/setup-sdcard.sh scripts/publish-artifact.sh sbin/pinas-install.sh sbin/pinas-update.sh; do
    if [[ -f "$script" ]]; then
        if [[ -x "$script" ]]; then
            check_pass "$script is executable"
        else
            check_warn "$script is not executable - run: chmod +x $script"
        fi
    else
        check_fail "$script not found"
    fi
done

echo ""

# Check 5: Required commands available
echo -e "${BLUE}Checking required commands...${NC}"
commands=("wrangler" "npm" "ssh" "jq" "tar" "shasum")
for cmd in "${commands[@]}"; do
    if command -v "$cmd" &> /dev/null; then
        check_pass "$cmd command available"
    else
        if [[ "$cmd" == "wrangler" ]]; then
            check_fail "$cmd not found - install: npm install -g wrangler"
        else
            check_warn "$cmd not found - some features may not work"
        fi
    fi
done

echo ""

# Check 6: SSH key configuration
echo -e "${BLUE}Checking SSH configuration...${NC}"
if [[ -n "${PINAS_SSH_KEY:-}" ]]; then
    if [[ -f "$PINAS_SSH_KEY" ]]; then
        check_pass "SSH key exists at $PINAS_SSH_KEY"

        if [[ -f "$PINAS_SSH_KEY.pub" ]]; then
            check_pass "SSH public key exists"
        else
            check_warn "SSH public key not found at $PINAS_SSH_KEY.pub"
        fi
    else
        check_fail "SSH key not found at $PINAS_SSH_KEY"
    fi
else
    check_warn "PINAS_SSH_KEY not set in .env"
fi

echo ""

# Check 7: Client registry
echo -e "${BLUE}Checking client registry...${NC}"
if [[ -f clients.json ]]; then
    check_pass "clients.json exists"

    if command -v jq &> /dev/null; then
        client_count=$(jq '. | length' clients.json)
        if [[ $client_count -gt 0 ]]; then
            check_pass "$client_count client(s) registered"
        else
            check_warn "No clients registered yet"
        fi
    fi
else
    check_warn "clients.json not found - will be created when adding first client"
fi

echo ""

# Check 8: Documentation
echo -e "${BLUE}Checking documentation...${NC}"
docs=(
    "README.md"
    "SETUP-CHECKLIST.md"
    "docs/deployment-setup.md"
    "docs/client-config.md"
)

for doc in "${docs[@]}"; do
    if [[ -f "$doc" ]]; then
        check_pass "$doc exists"
    else
        check_warn "$doc not found"
    fi
done

echo ""

# Check 9: Git status
echo -e "${BLUE}Checking git status...${NC}"
if git rev-parse --git-dir > /dev/null 2>&1; then
    check_pass "Git repository detected"

    # Check for uncommitted changes
    if [[ -n $(git status --porcelain) ]]; then
        check_warn "Uncommitted changes detected"
        echo -e "${YELLOW}  Run 'git status' to see details${NC}"
    else
        check_pass "No uncommitted changes"
    fi

    # Check if on a branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -n "$branch" ]]; then
        check_pass "On branch: $branch"
    fi
else
    check_warn "Not a git repository"
fi

echo ""

# Summary
echo -e "${BLUE}=== Summary ===${NC}\n"
echo -e "${GREEN}Passed:${NC}  $PASS"
echo -e "${RED}Failed:${NC}  $FAIL"
echo -e "${YELLOW}Warnings:${NC} $WARN"

echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}✓ Setup validation passed!${NC}"
    if [[ $WARN -gt 0 ]]; then
        echo -e "${YELLOW}  Note: $WARN warning(s) detected but not critical${NC}"
    fi
    echo -e "\n${BLUE}Next steps:${NC}"
    echo "1. Deploy Worker: cd infra/cloudflare && npm run deploy"
    echo "2. Add clients: ./scripts/manage-clients.sh add <ip> [hostname]"
    echo "3. Publish artifact: ./scripts/publish-artifact.sh"
    echo "4. Prepare SD card: ./scripts/setup-sdcard.sh"
    exit 0
else
    echo -e "${RED}✗ Setup validation failed with $FAIL error(s)${NC}"
    echo -e "\n${YELLOW}Fix the errors above and run this script again.${NC}"
    echo -e "For help, see: ${BLUE}docs/deployment-setup.md${NC}"
    exit 1
fi
