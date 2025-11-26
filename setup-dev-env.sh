#!/usr/bin/env bash
set -euo pipefail

# piNAS Development Environment Setup Script
# This script helps you set up your local development environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== piNAS Development Environment Setup ===${NC}\n"

# Check if .env exists
if [[ ! -f .env ]]; then
    echo -e "${YELLOW}No .env file found. Creating from template...${NC}"
    cp .env.example .env
    echo -e "${GREEN}✓ Created .env from template${NC}"
    echo -e "${YELLOW}⚠ Please edit .env and add your Cloudflare credentials${NC}\n"
fi

# Check if user-data exists in boot/
if [[ ! -f boot/user-data ]]; then
    echo -e "${YELLOW}No boot/user-data file found. Creating from template...${NC}"
    cp boot/user-data.example boot/user-data
    echo -e "${GREEN}✓ Created boot/user-data from template${NC}"
    echo -e "${YELLOW}⚠ Please edit boot/user-data and configure your WiFi settings${NC}\n"
fi

# Source .env
if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source .env
    echo -e "${GREEN}✓ Loaded environment variables from .env${NC}\n"
fi

# Check Cloudflare Worker infrastructure
echo -e "${BLUE}Checking Cloudflare infrastructure...${NC}"

if [[ ! -d infra/cloudflare/node_modules ]]; then
    echo -e "${YELLOW}Installing Cloudflare Worker dependencies...${NC}"
    cd infra/cloudflare
    npm install
    cd "$SCRIPT_DIR"
    echo -e "${GREEN}✓ Installed Worker dependencies${NC}"
else
    echo -e "${GREEN}✓ Worker dependencies already installed${NC}"
fi

# Check wrangler.toml for placeholder IDs
if grep -q "00000000-0000-0000-0000-000000000000" infra/cloudflare/wrangler.toml; then
    echo -e "${YELLOW}⚠ wrangler.toml contains placeholder IDs${NC}"
    echo -e "${YELLOW}  You need to create Cloudflare resources and update the IDs${NC}\n"
else
    echo -e "${GREEN}✓ wrangler.toml appears configured${NC}"
fi

# Check for SSH key
if [[ -n "${PINAS_SSH_KEY:-}" ]]; then
    if [[ -f "$PINAS_SSH_KEY" ]]; then
        echo -e "${GREEN}✓ SSH key found at $PINAS_SSH_KEY${NC}"
    else
        echo -e "${YELLOW}⚠ SSH key not found at $PINAS_SSH_KEY${NC}"
        echo -e "${YELLOW}  Run: ssh-keygen -t ed25519 -f $PINAS_SSH_KEY -C 'pinas-deploy'${NC}"
    fi
fi

# Print setup checklist
echo -e "\n${BLUE}=== Setup Checklist ===${NC}\n"

checklist=(
    "Edit .env with your Cloudflare credentials"
    "Edit boot/user-data with your WiFi settings"
    "Create Cloudflare KV namespace: cd infra/cloudflare && wrangler kv namespace create CLIENTS"
    "Create Cloudflare R2 bucket: wrangler r2 bucket create pinas-artifacts"
    "Update infra/cloudflare/wrangler.toml with real KV and R2 IDs"
    "Generate admin token: cd infra/cloudflare && wrangler secret put ADMIN_TOKEN"
    "Deploy Worker: cd infra/cloudflare && npm run deploy"
    "Generate SSH key if needed: ssh-keygen -t ed25519 -f ~/.ssh/pinas-deploy-key"
)

for item in "${checklist[@]}"; do
    echo -e "${YELLOW}☐${NC} $item"
done

echo -e "\n${BLUE}=== Quick Commands ===${NC}\n"
echo "Deploy Worker:           cd infra/cloudflare && npm run deploy"
echo "Add a client:            ./scripts/manage-clients.sh add <ip> [hostname]"
echo "Publish an artifact:     ./scripts/publish-artifact.sh --version v2025.11.26.01"
echo "Prepare SD card:         ./scripts/setup-sdcard.sh"
echo "Test client connection:  ./scripts/manage-clients.sh test <ip>"

echo -e "\n${GREEN}Setup script complete!${NC}"
echo -e "See ${BLUE}docs/deployment-setup.md${NC} for detailed instructions.\n"
